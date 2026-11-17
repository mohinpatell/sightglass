import Foundation
import IOKit

/// Power drawn by the parts of the chip that report it, in watts.
public struct ComponentPower: Equatable, Sendable {
    public let cpu: Double
    public let gpu: Double
    public let memory: Double

    public init(cpu: Double, gpu: Double, memory: Double) {
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
    }
}

// IOReport is a private Apple library. It is the only way to read these energy
// counters without root (powermetrics reads the same ones, but needs sudo).
@_silgen_name("IOReportCopyChannelsInGroup")
private func IOReportCopyChannelsInGroup(_ group: CFString?, _ subgroup: CFString?, _ a: UInt64, _ b: UInt64, _ c: UInt64) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSubscription")
private func IOReportCreateSubscription(_ a: UnsafeRawPointer?, _ desired: CFMutableDictionary, _ subscribed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, _ id: UInt64, _ b: CFTypeRef?) -> OpaquePointer?
@_silgen_name("IOReportCreateSamples")
private func IOReportCreateSamples(_ subscription: OpaquePointer?, _ channels: CFMutableDictionary?, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportCreateSamplesDelta")
private func IOReportCreateSamplesDelta(_ previous: CFDictionary, _ current: CFDictionary, _ a: CFTypeRef?) -> Unmanaged<CFDictionary>?
@_silgen_name("IOReportChannelGetChannelName")
private func IOReportChannelGetChannelName(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportChannelGetUnitLabel")
private func IOReportChannelGetUnitLabel(_ channel: CFDictionary) -> Unmanaged<CFString>?
@_silgen_name("IOReportSimpleGetIntegerValue")
private func IOReportSimpleGetIntegerValue(_ channel: CFDictionary, _ index: Int32) -> Int64

/// Reads the chip's cumulative energy counters and turns two readings into watts.
public final class PowerReader {
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var previous: CFDictionary?
    private var previousTime: UInt64 = 0

    /// Nil on Macs without these counters (Intel).
    public init?() {
        guard let group = IOReportCopyChannelsInGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let desired = CFDictionaryCreateMutableCopy(nil, 0, group) else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = IOReportCreateSubscription(nil, desired, &subscribed, 0, nil),
              let channels = subscribed?.takeUnretainedValue() else { return nil }
        self.subscription = subscription
        self.channels = channels
    }

    /// Returns nil on the first call, which only records a baseline.
    public func sample() -> ComponentPower? {
        guard let current = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer {
            previous = current
            previousTime = now
        }
        guard let previous,
              let delta = IOReportCreateSamplesDelta(previous, current, nil)?.takeRetainedValue() as NSDictionary?,
              let list = delta["IOReportChannels"] as? [NSDictionary] else { return nil }

        var cpu = 0.0, gpu = 0.0, memory = 0.0
        for case let channel as CFDictionary in list {
            guard let name = IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String? else { continue }
            let isMemory = name.hasPrefix("DRAM")
            guard name == "CPU Energy" || name == "GPU Energy" || isMemory else { continue }
            let unit = (IOReportChannelGetUnitLabel(channel)?.takeUnretainedValue() as String? ?? "")
                .trimmingCharacters(in: .whitespaces)
            let perJoule: Double
            switch unit {
            case "mJ": perJoule = 1e3
            case "uJ": perJoule = 1e6
            case "nJ": perJoule = 1e9
            default: continue
            }
            let joules = Double(IOReportSimpleGetIntegerValue(channel, 0)) / perJoule
            if isMemory { memory += joules } else if name == "CPU Energy" { cpu += joules } else { gpu += joules }
        }
        let seconds = Double(now - previousTime) / 1e9
        return ComponentPower(cpu: cpu / seconds, gpu: gpu / seconds, memory: memory / seconds)
    }
}

public struct BatteryState: Equatable, Sendable {
    public let onBattery: Bool
    /// Charge shown in the menu bar, 0 to 100.
    public let percent: Int
    public let remainingWattHours: Double
    public let fullWattHours: Double
    /// Power going out: whole machine draw as the battery controller reports it.
    /// macOS only refreshes this about every half minute.
    public let systemWatts: Double?
    /// Power coming in from the charger. Zero on battery, nil when not reported.
    public let adapterWatts: Double?

    public init(onBattery: Bool, percent: Int, remainingWattHours: Double,
                fullWattHours: Double, systemWatts: Double?, adapterWatts: Double?) {
        self.onBattery = onBattery
        self.percent = percent
        self.remainingWattHours = remainingWattHours
        self.fullWattHours = fullWattHours
        self.systemWatts = systemWatts
        self.adapterWatts = adapterWatts
    }

    /// In minus out. Positive means the battery is gaining charge. It can be negative
    /// while plugged in, when the Mac draws more than the charger supplies.
    public var netWatts: Double? {
        guard let adapterWatts, let systemWatts else { return nil }
        return adapterWatts - systemWatts
    }
}

/// Reads the battery controller's registry entry. Nil on a Mac without a battery.
public func readBattery() -> BatteryState? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let entry = properties?.takeRetainedValue() as? [String: Any] else { return nil }
    return batteryState(fromRegistry: entry)
}

/// Capacities are in mAh and voltage in mV, so their product over a million is Wh.
func batteryState(fromRegistry entry: [String: Any]) -> BatteryState? {
    func number(_ key: String, in dictionary: [String: Any]) -> Double? {
        (dictionary[key] as? NSNumber).map { Double($0.int64Value) }
    }
    guard let percent = number("CurrentCapacity", in: entry),
          let volts = number("Voltage", in: entry).map({ $0 / 1000 }),
          let remaining = number("AppleRawCurrentCapacity", in: entry),
          let full = number("AppleRawMaxCapacity", in: entry) else { return nil }
    let onBattery = (entry["ExternalConnected"] as? Bool) == false
    let telemetry = entry["PowerTelemetryData"] as? [String: Any]
    var systemWatts = telemetry.flatMap { number("SystemLoad", in: $0) }.map { $0 / 1000 }
    // Without telemetry, discharge current times voltage is the draw while on battery.
    if (systemWatts ?? 0) <= 0 {
        systemWatts = onBattery ? number("Amperage", in: entry).map { abs($0) / 1000 * volts } : nil
    }
    let adapterWatts = onBattery ? 0 : telemetry.flatMap { number("SystemPowerIn", in: $0) }.map { $0 / 1000 }
    return BatteryState(onBattery: onBattery, percent: Int(percent), remainingWattHours: remaining * volts / 1000,
                        fullWattHours: full * volts / 1000, systemWatts: systemWatts, adapterWatts: adapterWatts)
}

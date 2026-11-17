import CulpritCore
import Foundation
import Observation

/// One reading in the menu bar: its text and the SF Symbol that labels it. The symbol
/// is nil when the person chose plain dividers between readings instead.
struct MenuBarItem: Equatable {
    let symbol: String?
    let text: String
}

/// Samples on a background queue and publishes results on the main queue.
@Observable
final class Monitor {
    /// How much history the chart keeps, in seconds.
    static let historySeconds: TimeInterval = 600
    static let intervalChoices: [TimeInterval] = [1, 2, 5, 10]

    /// Seconds between samples while plugged in, and while on battery. Each sample is
    /// an average over the interval, so a longer one gives a calmer number and costs
    /// less energy, which only matters on battery.
    private(set) var intervalOnPower: TimeInterval
    private(set) var intervalOnBattery: TimeInterval
    private(set) var onBattery: Bool

    private(set) var latest: Snapshot?
    private(set) var history: [Snapshot] = []
    private(set) var spikes: [Spike]
    private(set) var currentSpike: Spike?
    private(set) var ledger = EnergyLedger()
    /// Which notifications the person asked for, and their limits. None are on by default.
    private(set) var alertSettings: AlertSettings

    /// Called on the main queue after every sample with the new menu bar readings.
    @ObservationIgnored var onHeadline: (([MenuBarItem]) -> Void)?

    @ObservationIgnored private var alertEngine = AlertEngine()
    @ObservationIgnored private var detector: SpikeDetector
    @ObservationIgnored private let store = SpikeStore()
    @ObservationIgnored private let timer: DispatchSourceTimer

    /// The interval in use right now.
    var interval: TimeInterval { onBattery ? intervalOnBattery : intervalOnPower }

    init() {
        UserDefaults.standard.register(defaults: ["menuBarCPU": true])
        func saved(_ key: String, fallback: TimeInterval) -> TimeInterval {
            let value = UserDefaults.standard.double(forKey: key)
            return Self.intervalChoices.contains(value) ? value : fallback
        }
        let onPower = saved("intervalOnPower", fallback: 1)
        let unplugged = saved("intervalOnBattery", fallback: 5)
        let startsOnBattery = readBattery()?.onBattery ?? false
        let seconds = startsOnBattery ? unplugged : onPower
        intervalOnPower = onPower
        intervalOnBattery = unplugged
        onBattery = startsOnBattery
        if let data = UserDefaults.standard.data(forKey: "alertSettings"),
           let saved = try? JSONDecoder().decode(AlertSettings.self, from: data) {
            alertSettings = saved
        } else {
            // The first version only stored which alerts were on.
            var settings = AlertSettings()
            let old = UserDefaults.standard.stringArray(forKey: "enabledAlerts") ?? []
            settings.enabled = Set(old.compactMap(AlertKind.init(rawValue:)))
            alertSettings = settings
        }
        detector = SpikeDetector(totalThreshold: 0.4 * cpuCount, interval: seconds)
        spikes = store.load()
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sampler", qos: .utility))
        timer.schedule(deadline: .now(), repeating: seconds, leeway: .milliseconds(100))

        let sampler = Sampler()
        let powerReader = PowerReader()
        let livePower = SMCPowerReader()
        var battery: BatteryState?
        var batteryReadAt = Date.distantPast
        timer.setEventHandler { [weak self] in
            let now = Date()
            let live = livePower?.read()
            // The battery registry is slow to read, so it is read every 5 seconds, or at
            // once when the live charger figure disagrees with it about being plugged in.
            let chargerSeen = live.map { $0.adapterWatts > 0.5 }
            if now.timeIntervalSince(batteryReadAt) >= 5 || (chargerSeen != nil && chargerSeen == battery?.onBattery) {
                battery = readBattery()
                batteryReadAt = now
            }
            // The registry's own power figures lag by up to half a minute. The live ones
            // update every second, which matters when chargers are swapped.
            var current = battery
            if let live, let battery {
                current = battery.replacingPower(systemWatts: live.systemWatts, adapterWatts: live.adapterWatts)
            }
            let power = powerReader?.sample()
            guard let sample = sampler.sample() else { return }
            let snap = snapshot(from: sample, at: now, power: power, battery: current, memory: readMemory())
            DispatchQueue.main.async { self?.apply(snap) }
        }
        timer.resume()
    }

    func setInterval(_ seconds: TimeInterval, onBattery forBattery: Bool) {
        if forBattery { intervalOnBattery = seconds } else { intervalOnPower = seconds }
        UserDefaults.standard.set(seconds, forKey: forBattery ? "intervalOnBattery" : "intervalOnPower")
        if forBattery == onBattery { reschedule() }
    }

    func setAlert(_ kind: AlertKind, on: Bool) {
        if on { Notifier.shared.requestPermission() }
        updateAlerts { if on { $0.enabled.insert(kind) } else { $0.enabled.remove(kind) } }
    }

    func updateAlerts(_ change: (inout AlertSettings) -> Void) {
        change(&alertSettings)
        UserDefaults.standard.set(try? JSONEncoder().encode(alertSettings), forKey: "alertSettings")
    }

    func sendTestAlert() {
        Notifier.shared.requestPermission()
        Notifier.shared.post(Alert(kind: .cpuHog, title: "Test alert from CPU Culprit",
                                   body: "If you can read this, alerts are working."), sound: alertSettings.sound)
    }

    private func reschedule() {
        detector.interval = interval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
    }

    /// Menu bar readings, empty before the first sample or when every one is switched
    /// off. They are chosen in the panel: CPU use, watts the Mac is using, and what the
    /// battery is gaining or losing.
    var headline: [MenuBarItem] {
        guard let latest else { return [] }
        let defaults = UserDefaults.standard
        let symbols = !defaults.bool(forKey: "menuBarDividers")
        var items: [MenuBarItem] = []
        if defaults.bool(forKey: "menuBarCPU") {
            items.append(MenuBarItem(symbol: symbols ? "cpu" : nil, text: totalPercent(latest.totalCores)))
        }
        if defaults.bool(forKey: "menuBarDraw"), let draw = latest.drawWatts {
            items.append(MenuBarItem(symbol: symbols ? "bolt.fill" : nil, text: watts(draw)))
        }
        if defaults.bool(forKey: "menuBarNet"), let net = latest.battery?.netWatts {
            items.append(MenuBarItem(symbol: symbols ? (net >= 0 ? "battery.100.bolt" : "battery.25") : nil,
                                     text: signedWatts(net)))
        }
        return items
    }

    /// Redraws the menu bar text now, for when its settings change between samples.
    func refreshHeadline() {
        onHeadline?(headline)
    }

    private func apply(_ snap: Snapshot) {
        if let unplugged = snap.battery?.onBattery, unplugged != onBattery {
            onBattery = unplugged
            reschedule()
        }
        latest = snap
        history.append(snap)
        history.removeAll { snap.time.timeIntervalSince($0.time) > Self.historySeconds }
        ledger.add(snap)
        if let finished = detector.ingest(snap) {
            spikes = SpikeStore.recent([finished] + spikes)
            try? store.save(spikes)
        }
        currentSpike = detector.current
        alertEngine.settings = alertSettings
        for alert in alertEngine.ingest(snap) { Notifier.shared.post(alert, sound: alertSettings.sound) }
        onHeadline?(headline)
    }
}

let cpuCount = Double(ProcessInfo.processInfo.activeProcessorCount)

/// The machine total always keeps one decimal, in the menu bar and the panel header.
func totalPercent(_ cores: Double) -> String {
    String(format: "%.1f%%", cores / cpuCount * 100)
}

/// A fraction of some whole as a number out of 100. Small shares keep one decimal.
func share(_ fraction: Double) -> String {
    let value = fraction * 100
    return value < 9.95 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
}

/// Share of the whole machine. On 12 cores, 2.4 cores reads as "20%".
func percent(_ cores: Double) -> String {
    share(cores / cpuCount)
}

func watts(_ value: Double) -> String {
    if value < 0.9995 { return "\(Int((value * 1000).rounded())) mW" }
    return String(format: value < 9.95 ? "%.1f W" : "%.0f W", value)
}

/// Battery gain or loss: "+12 W", "\u{2212}5.8 W", or "steady" within 50 mW of zero.
func signedWatts(_ value: Double) -> String {
    if abs(value) < 0.05 { return "steady" }
    return (value > 0 ? "+" : "\u{2212}") + watts(abs(value))
}

let gigabyte = Double(1 << 30)

func bytes(_ count: UInt64) -> String {
    let value = Double(count)
    return value >= gigabyte ? String(format: "%.1f GB", value / gigabyte) : String(format: "%.0f MB", value / Double(1 << 20))
}

func wattHours(joules: Double) -> String {
    let value = joules / 3600
    return String(format: value < 9.995 ? "%.2f Wh" : "%.1f Wh", value)
}

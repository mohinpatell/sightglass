import Foundation

public enum AlertKind: String, CaseIterable, Codable, Sendable {
    case cpuHog, busyMac, losingWhilePlugged, batteryLow, memoryPressure, appMemory

    public var title: String {
        switch self {
        case .cpuHog: "An app hogs the CPU"
        case .busyMac: "The whole Mac is busy"
        case .losingWhilePlugged: "Losing charge while plugged in"
        case .batteryLow: "Battery is running low"
        case .memoryPressure: "Memory is under pressure"
        case .appMemory: "An app uses a lot of memory"
        }
    }
}

/// Everything a person can choose about alerts. Nothing is on by default.
public struct AlertSettings: Codable, Equatable, Sendable {
    public var enabled: Set<AlertKind> = []
    /// An app counts as a hog at this many cores, held for this many minutes.
    public var hogCores = 1.0
    public var hogMinutes = 5.0
    /// The whole Mac counts as busy at this share of all cores, held for this long.
    public var busyShare = 0.75
    public var busyMinutes = 5.0
    public var losingMinutes = 2.0
    /// Alert when the battery would last less than this at the current draw.
    public var lowBatteryMinutes = 60.0
    /// False also alerts at the earlier "high" level.
    public var criticalPressureOnly = false
    public var appMemoryGigabytes = 8.0
    /// How long the same alert stays quiet after firing. Zero means once per
    /// occurrence: it only fires again after the problem went away and came back.
    public var repeatMinutes = 60.0
    /// Apps that never trigger the per app alerts, such as a long job you started on purpose.
    public var mutedApps: Set<String> = []
    public var sound = false

    public init() {}
}

public struct Alert: Equatable, Sendable {
    public let kind: AlertKind
    public let title: String
    public let body: String
    /// The app the alert is about, when it is about one. It can be muted.
    public let app: String?

    public init(kind: AlertKind, title: String, body: String, app: String? = nil) {
        self.kind = kind
        self.title = title
        self.body = body
        self.app = app
    }
}

/// Watches snapshots and decides when something is worth a notification. Every rule
/// needs its condition to hold for a while and then stays quiet for a while, so a
/// brief blip never notifies and a lasting problem does not nag.
public struct AlertEngine: Sendable {
    public var settings = AlertSettings()

    /// A dip shorter than this does not restart a CPU rule's clock.
    static let grace: TimeInterval = 15
    static let pressureSeconds: TimeInterval = 30
    static let appMemorySeconds: TimeInterval = 60
    static let lowBatterySeconds: TimeInterval = 60

    /// When a condition started, when it was last seen, and when it last notified.
    private struct Watch: Sendable {
        var since: Date?
        var lastSeen: Date?
        var notified: Date?
    }

    private var hogs: [String: Watch] = [:]
    private var busy = Watch()
    private var losing = Watch()
    private var pressure = Watch()
    private var lowBattery = Watch()
    private var memoryHogs: [String: Watch] = [:]

    public init() {}

    public mutating func ingest(_ snapshot: Snapshot) -> [Alert] {
        var alerts: [Alert] = []
        if settings.enabled.contains(.cpuHog) { alerts += hogAlerts(snapshot) } else { hogs = [:] }
        if settings.enabled.contains(.busyMac) { alerts += busyAlert(snapshot) } else { busy = Watch() }
        if settings.enabled.contains(.losingWhilePlugged) { alerts += losingAlert(snapshot) } else { losing = Watch() }
        if settings.enabled.contains(.batteryLow) { alerts += lowBatteryAlert(snapshot) } else { lowBattery = Watch() }
        if settings.enabled.contains(.memoryPressure) { alerts += pressureAlert(snapshot) } else { pressure = Watch() }
        if settings.enabled.contains(.appMemory) { alerts += memoryAlerts(snapshot) } else { memoryHogs = [:] }
        return alerts
    }

    /// Advances one watch. Returns how long the condition has held when it is time to
    /// notify, otherwise nil. `grace` lets the condition lapse briefly without restarting.
    private func step(_ watch: inout Watch, holds: Bool, at now: Date, after seconds: TimeInterval,
                      grace: TimeInterval = 0) -> TimeInterval? {
        guard holds else {
            if let seen = watch.lastSeen, now.timeIntervalSince(seen) <= grace { return nil }
            watch.since = nil
            watch.lastSeen = nil
            // "Once per occurrence": the occurrence is over, so the next one may notify.
            if settings.repeatMinutes == 0 { watch.notified = nil }
            return nil
        }
        watch.lastSeen = now
        let since = watch.since ?? now
        watch.since = since
        let held = now.timeIntervalSince(since)
        guard held >= seconds else { return nil }
        if let last = watch.notified {
            guard settings.repeatMinutes > 0, now.timeIntervalSince(last) >= settings.repeatMinutes * 60 else { return nil }
        }
        watch.notified = now
        return held
    }

    private func canAlertAbout(_ app: AppUsage) -> Bool {
        // The leftover rows are not something a person can act on.
        ![shortLivedName, unidentifiedName, systemEnergyName].contains(app.name) && !settings.mutedApps.contains(app.name)
    }

    private mutating func hogAlerts(_ snapshot: Snapshot) -> [Alert] {
        var alerts: [Alert] = []
        let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
        var seen: Set<String> = []
        for app in snapshot.apps where app.cores >= settings.hogCores && canAlertAbout(app) {
            seen.insert(app.name)
            var watch = hogs[app.name] ?? Watch()
            if let held = step(&watch, holds: true, at: snapshot.time, after: settings.hogMinutes * 60) {
                alerts.append(Alert(kind: .cpuHog, title: "\(app.name) is hogging the CPU",
                                    body: String(format: "It has used about %.0f%% of the whole CPU (%.1f cores) for %@.",
                                                 app.cores / cpus * 100, app.cores, Self.minutes(held)),
                                    app: app.name))
            }
            hogs[app.name] = watch
        }
        for name in hogs.keys where !seen.contains(name) {
            var watch = hogs[name]!
            _ = step(&watch, holds: false, at: snapshot.time, after: 0, grace: Self.grace)
            hogs[name] = watch.since == nil && watch.notified == nil ? nil : watch
        }
        return alerts
    }

    private mutating func busyAlert(_ snapshot: Snapshot) -> [Alert] {
        let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
        let share = snapshot.totalCores / cpus
        guard let held = step(&busy, holds: share >= settings.busyShare, at: snapshot.time,
                              after: settings.busyMinutes * 60, grace: Self.grace) else { return [] }
        var body = String(format: "CPU use has been above %.0f%% for %@.", settings.busyShare * 100, Self.minutes(held))
        if let top = snapshot.apps.first(where: canAlertAbout) {
            body += String(format: " Busiest: %@ at %.0f%%.", top.name, top.cores / cpus * 100)
        }
        return [Alert(kind: .busyMac, title: "The Mac is busy", body: body)]
    }

    private mutating func losingAlert(_ snapshot: Snapshot) -> [Alert] {
        let battery = snapshot.battery
        let net = battery?.netWatts ?? 0
        let holds = battery?.onBattery == false && net <= -1
        guard step(&losing, holds: holds, at: snapshot.time, after: settings.losingMinutes * 60) != nil,
              let battery, let adapter = battery.adapterWatts, let draw = battery.systemWatts else { return [] }
        return [Alert(kind: .losingWhilePlugged, title: "Plugged in but losing charge",
                      body: String(format: "The charger supplies %.0f W and the Mac is using %.0f W, so the battery is losing %.0f W.",
                                   adapter, draw, -net) + biggestEnergyUser(snapshot))]
    }

    private mutating func lowBatteryAlert(_ snapshot: Snapshot) -> [Alert] {
        let battery = snapshot.battery
        let draw = battery?.systemWatts ?? 0
        let minutesLeft = draw > 0 ? (battery?.remainingWattHours ?? 0) / draw * 60 : .infinity
        let holds = battery?.onBattery == true && minutesLeft < settings.lowBatteryMinutes
        guard step(&lowBattery, holds: holds, at: snapshot.time, after: Self.lowBatterySeconds) != nil else { return [] }
        return [Alert(kind: .batteryLow, title: "Battery is running low",
                      body: String(format: "At %.0f W the battery lasts about %.0f more minutes.", draw, minutesLeft)
                          + biggestEnergyUser(snapshot))]
    }

    private mutating func pressureAlert(_ snapshot: Snapshot) -> [Alert] {
        let level = snapshot.memory?.pressure ?? .normal
        let holds = settings.criticalPressureOnly ? level == .critical : level != .normal
        guard step(&pressure, holds: holds, at: snapshot.time, after: Self.pressureSeconds) != nil,
              let memory = snapshot.memory else { return [] }
        let gigabyte = Double(1 << 30)
        var body = String(format: "Using %.1f of %.0f GB, with %.1f GB swapped to disk.", Double(memory.usedBytes) / gigabyte,
                          Double(memory.totalBytes) / gigabyte, Double(memory.swapUsedBytes) / gigabyte)
        if let top = snapshot.apps.max(by: { $0.memoryBytes < $1.memoryBytes }), top.memoryBytes > 0 {
            body += String(format: " Biggest: %@ at %.1f GB.", top.name, Double(top.memoryBytes) / gigabyte)
        }
        return [Alert(kind: .memoryPressure, title: "Memory is under pressure", body: body)]
    }

    private mutating func memoryAlerts(_ snapshot: Snapshot) -> [Alert] {
        var alerts: [Alert] = []
        let gigabyte = Double(1 << 30)
        let limit = settings.appMemoryGigabytes * gigabyte
        var seen: Set<String> = []
        for app in snapshot.apps where Double(app.memoryBytes) >= limit && canAlertAbout(app) {
            seen.insert(app.name)
            var watch = memoryHogs[app.name] ?? Watch()
            if step(&watch, holds: true, at: snapshot.time, after: Self.appMemorySeconds) != nil {
                alerts.append(Alert(kind: .appMemory, title: "\(app.name) is using a lot of memory",
                                    body: String(format: "It holds %.1f GB, above your %.0f GB limit.",
                                                 Double(app.memoryBytes) / gigabyte, settings.appMemoryGigabytes),
                                    app: app.name))
            }
            memoryHogs[app.name] = watch
        }
        for name in memoryHogs.keys where !seen.contains(name) {
            var watch = memoryHogs[name]!
            _ = step(&watch, holds: false, at: snapshot.time, after: 0)
            memoryHogs[name] = watch.notified == nil ? nil : watch
        }
        return alerts
    }

    private func biggestEnergyUser(_ snapshot: Snapshot) -> String {
        guard let top = snapshot.apps.filter({ $0.name != systemEnergyName }).max(by: { $0.watts < $1.watts }),
              top.watts >= 0.5 else { return "" }
        return String(format: " Biggest user: %@ at %.1f W.", top.name, top.watts)
    }

    private static func minutes(_ seconds: TimeInterval) -> String {
        let count = Int((seconds / 60).rounded())
        return count == 1 ? "1 minute" : "\(count) minutes"
    }
}

import Foundation

public enum AlertKind: String, CaseIterable, Sendable {
    case cpuHog, losingWhilePlugged, memoryPressure, batteryLow

    /// What the alert watches for, as shown in the Alerts menu.
    public var title: String {
        switch self {
        case .cpuHog: "An app hogs the CPU for 5 minutes"
        case .losingWhilePlugged: "Losing charge while plugged in"
        case .memoryPressure: "Memory is under pressure"
        case .batteryLow: "Under an hour of battery left"
        }
    }
}

public struct Alert: Equatable, Sendable {
    public let kind: AlertKind
    public let title: String
    public let body: String

    public init(kind: AlertKind, title: String, body: String) {
        self.kind = kind
        self.title = title
        self.body = body
    }
}

/// Watches snapshots and decides when something is worth a notification. Every rule
/// needs the condition to hold for a while, and then stays quiet for a while, so a
/// brief blip never notifies and a lasting problem does not nag.
public struct AlertEngine: Sendable {
    public var enabled: Set<AlertKind> = []

    /// One app at or above this many cores, for `hogSeconds`, is a hog.
    static let hogCores = 1.0
    static let hogSeconds: TimeInterval = 300
    /// A dip shorter than this does not restart the hog clock.
    static let hogGrace: TimeInterval = 15
    static let losingWatts = 1.0
    static let losingSeconds: TimeInterval = 120
    static let pressureSeconds: TimeInterval = 30
    static let lowBatterySeconds: TimeInterval = 60
    static let quietSeconds: TimeInterval = 3600

    private var hogSince: [String: Date] = [:]
    private var hogLastSeen: [String: Date] = [:]
    private var hogNotified: [String: Date] = [:]
    private var losingSince: Date?
    private var losingNotified: Date?
    private var pressureSince: Date?
    private var pressureNotified: Date?
    private var lowSince: Date?
    private var lowNotified = false

    public init() {}

    public mutating func ingest(_ snapshot: Snapshot) -> [Alert] {
        var alerts: [Alert] = []
        if enabled.contains(.cpuHog) { alerts += hogs(snapshot) } else { hogSince = [:] }
        if enabled.contains(.losingWhilePlugged), let alert = losing(snapshot) { alerts.append(alert) }
        if enabled.contains(.memoryPressure), let alert = pressure(snapshot) { alerts.append(alert) }
        if enabled.contains(.batteryLow), let alert = lowBattery(snapshot) { alerts.append(alert) }
        return alerts
    }

    private func isQuiet(_ last: Date?, at time: Date) -> Bool {
        last.map { time.timeIntervalSince($0) < Self.quietSeconds } ?? false
    }

    private mutating func hogs(_ snapshot: Snapshot) -> [Alert] {
        let now = snapshot.time
        var alerts: [Alert] = []
        // These rows are leftovers, not something a person can act on.
        let buckets: Set = [shortLivedName, unidentifiedName, systemEnergyName]
        for app in snapshot.apps where app.cores >= Self.hogCores && !buckets.contains(app.name) {
            hogLastSeen[app.name] = now
            let since = hogSince[app.name] ?? now
            hogSince[app.name] = since
            guard now.timeIntervalSince(since) >= Self.hogSeconds, !isQuiet(hogNotified[app.name], at: now) else { continue }
            hogNotified[app.name] = now
            let share = app.cores / Double(ProcessInfo.processInfo.activeProcessorCount) * 100
            alerts.append(Alert(kind: .cpuHog, title: "\(app.name) is hogging the CPU",
                                body: String(format: "It has used about %.0f%% of the whole CPU (%.1f cores) for %.0f minutes.",
                                             share, app.cores, now.timeIntervalSince(since) / 60)))
        }
        for (name, seen) in hogLastSeen where now.timeIntervalSince(seen) > Self.hogGrace {
            hogSince[name] = nil
            hogLastSeen[name] = nil
        }
        return alerts
    }

    private mutating func losing(_ snapshot: Snapshot) -> Alert? {
        guard let battery = snapshot.battery, !battery.onBattery, let net = battery.netWatts,
              let adapter = battery.adapterWatts, let draw = battery.systemWatts, net <= -Self.losingWatts else {
            losingSince = nil
            return nil
        }
        let since = losingSince ?? snapshot.time
        losingSince = since
        guard snapshot.time.timeIntervalSince(since) >= Self.losingSeconds, !isQuiet(losingNotified, at: snapshot.time) else { return nil }
        losingNotified = snapshot.time
        return Alert(kind: .losingWhilePlugged, title: "Plugged in but losing charge",
                     body: String(format: "The charger supplies %.0f W and the Mac is using %.0f W, so the battery is losing %.0f W.",
                                  adapter, draw, -net) + biggestEnergyUser(snapshot))
    }

    private mutating func pressure(_ snapshot: Snapshot) -> Alert? {
        guard let memory = snapshot.memory, memory.pressure != .normal else {
            pressureSince = nil
            return nil
        }
        let since = pressureSince ?? snapshot.time
        pressureSince = since
        guard snapshot.time.timeIntervalSince(since) >= Self.pressureSeconds, !isQuiet(pressureNotified, at: snapshot.time) else { return nil }
        pressureNotified = snapshot.time
        let gigabyte = Double(1 << 30)
        var body = String(format: "Using %.1f of %.0f GB, with %.1f GB swapped to disk.", Double(memory.usedBytes) / gigabyte,
                          Double(memory.totalBytes) / gigabyte, Double(memory.swapUsedBytes) / gigabyte)
        if let top = snapshot.apps.max(by: { $0.memoryBytes < $1.memoryBytes }), top.memoryBytes > 0 {
            body += String(format: " Biggest: %@ at %.1f GB.", top.name, Double(top.memoryBytes) / gigabyte)
        }
        return Alert(kind: .memoryPressure, title: "Memory is under pressure", body: body)
    }

    private mutating func lowBattery(_ snapshot: Snapshot) -> Alert? {
        guard let battery = snapshot.battery, battery.onBattery else {
            // Plugging in ends the stretch, so the next one can notify again.
            lowSince = nil
            lowNotified = false
            return nil
        }
        guard let draw = battery.systemWatts, draw > 0, battery.remainingWattHours / draw < 1 else {
            lowSince = nil
            return nil
        }
        let since = lowSince ?? snapshot.time
        lowSince = since
        guard snapshot.time.timeIntervalSince(since) >= Self.lowBatterySeconds, !lowNotified else { return nil }
        lowNotified = true
        return Alert(kind: .batteryLow, title: "Under an hour of battery left",
                     body: String(format: "At %.0f W the battery lasts about %.0f more minutes.",
                                  draw, battery.remainingWattHours / draw * 60) + biggestEnergyUser(snapshot))
    }

    private func biggestEnergyUser(_ snapshot: Snapshot) -> String {
        guard let top = snapshot.apps.filter({ $0.name != systemEnergyName }).max(by: { $0.watts < $1.watts }),
              top.watts >= 0.5 else { return "" }
        return String(format: " Biggest user: %@ at %.1f W.", top.name, top.watts)
    }
}

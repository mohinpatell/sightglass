import Foundation

/// Running total of energy used by each app and component since the Mac was last
/// plugged in or unplugged.
public struct EnergyLedger: Sendable {
    /// When the current stretch started. Nil before the first snapshot.
    public private(set) var start: Date?
    public private(set) var onBattery = false
    /// Battery charge when the stretch started.
    public private(set) var startPercent: Int?
    public private(set) var joules: [String: Double] = [:]
    private var last: Date?

    public init() {}

    public var totalJoules: Double { joules.values.reduce(0, +) }

    /// Biggest users first.
    public var ranked: [(name: String, joules: Double)] {
        joules.map { (name: $0.key, joules: $0.value) }
            .sorted { ($0.joules, $1.name) > ($1.joules, $0.name) }
    }

    public mutating func add(_ snapshot: Snapshot) {
        let nowOnBattery = snapshot.battery?.onBattery ?? false
        defer { last = snapshot.time }
        if start == nil || nowOnBattery != onBattery {
            start = snapshot.time
            onBattery = nowOnBattery
            startPercent = snapshot.battery?.percent
            joules = [:]
            return
        }
        // A snapshot is an average over the time since the one before it. A long gap
        // means the Mac slept, and nothing here measured that time.
        guard let last else { return }
        let seconds = snapshot.time.timeIntervalSince(last)
        guard seconds > 0, seconds <= 60 else { return }
        for part in snapshot.energyBreakdown {
            joules[part.name, default: 0] += part.watts * seconds
        }
    }
}

import Foundation

public struct Spike: Codable, Equatable, Sendable, Identifiable {
    public struct Culprit: Codable, Equatable, Sendable {
        public let name: String
        public let averageCores: Double
    }

    public let start: Date
    public let duration: TimeInterval
    public let peakCores: Double
    /// Up to three apps, busiest first, averaged over the spike.
    public let culprits: [Culprit]
    public var id: Date { start }
}

/// Turns a stream of one second snapshots into spikes.
///
/// A spike opens when the whole machine stays over `totalThreshold` for 3 samples,
/// or one app stays over `appThreshold` for 5. It closes after 3 calm samples in a
/// row, so a short dip does not split one spike into two.
public struct SpikeDetector {
    public var totalThreshold: Double
    public var appThreshold: Double

    private let totalHold = 3
    private let appHold = 5
    private let cooldown = 3

    private var totalStreak = 0
    private var appStreak = 0
    private var calmStreak = 0
    private var isOpen = false

    // Running totals over the hot samples of the streak or spike in progress.
    private var start: Date?
    private var lastHot = Date.distantPast
    private var peak = 0.0
    private var hotSamples = 0
    private var coreSeconds: [String: Double] = [:]

    public init(totalThreshold: Double, appThreshold: Double = 1.0) {
        self.totalThreshold = totalThreshold
        self.appThreshold = appThreshold
    }

    /// The spike in progress, if one is open.
    public var current: Spike? { isOpen ? makeSpike() : nil }

    /// Feed one snapshot. Returns a spike at the moment it ends.
    public mutating func ingest(_ snapshot: Snapshot) -> Spike? {
        let hotTotal = snapshot.totalCores >= totalThreshold
        let hotApp = (snapshot.apps.first?.cores ?? 0) >= appThreshold
        totalStreak = hotTotal ? totalStreak + 1 : 0
        appStreak = hotApp ? appStreak + 1 : 0

        if hotTotal || hotApp {
            calmStreak = 0
            if start == nil { start = snapshot.time }
            lastHot = snapshot.time
            peak = max(peak, snapshot.totalCores)
            hotSamples += 1
            for app in snapshot.apps { coreSeconds[app.name, default: 0] += app.cores }
        } else {
            calmStreak += 1
        }

        if !isOpen {
            if totalStreak >= totalHold || appStreak >= appHold {
                isOpen = true
            } else if calmStreak > 0 {
                reset()
            }
            return nil
        }
        guard calmStreak >= cooldown else { return nil }
        let spike = makeSpike()
        reset()
        return spike
    }

    private func makeSpike() -> Spike? {
        guard let start, hotSamples > 0 else { return nil }
        let culprits = coreSeconds
            .map { Spike.Culprit(name: $0.key, averageCores: $0.value / Double(hotSamples)) }
            .filter { $0.averageCores >= 0.1 }
            .sorted { ($0.averageCores, $1.name) > ($1.averageCores, $0.name) }
            .prefix(3)
        // Samples are one second apart, so the last hot sample covers one more second.
        return Spike(start: start, duration: lastHot.timeIntervalSince(start) + 1,
                     peakCores: peak, culprits: Array(culprits))
    }

    private mutating func reset() {
        isOpen = false
        start = nil
        peak = 0
        hotSamples = 0
        coreSeconds = [:]
    }
}

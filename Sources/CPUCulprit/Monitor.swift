import CulpritCore
import Foundation
import Observation

/// Samples once a second on a background queue and publishes results on the main queue.
@Observable
final class Monitor {
    /// Ten minutes of one second snapshots.
    static let historyLimit = 600

    private(set) var latest: Snapshot?
    private(set) var history: [Snapshot] = []
    private(set) var spikes: [Spike]
    private(set) var currentSpike: Spike?

    /// Called on the main queue after every sample with the new menu bar text.
    @ObservationIgnored var onHeadline: ((String?) -> Void)?

    @ObservationIgnored private var detector: SpikeDetector
    @ObservationIgnored private let store = SpikeStore()
    @ObservationIgnored private let timer: DispatchSourceTimer

    init() {
        detector = SpikeDetector(totalThreshold: 0.4 * cpuCount)
        spikes = store.load()
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sampler", qos: .utility))
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        let sampler = Sampler()
        timer.setEventHandler { [weak self] in
            guard let sample = sampler.sample() else { return }
            let snap = snapshot(from: sample, at: Date())
            DispatchQueue.main.async { self?.apply(snap) }
        }
        timer.resume()
    }

    /// Menu bar text: whole machine CPU use, nil before the first sample.
    var headline: String? {
        latest.map { totalPercent($0.totalCores) }
    }

    private func apply(_ snap: Snapshot) {
        latest = snap
        history.append(snap)
        if history.count > Self.historyLimit { history.removeFirst() }
        if let finished = detector.ingest(snap) {
            spikes = SpikeStore.recent([finished] + spikes)
            try? store.save(spikes)
        }
        currentSpike = detector.current
        onHeadline?(headline)
    }
}

let cpuCount = Double(ProcessInfo.processInfo.activeProcessorCount)

/// The machine total always keeps one decimal, in the menu bar and the panel header.
func totalPercent(_ cores: Double) -> String {
    String(format: "%.1f%%", cores / cpuCount * 100)
}

/// Share of the whole machine, so every number in the panel is out of 100.
/// On 12 cores, 2.4 cores reads as "20%". Small shares keep one decimal.
func percent(_ cores: Double) -> String {
    let share = cores / cpuCount * 100
    return share < 9.95 ? String(format: "%.1f%%", share) : "\(Int(share.rounded()))%"
}

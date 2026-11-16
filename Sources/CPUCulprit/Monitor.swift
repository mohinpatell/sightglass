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

    @ObservationIgnored private var detector: SpikeDetector
    @ObservationIgnored private let store = SpikeStore()
    @ObservationIgnored private let timer: DispatchSourceTimer

    init() {
        let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
        detector = SpikeDetector(totalThreshold: 0.4 * cpus)
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

    /// Menu bar text: the busiest app, once it uses at least half a core.
    var headline: String? {
        guard let top = latest?.apps.first, top.cores >= 0.5 else { return nil }
        return "\(top.name.prefix(24)) \(percent(top.cores))"
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
    }
}

/// 2.12 cores reads as "212%", the same scale Activity Monitor uses.
func percent(_ cores: Double) -> String {
    "\(Int((cores * 100).rounded()))%"
}

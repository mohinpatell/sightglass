import CulpritCore
import Foundation
import Observation

/// Samples on a background queue and publishes results on the main queue.
@Observable
final class Monitor {
    /// How much history the chart keeps, in seconds.
    static let historySeconds: TimeInterval = 600
    static let intervalChoices: [TimeInterval] = [1, 2, 5, 10]

    /// Seconds between samples. Each sample is an average over this long, so a longer
    /// interval gives a calmer number and costs less energy.
    private(set) var interval: TimeInterval

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
        let saved = UserDefaults.standard.double(forKey: "updateInterval")
        let seconds = Self.intervalChoices.contains(saved) ? saved : 1
        interval = seconds
        detector = SpikeDetector(totalThreshold: 0.4 * cpuCount, interval: seconds)
        spikes = store.load()
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sampler", qos: .utility))
        timer.schedule(deadline: .now(), repeating: seconds, leeway: .milliseconds(100))
        let sampler = Sampler()
        timer.setEventHandler { [weak self] in
            guard let sample = sampler.sample() else { return }
            let snap = snapshot(from: sample, at: Date())
            DispatchQueue.main.async { self?.apply(snap) }
        }
        timer.resume()
    }

    func setInterval(_ seconds: TimeInterval) {
        interval = seconds
        detector.interval = seconds
        UserDefaults.standard.set(seconds, forKey: "updateInterval")
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(100))
    }

    /// Menu bar text: whole machine CPU use, nil before the first sample.
    var headline: String? {
        latest.map { totalPercent($0.totalCores) }
    }

    private func apply(_ snap: Snapshot) {
        latest = snap
        history.append(snap)
        history.removeAll { snap.time.timeIntervalSince($0.time) > Self.historySeconds }
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

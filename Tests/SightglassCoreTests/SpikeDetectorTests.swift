import Foundation
import Testing
@testable import SightglassCore

/// Feeds one snapshot per second. Each entry is the per app cores for that second;
/// the machine total is their sum.
private func run(_ seconds: [[String: Double]], threshold: Double = 4.0, interval: Double = 1) -> (spikes: [Spike], detector: SpikeDetector) {
    var detector = SpikeDetector(totalThreshold: threshold, interval: interval)
    var spikes: [Spike] = []
    for (i, usage) in seconds.enumerated() {
        let apps = usage.map { AppUsage(name: $0.key, cores: $0.value) }.sorted { $0.cores > $1.cores }
        let snap = Snapshot(time: Date(timeIntervalSince1970: Double(i) * interval), totalCores: usage.values.reduce(0, +), apps: apps)
        if let spike = detector.ingest(snap) { spikes.append(spike) }
    }
    return (spikes, detector)
}

private let calm = ["Finder": 0.1]
private let busy = ["Chrome": 0.9, "Xcode": 0.9, "node": 0.9, "Slack": 0.9, "mds": 0.8]  // 4.4 total, no app over 1

@Test func calmMachineHasNoSpikes() {
    #expect(run(Array(repeating: calm, count: 30)).spikes.isEmpty)
}

@Test func threeBusySecondsThenCalmIsOneSpike() {
    let spikes = run([calm, busy, busy, busy, calm, calm, calm]).spikes
    #expect(spikes.count == 1)
    #expect(spikes[0].start == Date(timeIntervalSince1970: 1))
    #expect(spikes[0].duration == 3)
    #expect(abs(spikes[0].peakCores - 4.4) < 1e-9)
    #expect(spikes[0].culprits.count == 3)
    #expect(spikes[0].culprits.allSatisfy { abs($0.averageCores - 0.9) < 1e-9 })
}

@Test func twoBusySecondsIsTooShort() {
    #expect(run([calm, busy, busy, calm, calm, calm, calm]).spikes.isEmpty)
}

@Test func oneAppOverACoreNeedsFiveSeconds() {
    let hog = ["yes": 1.0, "Finder": 0.05]
    #expect(run(Array(repeating: hog, count: 4) + Array(repeating: calm, count: 3)).spikes.isEmpty)
    let spikes = run(Array(repeating: hog, count: 5) + Array(repeating: calm, count: 3)).spikes
    #expect(spikes.count == 1)
    #expect(spikes[0].duration == 5)
    #expect(spikes[0].culprits == [Spike.Culprit(name: "yes", averageCores: 1.0)])
}

@Test func shortDipDoesNotSplitASpike() {
    let spikes = run([busy, busy, busy, calm, calm, busy, busy, calm, calm, calm]).spikes
    #expect(spikes.count == 1)
    #expect(spikes[0].duration == 7)
}

@Test func openSpikeIsVisibleBeforeItEnds() {
    let (spikes, detector) = run([busy, busy, busy, busy])
    #expect(spikes.isEmpty)
    #expect(detector.current?.duration == 4)
}

@Test func twoSeparateSpikesAreReportedSeparately() {
    let gap = Array(repeating: calm, count: 5)
    let spikes = run([busy, busy, busy] + gap + [busy, busy, busy, busy] + gap).spikes
    #expect(spikes.map(\.duration) == [3, 4])
}

@Test func atAFiveSecondIntervalOneHotSampleIsASpike() {
    let spikes = run([calm, busy, calm, calm, busy, busy, calm], interval: 5).spikes
    #expect(spikes.map(\.duration) == [5, 10])
    #expect(spikes.map(\.start) == [Date(timeIntervalSince1970: 5), Date(timeIntervalSince1970: 20)])
}

@Test func atATwoSecondIntervalHoldsRoundUpToWholeSamples() {
    // 3 seconds needs 2 samples, so one hot sample is not enough.
    #expect(run([calm, busy, calm, calm, calm], interval: 2).spikes.isEmpty)
    #expect(run([calm, busy, busy, calm, calm], interval: 2).spikes.map(\.duration) == [4])
}

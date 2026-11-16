import Foundation
import Testing
@testable import CulpritCore

@Test func spikesSurviveASaveAndLoadAndOldOnesAreDropped() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "culprit-test-\(UUID().uuidString)/spikes.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = SpikeStore(url: url)
    #expect(store.load().isEmpty)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh = Spike(start: now.addingTimeInterval(-3600), duration: 40, peakCores: 3.8,
                      culprits: [.init(name: "Google Chrome", averageCores: 2.6)])
    let old = Spike(start: now.addingTimeInterval(-8 * 24 * 3600), duration: 5, peakCores: 5, culprits: [])
    try store.save([fresh, old])
    #expect(store.load(now: now) == [fresh])
}

@Test func chartStacksTopAppsAndPutsTheRestInOther() {
    func snap(_ t: Double, _ total: Double, _ apps: [(String, Double)]) -> Snapshot {
        Snapshot(time: Date(timeIntervalSince1970: t), totalCores: total, apps: apps.map { AppUsage(name: $0.0, cores: $0.1) })
    }
    let history = [
        snap(100, 3.0, [("node", 2.0), ("Chrome", 0.5), ("mds", 0.2)]),
        snap(101, 3.0, [("node", 1.0), ("Chrome", 0.5), ("mds", 0.4)]),
        snap(105, 1.0, [("Chrome", 0.5)]),
    ]
    let (apps, points) = chartPoints(history: history, bucketSeconds: 5, topApps: 2)
    #expect(apps == ["node", "Chrome", otherName])
    #expect(points.map(\.app) == ["node", "Chrome", otherName, "node", "Chrome", otherName])
    #expect(points.map(\.cores) == [1.5, 0.5, 1.0, 0.0, 0.5, 0.5])
    #expect(points[0].time == Date(timeIntervalSince1970: 100))
    #expect(points[3].time == Date(timeIntervalSince1970: 105))
}

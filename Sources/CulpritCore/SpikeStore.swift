import Foundation

/// Keeps finished spikes in one small JSON file.
public struct SpikeStore {
    public static let retention: TimeInterval = 7 * 24 * 3600

    public let url: URL

    public init(url: URL = URL.applicationSupportDirectory.appending(path: "CPU Culprit/spikes.json")) {
        self.url = url
    }

    /// Drops spikes that started more than a week before `now`.
    public static func recent(_ spikes: [Spike], now: Date = Date()) -> [Spike] {
        spikes.filter { now.timeIntervalSince($0.start) <= retention }
    }

    /// Newest first. Empty when nothing has been saved yet.
    public func load(now: Date = Date()) -> [Spike] {
        guard let data = try? Data(contentsOf: url),
              let spikes = try? JSONDecoder().decode([Spike].self, from: data) else { return [] }
        return Self.recent(spikes, now: now)
    }

    public func save(_ spikes: [Spike]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(spikes).write(to: url, options: .atomic)
    }
}

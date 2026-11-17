import Foundation

public struct ChartPoint: Equatable, Sendable, Identifiable {
    public let time: Date
    public let app: String
    public let cores: Double
    public var id: String { "\(app) \(time.timeIntervalSince1970)" }
}

public let otherName = "Other"

/// Shapes history for a stacked chart: the busiest apps over the whole window each
/// get a series, and everything else is one "Other" series so the stack adds up to
/// the machine total. Samples are averaged into buckets to keep the chart light.
///
/// By default it charts CPU cores. Pass `value` and `total` to chart something else,
/// such as watts. `ChartPoint.cores` then holds that quantity.
public func chartPoints(history: [Snapshot], bucketSeconds: TimeInterval = 5, topApps: Int = 5,
                        other: String = otherName,
                        value: (AppUsage) -> Double = { $0.cores },
                        total: (Snapshot) -> Double = { $0.totalCores })
    -> (apps: [String], points: [ChartPoint])
{
    var totals: [String: Double] = [:]
    for snap in history {
        for app in snap.apps { totals[app.name, default: 0] += value(app) }
    }
    let names = totals.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(topApps).map(\.key)

    var buckets: [Int: [Snapshot]] = [:]
    for snap in history {
        buckets[Int(snap.time.timeIntervalSince1970 / bucketSeconds), default: []].append(snap)
    }

    var points: [ChartPoint] = []
    for (key, snaps) in buckets.sorted(by: { $0.key < $1.key }) {
        let time = Date(timeIntervalSince1970: Double(key) * bucketSeconds)
        let count = Double(snaps.count)
        var named = 0.0
        for name in names {
            let sum = snaps.reduce(0.0) { $0 + ($1.apps.first { $0.name == name }.map(value) ?? 0) }
            points.append(ChartPoint(time: time, app: name, cores: sum / count))
            named += sum / count
        }
        let bucketTotal = snaps.reduce(0.0) { $0 + total($1) } / count
        points.append(ChartPoint(time: time, app: other, cores: max(0, bucketTotal - named)))
    }
    return (names + [other], points)
}

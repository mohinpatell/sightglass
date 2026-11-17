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

public let otherAppsName = "Other apps"
public let chipName = "Graphics and memory"

/// Shapes history for the energy chart. The stack adds up to the whole machine's
/// draw, and every band says what it is: the apps using the most CPU energy, the
/// rest of the apps together, the chip's graphics and memory, and the hardware no
/// app can be blamed for (the screen, anything plugged into the ports, losses).
public func energyChartPoints(history: [Snapshot], bucketSeconds: TimeInterval = 5, topApps: Int = 4)
    -> (apps: [String], points: [ChartPoint])
{
    var totals: [String: Double] = [:]
    for snap in history {
        for app in snap.apps { totals[app.name, default: 0] += app.watts }
    }
    let names = totals.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(topApps).map(\.key)

    var buckets: [Int: [Snapshot]] = [:]
    for snap in history {
        buckets[Int(snap.time.timeIntervalSince1970 / bucketSeconds), default: []].append(snap)
    }

    var points: [ChartPoint] = []
    for (key, snaps) in buckets.sorted(by: { $0.key < $1.key }) {
        let time = Date(timeIntervalSince1970: Double(key) * bucketSeconds)
        func average(_ value: (Snapshot) -> Double) -> Double {
            snaps.reduce(0.0) { $0 + value($1) } / Double(snaps.count)
        }
        var named = 0.0
        for name in names {
            let watts = average { snap in snap.apps.first { $0.name == name }?.watts ?? 0 }
            points.append(ChartPoint(time: time, app: name, cores: watts))
            named += watts
        }
        let allApps = average { snap in snap.apps.reduce(0) { $0 + $1.watts } }
        points.append(ChartPoint(time: time, app: otherAppsName, cores: max(0, allApps - named)))
        points.append(ChartPoint(time: time, app: chipName, cores: average { ($0.power?.gpu ?? 0) + ($0.power?.memory ?? 0) }))
        points.append(ChartPoint(time: time, app: restName, cores: average(\.restWatts)))
    }
    return (names + [otherAppsName, chipName, restName], points)
}


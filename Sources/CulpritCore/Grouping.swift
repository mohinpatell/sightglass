import Foundation

/// Name of the app a process counts toward.
///
/// A process inside an app bundle belongs to the outermost bundle, so every
/// "Google Chrome Helper" rolls up into "Google Chrome". An XPC service outside
/// any bundle (Safari's web content, for example) belongs to the app it works for.
/// Anything else keeps its own executable name, so `node` stays `node`.
public func appName(path: String, responsiblePath: String? = nil) -> String {
    if let app = outermostApp(in: path) { return app }
    if path.contains(".xpc/"), let responsiblePath, let app = outermostApp(in: responsiblePath) {
        return app
    }
    return (path as NSString).lastPathComponent
}

private func outermostApp(in path: String) -> String? {
    for component in path.split(separator: "/") where component.hasSuffix(".app") {
        return String(component.dropLast(4))
    }
    return nil
}

public struct AppUsage: Equatable, Sendable, Identifiable {
    public let name: String
    public let cores: Double
    public var id: String { name }

    public init(name: String, cores: Double) {
        self.name = name
        self.cores = cores
    }
}

/// One second of CPU use, rolled up by app.
public struct Snapshot: Sendable {
    public let time: Date
    public let totalCores: Double
    /// Busiest first.
    public let apps: [AppUsage]

    public init(time: Date, totalCores: Double, apps: [AppUsage]) {
        self.time = time
        self.totalCores = totalCores
        self.apps = apps
    }
}

/// Label for CPU the kernel counted but no sampled process accounts for.
/// That is work done by processes that started and exited between two samples,
/// which is most of what a compiler or a shell script loop looks like.
public let shortLivedName = "Short lived processes"

public func snapshot(from sample: RawSample, at time: Date) -> Snapshot {
    var byApp: [String: Double] = [:]
    for process in sample.processes {
        byApp[process.app, default: 0] += process.cores
    }
    let gap = sample.totalCores - byApp.values.reduce(0, +)
    if gap >= 0.25 { byApp[shortLivedName] = gap }
    let apps = byApp.map { AppUsage(name: $0.key, cores: $0.value) }
        .sorted { ($0.cores, $1.name) > ($1.cores, $0.name) }
    return Snapshot(time: time, totalCores: sample.totalCores, apps: apps)
}

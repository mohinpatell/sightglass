import Foundation

/// Name of the app a process counts toward.
///
/// A process inside an app bundle belongs to the outermost bundle, so every
/// "Google Chrome Helper" rolls up into "Google Chrome". An XPC service outside
/// any bundle (Safari's web content, for example) belongs to the app it works for.
/// Anything else keeps its own executable name, so `clang` stays `clang`.
///
/// A script interpreter says nothing useful on its own, so when `arguments` (the
/// full argv) is given the script is named too: "Python train.py".
public func appName(path: String, responsiblePath: String? = nil, arguments: [String] = []) -> String {
    let base = baseName(path: path, responsiblePath: responsiblePath)
    guard isInterpreter(path: path),
          let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return base }
    return "\(base) \((script as NSString).lastPathComponent)"
}

public func isInterpreter(path: String) -> Bool {
    let name = (path as NSString).lastPathComponent.lowercased()
    return ["python", "node", "ruby", "perl", "php", "bun", "deno"].contains { name.hasPrefix($0) }
}

private func baseName(path: String, responsiblePath: String?) -> String {
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

/// Label for CPU the kernel counted but no measured process accounts for.
/// Mostly that is work done by processes that started and exited between two
/// samples, which is what a compiler or a shell script loop looks like. It also
/// holds kernel_task, which neither `proc_pid_rusage` nor `ps` will report.
public let shortLivedName = "Short lived or kernel"

/// Label for the same gap on a sample where other users' processes were not
/// measured, so the missing CPU may also be a system process.
public let unidentifiedName = "Not yet identified"

public func snapshot(from sample: RawSample, at time: Date) -> Snapshot {
    var byApp: [String: Double] = [:]
    for process in sample.processes {
        byApp[process.app, default: 0] += process.cores
    }
    let gap = sample.totalCores - byApp.values.reduce(0, +)
    if gap >= 0.25 { byApp[sample.sawEveryProcess ? shortLivedName : unidentifiedName] = gap }
    let apps = byApp.map { AppUsage(name: $0.key, cores: $0.value) }
        .sorted { ($0.cores, $1.name) > ($1.cores, $0.name) }
    return Snapshot(time: time, totalCores: sample.totalCores, apps: apps)
}

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
    guard isInterpreter(path: path) else { return base }
    for argument in arguments.dropFirst() {
        // Inline code (`python -c`, `node -e`) has no script name worth showing.
        if argument == "-c" || argument == "-e" { return base }
        if argument.hasPrefix("-") { continue }
        let script = (argument as NSString).lastPathComponent
        return script.isEmpty ? base : "\(base) \(script.prefix(40))"
    }
    return base
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
    /// CPU power billed to this app's processes. Zero when it could not be read.
    public let watts: Double
    /// Memory footprint of this app's processes, in bytes. Zero when it could not be read.
    public let memoryBytes: UInt64
    /// This app's processes that belong to the current user, so can be asked to quit.
    public let pids: [pid_t]
    public var id: String { name }

    public init(name: String, cores: Double, watts: Double = 0, memoryBytes: UInt64 = 0, pids: [pid_t] = []) {
        self.name = name
        self.cores = cores
        self.watts = watts
        self.memoryBytes = memoryBytes
        self.pids = pids
    }
}

/// One sampling interval of CPU and energy use, rolled up by app.
public struct Snapshot: Sendable {
    public let time: Date
    public let totalCores: Double
    /// Busiest by CPU first.
    public let apps: [AppUsage]
    public let power: ComponentPower?
    public let battery: BatteryState?
    public let memory: MemoryState?

    public init(time: Date, totalCores: Double, apps: [AppUsage],
                power: ComponentPower? = nil, battery: BatteryState? = nil, memory: MemoryState? = nil) {
        self.time = time
        self.totalCores = totalCores
        self.apps = apps
        self.power = power
        self.battery = battery
        self.memory = memory
    }

    /// Whole machine draw. The battery controller's figure when there is one,
    /// otherwise the parts of the chip that report their own power.
    public var drawWatts: Double? {
        battery?.systemWatts ?? power.map { $0.cpu + $0.gpu + $0.memory }
    }

    /// Draw that no chip counter covers: the display, storage, radios and losses.
    public var restWatts: Double {
        guard let system = battery?.systemWatts, let power else { return 0 }
        return max(0, system - power.cpu - power.gpu - power.memory)
    }

    /// Everything drawing power, by name, adding up to `drawWatts`.
    public var energyBreakdown: [(name: String, watts: Double)] {
        var parts = apps.filter { $0.watts > 0 }.map { (name: $0.name, watts: $0.watts) }
        if let power {
            parts.append((graphicsName, power.gpu))
            parts.append((memoryName, power.memory))
        }
        if restWatts > 0 { parts.append((restName, restWatts)) }
        return parts
    }
}

public let graphicsName = "Graphics"
public let memoryName = "Memory"
public let restName = "Screen and everything else"

/// Label for CPU energy the chip measured but did not bill to a readable process:
/// other users' processes, short lived ones, the kernel, and idle overhead. The
/// total is measured. It is not split further because a process on a performance
/// core costs about ten times one on an efficiency core, so a guess from CPU time
/// alone could be off by that much.
public let systemEnergyName = "System and short lived"

/// Label for CPU the kernel counted but no measured process accounts for.
/// Mostly that is work done by processes that started and exited between two
/// samples, which is what a compiler or a shell script loop looks like. It also
/// holds kernel_task, which neither `proc_pid_rusage` nor `ps` will report.
public let shortLivedName = "Short lived or kernel"

/// Label for the same gap on a sample where other users' processes were not
/// measured, so the missing CPU may also be a system process.
public let unidentifiedName = "Not yet identified"

/// Apps holding less memory than this, and using no CPU, are left out of a snapshot.
/// There are hundreds of tiny helpers and listing them would only add noise.
public let smallestListedMemory: UInt64 = 10 << 20

public func snapshot(from sample: RawSample, at time: Date, power: ComponentPower? = nil,
                     battery: BatteryState? = nil, memory: MemoryState? = nil) -> Snapshot {
    var cores: [String: Double] = [:]
    var watts: [String: Double] = [:]
    for process in sample.processes {
        cores[process.app, default: 0] += process.cores
        watts[process.app, default: 0] += process.watts ?? 0
    }
    let gap = sample.totalCores - cores.values.reduce(0, +)
    if gap >= 0.25 { cores[sample.sawEveryProcess ? shortLivedName : unidentifiedName] = gap }
    if let power {
        let unbilled = power.cpu - watts.values.reduce(0, +)
        if unbilled > 0 {
            cores[systemEnergyName, default: 0] += 0
            watts[systemEnergyName] = unbilled
        }
    }
    for (name, bytes) in sample.memory where bytes >= smallestListedMemory {
        cores[name, default: 0] += 0
    }
    let apps = cores.map {
        AppUsage(name: $0.key, cores: $0.value, watts: watts[$0.key] ?? 0,
                 memoryBytes: sample.memory[$0.key] ?? 0, pids: sample.pids[$0.key] ?? [])
    }
    .sorted { ($0.cores, $1.name) > ($1.cores, $0.name) }
    return Snapshot(time: time, totalCores: sample.totalCores, apps: apps, power: power,
                    battery: battery, memory: memory)
}

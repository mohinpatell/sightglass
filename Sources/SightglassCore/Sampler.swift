import Darwin
import Foundation

/// CPU used by one process over one sampling interval.
public struct ProcessUsage: Equatable, Sendable {
    public let pid: pid_t
    /// Executable path, or a bare name when the path is unknown.
    public let path: String
    /// The app this process counts toward, see `appName(path:responsiblePath:)`.
    public let app: String
    /// 1.0 means one full core for the whole interval.
    public let cores: Double
    /// CPU power the kernel billed to this process. Nil for other users' processes,
    /// whose energy counters cannot be read without root.
    public let watts: Double?

    public init(pid: pid_t, path: String, app: String, cores: Double, watts: Double? = nil) {
        self.pid = pid
        self.path = path
        self.app = app
        self.cores = cores
        self.watts = watts
    }
}

public struct RawSample: Sendable {
    /// Whole machine CPU use in cores, from the kernel's own counters.
    public let totalCores: Double
    /// Every process that used CPU in the interval, busiest first.
    public let processes: [ProcessUsage]
    /// False when other users' processes were not measured for this sample, so any
    /// CPU missing from `processes` may be theirs.
    public let sawEveryProcess: Bool
    /// Memory footprint in bytes per app, for every process of the current user,
    /// whether or not it used CPU. Other users' processes cannot be read.
    public let memory: [String: UInt64]
    /// The current user's process ids per app. These are the ones that can be quit.
    public let pids: [String: [pid_t]]

    public init(totalCores: Double, processes: [ProcessUsage], sawEveryProcess: Bool,
                memory: [String: UInt64] = [:], pids: [String: [pid_t]] = [:]) {
        self.totalCores = totalCores
        self.processes = processes
        self.sawEveryProcess = sawEveryProcess
        self.memory = memory
        self.pids = pids
    }
}

/// Reads cumulative CPU time for every process and turns two readings into usage.
///
/// Processes owned by the current user are read directly with `proc_pid_rusage`,
/// which costs under a millisecond for all of them. That call fails with EPERM for
/// everyone else's processes, so those come from `/bin/ps`, which is setuid root.
/// A `ps` run costs 15 to 35 ms, so it only happens while the kernel reports at
/// least `psThreshold` cores of work that the direct readings do not explain.
public final class Sampler {
    public var psThreshold = 0.25

    /// One direct reading: cumulative CPU time and CPU energy, the memory footprint
    /// (the figure Activity Monitor calls Memory), and the UUID of the running
    /// executable, which changes when a process calls exec.
    private struct Reading {
        let cpuNanos: UInt64
        /// CPU time of this process's children that have exited and been collected.
        let childNanos: UInt64
        let energyNanojoules: UInt64
        let footprint: UInt64
        let image: UUID
    }

    private var previousCPU: [pid_t: Reading] = [:]
    /// Path and app name per pid. Looking these up costs more than the CPU readings
    /// themselves, so they are kept until the pid is reused or the process execs.
    private var names: [pid_t: (path: String, app: String, parent: pid_t)] = [:]
    private var children = ChildLedger()
    private var previousTime: UInt64 = 0
    private var previousTicks: [UInt32] = []
    private var psCPU: [pid_t: UInt64] = [:]
    private var psTime: UInt64 = 0
    private var timebase = mach_timebase_info_data_t()

    public init() {
        mach_timebase_info(&timebase)
    }

    /// Returns nil on the first call, which only records a baseline.
    public func sample() -> RawSample? {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let ticks = hostTicks()
        var cpu: [pid_t: Reading] = [:]
        var unreadable: [pid_t] = []
        for pid in allPids() {
            if let reading = nativeCPU(pid) { cpu[pid] = reading } else { unreadable.append(pid) }
        }

        let before = (cpu: previousCPU, time: previousTime, ticks: previousTicks)
        previousCPU = cpu
        previousTime = now
        previousTicks = ticks
        guard before.time != 0 else { return nil }

        let interval = Double(now - before.time)
        var processes: [ProcessUsage] = []
        var memory: [String: UInt64] = [:]
        var pids: [String: [pid_t]] = [:]
        // A process that is gone was charged for its CPU while it lived. Its parent is
        // about to be credited with all of it again, so note what not to charge twice.
        for (pid, old) in before.cpu where cpu[pid] == nil {
            guard let parent = names[pid]?.parent else { continue }
            children.exited(parent: parent, alreadyCharged: old.cpuNanos + old.childNanos, now: now)
        }
        for (pid, reading) in cpu {
            // A missing or larger previous value means a new process or a reused pid,
            // and a new image means it called exec. Either way the cached name is stale.
            let old = before.cpu[pid]
            let sameProcess = old.map { reading.cpuNanos >= $0.cpuNanos } ?? false
            if !sameProcess || reading.image != old?.image { names[pid] = nil }
            let name = names[pid] ?? resolveName(pid)
            names[pid] = name
            memory[name.app, default: 0] += reading.footprint
            pids[name.app, default: []].append(pid)
            guard let old, sameProcess else { continue }
            // Commands that start and finish between two samples are never seen as
            // processes. The kernel adds their CPU time to the parent that ran them,
            // which is how a shell or an agent gets charged for what it spawned.
            var used = reading.cpuNanos - old.cpuNanos
            if reading.childNanos > old.childNanos {
                used += children.newWork(parent: pid, childDelta: reading.childNanos - old.childNanos, now: now)
            }
            guard used > 0 else { continue }
            // Nanojoules over nanoseconds is watts.
            let watts = reading.energyNanojoules >= old.energyNanojoules
                ? Double(reading.energyNanojoules - old.energyNanojoules) / interval : nil
            processes.append(ProcessUsage(pid: pid, path: name.path, app: name.app,
                                          cores: Double(used) / interval, watts: watts))
        }
        // Entries for dead pids are harmless but would pile up over weeks.
        if names.count > 2 * cpu.count + 100 { names = names.filter { cpu[$0.key] != nil } }

        // Tick counters are 32 bit and wrap, so subtract each one with wrapping.
        let delta = zip(ticks, before.ticks).map { UInt64($0 &- $1) }
        let busy = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_SYSTEM)] + delta[Int(CPU_STATE_NICE)]
        let all = busy + delta[Int(CPU_STATE_IDLE)]
        let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
        let total = all == 0 ? 0 : Double(busy) / Double(all) * cpus

        var sawEveryProcess = false
        if total - processes.reduce(0, { $0 + $1.cores }) >= psThreshold {
            let rows = parsePS(runPS(pids: unreadable))
            // Deltas only mean something against a ps reading from the previous sample.
            // Otherwise this run is just the baseline for the next one.
            if psTime == before.time {
                sawEveryProcess = true
                for row in rows {
                    guard let old = psCPU[row.pid], row.cpuNanos > old else { continue }
                    processes.append(ProcessUsage(pid: row.pid, path: row.path, app: appName(path: row.path),
                                                  cores: Double(row.cpuNanos - old) / interval))
                }
            }
            psCPU = Dictionary(rows.map { ($0.pid, $0.cpuNanos) }, uniquingKeysWith: { first, _ in first })
            psTime = now
        }

        processes.sort { $0.cores > $1.cores }
        return RawSample(totalCores: total, processes: processes, sawEveryProcess: sawEveryProcess,
                         memory: memory, pids: pids)
    }

    private func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(filled, 0))).filter { $0 > 0 }
    }

    private func nativeCPU(_ pid: pid_t) -> Reading? {
        // V6 is the first flavor with the energy counter.
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0 else { return nil }
        // These times are in Mach ticks, which are not nanoseconds on Apple Silicon.
        let scale = { (ticks: UInt64) in ticks * UInt64(self.timebase.numer) / UInt64(self.timebase.denom) }
        return Reading(cpuNanos: scale(info.ri_user_time + info.ri_system_time),
                       childNanos: scale(info.ri_child_user_time + info.ri_child_system_time),
                       energyNanojoules: info.ri_energy_nj,
                       footprint: info.ri_phys_footprint, image: UUID(uuid: info.ri_uuid))
    }

    private func resolveName(_ pid: pid_t) -> (path: String, app: String, parent: pid_t) {
        let path = nativePath(pid) ?? nativeName(pid)
        // Only XPC services need the extra lookup, everything else names itself.
        let responsible = path.contains(".xpc/") ? nativePath(responsiblePid(pid)) : nil
        let arguments = isInterpreter(path: path) ? nativeArguments(pid) : []
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let parent = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : 0
        return (path, appName(path: path, responsiblePath: responsible, arguments: arguments), parent)
    }

    private func nativePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process's argv. Empty for processes owned by other users.
    private func nativeArguments(_ pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    private func nativeName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        return name.isEmpty ? "pid \(pid)" : name
    }

    private func hostTicks() -> [UInt32] {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private func runPS(pids: [pid_t]) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "pid=,time=,comm=", "-p", pids.map(String.init).joined(separator: ",")]
        task.standardOutput = pipe
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Private libsystem call that Activity Monitor style tools use to find which app
/// an XPC service is working for.
@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsiblePid(_ pid: pid_t) -> pid_t

public struct PSRow: Equatable, Sendable {
    public let pid: pid_t
    public let cpuNanos: UInt64
    public let path: String
}

/// Parses the output of `ps -o pid=,time=,comm=`.
/// The time column looks like `1842:31.12` (minutes, seconds, hundredths).
public func parsePS(_ output: String) -> [PSRow] {
    output.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count == 3, let pid = pid_t(fields[0]) else { return nil }
        var seconds = 0.0
        for part in fields[1].split(separator: ":") {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return PSRow(pid: pid, cpuNanos: UInt64(seconds * 1e9), path: String(fields[2]))
    }
}

/// Parses a `KERN_PROCARGS2` buffer: a 32 bit argc, the executable path, zero
/// padding, then argc zero terminated strings (the environment follows and is ignored).
public func parseProcArgs(_ buffer: [UInt8]) -> [String] {
    guard buffer.count > 4 else { return [] }
    let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    var index = 4
    while index < buffer.count, buffer[index] != 0 { index += 1 }
    while index < buffer.count, buffer[index] == 0 { index += 1 }
    var arguments: [String] = []
    while arguments.count < argc, index < buffer.count {
        let end = buffer[index...].firstIndex(of: 0) ?? buffer.count
        arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
        index = end + 1
    }
    return arguments
}

/// Works out how much of a parent's child time is CPU nobody has been charged for.
///
/// When a child exits, the kernel adds the child's whole lifetime of CPU to its
/// parent's child time. A child that lived across several samples was already
/// charged for most of that as its own process, so that part is owed back.
struct ChildLedger {
    /// A parent that never collects a child would otherwise keep the debt forever.
    static let expiry: UInt64 = 10_000_000_000

    private var owed: [pid_t: (nanos: UInt64, at: UInt64)] = [:]

    /// A child of `parent` is gone, having already been charged `alreadyCharged`.
    mutating func exited(parent: pid_t, alreadyCharged: UInt64, now: UInt64) {
        owed[parent] = (outstanding(parent, now: now) + alreadyCharged, now)
        if owed.count > 512 { owed = owed.filter { now - $0.value.at <= Self.expiry } }
    }

    /// The parent's child time grew by `childDelta`. Returns the part that is new.
    mutating func newWork(parent: pid_t, childDelta: UInt64, now: UInt64) -> UInt64 {
        let debt = outstanding(parent, now: now)
        let repaid = min(debt, childDelta)
        owed[parent] = debt > repaid ? (debt - repaid, owed[parent]?.at ?? now) : nil
        return childDelta - repaid
    }

    private func outstanding(_ parent: pid_t, now: UInt64) -> UInt64 {
        guard let debt = owed[parent], now - debt.at <= Self.expiry else { return 0 }
        return debt.nanos
    }
}


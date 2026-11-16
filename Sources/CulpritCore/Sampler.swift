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

    public init(pid: pid_t, path: String, app: String, cores: Double) {
        self.pid = pid
        self.path = path
        self.app = app
        self.cores = cores
    }
}

public struct RawSample: Sendable {
    /// Whole machine CPU use in cores, from the kernel's own counters.
    public let totalCores: Double
    /// Every process that used CPU in the interval, busiest first.
    public let processes: [ProcessUsage]
}

/// Reads cumulative CPU time for every process and turns two readings into usage.
///
/// Processes owned by the current user are read directly with `proc_pid_rusage`.
/// That call fails with EPERM for everyone else's processes, so those come from
/// `/bin/ps`, which is setuid root.
public final class Sampler {
    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private var previousTicks: [UInt32]?
    private var timebase = mach_timebase_info_data_t()

    public init() {
        mach_timebase_info(&timebase)
    }

    /// Returns nil on the first call, which only records a baseline.
    public func sample() -> RawSample? {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let ticks = hostTicks()
        var cpu: [pid_t: UInt64] = [:]
        var psPaths: [pid_t: String] = [:]

        for pid in allPids() {
            if let ns = nativeCPU(pid) { cpu[pid] = ns }
        }
        for row in parsePS(runPS()) where cpu[row.pid] == nil {
            cpu[row.pid] = row.cpuNanos
            psPaths[row.pid] = row.path
        }

        defer {
            previousCPU = cpu
            previousTime = now
            previousTicks = ticks
        }
        guard previousTime != 0, let before = previousTicks else { return nil }

        let interval = Double(now - previousTime)
        var processes: [ProcessUsage] = []
        for (pid, ns) in cpu {
            // A missing or larger previous value means a new process or a reused pid.
            guard let old = previousCPU[pid], ns > old else { continue }
            let path = psPaths[pid] ?? nativePath(pid) ?? nativeName(pid)
            // Only XPC services need the extra lookup, everything else names itself.
            let responsible = path.contains(".xpc/") ? nativePath(responsiblePid(pid)) : nil
            let app = appName(path: path, responsiblePath: responsible)
            processes.append(ProcessUsage(pid: pid, path: path, app: app, cores: Double(ns - old) / interval))
        }
        processes.sort { $0.cores > $1.cores }

        // Tick counters are 32 bit and wrap, so subtract each one with wrapping.
        let delta = zip(ticks, before).map { UInt64($0 &- $1) }
        let busy = delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_SYSTEM)] + delta[Int(CPU_STATE_NICE)]
        let all = busy + delta[Int(CPU_STATE_IDLE)]
        let cpus = Double(ProcessInfo.processInfo.activeProcessorCount)
        let total = all == 0 ? 0 : Double(busy) / Double(all) * cpus

        return RawSample(totalCores: total, processes: processes)
    }

    private func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(filled, 0))).filter { $0 > 0 }
    }

    private func nativeCPU(_ pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        // These times are in Mach ticks, which are not nanoseconds on Apple Silicon.
        return (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    private func nativePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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

    private func runPS() -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,time=,comm="]
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

/// Parses the output of `ps -axo pid=,time=,comm=`.
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

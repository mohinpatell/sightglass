import Darwin
import Foundation

/// Whole machine memory, split the way Activity Monitor splits it.
public struct MemoryState: Equatable, Sendable {
    public enum Pressure: Int, Sendable {
        case normal = 1, warning = 2, critical = 4
    }

    public let totalBytes: UInt64
    /// Memory apps asked for and still hold.
    public let appBytes: UInt64
    /// Memory the system has pinned and cannot move.
    public let wiredBytes: UInt64
    /// Space taken by memory the system compressed to make room.
    public let compressedBytes: UInt64
    public let swapUsedBytes: UInt64
    public let pressure: Pressure

    public init(totalBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64,
                swapUsedBytes: UInt64, pressure: Pressure) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }

    public var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }
}

public func readMemory() -> MemoryState? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let page = UInt64(vm_kernel_page_size)

    var swap = xsw_usage()
    var swapSize = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

    var level: Int32 = 1
    var levelSize = MemoryLayout<Int32>.size
    sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

    // App memory is anonymous memory minus the part the system may throw away.
    let anonymous = UInt64(stats.internal_page_count)
    let purgeable = UInt64(stats.purgeable_count)
    return MemoryState(totalBytes: ProcessInfo.processInfo.physicalMemory,
                       appBytes: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
                       wiredBytes: UInt64(stats.wire_count) * page,
                       compressedBytes: UInt64(stats.compressor_page_count) * page,
                       swapUsedBytes: swap.xsu_used,
                       pressure: MemoryState.Pressure(rawValue: Int(level)) ?? .normal)
}

/// The apps whose memory grew most across `history`, biggest first. A steady climb
/// here is what a leak looks like.
public func memoryGrowth(history: [Snapshot], atLeast: UInt64 = 50 << 20) -> [(name: String, bytes: UInt64)] {
    guard let first = history.first, let last = history.last, history.count > 1 else { return [] }
    let before = Dictionary(first.apps.map { ($0.name, $0.memoryBytes) }, uniquingKeysWith: { a, _ in a })
    return last.apps.compactMap { app -> (name: String, bytes: UInt64)? in
        // An app that was not there at the start did not grow, it launched.
        guard let old = before[app.name], old > 0, app.memoryBytes > old else { return nil }
        let grown = app.memoryBytes - old
        return grown >= atLeast ? (app.name, grown) : nil
    }
    .sorted { ($0.bytes, $1.name) > ($1.bytes, $0.name) }
}

/// Asks processes to quit, or kills them outright with `force`. Returns how many
/// accepted the signal. Processes owned by other users refuse it.
@discardableResult
public func signal(pids: [pid_t], force: Bool) -> Int {
    pids.filter { $0 > 1 && kill($0, force ? SIGKILL : SIGTERM) == 0 }.count
}

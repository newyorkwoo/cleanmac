import Darwin
import Foundation

public enum MemoryPressure: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    public var title: String {
        switch self {
        case .normal: return L("正常")
        case .warning: return L("偏高")
        case .critical: return L("嚴重")
        }
    }
}

public struct MemorySnapshot: Sendable {
    public var total: Int64 = 0
    public var app: Int64 = 0
    public var wired: Int64 = 0
    public var compressed: Int64 = 0
    /// File cache and purgeable memory, which macOS reclaims on its own whenever needed.
    public var cached: Int64 = 0
    public var free: Int64 = 0
    public var swapUsed: Int64 = 0
    public var pressure: MemoryPressure = .normal

    public init() {}

    public var used: Int64 { app + wired + compressed }
    public var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

public struct ProcessMemory: Identifiable, Sendable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let bytes: Int64
}

public enum SystemMonitor {
    public static func memory() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = Int64(ProcessInfo.processInfo.physicalMemory)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let page = Int64(getpagesize())
            let purgeable = Int64(stats.purgeable_count)
            snapshot.app = max(0, Int64(stats.internal_page_count) - purgeable) * page
            snapshot.wired = Int64(stats.wire_count) * page
            snapshot.compressed = Int64(stats.compressor_page_count) * page
            snapshot.cached = (Int64(stats.external_page_count) + purgeable) * page
            snapshot.free = max(0, Int64(stats.free_count) - Int64(stats.speculative_count)) * page
        }

        var usage = xsw_usage()
        var usageSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &usage, &usageSize, nil, 0) == 0 {
            snapshot.swapUsed = Int64(usage.xsu_used)
        }

        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            snapshot.pressure = MemoryPressure(rawValue: Int(level)) ?? .normal
        }
        return snapshot
    }

    /// Top processes by memory footprint. Other users' processes are unreadable and left out.
    public static func topProcesses(limit: Int = 15) -> [ProcessMemory] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return [] }

        var list: [ProcessMemory] = []
        for pid in pids.prefix(Int(written)) where pid > 0 {
            guard let footprint = footprint(of: pid) else { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = String(cString: nameBuffer)
            list.append(ProcessMemory(pid: pid, name: name.isEmpty ? "PID \(pid)" : name, bytes: footprint))
        }
        return Array(list.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// A process's memory footprint, as Activity Monitor shows it. nil for processes this user can't read.
    public static func footprint(of pid: pid_t) -> Int64? {
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return status == 0 && usage.ri_phys_footprint > 0 ? Int64(usage.ri_phys_footprint) : nil
    }

    /// Runs macOS's `purge`, which drops file caches. Without the standing authorization it asks for
    /// an administrator password.
    public static func purgeInactiveMemory() throws {
        if PurgeAuthorization.isGranted(), PurgeAuthorization.purgeWithoutPrompt() { return }
        let result = Shell.runAsAdmin("/usr/sbin/purge")
        guard result.ok else {
            throw StartupError.command(result.err.isEmpty ? L("無法釋放記憶體。") : result.err)
        }
    }

    public static func disk(for url: URL = URL(fileURLWithPath: "/")) -> (total: Int64, available: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(values?.volumeTotalCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

/// Reports CPU use between successive calls.
public final class CPUSampler {
    private var last: (busy: UInt64, total: UInt64)?

    public init() {}

    public func sample() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        let busy = UInt64(info.cpu_ticks.0) + UInt64(info.cpu_ticks.1) + UInt64(info.cpu_ticks.3)
        let total = busy + UInt64(info.cpu_ticks.2)
        defer { last = (busy, total) }
        guard let last, total > last.total else { return 0 }
        return Double(busy - last.busy) / Double(total - last.total)
    }
}

/// Automatic purges run unattended, so they can't ask for a password each time. The user approves
/// once, which installs a sudoers rule letting this account run /usr/sbin/purge, and nothing else,
/// without a password.
public enum PurgeAuthorization {
    /// No "." in the name: sudo skips such files in sudoers.d, which the temporary file relies on.
    public static let rulePath = "/private/etc/sudoers.d/cleanmac-purge"

    /// The rule for one account. nil for a name that could change the rule's meaning.
    static func rule(for user: String) -> String? {
        guard user.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else { return nil }
        // The empty argument list allows purge exactly as is, with no arguments.
        return "\(user) ALL=(root) NOPASSWD: /usr/sbin/purge \"\""
    }

    /// Everything happens as root inside /etc/sudoers.d, so no file the user could swap is ever installed,
    /// and visudo checks the rule before it takes effect.
    static func installCommand(for user: String) -> String? {
        guard let rule = rule(for: user) else { return nil }
        let temp = rulePath + ".tmp"
        return [
            "umask 077", "/bin/mkdir -p /private/etc/sudoers.d",
            "/usr/bin/printf '%s\\n' '\(rule)' > '\(temp)'",
            "/usr/sbin/chown root:wheel '\(temp)'", "/bin/chmod 0440 '\(temp)'",
            "/usr/sbin/visudo -cf '\(temp)' >/dev/null", "/bin/mv -f '\(temp)' '\(rulePath)'",
        ].joined(separator: " && ") + " || { /bin/rm -f '\(temp)'; exit 1; }"
    }

    /// True when sudo would run purge for this account without asking. `sudo -l` only checks; it runs nothing.
    public static func isGranted() -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", "-l", "/usr/sbin/purge"], timeout: 10).ok
    }

    /// Asks for the administrator password once. Returns false when the prompt is cancelled or the rule is refused.
    public static func grant(user: String = NSUserName(), runAsAdmin: (String) -> Shell.Output = Shell.runAsAdmin) -> Bool {
        guard let command = installCommand(for: user) else { return false }
        return runAsAdmin(command).ok && isGranted()
    }

    public static func revoke(runAsAdmin: (String) -> Shell.Output = Shell.runAsAdmin) -> Bool {
        runAsAdmin("/bin/rm -f '\(rulePath)'").ok
    }

    /// Never prompts: without the rule, sudo -n fails instead of asking.
    public static func purgeWithoutPrompt() -> Bool {
        Shell.run("/usr/bin/sudo", ["-n", "/usr/sbin/purge"], timeout: 120).ok
    }
}

/// Decides when an automatic purge may run. All triggers share one limit so that, say, a wake
/// followed by low memory doesn't purge twice in a row.
public struct PurgeThrottle: Sendable {
    public static let interval: TimeInterval = 180
    public private(set) var lastRun: Date?

    public init(lastRun: Date? = nil) { self.lastRun = lastRun }

    public func allows(at now: Date) -> Bool {
        lastRun.map { now.timeIntervalSince($0) >= Self.interval } ?? true
    }

    /// Records a run and returns true when one is allowed now.
    public mutating func claim(at now: Date = Date()) -> Bool {
        guard allows(at: now) else { return false }
        lastRun = now
        return true
    }
}

/// Remembers how much memory each app last used, since a quit app can no longer be measured.
public struct AppMemoryTracker: Sendable {
    /// Quitting an app above this frees enough to be worth a purge.
    public static let heavyBytes: Int64 = 1 << 30
    private var lastFootprint: [pid_t: Int64] = [:]

    public init() {}

    public mutating func record(_ footprints: [pid_t: Int64]) {
        lastFootprint = footprints
    }

    /// True when the app that quit was a heavy one. Forgets it either way.
    public mutating func didQuit(pid: pid_t) -> Bool {
        (lastFootprint.removeValue(forKey: pid) ?? 0) >= Self.heavyBytes
    }
}

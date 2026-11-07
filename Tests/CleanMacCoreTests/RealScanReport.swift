import AppKit
import XCTest
@testable import CleanMacCore

/// Read-only smoke run against this Mac's real data. Deletes nothing.
/// Runs only when CLEANMAC_REAL_SCAN=1.
final class RealScanReport: XCTestCase {
    func testReport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLEANMAC_REAL_SCAN"] == "1")
        let home = FileManager.default.homeDirectoryForCurrentUser

        func timed<T>(_ name: String, _ work: () async -> T) async -> T {
            let start = Date()
            let value = await work()
            print(String(format: "[%@] %.1fs", name, Date().timeIntervalSince(start)))
            return value
        }

        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let junk = await timed("junk") {
            JunkScanner(home: home, runningBundleIDs: running) { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }.scan()
        }
        for c in junk { print("  \(c.title): \(c.items.count) items, \(formatBytes(c.size)), default=\(c.defaultSelected)") }

        let large = await timed("large") { LargeFileFinder.scan(root: home, options: .personalFiles(home: home), minimumBytes: 100_000_000) }
        print("  \(large.count) files, \(formatBytes(large.reduce(0) { $0 + $1.size }))")

        let dups = await timed("duplicates") { DuplicateFinder.scan(root: home, options: .personalFiles(home: home), minimumBytes: 1_000_000) }
        print("  \(dups.count) groups, reclaimable \(formatBytes(dups.reduce(0) { $0 + $1.reclaimable }))")

        let photos = await timed("photos") { await SimilarPhotoFinder.scan(root: home, options: .personalFiles(home: home)) }
        print("  \(photos.count) groups, reclaimable \(formatBytes(photos.reduce(0) { $0 + $1.reclaimable }))")

        let tree = await timed("diskmap") { DiskMapScanner.scan(root: home) }
        print("  total \(formatBytes(tree.size)), top: \(tree.children.prefix(5).map { "\($0.name)=\(formatBytes($0.size))" })")

        let apps = await timed("apps") { AppInventory.scan(home: home) }
        print("  \(apps.count) apps, \(apps.filter { $0.lastUsed != nil }.count) with last-used dates")

        let startup = await timed("startup") { StartupManager.list(home: home) }
        print("  \(startup.count) items, \(startup.filter(\.disabled).count) disabled")

        let audit = await timed("security") { SecurityAuditor.audit(startupItems: startup, apps: apps) }
        for f in audit where f.group == "系統" || f.group == "更新" { print("  \(f.severity) \(f.title): \(f.detail.prefix(70))") }
        print("  by severity: \(Dictionary(grouping: audit, by: \.severity).mapValues(\.count).sorted { $0.key > $1.key }.map { "\($0.key)=\($0.value)" })")

        let memory = SystemMonitor.memory()
        print("[memory] used \(formatBytes(memory.used))/\(formatBytes(memory.total)), cached \(formatBytes(memory.cached)), swap \(formatBytes(memory.swapUsed)), pressure \(memory.pressure.title); top: \(SystemMonitor.topProcesses(limit: 3).map(\.name))")
    }
}

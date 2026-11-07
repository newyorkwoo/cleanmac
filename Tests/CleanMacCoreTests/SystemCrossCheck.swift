import XCTest
@testable import CleanMacCore

/// Compares results with independent system tools on this Mac's real data. Read-only.
/// Runs only when CLEANMAC_REAL_SCAN=1. Set CLEANMAC_GROUPS_OUT to export duplicate groups as JSON.
final class SystemCrossCheck: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var enabled: Bool { ProcessInfo.processInfo.environment["CLEANMAC_REAL_SCAN"] == "1" }

    private func sh(_ command: String, timeout: TimeInterval = 300) -> String {
        Shell.run("/bin/sh", ["-c", command], timeout: timeout).out
    }

    private func q(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func testFolderSizesMatchDu() throws {
        try XCTSkipUnless(enabled)
        for folder in ["Downloads", "Documents/myproject", "Pictures", "Movies", "Music", ".npm"] {
            let url = home.appendingPathComponent(folder)
            let tree = DiskMapScanner.scan(root: url)
            let walked = FileWalker.allocatedSize(of: url)
            let du = (Int64(sh("du -sk \(q(url.path)) 2>/dev/null").split(separator: "\t").first ?? "0") ?? 0) * 1024
            guard du > 0 else { print("[du] \(folder): unavailable"); continue }
            let treeError = Double(abs(tree.size - du)) / Double(du) * 100
            let walkError = Double(abs(walked - du)) / Double(du) * 100
            print(String(format: "[du] %@: du=%@ tree=%@ (%.2f%%) walker=%@ (%.2f%%)", folder, formatBytes(du), formatBytes(tree.size), treeError, formatBytes(walked), walkError))
            // du counts hard links once and directory entries too, so a small gap is expected.
            XCTAssertLessThan(treeError, 3, folder)
            XCTAssertLessThan(walkError, 3, folder)
        }
    }

    func testLargeFilesMatchFind() throws {
        try XCTSkipUnless(enabled)
        let minimum: Int64 = 100_000_000
        let ours = LargeFileFinder.scan(root: home, options: .personalFiles(home: home), minimumBytes: minimum)
        let prune = ["node_modules", ".git", ".build", "DerivedData", "Pods", "venv", ".venv", "__pycache__", ".*", "*.app", "*.photoslibrary", "*.bundle", "*.framework", "*.xcarchive", "*.pkg", "*.rtfd", "*.fcpbundle", "*.logicx", "*.tvlibrary", "*.musiclibrary"]
            .map { "-name \(q($0))" }.joined(separator: " -o ")
        let lines = sh("find \(q(home.path)) -mindepth 1 \\( -path \(q(home.path + "/Library")) -o \\( -type d \\( \(prune) \\) \\) \\) -prune -o -type f ! -name '.*' -size +195312 -print 2>/dev/null", timeout: 400)
        let found = Set(lines.split(separator: "\n").map(String.init))
        let mine = Set(ours.map(\.url.path))
        // find uses logical size in 512-byte blocks, and ours uses bytes on disk.
        let minimumSet = found.filter { path in
            var info = stat()
            return lstat(path, &info) == 0 && Int64(info.st_blocks) * 512 >= minimum
        }
        let onlyFind = minimumSet.subtracting(mine)
        let onlyOurs = mine.subtracting(found)
        print("[find] ours=\(mine.count) find=\(minimumSet.count) onlyFind=\(onlyFind.count) onlyOurs=\(onlyOurs.count)")
        for path in onlyFind.prefix(10) { print("  onlyFind \(path)") }
        for path in onlyOurs.prefix(10) { print("  onlyOurs \(path)") }
        XCTAssertTrue(onlyFind.isEmpty, "large files missed")
        for file in ours {
            var info = stat()
            XCTAssertEqual(lstat(file.url.path, &info), 0)
            XCTAssertEqual(Int64(info.st_blocks) * 512, file.size, file.url.path)
        }
        XCTAssertEqual(ours.map(\.size), ours.map(\.size).sorted(by: >), "sorted by size")
    }

    func testDuplicateGroupsAreByteIdenticalPerShasumAndCmp() throws {
        try XCTSkipUnless(enabled)
        let groups = DuplicateFinder.scan(root: home, options: .personalFiles(home: home), minimumBytes: 1_000_000)
        print("[dup] \(groups.count) groups")
        if let out = ProcessInfo.processInfo.environment["CLEANMAC_GROUPS_OUT"] {
            let json = groups.map { $0.files.map(\.url.path) }
            try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: out))
        }
        var filesChecked = 0
        for group in groups {
            XCTAssertGreaterThan(group.files.count, 1)
            let paths = group.files.map(\.url.path)
            let hashes = Set(paths.map { sh("/usr/bin/shasum -a 256 \(q($0)) | cut -d' ' -f1") })
            XCTAssertEqual(hashes.count, 1, "not identical: \(paths)")
            XCTAssertEqual(hashes.first?.trimmingCharacters(in: .whitespacesAndNewlines), group.id, "our hash differs from shasum")
            for other in paths.dropFirst() {
                XCTAssertEqual(Shell.run("/usr/bin/cmp", [paths[0], other]).status, 0, "cmp: \(paths[0]) vs \(other)")
            }
            XCTAssertEqual(Set(paths).count, paths.count, "a file is listed twice")
            filesChecked += paths.count
        }
        print("[dup] \(filesChecked) files verified with shasum and cmp")
        XCTAssertEqual(Set(groups.flatMap { $0.files.map(\.url.path) }).count, filesChecked, "a file appears in two groups")
    }

    func testSimilarPhotoGroupsAreRealImages() async throws {
        try XCTSkipUnless(enabled)
        let groups = await SimilarPhotoFinder.scan(root: home, options: .personalFiles(home: home))
        for group in groups {
            XCTAssertGreaterThan(group.photos.count, 1)
            let pixels = group.photos.map { $0.pixelWidth * $0.pixelHeight }
            XCTAssertEqual(pixels[0], pixels.max(), "the best photo must rank first")
            XCTAssertEqual(Set(group.photos.map(\.id)).count, group.photos.count)
        }
        print("[photos] \(groups.count) groups, largest \(groups.map(\.photos.count).max() ?? 0)")
    }

    func testAppSignaturesMatchCodesign() throws {
        try XCTSkipUnless(enabled)
        let apps = AppInventory.scan(home: home)
        let listed = Set(sh("find /Applications -maxdepth 4 -type d -name '*.app' -prune 2>/dev/null; find \(q(home.path))/Applications -maxdepth 4 -type d -name '*.app' -prune 2>/dev/null")
            .split(separator: "\n").map(String.init))
        let mine = Set(apps.map(\.url.path))
        print("[apps] ours=\(mine.count) find=\(listed.count) onlyFind=\(listed.subtracting(mine).sorted())")
        XCTAssertEqual(mine, listed, "every app find sees should be listed")
        for app in apps {
            let verify = Shell.run("/usr/bin/codesign", ["--verify", "--no-strict", app.url.path], timeout: 120)
            let details = Shell.run("/usr/bin/codesign", ["-dv", app.url.path]).err
            let status = SecurityAuditor.signature(of: app.url)
            let line = "\(app.name): ours=\(status) codesign=\(verify.status) adhoc=\(details.contains("Signature=adhoc"))"
            switch status {
            case .developerSigned:
                XCTAssertFalse(details.contains("Signature=adhoc"), line)
                XCTAssertEqual(verify.status, 0, line)
            case .adHoc:
                XCTAssertTrue(details.contains("Signature=adhoc"), line)
                XCTAssertEqual(verify.status, 0, line)
            case .unsigned: XCTAssertTrue(details.contains("not signed"), line)
            case .invalid: XCTAssertNotEqual(verify.status, 0, line)
            case .missing: XCTFail(line)
            }
            if verify.status != 0 { print("  [codesign fails] \(line) \(verify.err.prefix(100))") }
        }
        for app in apps.prefix(8) {
            let du = (Int64(sh("du -sk \(q(app.url.path))").split(separator: "\t").first ?? "0") ?? 0) * 1024
            XCTAssertLessThan(Double(abs(app.size - du)) / Double(max(du, 1)), 0.03, app.name)
            let id = sh("/usr/bin/defaults read \(q(app.url.path + "/Contents/Info")) CFBundleIdentifier").trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(id, app.bundleID, app.name)
        }
    }

    func testStartupMatchesPlutilAndLaunchctl() throws {
        try XCTSkipUnless(enabled)
        let items = StartupManager.list(home: home)
        let disabled = sh("launchctl print-disabled gui/\(getuid())") + sh("launchctl print-disabled system")
        var expected = Set<String>()
        for folder in [home.appendingPathComponent("Library/LaunchAgents").path, "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
            for plist in sh("ls \(q(folder)) 2>/dev/null").split(separator: "\n") where plist.hasSuffix(".plist") {
                let label = sh("plutil -extract Label raw \(q(folder + "/" + plist)) 2>/dev/null").trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty, !label.hasPrefix("com.apple.") { expected.insert(label) }
            }
        }
        XCTAssertEqual(Set(items.map(\.label)), expected)
        for item in items {
            let isDisabled = disabled.contains("\"\(item.label)\" => disabled") || disabled.contains("\"\(item.label)\" => true")
            XCTAssertEqual(item.disabled, isDisabled, item.label)
            if let plist = item.plistURL {
                let program = sh("plutil -extract Program raw \(q(plist.path)) 2>/dev/null; plutil -extract ProgramArguments.0 raw \(q(plist.path)) 2>/dev/null")
                    .split(separator: "\n").first.map(String.init)
                XCTAssertEqual(item.program, program, item.label)
            }
        }
        print("[startup] \(items.count) items match plutil and launchctl")
    }

    func testSecurityMatchesRawCommands() throws {
        try XCTSkipUnless(enabled)
        let findings = SecurityAuditor.audit(startupItems: [], apps: [], includeUpdates: false)
        func ok(_ key: String) -> Bool { translationKeyedFinding(findings, key)?.severity == .ok }
        let checks: [(String, String, String)] = [
            ("系統完整性保護 (SIP)", sh("csrutil status"), "status: enabled"),
            ("Gatekeeper", sh("spctl --status 2>&1"), "assessments enabled"),
            ("FileVault 磁碟加密", sh("fdesetup status"), "FileVault is On"),
            ("防火牆", sh("/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"), "enabled"),
        ]
        for (key, raw, marker) in checks {
            print("[security] \(key): \(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70))")
            XCTAssertEqual(ok(key), raw.contains(marker), key)
        }
    }

    private func translationKeyedFinding(_ findings: [SecurityFinding], _ key: String) -> SecurityFinding? {
        findings.first { $0.title == L(key) }
    }

    func testMemoryAndDiskMatchVmStatAndDf() throws {
        try XCTSkipUnless(enabled)
        let total = Int64(sh("sysctl -n hw.memsize").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let memory = SystemMonitor.memory()
        XCTAssertEqual(memory.total, total)

        let vm = sh("vm_stat")
        func pages(_ label: String) -> Int64 {
            guard let line = vm.split(separator: "\n").first(where: { $0.hasPrefix(label) }) else { return -1 }
            return Int64(line.split(separator: ":")[1].trimmingCharacters(in: CharacterSet(charactersIn: " .\t"))) ?? -1
        }
        let page = Int64(getpagesize())
        let wired = pages("Pages wired down") * page
        let compressed = pages("Pages occupied by compressor") * page
        // Memory moves between the two samples, so allow a tenth of a gigabyte plus 10%.
        for (name, ours, theirs) in [("wired", memory.wired, wired), ("compressed", memory.compressed, compressed)] {
            print("[mem] \(name) ours=\(formatBytes(ours)) vm_stat=\(formatBytes(theirs))")
            XCTAssertLessThan(abs(ours - theirs), 100_000_000 + theirs / 10, name)
        }
        XCTAssertLessThanOrEqual(memory.app + memory.wired + memory.compressed + memory.cached + memory.free, total + total / 20,
                                 "parts must not exceed the total")
        let level = Int(sh("sysctl -n kern.memorystatus_vm_pressure_level").trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(memory.pressure.rawValue, level)
        let swap = sh("sysctl -n vm.swapusage")
        print("[mem] swap ours=\(formatBytes(memory.swapUsed)) sysctl=\(swap.trimmingCharacters(in: .whitespacesAndNewlines))")

        let top = SystemMonitor.topProcesses(limit: 5)
        for process in top {
            XCTAssertFalse(sh("ps -p \(process.pid) -o pid=").isEmpty || process.bytes <= 0, process.name)
        }

        let df = sh("df -k /").split(separator: "\n").last?.split(separator: " ", omittingEmptySubsequences: true) ?? []
        let dfTotal = (Int64(df[1]) ?? 0) * 1024
        let disk = SystemMonitor.disk()
        print("[disk] ours total=\(formatBytes(disk.total)) available=\(formatBytes(disk.available)) df total=\(formatBytes(dfTotal))")
        XCTAssertEqual(disk.total, dfTotal, accuracy: 5_000_000)
        XCTAssertGreaterThan(disk.available, 0)
        XCTAssertLessThanOrEqual(disk.available, disk.total)

        let sampler = CPUSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.3)
        let cpu = sampler.sample()
        XCTAssertTrue((0...1).contains(cpu), "\(cpu)")
    }

    func testJunkItemsAllExistPassTheGuardAndMatchDu() throws {
        try XCTSkipUnless(enabled)
        let categories = JunkScanner(home: home, runningBundleIDs: []) { _ in true }.scan()
        let pathGuard = PathGuard()
        var total = 0
        for item in categories.flatMap(\.items) {
            total += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path), item.url.path)
            XCTAssertNoThrow(try pathGuard.check(item.url), item.url.path)
            XCTAssertFalse(item.url.lastPathComponent.hasPrefix("com.apple."), item.url.path)
            XCTAssertFalse(item.url.path.contains("/Keychains"), item.url.path)
        }
        for item in categories.flatMap(\.items).sorted(by: { $0.size > $1.size }).prefix(10) {
            let du = (Int64(sh("du -sk \(q(item.url.path)) 2>/dev/null").split(separator: "\t").first ?? "0") ?? 0) * 1024
            XCTAssertLessThan(Double(abs(item.size - du)), max(5_000_000, Double(du) * 0.05), "\(item.name): ours \(item.size) du \(du)")
        }
        print("[junk] \(total) items verified")
    }
}

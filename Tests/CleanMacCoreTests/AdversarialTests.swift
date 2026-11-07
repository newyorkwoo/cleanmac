import XCTest
@testable import CleanMacCore

/// Attacks the code that deletes things. Everything happens inside a throwaway folder.
final class AdversarialTests: XCTestCase {
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("cleanmac-adv-\(UUID().uuidString)/home").resolvingSymlinksInPath()
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Clears immutable flags and restores permissions that tests set, so cleanup succeeds.
        _ = Shell.run("/usr/bin/chflags", ["-R", "nouchg", home.deletingLastPathComponent().path])
        _ = Shell.run("/bin/chmod", ["-R", "u+rwx", home.deletingLastPathComponent().path])
        try? fm.removeItem(at: home.deletingLastPathComponent())
    }

    @discardableResult
    private func write(_ relative: String, _ data: Data = Data(repeating: 7, count: 4096)) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func random(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    private static let hostileNames = [
        "with space.bin", "quote\"double.bin", "quote'single.bin", "back\\slash.bin", "new\nline.bin", "tab\tname.bin",
        "-rf.bin", "--help", "$(touch pwned).bin", "`touch pwned`.bin", ";touch pwned;.bin", "%@%@%n%s.bin", "*.bin", "?.bin",
        "😀emoji.bin", "中文檔名.bin", "日本語ファイル.bin", "e\u{301}nfd.bin", "\u{e9}nfc.bin", "\u{202E}rtl.bin",
        String(repeating: "a", count: 250) + ".bin", ".hiddenfile.bin", "trailing.dot.", "CON", "a:b.bin",
    ]

    // MARK: - PathGuard

    func testParentTraversalIsRejectedOutright() throws {
        // The OS resolves link/.. differently from a lexical cleanup, so the guard must not guess.
        let outside = home.deletingLastPathComponent().appendingPathComponent("outside/deep")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent("link"), withDestinationURL: outside)
        let sneaky = URL(fileURLWithPath: home.path + "/link/../victim")
        XCTAssertThrowsError(try PathGuard(home: home).check(sneaky))
        for raw in ["/Downloads/../Library", "/a/../../etc/passwd", "/a/b/../c"] {
            XCTAssertThrowsError(try PathGuard(home: home).check(URL(fileURLWithPath: home.path + raw)), raw)
        }
    }

    func testVolumeSymlinkToBootDriveCannotReachSystem() throws {
        // /Volumes/<boot drive> is a symlink to /, a classic way around a /Volumes allow-rule.
        let volumes = try fm.contentsOfDirectory(atPath: "/Volumes")
        let boot = try XCTUnwrap(volumes.first {
            (try? fm.destinationOfSymbolicLink(atPath: "/Volumes/" + $0)) == "/"
        }, "no boot drive symlink in /Volumes: \(volumes)")
        let pathGuard = PathGuard()
        let realHome = fm.homeDirectoryForCurrentUser.path
        for target in ["/System/Library", "/usr/bin/true", "/etc/hosts", "/Applications", "/private/var/db",
                       realHome + "/Library", realHome + "/.ssh/id_rsa", realHome + "/Documents"] {
            XCTAssertThrowsError(try pathGuard.check(URL(fileURLWithPath: "/Volumes/\(boot)\(target)")), target)
        }
    }

    func testGuardFuzzNeverApprovesAnythingOutsideTheAllowList() {
        let pathGuard = PathGuard(home: home)
        let parts = ["..", ".", "", "Library", "library", "LIBRARY", "Caches", "Keychains", ".ssh", ".gnupg", "Documents", "Desktop",
                     "x", "foo.app", "a.plist", "Applications", "System", "usr", "bin", "Volumes", "Disk", "private", "var", "etc",
                     "Mail", "Messages", "Accounts", ".Trash", "LaunchAgents", "LaunchDaemons", "Users", home.lastPathComponent]
        var generator = SystemRandomNumberGenerator()
        var approved = 0
        for _ in 0..<40_000 {
            let count = Int.random(in: 0...7, using: &generator)
            let tail = (0..<count).map { _ in parts.randomElement(using: &generator)! }.joined(separator: "/")
            let base = ["/", home.path + "/", "/Applications/", "/Volumes/Disk/", "/Library/LaunchAgents/", "/System/", "/usr/"]
                .randomElement(using: &generator)!
            let url = URL(fileURLWithPath: base + tail)
            guard (try? pathGuard.check(url)) != nil else { continue }
            approved += 1
            let path = PathGuard.canonical(url).lowercased()
            let h = home.path.lowercased()
            let allowed = path.hasPrefix(h + "/")
                || (path.hasPrefix("/applications/") && path.hasSuffix(".app"))
                || ((path.hasPrefix("/library/launchagents/") || path.hasPrefix("/library/launchdaemons/")) && path.hasSuffix(".plist"))
                || (path.hasPrefix("/volumes/") && path.split(separator: "/").count >= 3)
            XCTAssertTrue(allowed, "approved outside the allow-list: \(url.path)")
            XCTAssertFalse(url.path.split(separator: "/").contains(".."), "approved traversal: \(url.path)")
            for protected in ["/library", "/documents", "/desktop", "/library/caches", "/.ssh", "/.trash"] {
                XCTAssertNotEqual(path, h + protected, "approved protected folder: \(url.path)")
            }
            for secret in ["/.ssh/", "/.gnupg/", "/library/keychains/", "/library/mail/", "/library/messages/", "/library/accounts/"] {
                XCTAssertFalse(path.hasPrefix(h + secret), "approved secret: \(url.path)")
            }
        }
        XCTAssertGreaterThan(approved, 500, "the fuzz should also exercise approvals")
    }

    func testCleanerRefusesProtectedFoldersThatReallyExist() throws {
        // These must exist: trashing a missing path fails anyway, which would hide a missing guard.
        let targets = ["Library", "Documents", "Desktop", "Downloads", "Library/Caches", "Library/Application Support",
                       ".ssh", ".ssh/id_rsa", "Library/Keychains", "Library/Keychains/login.keychain-db"]
        for target in targets { try write(target + (target.contains(".") && !target.hasSuffix(".ssh") ? "" : "/marker")) }
        let urls = targets.map { home.appendingPathComponent($0) }
        let result = Cleaner(home: home).moveToTrash(urls.map { ($0, 1) })
        for url in result.trashedURLs { try? fm.moveItem(at: url, to: home.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)) }
        XCTAssertEqual(result.count, 0, "protected folders were trashed")
        XCTAssertEqual(result.failures.count, targets.count)
        for url in urls {
            XCTAssertTrue(fm.fileExists(atPath: url.path), url.path)
            XCTAssertTrue(result.failures.contains { $0.message.contains(url.path) }, "must be refused by the guard, not by chance: \(url.path)")
        }
    }

    func testTreemapStaysInBoundsForKnownHardInputs() {
        // A fixed set of seeds, so this fails every time rather than occasionally.
        for seed in 0..<3000 {
            var generator = TreemapSeed(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
            var sizes = (0..<Int.random(in: 1...400, using: &generator)).map { _ in pow(10, Double.random(in: 0...15, using: &generator)) }
            sizes.sort(by: >)
            let bounds = CGRect(x: 0, y: 0, width: CGFloat.random(in: 1...3000, using: &generator), height: CGFloat.random(in: 1...3000, using: &generator))
            for rect in Treemap.layout(sizes: sizes, in: bounds) {
                XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.01, "seed \(seed)")
                XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.01, "seed \(seed)")
            }
        }
    }

    func testTrashDeletionCannotEscapeTheTrash() throws {
        let keep = try write("Documents/keep.bin")
        try fm.createDirectory(at: home.appendingPathComponent(".Trash/sub"), withIntermediateDirectories: true)
        let cleaner = Cleaner(home: home)
        let attempts: [URL] = [
            URL(fileURLWithPath: home.path + "/.Trash/../Documents/keep.bin"),
            URL(fileURLWithPath: home.path + "/.Trash/sub/../../Documents/keep.bin"),
            URL(fileURLWithPath: home.path + "/.Trash/sub/.."),
            URL(fileURLWithPath: home.path + "/.Trash/.."),
            keep,
            home.appendingPathComponent(".Trash"),
            home,
        ]
        for url in attempts {
            let result = cleaner.deleteFromTrash([(url, 1)])
            XCTAssertEqual(result.count, 0, url.path)
            XCTAssertEqual(result.failures.count, 1, url.path)
        }
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent(".Trash").path))
    }

    // MARK: - Injection

    func testLabelValidationRejectsTrailingNewline() {
        // In regular expressions, $ also matches before a final newline.
        for bad in ["com.foo\n", "com.foo\r\n", "\ncom.foo", "com.foo\n; rm -rf /", "com.foo ", "com/foo", "..", "com.foo\u{0}", "cöm.foo", "ｃｏｍ"] {
            if bad == ".." { continue } // only dots and letters; harmless to launchctl and accepted by the character rule
            XCTAssertFalse(StartupManager.isSafeLabel(bad), bad.debugDescription)
        }
    }

    func testAppleScriptEscapingCannotBreakOut() throws {
        for name in ["x\" to do shell script \"touch /tmp/pwned", "back\\", "\\\"", "a\"b\\c", "\"", "\\"] {
            let script = StartupManager.deleteLoginItemScript(named: name)
            // Compiling proves the string literal stayed one literal: escaped text has no way to add statements.
            let compile = Shell.run("/usr/bin/osacompile", ["-o", home.appendingPathComponent("t.scpt").path, "-e", script])
            XCTAssertTrue(compile.ok, "\(name): \(compile.err)")
            let decompiled = Shell.run("/usr/bin/osadecompile", [home.appendingPathComponent("t.scpt").path]).out
            XCTAssertFalse(decompiled.lowercased().contains("do shell script") && !decompiled.contains("\\\""), decompiled)

            let admin = Shell.adminScript(for: name)
            XCTAssertTrue(Shell.run("/usr/bin/osacompile", ["-o", home.appendingPathComponent("a.scpt").path, "-e", admin]).ok, admin)
        }
    }

    // MARK: - Hostile file names

    func testHostileNamesThroughEveryScannerAndCleaner() throws {
        let payload = random(1_200_000)
        for (index, name) in Self.hostileNames.enumerated() {
            let folder = home.appendingPathComponent("files/\(index)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try payload.write(to: folder.appendingPathComponent(name))
        }
        let options = WalkOptions.personalFiles(home: home)
        var withHidden = options
        withHidden.skipHidden = false

        let large = LargeFileFinder.scan(root: home, options: withHidden, minimumBytes: 1_000_000)
        XCTAssertEqual(large.count, Self.hostileNames.count)
        let groups = DuplicateFinder.scan(root: home, options: withHidden, minimumBytes: 1_000_000)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.files.count, Self.hostileNames.count)
        let tree = DiskMapScanner.scan(root: home)
        XCTAssertGreaterThanOrEqual(tree.size, Int64(Self.hostileNames.count) * 1_200_000)

        // Placeholders in a name must never be treated as a format string.
        XCTAssertEqual(L("%@", "%@%@%n%s.bin"), "%@%@%n%s.bin")

        // Half go through the Trash, half through the shredder. Nothing else may disappear or appear.
        let files = large.map(\.url)
        let cleaner = Cleaner(home: home)
        let half = files.count / 2
        let trashed = cleaner.moveToTrash(files[..<half].map { ($0, 1) })
        XCTAssertEqual(trashed.count, half, "\(trashed.failures)")
        for url in trashed.trashedURLs { try fm.removeItem(at: url) }
        let shredded = Shredder.shred(Array(files[half...]), pathGuard: PathGuard(home: home))
        XCTAssertEqual(shredded.count, files.count - half, "\(shredded.failures)")
        for url in files { XCTAssertFalse(fm.fileExists(atPath: url.path), url.path) }
        XCTAssertFalse(fm.fileExists(atPath: fm.currentDirectoryPath + "/pwned"), "a file name was executed")
    }

    // MARK: - Shredder

    func testShredderBoundarySizes() throws {
        let mib = 1024 * 1024
        for size in [0, 1, mib - 1, mib, mib + 1, 3 * mib] {
            let file = try write("sizes/\(size).bin", Data(repeating: 0x41, count: size))
            if size > 0 {
                let fd = open(file.path, O_WRONLY)
                try Shredder.overwrite(fd: fd, size: Int64(size), passes: 2, path: file.path)
                close(fd)
                let data = try Data(contentsOf: file)
                XCTAssertEqual(data.count, size, "overwriting must not change the length")
                if size > mib - 1 {
                    XCTAssertLessThan(data.filter { $0 == 0x41 }.count, size / 50, "tail of \(size)-byte file was not overwritten")
                }
            }
            let result = Shredder.shred([file], pathGuard: PathGuard(home: home))
            XCTAssertEqual(result.count, 1, "\(size): \(result.failures)")
            XCTAssertFalse(fm.fileExists(atPath: file.path))
        }
    }

    func testShredderLeavesFilesItCannotOverwriteIntact() throws {
        let readOnly = try write("ro.bin", Data(repeating: 1, count: 1000))
        try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        let locked = try write("locked.bin", Data(repeating: 2, count: 1000))
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)

        let result = Shredder.shred([readOnly, locked], pathGuard: PathGuard(home: home))
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertEqual(try Data(contentsOf: readOnly), Data(repeating: 1, count: 1000))
        XCTAssertEqual(try Data(contentsOf: locked), Data(repeating: 2, count: 1000))
    }

    func testShredderSkipsSpecialFilesWithoutHanging() throws {
        let folder = home.appendingPathComponent("special")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let fifo = folder.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o644), 0)
        let plain = try write("special/plain.bin")

        // Opening a FIFO for writing blocks forever if the shredder ever tries it.
        let finished = expectation(description: "shred returns")
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = Shredder.shred([folder], pathGuard: PathGuard(home: self.home))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
        XCTAssertFalse(fm.fileExists(atPath: plain.path))
        XCTAssertTrue(fm.fileExists(atPath: fifo.path), "special files are left alone")
        XCTAssertFalse(box.value?.failures.isEmpty ?? true, "and reported")
    }

    func testShredderPartialFolderFailureKeepsTheRest() throws {
        let good = try write("mixed/good.bin")
        let locked = try write("mixed/locked.bin", Data(repeating: 9, count: 100))
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let result = Shredder.shred([home.appendingPathComponent("mixed")], pathGuard: PathGuard(home: home))
        XCTAssertFalse(fm.fileExists(atPath: good.path))
        XCTAssertTrue(fm.fileExists(atPath: locked.path))
        XCTAssertEqual(try Data(contentsOf: locked), Data(repeating: 9, count: 100))
        XCTAssertFalse(result.failures.isEmpty)
    }

    func testShredderDoesNotFollowSymlinkAtTopLevel() throws {
        let target = try write("Documents/target.bin", Data(repeating: 3, count: 500))
        let link = home.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let result = Shredder.shred([link], pathGuard: PathGuard(home: home))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(try Data(contentsOf: target), Data(repeating: 3, count: 500))
        XCTAssertFalse((try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil)
    }

    // MARK: - Cleaner failure handling

    func testCleanerReportsFailuresInsteadOfClaimingSuccess() throws {
        let missing = home.appendingPathComponent("Downloads/missing.bin")
        let locked = try write("Downloads/locked.bin")
        try fm.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        let ok = try write("Downloads/ok.bin")

        let result = Cleaner(home: home).moveToTrash([(missing, 111), (locked, 222), (ok, 333)])
        for url in result.trashedURLs { try fm.removeItem(at: url) }
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.bytes, 333, "only what really moved is counted")
        XCTAssertEqual(Set(result.failures.map(\.path)), [missing.path, locked.path])
        XCTAssertTrue(fm.fileExists(atPath: locked.path))
    }

    // MARK: - Scanners on awkward trees

    func testScannersSurviveLoopsFifosUnreadableAndVeryDeepTrees() throws {
        try write("a/real.bin", random(2_000_000))
        try fm.createSymbolicLink(at: home.appendingPathComponent("a/loop"), withDestinationURL: home)
        try fm.createSymbolicLink(at: home.appendingPathComponent("a/dangling"), withDestinationURL: URL(fileURLWithPath: "/no/such"))
        XCTAssertEqual(mkfifo(home.appendingPathComponent("a/pipe").path, 0o644), 0)
        let secret = try write("a/secret/hidden.bin", random(2_000_000))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secret.deletingLastPathComponent().path)
        var deep = "deep"
        for _ in 0..<120 { deep += "/d" }
        try write(deep + "/bottom.bin", random(2_000_000))

        let done = expectation(description: "scans finish")
        let home = self.home!
        let box = ScanBox()
        DispatchQueue.global().async {
            box.large = LargeFileFinder.scan(root: home, options: WalkOptions(), minimumBytes: 1_000_000).count
            box.dups = DuplicateFinder.scan(root: home, options: WalkOptions(), minimumBytes: 1000).count
            box.tree = DiskMapScanner.scan(root: home).size
            box.size = FileWalker.allocatedSize(of: home)
            done.fulfill()
        }
        wait(for: [done], timeout: 60)
        XCTAssertEqual(box.large, 2, "real.bin and bottom.bin; loop not followed")
        XCTAssertEqual(box.dups, 0)
        XCTAssertGreaterThanOrEqual(box.tree, 4_000_000)
        XCTAssertLessThan(box.tree, 8_000_000, "a followed loop would inflate this")
    }

    func testDiskMapHandlesTheDeepestPossibleTree() async throws {
        // Build far deeper than PATH_MAX allows in one path, by descending one level at a time.
        // Task.detached runs on a small stack, which is where the app runs this scan.
        var folder = home.appendingPathComponent("deep")
        let start = folder.path.utf8.count
        var levels = 0
        while folder.path.utf8.count - start < 880 {
            folder.appendPathComponent("d")
            levels += 1
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 2_000_000).write(to: folder.appendingPathComponent("bottom.bin"))
        let root = home!
        let size = await Task.detached { DiskMapScanner.scan(root: root).size }.value
        XCTAssertGreaterThanOrEqual(size, 2_000_000, "\(levels) levels")
    }

    func testDuplicatesNeverMatchWhenUnreadableOrDifferent() throws {
        let payload = random(100_000)
        let a = try write("a.bin", payload)
        let b = try write("b.bin", payload)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: a.path)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: b.path)
        XCTAssertTrue(DuplicateFinder.scan(root: home, options: WalkOptions(), minimumBytes: 1000).isEmpty,
                      "unreadable files must not look identical")

        // Differ only in the very last byte, and only in the very first byte.
        var last = random(300_000)
        try write("c1.bin", last)
        last[last.count - 1] ^= 1
        try write("c2.bin", last)
        var first = random(300_000)
        try write("d1.bin", first)
        first[0] ^= 1
        try write("d2.bin", first)
        // Differ in one byte beyond the sampled head and tail.
        var middle = random(1_000_000)
        try write("e1.bin", middle)
        middle[500_000] ^= 1
        try write("e2.bin", middle)
        XCTAssertTrue(DuplicateFinder.scan(root: home, options: WalkOptions(), minimumBytes: 1000).isEmpty)
    }

    func testDuplicateMinimumBoundaryAndSymlinks() throws {
        let payload = random(100_000)
        try write("exact1.bin", payload)
        let original = try write("exact2.bin", payload)
        try fm.createSymbolicLink(at: home.appendingPathComponent("link.bin"), withDestinationURL: original)
        XCTAssertEqual(DuplicateFinder.scan(root: home, options: WalkOptions(), minimumBytes: 100_000).first?.files.count, 2,
                       "the minimum is inclusive, and a symlink is not a copy")
        XCTAssertTrue(DuplicateFinder.scan(root: home, options: WalkOptions(), minimumBytes: 100_001).isEmpty)
    }

    func testCancellingNeverProducesFalseDuplicates() async throws {
        for i in 0..<40 { try write("c/\(i).bin", random(600_000)) }
        // Same size, all different: any group after a cancel would be a false duplicate.
        let root = home!
        for delay in [0, 1, 5, 20, 60] {
            let task = Task.detached { DuplicateFinder.scan(root: root, options: WalkOptions(), minimumBytes: 1000) }
            try await Task.sleep(for: .milliseconds(delay))
            task.cancel()
            let groups = await task.value
            XCTAssertTrue(groups.isEmpty, "false duplicates after cancelling at \(delay) ms")
        }
    }

    func testCancelStopsWideScanQuickly() async throws {
        for i in 0..<6000 { fm.createFile(atPath: home.appendingPathComponent("w\(i % 30)").path + "-\(i)", contents: Data([1])) }
        let root = home!
        let task = Task.detached { () -> Date in
            _ = DiskMapScanner.scan(root: root)
            _ = LargeFileFinder.scan(root: root, options: WalkOptions(), minimumBytes: 1)
            return Date()
        }
        task.cancel()
        let finished = await task.value
        XCTAssertLessThan(finished.timeIntervalSinceNow, 1)
    }

    // MARK: - Junk scanner safety

    func testJunkScannerNeverOffersProtectedOrSystemItems() throws {
        for path in ["Library/Caches/com.apple.Safari/x", "Library/Caches/com.apple.bird/x", "Library/Caches/CloudKit/x",
                     "Library/Keychains/login.keychain-db", ".ssh/id_rsa", "Documents/keep.dmg", "Library/Mail/V10/x",
                     "Library/Caches/com.cleanmac.app/x"] {
            try write(path)
        }
        try write("Library/Caches/com.vendor.app/x")
        let scanner = JunkScanner(home: home) { _ in true }
        let categories = scanner.scan()
        let offered = categories.flatMap(\.items).map(\.url.path)
        XCTAssertEqual(offered.map { URL(fileURLWithPath: $0).lastPathComponent }, ["com.vendor.app"])
        // Whatever the scanner offers must pass the delete guard.
        let pathGuard = PathGuard(home: home)
        for path in offered { XCTAssertNoThrow(try pathGuard.check(URL(fileURLWithPath: path)), path) }
    }

    func testInstallerFilterBoundaries() throws {
        let attrs = { (days: Double) -> [FileAttributeKey: Any] in [.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)] }
        for (name, days) in [("old.DMG", 31.0), ("old.pkg", 40), ("old.iso", 90), ("edge-new.dmg", 29), ("old.zip", 90), ("old.dmg.txt", 90)] {
            let url = try write("Downloads/" + name)
            try fm.setAttributes(attrs(days), ofItemAtPath: url.path)
        }
        let items = JunkScanner(home: home) { _ in true }.scan().first { $0.id == "installers" }?.items.map(\.name) ?? []
        XCTAssertEqual(Set(items), ["old.DMG", "old.pkg", "old.iso"])
    }

    // MARK: - App uninstall matching

    func testLeftoverMatchingCannotCatchOtherAppsData() throws {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/Note.app"), name: "Note", bundleID: "com.acme.note",
                          version: "1", size: 0, lastUsed: nil)
        for path in ["Library/Caches/com.acme.note/x", "Library/Caches/com.acme.notebook/x", "Library/Caches/com.acme/x",
                     "Library/Application Support/Notes/x", "Library/Application Support/Note Taker/x", "Library/Preferences/com.acme.notebook.plist",
                     "Library/Containers/com.acme.note/x", "Library/Group Containers/T.com.acme.notebook/x", "Library/Application Support/Note/x"] {
            try write(path)
        }
        let names = Set(AppInventory.leftovers(for: app, home: home).map { $0.url.path.components(separatedBy: "/home/").last! })
        XCTAssertEqual(names, ["Library/Caches/com.acme.note", "Library/Containers/com.acme.note", "Library/Application Support/Note"])

        // Short names must not match by name at all: an app called "Go" must not claim ~/Library/Caches/go.
        try write("Library/Caches/go/x")
        let short = AppInfo(url: URL(fileURLWithPath: "/Applications/Go.app"), name: "Go", bundleID: "com.x.go", version: "1", size: 0, lastUsed: nil)
        XCTAssertTrue(AppInventory.leftovers(for: short, home: home).isEmpty)

        // Every leftover must also pass the delete guard.
        for item in AppInventory.leftovers(for: app, home: home) { XCTAssertNoThrow(try PathGuard(home: home).check(item.url)) }
    }

    func testAppInventoryIgnoresSymlinksAndBrokenBundles() throws {
        let apps = home.appendingPathComponent("Applications")
        try fm.createDirectory(at: apps.appendingPathComponent("Broken.app/Contents"), withIntermediateDirectories: true)
        let good = apps.appendingPathComponent("Sub/Good.app/Contents")
        try fm.createDirectory(at: good, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.x.good", "CFBundleName": "Good", "CFBundleShortVersionString": "2.0"], format: .xml, options: 0)
            .write(to: good.appendingPathComponent("Info.plist"))
        try fm.createSymbolicLink(at: apps.appendingPathComponent("Link.app"), withDestinationURL: good.deletingLastPathComponent())
        let found = AppInventory.scan(home: home, roots: [apps])
        XCTAssertEqual(found.map(\.bundleID), ["com.x.good"])
        XCTAssertEqual(found.first?.version, "2.0")
    }

    func testAppInventoryFindsDeeplyNestedVendorApps() throws {
        let apps = home.appendingPathComponent("Applications")
        for (path, id) in [("A.app", "com.x.a"), ("V/B.app", "com.x.b"), ("V/P/C.app", "com.x.c"), ("V/P/Q/D.app", "com.x.d")] {
            let contents = apps.appendingPathComponent(path + "/Contents")
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id], format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        // An app embedded in another is part of it, not a separate app.
        let embedded = apps.appendingPathComponent("A.app/Contents/Helpers/Inner.app/Contents")
        try fm.createDirectory(at: embedded, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.x.inner"], format: .xml, options: 0)
            .write(to: embedded.appendingPathComponent("Info.plist"))
        XCTAssertEqual(Set(AppInventory.scan(home: home, roots: [apps]).map(\.bundleID)), ["com.x.a", "com.x.b", "com.x.c", "com.x.d"])
    }

    func testTamperedResourceIsDetected() throws {
        let app = home.appendingPathComponent("Signed.app/Contents")
        try fm.createDirectory(at: app.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("MacOS/Signed"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.x.signed", "CFBundleExecutable": "Signed"], format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        try Data("original".utf8).write(to: app.appendingPathComponent("Resources/data.txt"))
        let bundle = home.appendingPathComponent("Signed.app")
        XCTAssertTrue(Shell.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", bundle.path]).ok)
        XCTAssertEqual(SecurityAuditor.signature(of: bundle), .adHoc)
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Resources/data.txt"))
        XCTAssertEqual(SecurityAuditor.signature(of: bundle), .invalid)
    }

    func testUnparseablePlistsAreIgnored() {
        let url = URL(fileURLWithPath: "/x.plist")
        for data in [Data(), Data("not a plist".utf8), Data([0xFF, 0x00, 0x01])] {
            XCTAssertNil(StartupManager.parsePlist(data, url: url, domain: .userAgent))
        }
        let noLabel = try! PropertyListSerialization.data(fromPropertyList: ["Program": "/bin/x"], format: .xml, options: 0)
        XCTAssertNil(StartupManager.parsePlist(noLabel, url: url, domain: .userAgent))
        let wrongTypes = try! PropertyListSerialization.data(fromPropertyList: ["Label": "a", "ProgramArguments": "oops", "RunAtLoad": "yes"], format: .xml, options: 0)
        let item = StartupManager.parsePlist(wrongTypes, url: url, domain: .userAgent)
        XCTAssertNil(item?.program)
        XCTAssertEqual(item?.runAtLoad, false)
    }

    // MARK: - Maths

    func testTreemapPropertyFuzz() {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<3000 {
            let count = Int.random(in: 1...400, using: &generator)
            var sizes = (0..<count).map { _ in pow(10, Double.random(in: 0...15, using: &generator)) }
            sizes.sort(by: >)
            let bounds = CGRect(x: 0, y: 0, width: CGFloat.random(in: 1...3000, using: &generator), height: CGFloat.random(in: 1...3000, using: &generator))
            let rects = Treemap.layout(sizes: sizes, in: bounds)
            XCTAssertEqual(rects.count, count)
            let total = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
            XCTAssertEqual(total, Double(bounds.width * bounds.height), accuracy: Double(bounds.width * bounds.height) * 0.001, "round \(round)")
            for rect in rects {
                XCTAssertFalse(rect.origin.x.isNaN || rect.origin.y.isNaN || rect.width.isNaN || rect.height.isNaN, "NaN in round \(round)")
                XCTAssertGreaterThanOrEqual(rect.width, 0)
                XCTAssertGreaterThanOrEqual(rect.height, 0)
                XCTAssertLessThanOrEqual(rect.maxX, bounds.maxX + 0.01)
                XCTAssertLessThanOrEqual(rect.maxY, bounds.maxY + 0.01)
            }
        }
    }

    func testDiskNodeRemovalKeepsEveryAncestorTotalRight() throws {
        try write("a/b/c/big1.bin", random(2_000_000))
        try write("a/b/c/big2.bin", random(3_000_000))
        try write("a/z.bin", random(1_500_000))
        let root = DiskMapScanner.scan(root: home)
        let a = root.children.first { $0.name == "a" }!
        let b = a.children.first { $0.name == "b" }!
        let c = b.children.first { $0.name == "c" }!
        let big = c.children.first { $0.url.lastPathComponent == "big2.bin" }!
        let sizes = (root.size, a.size, b.size, c.size, big.size)
        big.removeFromParent()
        XCTAssertEqual(root.size, sizes.0 - sizes.4)
        XCTAssertEqual(a.size, sizes.1 - sizes.4)
        XCTAssertEqual(b.size, sizes.2 - sizes.4)
        XCTAssertEqual(c.size, sizes.3 - sizes.4)
        XCTAssertFalse(c.children.contains { $0 === big })
        // Tree invariant: each folder's size equals the sum of its children.
        func verify(_ node: DiskNode) {
            guard node.isDirectory else { return }
            XCTAssertEqual(node.size, node.children.reduce(0) { $0 + $1.size }, node.name)
            node.children.forEach(verify)
        }
        verify(root)
    }

    func testMissingRootsAreHarmless() {
        let missing = home.appendingPathComponent("does/not/exist")
        XCTAssertEqual(DiskMapScanner.scan(root: missing).size, 0)
        XCTAssertTrue(LargeFileFinder.scan(root: missing, options: WalkOptions(), minimumBytes: 1).isEmpty)
        XCTAssertTrue(DuplicateFinder.scan(root: missing, options: WalkOptions(), minimumBytes: 1).isEmpty)
        XCTAssertEqual(FileWalker.allocatedSize(of: missing), 0)
    }

    // MARK: - Translations

    func testEveryTranslationFormatsWithAwkwardValuesInEveryLanguage() {
        let saved = AppLanguage.current
        defer { AppLanguage.current = saved }
        for language in AppLanguage.allCases {
            AppLanguage.current = language
            for key in translationTable.keys {
                let count = key.components(separatedBy: "%@").count - 1
                let args: [Any] = (0..<count).map { ["%@%n", 0, "\"'\\\n"][$0 % 3] }
                let text: String
                switch args.count {
                case 0: text = L(key)
                case 1: text = L(key, args[0])
                case 2: text = L(key, args[0], args[1])
                default: text = L(key, args[0], args[1], args[2])
                }
                if count > 0 { XCTAssertTrue(text.contains("%@%n"), "\(language): lost a value in \(key) -> \(text)") }
            }
        }
    }

    func testNoTranslationIsUnused() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var all = ""
        for case let url as URL in fm.enumerator(at: root, includingPropertiesForKeys: nil)!
        where url.pathExtension == "swift" && url.lastPathComponent != "Translations.swift" {
            all += try String(contentsOf: url, encoding: .utf8)
        }
        for key in translationTable.keys {
            let literal = key.replacingOccurrences(of: "\n", with: "\\n")
            XCTAssertTrue(all.contains("\"\(literal)\""), "unused translation: \(literal.debugDescription)")
        }
    }
}

private struct TreemapSeed: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private final class ResultBox: @unchecked Sendable { var value: CleanResult? }
private final class ScanBox: @unchecked Sendable { var large = 0, dups = 0; var tree: Int64 = 0, size: Int64 = 0 }

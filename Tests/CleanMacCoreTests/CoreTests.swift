import AppKit
import XCTest
@testable import CleanMacCore

final class CoreTests: XCTestCase {
    var sandbox: URL!
    var home: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanmac-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = sandbox.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    @discardableResult
    private func write(_ relative: String, bytes: Int = 8192, fill: UInt8 = 1, base: URL? = nil) throws -> URL {
        let url = (base ?? home).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: fill, count: bytes).write(to: url)
        return url
    }

    private func randomData(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    // MARK: - PathGuard

    func testFullDiskAccessIgnoresMissingProbes() throws {
        let readable = home.appendingPathComponent("readable")
        try Data().write(to: readable)
        let missing = home.appendingPathComponent("missing").path

        XCTAssertTrue(hasFullDiskAccess(probes: [missing, readable.path]))
        XCTAssertFalse(hasFullDiskAccess(probes: [missing]))
    }

    func testFullDiskAccessIsFalseWhenProbeIsDenied() throws {
        let denied = home.appendingPathComponent("denied")
        try Data().write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }

        XCTAssertFalse(hasFullDiskAccess(probes: [denied.path]))
    }

    func testFullDiskAccessProbesIncludeSystemDatabase() {
        XCTAssertTrue(fullDiskAccessProbes(home: home).contains("/Library/Application Support/com.apple.TCC/TCC.db"))
    }

    func testGuardRejectsEverythingImportant() {
        let pathGuard = PathGuard(home: home)
        let rejected: [URL] = [
            home, home.appendingPathComponent("Library"), home.appendingPathComponent("Documents"),
            home.appendingPathComponent("library/caches"), // the volume is case-insensitive
            home.appendingPathComponent("Library/Application Support"),
            home.appendingPathComponent(".ssh/id_rsa"), home.appendingPathComponent("Library/Keychains/login.keychain-db"),
            home.appendingPathComponent("Documents/../Library"),
            URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System/Library/foo"), URL(fileURLWithPath: "/usr/bin/true"),
            URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/notes.txt"),
            URL(fileURLWithPath: "/Library/Preferences/x.plist"), URL(fileURLWithPath: "/Volumes/Disk"),
            sandbox.appendingPathComponent("other-user/file"),
        ]
        for url in rejected {
            XCTAssertThrowsError(try pathGuard.check(url), "should reject \(url.path)")
        }
    }

    func testGuardAllowsNormalTargets() throws {
        let pathGuard = PathGuard(home: home)
        let allowed: [URL] = [
            home.appendingPathComponent("Library/Caches/com.foo"), home.appendingPathComponent("Downloads/a.dmg"),
            home.appendingPathComponent("project/file.bin"), URL(fileURLWithPath: "/Applications/Foo.app"),
            URL(fileURLWithPath: "/Library/LaunchAgents/com.foo.plist"), URL(fileURLWithPath: "/Volumes/Disk/file"),
        ]
        for url in allowed { XCTAssertNoThrow(try pathGuard.check(url), url.path) }
    }

    func testGuardSeesThroughSymlinkedParent() throws {
        // ~/link -> /usr: ~/link/bin must be judged as /usr/bin.
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/usr"))
        XCTAssertThrowsError(try PathGuard(home: home).check(home.appendingPathComponent("link/bin")))
        // The link itself is an ordinary removable entry.
        XCTAssertNoThrow(try PathGuard(home: home).check(home.appendingPathComponent("link")))
    }

    func testMoveToTrashIsRecoverableAndGuarded() throws {
        let file = try write("Downloads/item.bin")
        let result = Cleaner(home: home).moveToTrash([
            (file, 8192), (home.appendingPathComponent("Library"), 1),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let trashed = try XCTUnwrap(result.trashedURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        try FileManager.default.removeItem(at: trashed) // don't leave test files in the real Trash
    }

    func testDeleteFromTrashOnlyTouchesTrashChildren() throws {
        let inTrash = try write(".Trash/old.bin")
        let outside = try write("Documents/keep.bin")
        let result = Cleaner(home: home).deleteFromTrash([(inTrash, 1), (outside, 1)])
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inTrash.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: - Emptying the Trash (Finder is simulated, so nothing is really emptied)

    private func fakeFinder(counts: [String], empty: Shell.Output) -> (String) -> Shell.Output {
        var remaining = counts
        return { script in
            if script.contains("empty trash") { return empty }
            return Shell.Output(status: 0, out: remaining.removeFirst(), err: "")
        }
    }

    func testEmptyTrashOutcomes() {
        let cancelled = Shell.Output(status: 1, out: "", err: "execution error: Finder (-128)")
        let ok = Shell.Output(status: 0, out: "", err: "")
        XCTAssertEqual(TrashEmptier.run(script: fakeFinder(counts: ["3"], empty: ok)), .emptied)
        XCTAssertEqual(TrashEmptier.run(script: fakeFinder(counts: ["3", "3"], empty: cancelled)), .cancelled)
        XCTAssertEqual(TrashEmptier.run(script: fakeFinder(counts: ["3", "0"], empty: cancelled)), .emptied)
        let denied = Shell.Output(status: 1, out: "", err: "not authorized (-1743)\n")
        XCTAssertEqual(TrashEmptier.run(script: fakeFinder(counts: ["3"], empty: denied)), .failed("not authorized (-1743)"))
    }

    func testEmptyTrashSkipsFinderWhenAlreadyEmpty() {
        var emptyCalled = false
        let outcome = TrashEmptier.run { script in
            if script.contains("empty trash") { emptyCalled = true }
            return Shell.Output(status: 0, out: "0\n", err: "")
        }
        XCTAssertEqual(outcome, .alreadyEmpty)
        XCTAssertFalse(emptyCalled)
    }

    // MARK: - Junk

    func testJunkScannerCategoriesAndDefaults() throws {
        try write("Library/Caches/com.foo.app/data")
        try write("Library/Caches/com.running.app/data")
        try write("Library/Caches/com.apple.Safari/data")
        try write("Library/Caches/CloudKit/data")
        try write("Library/Caches/Google/Chrome/Default/cache")
        try write("Library/Caches/Homebrew/x.tar.gz")
        try write("Library/Logs/foo.log")
        try write("Library/Developer/Xcode/DerivedData/Proj-abc/index")
        try write(".Trash/old.bin")
        let oldInstaller = try write("Downloads/old.dmg")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60 * 86_400)], ofItemAtPath: oldInstaller.path)
        try write("Downloads/new.dmg")
        try write("Downloads/old-document.pdf")
        try write("Library/Saved Application State/com.gone.app.savedState/data")
        try write("Library/Saved Application State/com.here.app.savedState/data")

        let scanner = JunkScanner(home: home, runningBundleIDs: ["com.running.app"]) { $0 == "com.here.app" }
        let categories = Dictionary(uniqueKeysWithValues: scanner.scan().map { ($0.id, $0) })

        let userNames = try XCTUnwrap(categories["user-cache"]).items.map(\.name)
        XCTAssertEqual(Set(userNames), ["com.foo.app", "com.running.app"], "system and categorized caches stay out")
        XCTAssertTrue(try XCTUnwrap(categories["user-cache"]).items.first { $0.name == "com.running.app" }!.inUse)
        XCTAssertEqual(categories["browser-cache"]?.items.map(\.name), ["Chrome"])
        XCTAssertEqual(categories["dev-cache"]?.defaultSelected, false)
        XCTAssertEqual(categories["installers"]?.items.map(\.name), ["old.dmg"])
        XCTAssertEqual(categories["orphans"]?.items.map(\.name), ["~/Library/Saved Application State/com.gone.app.savedState"])
        XCTAssertEqual(categories["trash"]?.permanent, true)
        XCTAssertEqual(categories["trash"]?.defaultSelected, false)
    }

    func testOrphanDetectionRespectsParentAppsAndApple() {
        let scanner = JunkScanner(home: home) { $0 == "com.foo.app" }
        XCTAssertFalse(scanner.isOrphan("com.foo.app.helper"))
        XCTAssertFalse(scanner.isOrphan("com.apple.Music"))
        XCTAssertFalse(scanner.isOrphan("notAnIdentifier"))
        XCTAssertTrue(scanner.isOrphan("com.gone.app"))
    }

    func testDeepOrphanScanCoversLibraryFoldersAndKeepsInstalledVendors() throws {
        let system = sandbox.appendingPathComponent("Library")
        try write("Library/Application Support/com.gone.app/data")
        try write("Library/Preferences/com.gone.app.plist")
        try write("Library/Preferences/ByHost/com.gone.app.0A1B2C3D-0000-0000-0000-000000000000.plist")
        try write("Library/Group Containers/ABCDE12345.com.gone.app/data")
        try write("Library/HTTPStorages/com.gone.app.binarycookies")
        // Same vendor as an installed product, so shared data stays.
        try write("Library/Preferences/com.kept.shared.plist")
        // macOS's own namespaces and names that aren't bundle IDs stay.
        try write("Library/Preferences/org.cups.PrintingPrefs.plist")
        try write("Library/Application Support/Some Folder 1.2.3/data")
        try write("Library/Caches/com.gone.app/data")

        func job(_ label: String, program: String, in folder: String, base: URL) throws {
            let url = base.appendingPathComponent(folder).appendingPathComponent(label + ".plist")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist: [String: Any] = ["Label": label, "Program": program]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        }
        let existing = try write("bin/tool")
        try job("com.gone.agent", program: home.appendingPathComponent("bin/missing").path, in: "Library/LaunchAgents", base: home)
        try job("homebrew.mxcl.db", program: existing.path, in: "Library/LaunchAgents", base: home)

        try write("Application Support/com.gone.app/data", base: system)
        try write("Preferences/com.gone.app.plist", base: system)
        try write("PrivilegedHelperTools/com.gone.helper", base: system)
        try write("PrivilegedHelperTools/com.used.helper", base: system)
        try job("com.gone.daemon", program: system.appendingPathComponent("PrivilegedHelperTools/com.gone.missing").path,
                in: "LaunchDaemons", base: system)
        try job("com.used.daemon", program: system.appendingPathComponent("PrivilegedHelperTools/com.used.helper").path,
                in: "LaunchDaemons", base: system)

        let scanner = JunkScanner(home: home, installedBundleIDs: ["com.kept.app"], systemRoot: system) { _ in false }
        let items = try XCTUnwrap(scanner.scan().first { $0.id == "orphans" }).items
        XCTAssertEqual(Set(items.filter { !$0.isSystem }.map(\.name)), [
            "~/Library/Application Support/com.gone.app", "~/Library/Preferences/com.gone.app.plist",
            "~/Library/Preferences/ByHost/com.gone.app.0A1B2C3D-0000-0000-0000-000000000000.plist",
            "~/Library/Group Containers/ABCDE12345.com.gone.app", "~/Library/HTTPStorages/com.gone.app.binarycookies",
            "~/Library/LaunchAgents/com.gone.agent.plist",
        ])
        XCTAssertEqual(Set(items.filter(\.isSystem).map(\.url.lastPathComponent)), [
            "com.gone.app", "com.gone.app.plist", "com.gone.helper", "com.gone.daemon.plist",
        ])
        XCTAssertNil(try XCTUnwrap(scanner.scan().first { $0.id == "orphans" }).items.first { $0.url.lastPathComponent == "com.used.helper" })
    }

    func testOrphanIdentifierParsing() {
        XCTAssertEqual(JunkScanner.identifier(in: "com.foo.app.plist"), "com.foo.app")
        XCTAssertEqual(JunkScanner.identifier(in: "com.foo.app.savedState"), "com.foo.app")
        XCTAssertEqual(JunkScanner.identifier(in: "group.com.foo.app"), "com.foo.app")
        XCTAssertEqual(JunkScanner.identifier(in: "UBF8T346G9.com.foo.app"), "com.foo.app")
        XCTAssertNil(JunkScanner.identifier(in: "UBF8T346G9.Office"))
        XCTAssertNil(JunkScanner.identifier(in: "Foo 1.2.3"))
        XCTAssertNil(JunkScanner.identifier(in: "1.2.3"))
        XCTAssertEqual(JunkScanner.identifier(in: "L82V4Y2P3C.group.com.wireguard.macos"), "com.wireguard.macos")
        let scanner = JunkScanner(home: home) { _ in false }
        XCTAssertFalse(scanner.isOrphan(JunkScanner.identifier(in: "243LU875E5.groups.com.apple.podcasts")!))
        XCTAssertFalse(scanner.isOrphan(JunkScanner.identifier(in: "group.is.workflow.shortcuts")!))
        XCTAssertFalse(scanner.isOrphan("org.sparkle-project.DownloaderService"))
        let withCLI = JunkScanner(home: home, installedCommands: ["vercel", "cli"]) { _ in false }
        XCTAssertFalse(withCLI.isOrphan("com.vercel.cli"), "an installed command keeps its data")
        XCTAssertTrue(withCLI.isOrphan("com.gone.cli"), "generic words like cli don't count")
    }

    func testContainersOfAnInstalledDeveloperStay() throws {
        let container = try write("Library/Containers/Odd.Service.Name/Data/x").deletingLastPathComponent().deletingLastPathComponent()
        let metadata: [String: Any] = ["MCMMetadataInfo": ["Owners": #"[{"teamIdentifier":"VUTU7AKEUR","signingIdentifier":"Odd.Service.Name"}]"#]]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .binary, options: 0)
            .write(to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        XCTAssertEqual(JunkScanner.ownerTeamID(of: container), "VUTU7AKEUR")
        try write("Library/Group Containers/VUTU7AKEUR.group.odd.shared.data/x")
        try write("Library/Group Containers/ZZZZZ99999.group.gone.shared.data/x")

        func orphanNames(teams: Set<String>) -> Set<String> {
            let scanner = JunkScanner(home: home, installedTeamIDs: teams) { _ in false }
            return Set(scanner.scan().first { $0.id == "orphans" }?.items.map(\.url.lastPathComponent) ?? [])
        }
        XCTAssertEqual(orphanNames(teams: ["VUTU7AKEUR"]), ["ZZZZZ99999.group.gone.shared.data"])
        XCTAssertEqual(orphanNames(teams: []).count, 3)
    }

    func testInstalledBundlesIncludeNonAppBundles() throws {
        let system = sandbox.appendingPathComponent("Library")
        let pane = system.appendingPathComponent("PreferencePanes/Thing.prefPane/Contents")
        try FileManager.default.createDirectory(at: pane, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.vendor.thing.pane", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: pane.appendingPathComponent("Info.plist"))
        XCTAssertTrue(AppInventory.installedSoftware(home: home, systemRoot: system).bundleIDs.contains("com.vendor.thing.pane"))
        XCTAssertEqual(AppInventory.vendor(of: "com.Vendor.thing.pane"), "com.vendor")
    }

    // MARK: - Memory purge

    func testPurgeRuleOnlyAllowsPurgeAndRefusesOddNames() throws {
        XCTAssertEqual(PurgeAuthorization.rule(for: "steven"), "steven ALL=(root) NOPASSWD: /usr/sbin/purge")
        for hostile in ["", "a b", "x'; rm -rf /", "root ALL=(ALL) ALL", "-x", "a\nb"] {
            XCTAssertNil(PurgeAuthorization.rule(for: hostile), hostile)
            XCTAssertNil(PurgeAuthorization.installCommand(for: hostile), hostile)
        }
        let command = try XCTUnwrap(PurgeAuthorization.installCommand(for: "steven"))
        XCTAssertTrue(command.contains("visudo -cf"), "the rule is checked before it is installed")
        XCTAssertTrue(Shell.run("/bin/sh", ["-n", "-c", command]).ok, command)
        XCTAssertTrue(command.contains("NOPASSWD: /usr/sbin/purge'"))
        XCTAssertFalse(PurgeAuthorization.rulePath.split(separator: "/").last!.contains("."), "sudo skips names with a dot")
    }

    func testGeneratedRulePassesVisudo() throws {
        let file = sandbox.appendingPathComponent("rule")
        try (PurgeAuthorization.rule(for: "steven")! + "\n").write(to: file, atomically: true, encoding: .utf8)
        let result = Shell.run("/usr/sbin/visudo", ["-c", "-f", file.path])
        XCTAssertTrue(result.out.contains("parsed OK") || result.err.contains("parsed OK"), result.out + result.err)
    }

    func testPurgeThrottleAllowsOneRunEveryThreeMinutes() {
        var throttle = PurgeThrottle()
        let start = Date()
        XCTAssertTrue(throttle.claim(at: start))
        XCTAssertFalse(throttle.claim(at: start.addingTimeInterval(179)))
        XCTAssertTrue(throttle.claim(at: start.addingTimeInterval(180)))
    }

    func testOnlyHeavyAppsTriggerPurgeOnQuit() {
        var tracker = AppMemoryTracker()
        tracker.record([1: AppMemoryTracker.heavyBytes, 2: 100_000_000])
        XCTAssertTrue(tracker.didQuit(pid: 1))
        XCTAssertFalse(tracker.didQuit(pid: 1), "forgotten once reported")
        XCTAssertFalse(tracker.didQuit(pid: 2))
        XCTAssertFalse(tracker.didQuit(pid: 3))
        XCTAssertNotNil(SystemMonitor.footprint(of: getpid()))
    }

    // MARK: - Large files & duplicates

    func testLargeFilesSkipLibraryAndHonorThreshold() throws {
        try write("Movies/big.mov", bytes: 3_000_000)
        try write("Movies/small.mov", bytes: 1000)
        try write("Library/Caches/big.bin", bytes: 3_000_000)
        try write("project/node_modules/big.bin", bytes: 3_000_000)
        let found = LargeFileFinder.scan(root: home, options: .personalFiles(home: home), minimumBytes: 1_000_000)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["big.mov"])
    }

    func testDuplicatesMatchContentNotJustSize() throws {
        let payload = randomData(200_000)
        for name in ["a/one.bin", "b/two.bin", "c/three.bin"] {
            let url = home.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: url)
        }
        try randomData(200_000).write(to: home.appendingPathComponent("a/same-size-different.bin"))
        // Same head and tail, different middle: only the full hash can tell these apart.
        var altered = payload
        altered[100_000] ^= 0xFF
        try altered.write(to: home.appendingPathComponent("b/middle-differs.bin"))

        let groups = DuplicateFinder.scan(root: home, options: .personalFiles(home: home), minimumBytes: 1000)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.url.lastPathComponent)), ["one.bin", "two.bin", "three.bin"])
        XCTAssertEqual(groups[0].reclaimable, 400_000)
    }

    func testHardLinksAreNotDuplicates() throws {
        let original = try write("a/file.bin", bytes: 100_000)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: home.appendingPathComponent("b/link.bin"))
        XCTAssertTrue(DuplicateFinder.scan(root: home, options: .personalFiles(home: home), minimumBytes: 1000).isEmpty)
    }

    // MARK: - Similar photos

    private func writeJPEG(_ name: String, size: Int = 1400, draw: @escaping (NSRect) -> Void) throws {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in draw(rect); return true }
        let rep = NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))!
        let data = try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]))
        let url = home.appendingPathComponent("Pictures/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func scene(_ rect: NSRect, shift: CGFloat, seed: Int, base: NSColor) {
        base.setFill(); rect.fill()
        var generator = SeededGenerator(seed: UInt64(seed))
        for _ in 0..<160 {
            NSColor(hue: .random(in: 0...1, using: &generator), saturation: 0.8, brightness: .random(in: 0.3...1, using: &generator), alpha: 1).setFill()
            let box = NSRect(x: .random(in: 0...1300, using: &generator) + shift, y: .random(in: 0...1300, using: &generator),
                             width: .random(in: 20...140, using: &generator), height: .random(in: 20...140, using: &generator))
            NSBezierPath(ovalIn: box).fill()
        }
    }

    func testSimilarPhotosGroupsNearCopiesOnly() async throws {
        try writeJPEG("burst1.jpg") { self.scene($0, shift: 0, seed: 7, base: .white) }
        try writeJPEG("burst2.jpg") { self.scene($0, shift: 4, seed: 7, base: .white) }
        try writeJPEG("smaller-copy.jpg", size: 1000) { rect in
            // A true downscale of burst1: same scene drawn at 1000/1400 scale.
            let scale = NSAffineTransform()
            scale.scale(by: 1000.0 / 1400.0)
            scale.concat()
            self.scene(NSRect(x: 0, y: 0, width: 1400, height: 1400), shift: 0, seed: 7, base: .white)
        }
        try writeJPEG("other1.jpg") { self.scene($0, shift: 0, seed: 99, base: .black) }
        try writeJPEG("other2.jpg") {
            NSColor.systemBlue.setFill(); $0.fill()
            NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1400, height: 300)).fill()
        }

        let groups = await SimilarPhotoFinder.scan(root: home, options: .personalFiles(home: home))
        XCTAssertEqual(groups.count, 1, "groups: \(groups.map { $0.photos.map(\.url.lastPathComponent) })")
        XCTAssertEqual(Set(groups[0].photos.map(\.url.lastPathComponent)), ["burst1.jpg", "burst2.jpg", "smaller-copy.jpg"])
        XCTAssertNotEqual(groups[0].photos[0].url.lastPathComponent, "smaller-copy.jpg", "best photo ranks first")
    }

    // MARK: - Disk map

    func testDiskMapTotalsAndSymlinks() throws {
        try write("a/big.bin", bytes: 3_000_000)
        try write("a/tiny1", bytes: 8192)
        try write("a/tiny2", bytes: 8192)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("loop"), withDestinationURL: home)

        let root = DiskMapScanner.scan(root: home)
        let folderA = try XCTUnwrap(root.children.first { $0.name == "a" })
        XCTAssertEqual(root.size, root.children.reduce(0) { $0 + $1.size })
        XCTAssertEqual(folderA.children.count, 2, "big file plus one aggregate")
        XCTAssertTrue(folderA.children.contains { $0.isAggregate })

        let big = try XCTUnwrap(folderA.children.first { !$0.isAggregate })
        let before = root.size
        big.removeFromParent()
        XCTAssertEqual(root.size, before - big.size)
    }

    func testTreemapFillsBoundsWithoutOverlap() {
        let bounds = CGRect(x: 10, y: 20, width: 800, height: 500)
        let sizes: [Double] = [500, 300, 120, 90, 40, 40, 20, 5, 1, 1]
        let rects = Treemap.layout(sizes: sizes, in: bounds)
        XCTAssertEqual(rects.count, sizes.count)
        let area = rects.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, bounds.width * bounds.height, accuracy: 1)
        for (i, rect) in rects.enumerated() {
            XCTAssertEqual(rect.width * rect.height, 400_000 * sizes[i] / sizes.reduce(0, +), accuracy: 1)
            XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect))
            for other in rects[(i + 1)...] {
                XCTAssertLessThan(rect.intersection(other).width * rect.intersection(other).height, 0.5)
            }
        }
        XCTAssertEqual(Treemap.layout(sizes: [0, 0], in: bounds), [.zero, .zero])
    }

    // MARK: - Apps

    func testLeftoversAreStrict() throws {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/Foo Editor.app"), name: "Foo Editor",
                          bundleID: "com.acme.foo", version: "1", size: 0, lastUsed: nil)
        try write("Library/Caches/com.acme.foo/x")
        try write("Library/Caches/com.acme.foo.helper/x")
        try write("Library/Caches/com.acme.foobar/x")
        try write("Library/Preferences/com.acme.foo.plist")
        try write("Library/Application Support/Foo Editor/x")
        try write("Library/Application Support/Foo Editor Pro/x")
        try write("Library/Saved Application State/com.acme.foo.savedState/x")
        try write("Library/Group Containers/ABC123.com.acme.foo/x")
        try write("Library/Group Containers/ABC123.com.other/x")

        let names = Set(AppInventory.leftovers(for: app, home: home).map(\.url.lastPathComponent))
        XCTAssertEqual(names, [
            "com.acme.foo", "com.acme.foo.helper", "com.acme.foo.plist", "Foo Editor",
            "com.acme.foo.savedState", "ABC123.com.acme.foo",
        ])
    }

    func testAppleAppsNeverMatchByPrefix() throws {
        let app = AppInfo(url: URL(fileURLWithPath: "/Applications/Xcode.app"), name: "Xcode",
                          bundleID: "com.apple.dt.Xcode", version: "1", size: 0, lastUsed: nil)
        try write("Library/Caches/com.apple.dt.Xcode/x")
        try write("Library/Caches/com.apple.dt.Xcode.sourcecontrol/x")
        let names = AppInventory.leftovers(for: app, home: home).map(\.url.lastPathComponent)
        XCTAssertEqual(names, ["com.apple.dt.Xcode"])
    }

    // MARK: - Deep uninstall

    private var system: URL { sandbox.appendingPathComponent("SystemLibrary") }
    private var fooApp: AppInfo {
        AppInfo(url: URL(fileURLWithPath: "/Applications/Foo Editor.app"), name: "Foo Editor",
                bundleID: "com.cleanmac-test.foo", version: "1", size: 0, lastUsed: nil)
    }

    private func writeJob(_ relative: String, label: String, extra: [String: Any]) throws {
        var plist = extra
        plist["Label"] = label
        let url = system.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    func testDeepUninstallFindsEveryUserLocation() throws {
        try write("Library/Preferences/ByHost/com.cleanmac-test.foo.0A1B2C3D-1111-2222-3333-444455556666.plist")
        try write("Library/Preferences/ByHost/com.cleanmac-test.foobar.0A1B2C3D-1111-2222-3333-444455556666.plist")
        try write("Library/Application Scripts/ABC123.com.cleanmac-test.foo/x")
        try write("Library/Logs/DiagnosticReports/Foo Editor-2026-01-31-120000.ips")
        try write("Library/Logs/DiagnosticReports/Foo Editor Pro-2026-01-31-120000.ips")
        try write("Library/Logs/DiagnosticReports/Foo Editor-notes.txt")
        try write("Library/Application Support/CrashReporter/Foo Editor_0A1B2C3D-1111-2222-3333-444455556666.plist")

        let names = Set(AppInventory.leftovers(for: fooApp, home: home, systemRoot: system).map(\.url.lastPathComponent))
        XCTAssertEqual(names, [
            "com.cleanmac-test.foo.0A1B2C3D-1111-2222-3333-444455556666.plist", "ABC123.com.cleanmac-test.foo",
            "Foo Editor-2026-01-31-120000.ips", "Foo Editor_0A1B2C3D-1111-2222-3333-444455556666.plist",
        ])
    }

    func testDeepUninstallFindsSystemItemsAndJobsThatNameTheApp() throws {
        try write("Application Support/Foo Editor/x", base: system)
        try write("Application Support/Foo Editor Pro/x", base: system)
        try write("Caches/com.cleanmac-test.foo/x", base: system)
        try write("Preferences/com.cleanmac-test.foo.plist", base: system)
        try write("Preferences/com.cleanmac-test.foobar.plist", base: system)
        try write("PrivilegedHelperTools/com.cleanmac-test.unrelated", base: system)
        let helper = try write("PrivilegedHelperTools/com.vendor.helper", base: system)
        try writeJob("LaunchDaemons/com.vendor.helper.plist", label: "com.vendor.helper",
                     extra: ["Program": helper.path, "AssociatedBundleIdentifiers": ["com.cleanmac-test.foo"]])
        try writeJob("LaunchAgents/com.vendor.agent.plist", label: "com.vendor.agent",
                     extra: ["ProgramArguments": ["/Applications/Foo Editor.app/Contents/MacOS/agent", "-x"]])
        try writeJob("LaunchAgents/com.vendor.other.plist", label: "com.vendor.other",
                     extra: ["ProgramArguments": ["/Applications/Foo Editor Pro.app/Contents/MacOS/agent"]])
        // A job may point its program anywhere: it must not pull that file into the list.
        try writeJob("LaunchDaemons/com.vendor.bad.plist", label: "com.vendor.bad",
                     extra: ["Program": "/usr/bin/true", "AssociatedBundleIdentifiers": ["com.cleanmac-test.foo"]])

        let found = AppInventory.leftovers(for: fooApp, home: home, systemRoot: system)
        XCTAssertTrue(found.allSatisfy(\.isSystem))
        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), [
            "Foo Editor", "com.cleanmac-test.foo", "com.cleanmac-test.foo.plist", "com.vendor.helper",
            "com.vendor.helper.plist", "com.vendor.agent.plist", "com.vendor.bad.plist",
        ])
    }

    func testHelpersDeclaredByTheAppBundleAreFound() throws {
        // The shape of Docker: helpers share a vendor prefix, not the app's bundle ID.
        let bundle = sandbox.appendingPathComponent("Apps/Whale.app")
        try write("Contents/MacOS/com.whale.socket", base: bundle)
        try write("Contents/MacOS/whale", base: bundle)
        let info = ["CFBundleIdentifier": "com.whale.desktop", "SMPrivilegedExecutables": ["com.whale.vmnetd": "identifier"]] as [String: Any]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))

        let vmnetd = try write("PrivilegedHelperTools/com.whale.vmnetd", base: system)
        let socket = try write("PrivilegedHelperTools/com.whale.socket", base: system)
        try write("PrivilegedHelperTools/com.whale.otherproduct", base: system)
        try writeJob("LaunchDaemons/com.whale.vmnetd.plist", label: "com.whale.vmnetd", extra: ["Program": vmnetd.path])
        try writeJob("LaunchDaemons/com.whale.socket.plist", label: "com.whale.socket", extra: ["Program": socket.path])
        try writeJob("LaunchDaemons/com.whale.otherproduct.plist", label: "com.whale.otherproduct",
                     extra: ["Program": system.appendingPathComponent("PrivilegedHelperTools/com.whale.otherproduct").path])
        try writeJob("LaunchDaemons/com.other.whale.plist", label: "com.other.whale", extra: ["Program": "/opt/whale"])

        let app = AppInfo(url: bundle, name: "Whale", bundleID: "com.whale.desktop", version: "1", size: 0, lastUsed: nil)
        let names = Set(AppInventory.leftovers(for: app, home: home, systemRoot: system).map(\.url.lastPathComponent))
        XCTAssertEqual(names, ["com.whale.vmnetd", "com.whale.vmnetd.plist", "com.whale.socket", "com.whale.socket.plist"])
    }

    func testAppleAppsGetNoSystemItems() throws {
        try write("Application Support/Xcode/x", base: system)
        try write("Preferences/com.apple.dt.Xcode.plist", base: system)
        let xcode = AppInfo(url: URL(fileURLWithPath: "/Applications/Xcode.app"), name: "Xcode",
                            bundleID: "com.apple.dt.Xcode", version: "1", size: 0, lastUsed: nil)
        XCTAssertTrue(AppInventory.leftovers(for: xcode, home: home, systemRoot: system).isEmpty)
    }

    func testSystemItemGuardAllowsOnlyDirectChildrenOfKnownFolders() throws {
        let realGuard = PathGuard(home: home)
        for path in ["/Library/Application Support/Foo", "/Library/Caches/com.foo", "/Library/Logs/Foo",
                     "/Library/Preferences/com.foo.plist", "/Library/PrivilegedHelperTools/com.foo.helper",
                     "/Library/LaunchDaemons/com.foo.plist", "/Library/LaunchAgents/com.foo.plist"] {
            XCTAssertNoThrow(try realGuard.checkSystemItem(URL(fileURLWithPath: path)), path)
        }
        for path in ["/Library", "/Library/Application Support", "/Library/Application Support/Foo/inner",
                     "/Library/Application Support/com.apple.TCC", "/Library/Preferences/com.apple.foo.plist",
                     "/Library/Keychains/System.keychain", "/Library/LaunchDaemons/notes.txt", "/System/Library/Caches/x",
                     "/Library/Caches/../Keychains", "/usr/bin/true", "/etc/hosts", "/Applications/Foo.app"] {
            XCTAssertThrowsError(try realGuard.checkSystemItem(URL(fileURLWithPath: path)), path)
        }
        // The general gate stays closed to these paths, so no scan result can reach them.
        XCTAssertThrowsError(try realGuard.check(URL(fileURLWithPath: "/Library/Application Support/Foo")))
    }

    private func runInShell(_ command: String) -> Shell.Output { Shell.run("/bin/sh", ["-c", command]) }

    func testUninstallMovesSystemItemsThroughOnePasswordPrompt() throws {
        // A hostile name has to stay one argument to the root command.
        let hostile = try write("Application Support/com.cleanmac-test.foo'; touch pwned; '\"$(touch pwned)", base: system)
        let helper = try write("PrivilegedHelperTools/com.vendor.helper", base: system)
        let user = try write("Library/Caches/com.cleanmac-test.foo/x")
        let bundle = try write("Applications/Foo.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()

        var prompts = 0
        let result = try XCTUnwrap(Cleaner(home: home, systemRoot: system).uninstall(
            app: (bundle, 10),
            leftovers: [LeftoverItem(url: hostile, size: 1, isSystem: true), LeftoverItem(url: helper, size: 2, isSystem: true),
                        LeftoverItem(url: user.deletingLastPathComponent(), size: 3)],
            runAsAdmin: { prompts += 1; return self.runInShell("cd '\(self.sandbox.path)'; \($0)") }
        ))
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(result.count, 4, "\(result.failures)")
        XCTAssertEqual(result.bytes, 16)
        XCTAssertTrue(result.failures.isEmpty)
        for url in [hostile, helper, user, bundle] { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), url.path) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".Trash/com.vendor.helper").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("pwned").path), "the name ran as a command")
        for url in result.trashedURLs { try? FileManager.default.removeItem(at: url) }
    }

    func testCancellingThePasswordRemovesNothing() throws {
        let helper = try write("PrivilegedHelperTools/com.vendor.helper", base: system)
        let user = try write("Library/Caches/com.cleanmac-test.foo/x")
        let bundle = try write("Applications/Foo.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        let result = Cleaner(home: home, systemRoot: system).uninstall(
            app: (bundle, 10),
            leftovers: [LeftoverItem(url: helper, size: 2, isSystem: true), LeftoverItem(url: user, size: 3)],
            runAsAdmin: { _ in Shell.Output(status: 1, out: "", err: "execution error: User canceled. (-128)") }
        )
        XCTAssertNil(result)
        for url in [helper, user, bundle] { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path) }
    }

    func testSystemItemThatDidNotMoveIsReportedAsFailed() throws {
        let helper = try write("PrivilegedHelperTools/com.vendor.helper", base: system)
        let bundle = try write("Applications/Foo.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        let result = try XCTUnwrap(Cleaner(home: home, systemRoot: system).uninstall(
            app: (bundle, 10), leftovers: [LeftoverItem(url: helper, size: 2, isSystem: true)],
            runAsAdmin: { _ in Shell.Output(status: 0, out: "mv: Operation not permitted", err: "") }
        ))
        XCTAssertEqual(result.count, 1, "the app still moved")
        XCTAssertEqual(result.failures.map(\.path), [helper.path])
        XCTAssertEqual(result.failures.first?.message, "mv: Operation not permitted")
        for url in result.trashedURLs { try? FileManager.default.removeItem(at: url) }
    }

    func testListedSystemItemOutsideTheGuardIsRefused() throws {
        let bundle = try write("Applications/Foo.app/Contents/Info.plist").deletingLastPathComponent().deletingLastPathComponent()
        var commands: [String] = []
        let result = try XCTUnwrap(Cleaner(home: home, systemRoot: system).uninstall(
            app: (bundle, 10), leftovers: [LeftoverItem(url: URL(fileURLWithPath: "/usr/bin/true"), size: 2, isSystem: true)],
            runAsAdmin: { commands.append($0); return self.runInShell($0) }
        ))
        XCTAssertTrue(commands.isEmpty, "a refused item never reaches the root command")
        XCTAssertEqual(result.failures.map(\.path), ["/usr/bin/true"])
        for url in result.trashedURLs { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Startup & security

    func testStartupPlistParsing() throws {
        let plist: [String: Any] = ["Label": "com.foo.agent", "ProgramArguments": ["/Applications/Foo.app/Contents/MacOS/agent", "-x"],
                                    "RunAtLoad": true, "KeepAlive": ["SuccessfulExit": false]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let item = try XCTUnwrap(StartupManager.parsePlist(data, url: URL(fileURLWithPath: "/x.plist"), domain: .userAgent))
        XCTAssertEqual(item.label, "com.foo.agent")
        XCTAssertEqual(item.program, "/Applications/Foo.app/Contents/MacOS/agent")
        XCTAssertEqual(item.displayName, "Foo")
        XCTAssertTrue(item.runAtLoad)
        XCTAssertTrue(item.keepAlive)
    }

    func testLoginItemParsing() {
        let items = StartupManager.parseLoginItems("Boom 3D\t/Applications/Boom 3D.app\nClaude\t/Applications/Claude.app\n")
        XCTAssertEqual(items.map(\.label), ["Boom 3D", "Claude"])
        XCTAssertEqual(items[0].program, "/Applications/Boom 3D.app")
    }

    func testDisabledOutputParsing() {
        let parsed = StartupManager.parseDisabled("""
        disabled services = {
            "com.a" => disabled
            "com.b" => enabled
            "com.c" => true
            "com.d" => false
        }
        """)
        XCTAssertEqual(parsed, ["com.a": true, "com.b": false, "com.c": true, "com.d": false])
    }

    func testLabelValidationBlocksShellInjection() {
        XCTAssertTrue(StartupManager.isSafeLabel("com.foo-bar_baz.1"))
        for bad in ["", "a b", "a;rm -rf /", "$(id)", "a'b", "a\"b", "a/b", "a\nb"] {
            XCTAssertFalse(StartupManager.isSafeLabel(bad), bad)
        }
    }

    func testAdwareAndSuspiciousLocationFindings() {
        func item(_ label: String, _ program: String?) -> StartupItem {
            StartupItem(label: label, domain: .userAgent, plistURL: nil, program: program, runAtLoad: true, keepAlive: false, disabled: false)
        }
        XCTAssertEqual(SecurityAuditor.inspect(item("com.pirrit.agent", "/usr/bin/true"))?.severity, .critical)
        XCTAssertEqual(SecurityAuditor.inspect(item("com.foo", "/nonexistent/binary"))?.severity, .info)
        XCTAssertNil(SecurityAuditor.inspect(item("com.ok", "/usr/bin/true")), "Apple-signed binary raises nothing")
        let hidden = home.appendingPathComponent(".hidden/tool")
        FileManager.default.createFile(atPath: hidden.deletingLastPathComponent().path, contents: nil)
        try? FileManager.default.removeItem(at: hidden.deletingLastPathComponent())
        try? FileManager.default.createDirectory(at: hidden.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: hidden.path, contents: Data([1]))
        XCTAssertEqual(SecurityAuditor.inspect(item("com.x", hidden.path))?.severity, .warning)
    }

    func testSoftwareUpdateParsing() {
        let output = """
        Software Update Tool

        Finding available software
        Software Update found the following new or updated software:
        * Label: macOS 27.3-27D1
        \tTitle: macOS 27.3, Version: 27.3, Size: 1000KiB, Recommended: YES,
        """
        XCTAssertEqual(SecurityAuditor.parseSoftwareUpdates(output), ["macOS 27.3-27D1"])
        XCTAssertEqual(SecurityAuditor.parseOnOff("FileVault is On.", on: "FileVault is On", off: "FileVault is Off"), true)
        XCTAssertNil(SecurityAuditor.parseOnOff("???", on: "a", off: "b"))
    }

    func testSignatureDetection() {
        XCTAssertEqual(SecurityAuditor.signature(of: URL(fileURLWithPath: "/usr/bin/true")), .developerSigned)
        XCTAssertEqual(SecurityAuditor.signature(of: URL(fileURLWithPath: "/no/such/file")), .missing)
    }

    // MARK: - Memory

    func testMemorySnapshotIsSane() {
        let memory = SystemMonitor.memory()
        XCTAssertEqual(memory.total, Int64(ProcessInfo.processInfo.physicalMemory))
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
        let processes = SystemMonitor.topProcesses()
        XCTAssertFalse(processes.isEmpty)
        XCTAssertGreaterThanOrEqual(processes[0].bytes, processes.last!.bytes)
        XCTAssertGreaterThan(SystemMonitor.disk().total, 0)
    }

    // MARK: - Shredder

    func testShredRemovesFileAndOverwritesInPlace() throws {
        let file = try write("secret/a.txt", bytes: 3_000_000, fill: 0x41)
        let result = Shredder.shred([file], pathGuard: PathGuard(home: home))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.bytes, 3_000_000)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), [],
                       "no temp names left behind")
    }

    func testOverwriteReplacesEveryByte() throws {
        let file = try write("b.bin", bytes: 2_500_000, fill: 0x41)
        let fd = open(file.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        try Shredder.overwrite(fd: fd, size: 2_500_000, passes: 1, path: file.path)
        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.count, 2_500_000)
        // Random data leaves about 1/256 of bytes equal to the old fill value.
        XCTAssertLessThan(data.filter { $0 == 0x41 }.count, 20_000)
    }

    func testShredRefusesHardLinksAndKeepsContent() throws {
        let file = try write("a.bin", bytes: 1000, fill: 0x42)
        let link = home.appendingPathComponent("b.bin")
        try FileManager.default.linkItem(at: file, to: link)
        let result = Shredder.shred([file], pathGuard: PathGuard(home: home))
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: link), Data(repeating: 0x42, count: 1000))
    }

    func testShredOnlyRemovesSymlinkNotTarget() throws {
        let target = try write("Documents/target.bin", bytes: 1000, fill: 0x43)
        let folder = home.appendingPathComponent("toShred")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("toShred/plain.bin", bytes: 1000)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: target)

        let result = Shredder.shred([folder], pathGuard: PathGuard(home: home))
        XCTAssertTrue(result.failures.isEmpty, "\(result.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: target), Data(repeating: 0x43, count: 1000))
    }

    func testShredRefusesProtectedPaths() throws {
        let documents = try write("Documents/keep.bin").deletingLastPathComponent()
        let result = Shredder.shred([documents, home], pathGuard: PathGuard(home: home))
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent("keep.bin").path))
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

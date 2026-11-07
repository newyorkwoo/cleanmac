import AppKit
import CoreServices
@testable import CleanMacCore
import SwiftUI
import XCTest
@testable import CleanMac

/// Drives the real view models against a throwaway home folder and renders every page.
/// Set CLEANMAC_SNAPSHOT_DIR to save the rendered pages as PNG files.
@MainActor
final class AppFlowTests: XCTestCase {
    var sandbox: URL!
    var home: URL!
    var app: AppModel!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("cleanmac-flow-\(UUID().uuidString)")
        home = sandbox.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        app = AppModel(home: home, systemRoot: nil)
        app.hasFullDiskAccess = true
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        // Whatever the flows moved to the real Trash goes away with the sandbox.
        for url in app.lastResult?.trashedURLs ?? [] { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func openEvent(launchKind: OSType?) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        if let launchKind {
            event.setParam(NSAppleEventDescriptor(enumCode: launchKind), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    func testOnlyLoginItemLaunchCountsAsHidden() {
        XCTAssertTrue(isLoginItemLaunch(openEvent(launchKind: OSType(keyAELaunchedAsLogInItem))))
        XCTAssertFalse(isLoginItemLaunch(openEvent(launchKind: nil)))
        XCTAssertFalse(isLoginItemLaunch(openEvent(launchKind: OSType(keyAELaunchedAsServiceItem))))
        XCTAssertFalse(isLoginItemLaunch(nil))
    }

    @discardableResult
    private func write(_ relative: String, data: Data) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private func random(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    private func render(_ page: Page, file: StaticString = #filePath, line: UInt = #line) throws {
        app.page = page
        let root = RootView().environment(app).frame(width: 1160, height: 740)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: 1160, height: 740)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), file: file, line: line)
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0, file: file, line: line)
        if let folder = ProcessInfo.processInfo.environment["CLEANMAC_SNAPSHOT_DIR"] {
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(page.rawValue + ".png"))
        }
    }

    func testSettingsRenderAndThresholdIsClamped() throws {
        XCTAssertEqual(clampedThreshold(0), 1)
        XCTAssertEqual(clampedThreshold(5000), 1024)
        XCTAssertEqual(clampedThreshold(32), 32)
        let host = NSHostingView(rootView: SettingsView(language: .traditionalChinese).background(Color.white))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        if let folder = ProcessInfo.processInfo.environment["CLEANMAC_SNAPSHOT_DIR"] {
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent("settings.png"))
        }
    }

    func testJunkFlowHonorsDefaultsAndCleansOnlySelection() async throws {
        let cache = try write("Library/Caches/com.acme.app/blob", data: random(4_000_000))
        try write("Library/Logs/acme.log", data: random(200_000))
        let devCache = try write("Library/Caches/Homebrew/pkg.tar.gz", data: random(1_000_000))
        try write(".Trash/old.bin", data: random(50_000))

        app.junk.scan()
        await app.junk.waitUntilDone()
        XCTAssertEqual(Set(app.junk.categories.map(\.id)), ["user-cache", "logs", "dev-cache", "trash"])
        XCTAssertEqual(Set(app.junk.selectedItems.map(\.name)), ["com.acme.app", "acme.log"], "risky categories start unchecked")
        try render(.junk)

        await app.junk.clean().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: devCache.path), "unselected items stay")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".Trash/old.bin").path))
        XCTAssertEqual(app.lastResult?.count, 2)
        XCTAssertEqual(app.banner?.offerEmptyTrash, true)
        XCTAssertEqual(Set(app.junk.categories.map(\.id)), ["dev-cache", "trash"])
    }

    func testDuplicateFlowAlwaysKeepsOneCopy() async throws {
        let payload = random(1_500_000)
        let keep = try write("Documents/report.pdf", data: payload)
        let older = Date(timeIntervalSinceNow: -86_400)
        try FileManager.default.setAttributes([.modificationDate: older], ofItemAtPath: keep.path)
        let copy = try write("Downloads/report copy.pdf", data: payload)

        app.duplicates.scan()
        await app.duplicates.waitUntilDone()
        let group = try XCTUnwrap(app.duplicates.groups.first)
        app.duplicates.autoSelect()
        XCTAssertEqual(app.duplicates.selectedFiles.map(\.url.lastPathComponent), ["report copy.pdf"], "oldest is kept")
        let keeper = try XCTUnwrap(group.files.first { !app.duplicates.selected.contains($0.id) })
        XCTAssertFalse(app.duplicates.canSelect(keeper, in: group), "the last copy cannot be checked")
        try render(.duplicates)

        await app.duplicates.clean().value
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(app.duplicates.groups.isEmpty)
    }

    func testLargeFileFlow() async throws {
        let big = try write("Movies/film.mov", data: random(3_000_000))
        app.large.minimumMB = 1
        app.large.scan()
        await app.large.waitUntilDone()
        XCTAssertEqual(app.large.files.map(\.url.lastPathComponent), ["film.mov"])
        XCTAssertTrue(app.large.selected.isEmpty, "nothing is preselected")
        try render(.large)
        app.large.selected = Set(app.large.files.map(\.id))
        await app.large.clean().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: big.path))
    }

    func testDiskMapFlowRendersAndDrillsDown() async throws {
        try write("Movies/film.mov", data: random(5_000_000))
        try write("Documents/a.bin", data: random(2_000_000))
        app.diskMap.scan()
        await app.diskMap.waitUntilDone()
        XCTAssertEqual(Set(try XCTUnwrap(app.diskMap.current).children.map(\.name)), ["Movies", "Documents"])
        try render(.diskMap)
    }

    func testShredderFlowDeletesForGood() async throws {
        let secret = try write("private/secret.txt", data: random(10_000))
        app.shredder.add([secret])
        app.shredder.add([secret])
        XCTAssertEqual(app.shredder.queue.count, 1, "no duplicates in the queue")
        try render(.shredder)
        app.shredder.shred()
        await app.shredder.waitUntilDone()
        XCTAssertFalse(FileManager.default.fileExists(atPath: secret.path))
        XCTAssertTrue(app.shredder.queue.isEmpty)
        XCTAssertEqual(app.banner?.offerEmptyTrash, false)
    }

    func testUninstallMovesAppAndOnlySelectedLeftovers() async throws {
        let bundle = try write("Applications/E2E.app/Contents/Info.plist", data: try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.e2e.flow", "CFBundleName": "E2E"], format: .xml, options: 0))
            .deletingLastPathComponent().deletingLastPathComponent()
        let cache = try write("Library/Caches/com.e2e.flow/blob", data: random(10_000))
        let prefs = try write("Library/Preferences/com.e2e.flow.plist", data: random(1000))
        let other = try write("Library/Caches/com.e2e.flowers/blob", data: random(1000))

        let info = try XCTUnwrap(AppInventory.scan(home: home, roots: [home.appendingPathComponent("Applications")]).first)
        app.apps.apps = [info]
        XCTAssertFalse(app.apps.isRunning(info))
        app.apps.choose(info)
        while app.apps.isLoadingLeftovers { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(Set(app.apps.leftovers.map(\.url.lastPathComponent)), ["com.e2e.flow", "com.e2e.flow.plist"])
        XCTAssertEqual(app.apps.selectedLeftovers.count, 2, "leftovers start selected")
        app.apps.selectedLeftovers.remove(try XCTUnwrap(app.apps.leftovers.first { $0.url.lastPathComponent.hasSuffix("plist") }).id)

        await app.apps.uninstall(info).value
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefs.path), "an unchecked leftover stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "another app's data stays")
        XCTAssertTrue(app.apps.apps.isEmpty)
        XCTAssertNil(app.apps.chosen)
    }

    func testRunningAppDataAndRiskyCategoriesStartUnchecked() throws {
        let scanner = JunkScanner(home: home, runningBundleIDs: ["com.running.app"]) { _ in true }
        try write("Library/Caches/com.running.app/x", data: random(1000))
        try write("Library/Caches/com.idle.app/x", data: random(1000))
        try write("Library/Caches/Homebrew/x", data: random(1000))
        let selected = JunkModel.defaultSelection(for: scanner.scan())
        XCTAssertEqual(selected.map { URL(fileURLWithPath: $0).lastPathComponent }, ["com.idle.app"])
    }

    func testRunningAppIsRecognized() {
        // The uninstall button is disabled for running apps. Finder is always running.
        let finder = AppInfo(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), name: "Finder",
                             bundleID: "com.apple.finder", version: "", size: 0, lastUsed: nil)
        XCTAssertTrue(app.apps.isRunning(finder))
    }

    func testPhotoFlowKeepsTheBestInEveryGroup() async throws {
        func group(_ id: Int) -> PhotoGroup {
            PhotoGroup(id: "g\(id)", photos: (0..<Int.random(in: 2...6)).map {
                PhotoRecord(url: home.appendingPathComponent("p\(id)-\($0).jpg"), size: 1000, pixelWidth: 10, pixelHeight: 10, modified: nil)
            })
        }
        app.photos.groups = (0..<20).map(group)
        for _ in 0..<5000 {
            let g = app.photos.groups.randomElement()!
            app.photos.toggle(g.photos.randomElement()!, in: g)
            XCTAssertTrue(g.photos.contains { !app.photos.selected.contains($0.id) }, "every photo in a group got selected")
        }
        app.photos.autoSelect()
        for g in app.photos.groups {
            XCTAssertFalse(app.photos.selected.contains(g.photos[0].id), "the best photo is never auto-selected")
            XCTAssertEqual(g.photos.filter { app.photos.selected.contains($0.id) }.count, g.photos.count - 1)
        }
    }

    func testDuplicateKeepOneInvariantUnderRandomClicks() throws {
        func file(_ g: Int, _ i: Int) -> FileRecord { FileRecord(url: home.appendingPathComponent("d\(g)-\(i)"), size: 10, modified: Date(timeIntervalSince1970: TimeInterval(i))) }
        app.duplicates.groups = (0..<20).map { g in
            DuplicateGroup(id: "g\(g)", size: 10, files: (0..<Int.random(in: 2...6)).map { file(g, $0) })
        }
        for _ in 0..<5000 {
            let g = app.duplicates.groups.randomElement()!
            let f = g.files.randomElement()!
            // The same rule the checkbox applies: it is disabled when canSelect is false.
            if app.duplicates.canSelect(f, in: g) {
                if app.duplicates.selected.contains(f.id) { app.duplicates.selected.remove(f.id) } else { app.duplicates.selected.insert(f.id) }
            }
            XCTAssertTrue(g.files.contains { !app.duplicates.selected.contains($0.id) })
        }
        app.duplicates.autoSelect()
        for g in app.duplicates.groups {
            XCTAssertFalse(app.duplicates.selected.contains(g.suggestedKeeper!.id))
            XCTAssertEqual(g.suggestedKeeper?.url.lastPathComponent, g.files.first?.url.lastPathComponent, "oldest is kept")
        }
    }

    func testFailedCleanKeepsFailedItemsListedAndSelected() async throws {
        let good = try write("Movies/a.mov", data: random(2_000_000))
        let locked = try write("Movies/locked.mov", data: random(2_000_000))
        app.large.minimumMB = 1
        app.large.scan()
        await app.large.waitUntilDone()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        app.large.selected = Set(app.large.files.map(\.id))
        await app.large.clean().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locked.path))
        XCTAssertEqual(app.large.files.map(\.url.lastPathComponent), ["locked.mov"])
        XCTAssertEqual(app.large.selected.count, 1)
        XCTAssertEqual(app.banner?.failures.count, 1)
        XCTAssertEqual(app.lastResult?.count, 1)
    }

    func testDoubleLaunchAndCancelAreSafe() async throws {
        for i in 0..<200 { try write("many/\(i).bin", data: random(50_000)) }
        app.duplicates.minimumMB = 0
        app.duplicates.scan()
        app.duplicates.scan() // ignored while running
        XCTAssertTrue(app.duplicates.isScanning)
        app.duplicates.cancel()
        await app.duplicates.waitUntilDone()
        XCTAssertFalse(app.duplicates.isScanning)
        XCTAssertTrue(app.duplicates.groups.isEmpty, "random files have no duplicates, even after a cancel")
    }

    func testSmartScanRunsEverythingConcurrentlyAndFinishes() async throws {
        try write("Library/Caches/com.acme.app/blob", data: random(1_000_000))
        app.startSmartScan([.junk, .large, .duplicates, .photos, .startup])
        XCTAssertTrue(app.isSmartScanning)
        for item in SmartScanItem.allCases { await app.model(for: item).waitUntilDone() }
        XCTAssertFalse(app.isSmartScanning)
        XCTAssertEqual(app.junk.categories.map(\.id), ["user-cache"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Caches/com.acme.app/blob").path),
                      "a scan deletes nothing")
    }

    func testChangingLanguageUpdatesResultsAlreadyOnScreen() async throws {
        let saved = AppLanguage.current
        defer { AppLanguage.current = saved }
        try write("Library/Caches/com.acme.app/blob", data: random(1_000_000))
        app.junk.scan()
        await app.junk.waitUntilDone()
        AppLanguage.current = .english
        XCTAssertEqual(app.junk.categories.first?.title, "User caches")
        AppLanguage.current = .japanese
        XCTAssertEqual(app.junk.categories.first?.title, "ユーザキャッシュ")
    }

    func testEveryPageRendersInEveryLanguageWithResults() async throws {
        let saved = AppLanguage.current
        defer { AppLanguage.current = saved }
        let payload = random(1_500_000)
        try write("Documents/a.bin", data: payload)
        try write("Downloads/b.bin", data: payload)
        try write("Library/Caches/com.acme.app/blob", data: random(1_000_000))
        try write("Movies/film.mov", data: random(2_000_000))
        app.large.minimumMB = 1
        app.startSmartScan([.junk, .large, .duplicates, .startup])
        app.diskMap.scan()
        for item in SmartScanItem.allCases { await app.model(for: item).waitUntilDone() }
        await app.diskMap.waitUntilDone()
        await app.memory.refresh()
        app.banner = ResultBanner(message: L("垃圾桶已經是空的。"), failures: [.init(path: "/x", message: "y")], offerEmptyTrash: true)
        for language in AppLanguage.allCases {
            AppLanguage.current = language
            for page in Page.allCases where page != .apps && page != .security {
                app.page = page
                let host = NSHostingView(rootView: RootView().environment(app).frame(width: 1000, height: 640))
                host.frame = NSRect(x: 0, y: 0, width: 1000, height: 640)
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                XCTAssertEqual(rep.pixelsWide > 0, true, "\(language) \(page)")
                XCTAssertFalse(page.title.isEmpty)
            }
        }
    }

    func testRemovalOnOnePageUpdatesEveryOtherPage() async throws {
        let payload = random(2_000_000)
        let film = try write("Movies/film.mov", data: payload)
        let copy = try write("Downloads/film copy.mov", data: payload)
        let cache = try write("Library/Caches/com.acme.app/blob", data: random(3_000_000))
        let keep = try write("Movies/keep.mov", data: random(2_000_000))
        app.large.minimumMB = 1
        app.junk.scan()
        app.large.scan()
        app.duplicates.scan()
        app.diskMap.scan()
        for model: ScanModel in [app.junk, app.large, app.duplicates, app.diskMap] { await model.waitUntilDone() }
        let root = try XCTUnwrap(app.diskMap.tree)
        let totalBefore = root.size
        XCTAssertEqual(app.duplicates.groups.count, 1)

        // Remove one copy on the large files page: the duplicate group no longer has a pair.
        app.large.selected = Set(app.large.files.filter { $0.url.lastPathComponent == "film copy.mov" }.map(\.id))
        let revision = app.diskMap.revision
        await app.large.clean().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(app.duplicates.groups.isEmpty, "the duplicates page must not offer a removed file")
        XCTAssertNil(root.children.first { $0.name == "Downloads" }?.children.first { $0.url.lastPathComponent == "film copy.mov" })
        XCTAssertLessThan(root.size, totalBefore)
        XCTAssertGreaterThan(app.diskMap.revision, revision)
        for url in app.lastResult?.trashedURLs ?? [] { try? FileManager.default.removeItem(at: url) }

        // Remove a cache folder on the junk page while the disk map is showing a folder inside it.
        let library = try XCTUnwrap(root.children.first { $0.name == "Library" })
        let caches = try XCTUnwrap(library.children.first { $0.name == "Caches" })
        let acme = try XCTUnwrap(caches.children.first { $0.name == "com.acme.app" })
        app.diskMap.current = acme
        await app.junk.clean().value
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(app.diskMap.current === caches, "the view moves up when its folder is removed")
        XCTAssertFalse(caches.children.contains { $0 === acme })

        // Untouched files stay everywhere, and folder totals still add up.
        XCTAssertTrue(FileManager.default.fileExists(atPath: film.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))
        XCTAssertEqual(Set(app.large.files.map(\.url.lastPathComponent)), ["film.mov", "keep.mov"])
        func verify(_ node: DiskNode) {
            guard node.isDirectory else { return }
            XCTAssertEqual(node.size, node.children.reduce(0) { $0 + $1.size }, node.name)
            node.children.forEach(verify)
        }
        verify(root)
    }

    func testPruningNeverLeavesAGroupFullySelected() {
        func file(_ name: String, _ age: Double) -> FileRecord {
            FileRecord(url: home.appendingPathComponent(name), size: 10, modified: Date(timeIntervalSince1970: age))
        }
        let keeper = file("keeper", 3), a = file("a", 1), b = file("b", 2)
        app.duplicates.groups = [DuplicateGroup(id: "g", size: 10, files: [keeper, a, b])]
        app.duplicates.selected = [a.id, b.id] // only "keeper" is unchecked
        app.prune(removedPaths: [keeper.url.path])
        let group = app.duplicates.groups[0]
        XCTAssertEqual(group.files.count, 2)
        XCTAssertTrue(group.files.contains { !app.duplicates.selected.contains($0.id) }, "both remaining copies were still checked")

        func photo(_ name: String) -> PhotoRecord {
            PhotoRecord(url: home.appendingPathComponent(name), size: 10, pixelWidth: 1, pixelHeight: 1, modified: nil)
        }
        let best = photo("best"), p1 = photo("p1"), p2 = photo("p2")
        app.photos.groups = [PhotoGroup(id: "p", photos: [best, p1, p2])]
        app.photos.selected = [p1.id, p2.id]
        app.prune(removedPaths: [best.url.path])
        XCTAssertTrue(app.photos.groups[0].photos.contains { !app.photos.selected.contains($0.id) })
    }

    func testPruningMatchesFoldersExactlyNotByNamePrefix() {
        let inside = FileRecord(url: home.appendingPathComponent("Movies/old/a.mov"), size: 1, modified: nil)
        let sibling = FileRecord(url: home.appendingPathComponent("Movies/older/b.mov"), size: 1, modified: nil)
        app.large.files = [inside, sibling]
        app.large.selected = [inside.id, sibling.id]
        app.prune(removedPaths: [home.appendingPathComponent("Movies/old").path])
        XCTAssertEqual(app.large.files.map(\.url.lastPathComponent), ["b.mov"], "Movies/older is not inside Movies/old")
        XCTAssertEqual(app.large.selected, [sibling.id])
    }

    func testFailedRemovalIsNotPruned() async throws {
        let locked = try write("Movies/locked.mov", data: random(2_000_000))
        app.large.minimumMB = 1
        app.large.scan()
        app.diskMap.scan()
        await app.large.waitUntilDone()
        await app.diskMap.waitUntilDone()
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
        app.large.selected = Set(app.large.files.map(\.id))
        await app.large.clean().value
        XCTAssertEqual(app.large.files.count, 1)
        let movies = app.diskMap.tree?.children.first { $0.name == "Movies" }
        XCTAssertNotNil(movies, "a file that wasn't removed stays on the disk map")
    }

    func testVersionText() {
        XCTAssertEqual(versionText(["CFBundleShortVersionString": "1.2", "CFBundleVersion": "3"]), "1.2 (3)")
        XCTAssertEqual(versionText(["CFBundleShortVersionString": "1.2"]), "1.2")
        XCTAssertEqual(versionText([:]), "?", "swift run has no Info.plist")
    }

    func testRemainingPagesRender() async throws {
        await app.memory.refresh()
        XCTAssertFalse(app.memory.processes.isEmpty)
        for page in [Page.dashboard, .photos, .memory, .startup, .apps, .security] { try render(page) }
    }
}

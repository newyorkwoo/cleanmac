import Foundation

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let size: Int64
    /// Belongs to an app that is running now, so it is never preselected.
    public let inUse: Bool
}

public struct JunkCategory: Identifiable, Sendable {
    public let id: String
    /// Untranslated keys, so that a language change applies to results already on screen.
    public let titleKey: String
    public let detailKey: String
    public let symbol: String
    public let defaultSelected: Bool
    /// Trash contents are deleted for good rather than moved.
    public let permanent: Bool
    public let items: [JunkItem]

    public init(id: String, title: String, detail: String, symbol: String, defaultSelected: Bool, permanent: Bool, items: [JunkItem]) {
        self.id = id
        self.titleKey = title
        self.detailKey = detail
        self.symbol = symbol
        self.defaultSelected = defaultSelected
        self.permanent = permanent
        self.items = items
    }

    public var title: String { L(titleKey) }
    public var detail: String { L(detailKey) }
    public var size: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct JunkScanner: Sendable {
    public let home: URL
    public let runningBundleIDs: Set<String>
    public let isInstalled: @Sendable (String) -> Bool

    private static let browsers: [(path: String, bundleID: String)] = [
        ("Google/Chrome", "com.google.chrome"),
        ("Firefox/Profiles", "org.mozilla.firefox"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("BraveSoftware", "com.brave.browser"),
        ("com.operasoftware.Opera", "com.operasoftware.opera"),
        ("Vivaldi", "com.vivaldi.vivaldi"),
        ("company.thebrowser.Browser", "company.thebrowser.browser"),
    ]

    private static let developerCacheNames = [
        "Homebrew", "pip", "Yarn", "pnpm", "go-build", "ms-playwright", "node-gyp", "CocoaPods", "org.swift.swiftpm",
    ]

    /// Top-level cache folders reported in another category or used by the system.
    private static let cacheExclusions: Set<String> = Set(
        ["Google", "Firefox", "Microsoft Edge", "BraveSoftware", "com.operasoftware.Opera", "Vivaldi",
         "company.thebrowser.Browser", "CloudKit", "FamilyCircle", "GeoServices", "familycircled", "com.cleanmac.app"]
            + developerCacheNames
    )

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        runningBundleIDs: [String] = [],
        isInstalled: @escaping @Sendable (String) -> Bool
    ) {
        self.home = home
        self.runningBundleIDs = Set(runningBundleIDs.map { $0.lowercased() })
        self.isInstalled = isInstalled
    }

    public func scan(progress: ProgressHandler? = nil) -> [JunkCategory] {
        let builders: [(String, () -> JunkCategory)] = [
            (L("使用者快取"), userCaches), (L("瀏覽器快取"), browserCaches), (L("記錄檔"), logs),
            (L("Xcode 建置快取"), xcodeBuildCaches), (L("開發工具快取"), developerCaches),
            (L("Xcode 封存與裝置支援"), xcodeArchives), (L("已下載的安裝檔"), oldInstallers),
            (L("iOS 裝置備份"), iosBackups), (L("已移除 App 的殘留"), orphans), (L("垃圾桶"), trash),
        ]
        var categories: [JunkCategory] = []
        for (name, build) in builders {
            if Task.isCancelled { break }
            progress?(L("正在掃瞄%@", name))
            let category = build()
            if !category.items.isEmpty { categories.append(category) }
        }
        return categories
    }

    // MARK: - Categories

    private func userCaches() -> JunkCategory {
        let urls = children(of: "Library/Caches").filter {
            let name = $0.lastPathComponent
            return !name.hasPrefix("com.apple.") && !name.hasPrefix(".") && !Self.cacheExclusions.contains(name)
        }
        let items = urls.map { item($0, inUse: runningBundleIDs.contains($0.lastPathComponent.lowercased())) }
        return category("user-cache", "使用者快取", "App 暫存的資料，App 需要時會重新產生。", "shippingbox", on: true, items)
    }

    private func browserCaches() -> JunkCategory {
        var items: [JunkItem] = []
        for browser in Self.browsers {
            let url = home.appendingPathComponent("Library/Caches").appendingPathComponent(browser.path)
            if FileManager.default.fileExists(atPath: url.path) {
                items.append(item(url, inUse: runningBundleIDs.contains(browser.bundleID)))
            }
        }
        return category("browser-cache", "瀏覽器快取", "網頁暫存檔，不會影響書籤和密碼。", "globe", on: true, items)
    }

    private func logs() -> JunkCategory {
        category("logs", "記錄檔", "App 和當機記錄。除非正在排查問題，否則不需要保留。", "doc.text", on: true,
                 children(of: "Library/Logs").map { item($0) })
    }

    private func xcodeBuildCaches() -> JunkCategory {
        let xcodeRunning = runningBundleIDs.contains("com.apple.dt.xcode")
        let urls = children(of: "Library/Developer/Xcode/DerivedData")
            + children(of: "Library/Developer/CoreSimulator/Caches")
        return category("xcode-build", "Xcode 建置快取", "DerivedData 與模擬器快取，下次建置時會重新產生。", "hammer", on: true,
                        urls.map { item($0, inUse: xcodeRunning) })
    }

    private func developerCaches() -> JunkCategory {
        var urls = Self.developerCacheNames
            .map { home.appendingPathComponent("Library/Caches").appendingPathComponent($0) }
        urls += [".npm/_cacache", ".gradle/caches", ".cargo/registry/cache"].map { home.appendingPathComponent($0) }
        urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        urls += children(of: ".cache")
        return category("dev-cache", "開發工具快取", "npm、Homebrew、pip 等的下載快取。清除後下次使用要重新下載，模型或大型套件可能很費時。",
                        "terminal", on: false, urls.map { item($0) })
    }

    private func xcodeArchives() -> JunkCategory {
        let urls = children(of: "Library/Developer/Xcode/Archives")
            + children(of: "Library/Developer/Xcode/iOS DeviceSupport")
            + children(of: "Library/Developer/Xcode/watchOS DeviceSupport")
        return category("xcode-archives", "Xcode 封存與裝置支援", "封存檔是解析已上架版本當機記錄所必需的，請確認後再清除。",
                        "archivebox", on: false, urls.map { item($0) })
    }

    private func oldInstallers() -> JunkCategory {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        let urls = children(of: "Downloads").filter {
            guard ["dmg", "pkg", "iso"].contains($0.pathExtension.lowercased()) else { return false }
            let modified = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (modified ?? .distantFuture) < cutoff
        }
        return category("installers", "已下載的安裝檔", "「下載項目」中超過 30 天的 .dmg、.pkg、.iso 檔。", "arrow.down.circle", on: false,
                        urls.map { item($0) })
    }

    private func iosBackups() -> JunkCategory {
        category("ios-backups", "iOS 裝置備份", "iPhone／iPad 的本機備份，可能是唯一的備份，請確認後再清除。", "iphone", on: false,
                 children(of: "Library/Application Support/MobileSync/Backup").map { item($0) })
    }

    private func orphans() -> JunkCategory {
        let containers = children(of: "Library/Containers").filter { isOrphan($0.lastPathComponent) }
        let saved = children(of: "Library/Saved Application State").filter {
            isOrphan($0.lastPathComponent.replacingOccurrences(of: ".savedState", with: ""))
        }
        return category("orphans", "已移除 App 的殘留", "找不到對應 App 的資料。若 App 放在外接硬碟上也可能被列入，請確認後再清除。",
                        "questionmark.folder", on: false, (containers + saved).map { item($0) })
    }

    private func trash() -> JunkCategory {
        let items = Cleaner(home: home).trashContents().map {
            JunkItem(url: $0.url, name: $0.url.lastPathComponent, size: $0.size, inUse: false)
        }
        return JunkCategory(id: "trash", title: "垃圾桶", detail: "清除後無法復原。", symbol: "trash",
                            defaultSelected: false, permanent: true, items: items.sorted { $0.size > $1.size })
    }

    // MARK: - Helpers

    /// Only reverse-DNS, non-Apple identifiers qualify. Helpers count as installed when a parent ID is.
    func isOrphan(_ identifier: String) -> Bool {
        var parts = identifier.split(separator: ".").map(String.init)
        guard parts.count >= 3, !identifier.hasPrefix("com.apple.") else { return false }
        while parts.count >= 3 {
            if isInstalled(parts.joined(separator: ".")) { return false }
            parts.removeLast()
        }
        return true
    }

    private func children(of relative: String) -> [URL] {
        let folder = home.appendingPathComponent(relative)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent != ".DS_Store" }
    }

    private func item(_ url: URL, inUse: Bool = false) -> JunkItem {
        JunkItem(url: url, name: url.lastPathComponent, size: FileWalker.allocatedSize(of: url), inUse: inUse)
    }

    private func category(
        _ id: String, _ title: String, _ detail: String, _ symbol: String, on: Bool, _ items: [JunkItem]
    ) -> JunkCategory {
        JunkCategory(
            id: id, title: title, detail: detail, symbol: symbol, defaultSelected: on, permanent: false,
            items: items.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        )
    }
}

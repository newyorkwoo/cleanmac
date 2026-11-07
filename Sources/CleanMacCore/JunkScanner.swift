import Foundation

public struct JunkItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let size: Int64
    /// Belongs to an app that is running now, so it is never preselected.
    public let inUse: Bool
    /// In /Library, so removing it takes an administrator password.
    public var isSystem = false
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
    /// Vendors ("com.vendor") with installed software; their data is never called a leftover.
    public let installedVendors: Set<String>
    /// Developers (Team IDs) with installed apps; containers they own are never called leftovers.
    public let installedTeamIDs: Set<String>
    /// Command-line tools on this Mac, by name.
    public let installedCommands: Set<String>
    /// Where system-wide leftovers are looked for. nil leaves /Library out of the scan.
    public let systemRoot: URL?

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
        installedBundleIDs: Set<String> = [],
        installedTeamIDs: Set<String> = [],
        installedCommands: Set<String> = [],
        systemRoot: URL? = nil,
        isInstalled: @escaping @Sendable (String) -> Bool
    ) {
        self.home = home
        self.runningBundleIDs = Set(runningBundleIDs.map { $0.lowercased() })
        self.isInstalled = isInstalled
        self.installedVendors = Set((installedBundleIDs.map { $0.lowercased() } + runningBundleIDs.map { $0.lowercased() })
            .map(AppInventory.vendor(of:)))
        self.installedTeamIDs = installedTeamIDs
        self.installedCommands = installedCommands
        self.systemRoot = systemRoot
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

    /// Folders in ~/Library whose items are named after the app's bundle ID. Caches and Logs are left
    /// out because their own categories already list everything in them.
    private static let orphanFolders = [
        "Application Support", "Containers", "Group Containers", "Application Scripts", "HTTPStorages", "WebKit",
        "Saved Application State", "Preferences", "Cookies",
    ]

    /// Data of software that is no longer installed, in ~/Library and, with a password, in /Library.
    private func orphans() -> JunkCategory {
        var user: [(folder: String, url: URL)] = []
        func add(_ folder: String, where isLeftover: (URL) -> Bool) {
            user += children(of: "Library/" + folder).filter(isLeftover).map { (folder, $0) }
        }
        for folder in Self.orphanFolders {
            add(folder) { url in
                guard let id = Self.identifier(in: url.lastPathComponent), isOrphan(id) else { return false }
                // Application Scripts folders carry no metadata, but the app's container of the same name does.
                let owner = Self.ownerTeamID(of: url)
                    ?? Self.ownerTeamID(of: home.appendingPathComponent("Library/Containers").appendingPathComponent(url.lastPathComponent))
                return owner.map { !installedTeamIDs.contains($0) } ?? true
            }
        }
        // These are named "<bundle id>.<host UUID>.plist".
        add("Preferences/ByHost") {
            $0.pathExtension == "plist" && isOrphan($0.deletingPathExtension().deletingPathExtension().lastPathComponent)
        }
        add("LaunchAgents", where: isBrokenLaunchJob)

        var items = user.map {
            JunkItem(url: $0.url, name: "~/Library/\($0.folder)/\($0.url.lastPathComponent)", size: FileWalker.allocatedSize(of: $0.url), inUse: false)
        }
        if let systemRoot {
            items += systemOrphans(in: systemRoot).map {
                JunkItem(url: $0, name: $0.path, size: FileWalker.allocatedSize(of: $0), inUse: false, isSystem: true)
            }
        }
        // Empty folders and unreadable system items still count, so nothing is filtered out by size.
        return JunkCategory(id: "orphans", title: "已移除 App 的殘留", detail: "已不存在的軟體留下的設定、支援檔案與容器，以及指向已刪除程式的背景服務。同一開發者仍有安裝其他軟體時不會列入。若 App 放在外接硬碟上也可能被列入，請確認後再清除。", symbol: "questionmark.folder", defaultSelected: false, permanent: false, items: items.sorted { $0.size > $1.size })
    }

    private func systemOrphans(in root: URL) -> [URL] {
        var found: [URL] = []
        for folder in ["Application Support", "Caches", "Preferences"] {
            found += children(at: root.appendingPathComponent(folder)).filter {
                Self.identifier(in: $0.lastPathComponent).map(isOrphan) ?? false
            }
        }
        let jobs = PathGuard.launchFolders.flatMap { children(at: root.appendingPathComponent($0)) }
        let broken = jobs.filter(isBrokenLaunchJob)
        found += broken
        // A privileged helper is only ever started by a launch daemon, so one no working job runs is dead.
        let liveJobs = jobs.filter { !broken.contains($0) }
        let usedHelpers = Set(liveJobs.compactMap { LaunchJob(url: $0)?.program }.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
        found += children(at: root.appendingPathComponent("PrivilegedHelperTools")).filter {
            !usedHelpers.contains($0.lastPathComponent.lowercased()) && isOrphan($0.lastPathComponent)
        }
        return found
    }

    /// A launch job whose program is gone can never run again, whatever its name says.
    /// Programs on other volumes, or in folders this app can't read, can't be judged and are kept.
    func isBrokenLaunchJob(_ url: URL) -> Bool {
        guard let job = LaunchJob(url: url), let program = job.program, program.hasPrefix("/"),
              !job.label.lowercased().hasPrefix("com.apple."), !program.hasPrefix("/Volumes/"),
              !FileManager.default.fileExists(atPath: program) else { return false }
        var parent = URL(fileURLWithPath: program).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            parent = parent.deletingLastPathComponent()
        }
        return (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil
    }

    /// The developer who owns a container: group containers start with the Team ID, and app containers
    /// record it in their metadata. nil when neither says.
    static func ownerTeamID(of url: URL) -> String? {
        if let first = url.lastPathComponent.split(separator: ".").first.map(String.init), isTeamID(first) { return first }
        guard let data = try? Data(contentsOf: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        let text = String(describing: plist)
        guard let range = text.range(of: #"teamIdentifier\\?"\s*:\s*\\?"[A-Z0-9]{10}"#, options: .regularExpression) else { return nil }
        return String(text[range].suffix(10))
    }

    private static func isTeamID(_ text: String) -> Bool {
        text.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
    }

    /// The bundle ID an item is named after: "com.foo.app", "com.foo.app.plist", "com.foo.app.savedState",
    /// "com.foo.app.binarycookies", "<team ID>.com.foo.app" or "<team ID>.group.com.foo.app".
    static func identifier(in name: String) -> String? {
        var parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.last?.lowercased(), ["plist", "savedstate", "binarycookies"].contains(last) { parts.removeLast() }
        if let first = parts.first, isTeamID(first) { parts.removeFirst() }
        if let first = parts.first?.lowercased(), ["group", "groups", "systemgroup"].contains(first) { parts.removeFirst() }
        let id = parts.joined(separator: ".")
        return id.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil ? id : nil
    }

    private func trash() -> JunkCategory {
        let items = Cleaner(home: home).trashContents().map {
            JunkItem(url: $0.url, name: $0.url.lastPathComponent, size: $0.size, inUse: false)
        }
        return JunkCategory(id: "trash", title: "垃圾桶", detail: "清除後無法復原。", symbol: "trash",
                            defaultSelected: false, permanent: true, items: items.sorted { $0.size > $1.size })
    }

    // MARK: - Helpers

    /// Namespaces of software that ships with macOS (Shortcuts was once Workflow), and of frameworks
    /// that many apps embed and share data under, so no single app's removal makes them leftovers.
    private static let systemNamespaces = [
        "com.apple.", "org.cups.", "org.openssh.", "com.openssh.", "org.ntp.", "org.webkit.", "org.swift.", "org.llvm.",
        "is.workflow.", "org.sparkle-project.", "com.firebase.", "com.install4j.", "com.crashlytics.", "io.sentry.",
    ]

    /// Only reverse-DNS identifiers outside macOS's own namespaces qualify. Helpers count as installed
    /// when a parent ID is, and nothing counts as left over while its vendor has software installed.
    func isOrphan(_ identifier: String) -> Bool {
        let lower = identifier.lowercased()
        var parts = identifier.split(separator: ".").map(String.init)
        guard parts.count >= 3, !Self.systemNamespaces.contains(where: lower.hasPrefix), !lower.contains("com.apple."),
              !installedVendors.contains(AppInventory.vendor(of: lower)) else { return false }
        // "com.vercel.cli" names the installed command "vercel". The top-level domain and generic words don't count.
        let generic: Set<String> = ["app", "apps", "cli", "mac", "macos", "osx", "desktop", "helper", "agent", "daemon", "service", "launcher"]
        if lower.split(separator: ".").dropFirst().contains(where: { $0.count >= 3 && !generic.contains(String($0)) && installedCommands.contains(String($0)) }) {
            return false
        }
        while parts.count >= 3 {
            if isInstalled(parts.joined(separator: ".")) { return false }
            parts.removeLast()
        }
        return true
    }

    private func children(of relative: String) -> [URL] {
        children(at: home.appendingPathComponent(relative))
    }

    private func children(at folder: URL) -> [URL] {
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

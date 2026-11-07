import CoreServices
import Foundation

public struct AppInfo: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public var size: Int64
    public let lastUsed: Date?
}

public struct LeftoverItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
}

public enum AppInventory {
    public static func scan(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        roots: [URL]? = nil,
        progress: ProgressHandler? = nil
    ) -> [AppInfo] {
        let searchRoots = roots ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        // Vendors nest apps, as in /Applications/Vendor/Product/Product.app.
        let bundles = searchRoots.flatMap { findBundles(in: $0, depth: 4) }
        var apps: [AppInfo] = []
        for (index, url) in bundles.enumerated() {
            if Task.isCancelled { break }
            progress?(L("正在讀取 App %@/%@", index + 1, bundles.count))
            if let app = read(url) { apps.append(app) }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Symlinks are skipped, which also leaves out the system apps linked into /Applications.
    private static func findBundles(in folder: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return urls.flatMap { url -> [URL] in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { return [] }
            return url.pathExtension == "app" ? [url] : findBundles(in: url, depth: depth - 1)
        }
    }

    private static func read(_ url: URL) -> AppInfo? {
        guard let info = Bundle(url: url)?.infoDictionary, let bundleID = info["CFBundleIdentifier"] as? String else {
            return nil
        }
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppInfo(
            url: url, name: name, bundleID: bundleID,
            version: (info["CFBundleShortVersionString"] as? String) ?? "",
            size: FileWalker.allocatedSize(of: url),
            lastUsed: lastUsedDate(url)
        )
    }

    private static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Finds data belonging to an app. Matching stays strict (the exact bundle ID, its
    /// children, or the exact app name) so other apps' data is not swept up.
    public static func leftovers(for app: AppInfo, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [LeftoverItem] {
        let id = app.bundleID.lowercased()
        let appName = app.url.deletingPathExtension().lastPathComponent.lowercased()
        // Short IDs and Apple's shared namespace are matched exactly, never by prefix.
        let allowPrefix = id.split(separator: ".").count >= 3 && !id.hasPrefix("com.apple.")

        func matchesID(_ candidate: String) -> Bool {
            candidate == id || (allowPrefix && candidate.hasPrefix(id + "."))
        }

        let idFolders = [
            "Library/Application Support", "Library/Caches", "Library/Containers", "Library/Application Scripts",
            "Library/HTTPStorages", "Library/WebKit", "Library/Logs", "Library/Saved Application State",
            "Library/Preferences", "Library/Cookies", "Library/LaunchAgents",
        ]
        let nameFolders: Set<String> = ["Library/Application Support", "Library/Caches", "Library/Logs"]

        var found: [URL] = []
        for folder in idFolders {
            for url in children(of: home.appendingPathComponent(folder)) {
                let raw = url.lastPathComponent.lowercased()
                let stem = ["plist", "savedstate", "binarycookies"].contains(url.pathExtension.lowercased())
                    ? url.deletingPathExtension().lastPathComponent.lowercased() : raw
                if matchesID(stem) || (nameFolders.contains(folder) && appName.count >= 4 && raw == appName) {
                    found.append(url)
                }
            }
        }
        // Group containers are named "<team id>.<bundle id>".
        for url in children(of: home.appendingPathComponent("Library/Group Containers")) {
            if url.lastPathComponent.lowercased().hasSuffix("." + id) { found.append(url) }
        }

        return found
            .map { LeftoverItem(url: $0, size: FileWalker.allocatedSize(of: $0)) }
            .sorted { $0.size > $1.size }
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }
}

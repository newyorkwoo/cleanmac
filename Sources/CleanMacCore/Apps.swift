import CoreServices
import Foundation
import Security

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
    /// Outside the home folder, so removing it takes an administrator password.
    public var isSystem = false
}

/// The parts of a launchd plist that tie a job to an app or are needed to stop it.
struct LaunchJob {
    let label: String
    let program: String?
    let bundleIDs: [String]

    init?(url: URL) {
        guard url.pathExtension.lowercased() == "plist", let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        self.label = label
        program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        let associated = plist["AssociatedBundleIdentifiers"]
        bundleIDs = ((associated as? [String]) ?? (associated as? String).map { [$0] } ?? []).map { $0.lowercased() }
    }
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
        findBundles(in: folder, depth: depth, extensions: ["app"])
    }

    /// Bundle IDs of installed software of every kind, not only apps: prefpanes, plugins, drivers, JDKs and
    /// frameworks also keep data under their vendor's IDs, and so do the XPC services and extensions inside
    /// apps. Application Support is left out on purpose, since removed apps often leave updater apps there,
    /// which would make their own leftovers look installed.
    public static func installedSoftware(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemRoot: URL = URL(fileURLWithPath: "/Library")
    ) -> (bundleIDs: Set<String>, teamIDs: Set<String>) {
        let libraryFolders = [
            "PreferencePanes", "Input Methods", "Audio/Plug-Ins", "Internet Plug-Ins", "QuickLook", "Spotlight",
            "Screen Savers", "Services", "Components", "Contextual Menu Items", "Extensions", "Printers",
            "Image Capture", "Java/JavaVirtualMachines", "Frameworks", "Mail/Bundles",
        ]
        var roots: [(URL, Int)] = [
            (URL(fileURLWithPath: "/Applications"), 4), (home.appendingPathComponent("Applications"), 4),
            (URL(fileURLWithPath: "/System/Applications"), 3),
        ]
        for folder in libraryFolders {
            roots.append((systemRoot.appendingPathComponent(folder), 3))
            roots.append((home.appendingPathComponent("Library").appendingPathComponent(folder), 3))
        }
        var ids: Set<String> = []
        var teams: Set<String> = []
        for (root, depth) in roots {
            for url in findBundles(in: root, depth: depth, extensions: installedBundleExtensions) {
                if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id.lowercased()) }
                guard url.pathExtension.lowercased() == "app" else { continue }
                if let team = teamIdentifier(of: url) { teams.insert(team) }
                let contents = url.appendingPathComponent("Contents")
                for folder in ["XPCServices", "PlugIns", "Library", "Helpers"] {
                    for inner in findBundles(in: contents.appendingPathComponent(folder), depth: 2, extensions: embeddedBundleExtensions) {
                        if let id = Bundle(url: inner)?.bundleIdentifier { ids.insert(id.lowercased()) }
                    }
                }
            }
        }
        return (ids, teams)
    }

    /// Names of command-line tools. They have no bundle, but some keep data under IDs such as
    /// "com.vercel.cli", so an ID naming an installed command isn't a leftover.
    public static func installedCommands(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        var folders = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        folders += ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin", "/opt/local/bin"]
        folders += [".local/bin", "bin", ".cargo/bin", "go/bin", ".bun/bin", ".deno/bin", ".npm-global/bin", ".volta/bin",
                    ".yarn/bin", ".pyenv/shims", ".rbenv/shims", ".asdf/shims", ".dotnet/tools"].map { home.appendingPathComponent($0).path }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        folders += ((try? FileManager.default.contentsOfDirectory(atPath: nvm.path)) ?? []).map { nvm.appendingPathComponent($0 + "/bin").path }
        var names: Set<String> = []
        for folder in Set(folders) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] { names.insert(name.lowercased()) }
        }
        return names
    }

    /// The developer's Team ID from the code signature, without validating it.
    static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static let embeddedBundleExtensions: Set<String> = installedBundleExtensions.union(["xpc", "appex", "systemextension"])

    static let installedBundleExtensions: Set<String> = [
        "app", "prefpane", "plugin", "component", "bundle", "kext", "driver", "jdk", "framework", "qlgenerator",
        "mdimporter", "saver", "vst", "vst3", "mailbundle", "service",
    ]

    /// "com.vendor" for "com.vendor.product.helper". Products of one vendor share data, so any installed
    /// product of the vendor keeps the vendor's data from being called a leftover.
    public static func vendor(of identifier: String) -> String {
        identifier.lowercased().split(separator: ".").prefix(2).joined(separator: ".")
    }

    private static func findBundles(in folder: URL, depth: Int, extensions: Set<String>) -> [URL] {
        guard depth > 0 else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        return urls.flatMap { url -> [URL] in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isDirectory == true else { return [] }
            return extensions.contains(url.pathExtension.lowercased()) ? [url] : findBundles(in: url, depth: depth - 1, extensions: extensions)
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
    /// children, the exact app name, or a launchd job that names the app) so other apps' data
    /// is not swept up. Apple's apps get no system-level matches, since those folders are the OS's.
    public static func leftovers(
        for app: AppInfo,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemRoot: URL = URL(fileURLWithPath: "/Library")
    ) -> [LeftoverItem] {
        let id = app.bundleID.lowercased()
        let appName = app.url.deletingPathExtension().lastPathComponent.lowercased()
        let isApple = id.hasPrefix("com.apple.")
        // Short IDs and Apple's shared namespace are matched exactly, never by prefix.
        let allowPrefix = id.split(separator: ".").count >= 3 && !isApple
        let nameFolders: Set<String> = ["Application Support", "Caches", "Logs"]

        func matchesID(_ candidate: String) -> Bool {
            candidate == id || (allowPrefix && candidate.hasPrefix(id + "."))
        }

        func matches(_ url: URL, in folder: String) -> Bool {
            let raw = url.lastPathComponent.lowercased()
            let stem = ["plist", "savedstate", "binarycookies"].contains(url.pathExtension.lowercased())
                ? url.deletingPathExtension().lastPathComponent.lowercased() : raw
            return matchesID(stem) || (nameFolders.contains(folder) && appName.count >= 4 && raw == appName)
        }

        let helpers = declaredHelpers(of: app.url)

        func belongsToApp(_ job: LaunchJob) -> Bool {
            job.program?.hasPrefix(app.url.path + "/") == true || job.bundleIDs.contains(id)
                || helpers.contains(job.label.lowercased())
                || job.program.map { helpers.contains(URL(fileURLWithPath: $0).lastPathComponent.lowercased()) } == true
        }

        let userLibrary = home.appendingPathComponent("Library")
        var found: [URL] = []
        let userFolders = [
            "Application Support", "Caches", "Containers", "Application Scripts", "HTTPStorages", "WebKit",
            "Logs", "Saved Application State", "Preferences", "Cookies", "LaunchAgents",
        ]
        for folder in userFolders {
            for url in children(of: userLibrary.appendingPathComponent(folder)) where matches(url, in: folder) {
                found.append(url)
            }
        }
        for url in children(of: userLibrary.appendingPathComponent("LaunchAgents")) {
            if let job = LaunchJob(url: url), belongsToApp(job) { found.append(url) }
        }
        // These are named "<team id>.<bundle id>".
        for folder in ["Group Containers", "Application Scripts"] {
            for url in children(of: userLibrary.appendingPathComponent(folder))
            where url.lastPathComponent.lowercased().hasSuffix("." + id) {
                found.append(url)
            }
        }
        // These are named "<bundle id>.<host UUID>.plist".
        for url in children(of: userLibrary.appendingPathComponent("Preferences/ByHost")) where url.pathExtension == "plist" {
            if matchesID(url.deletingPathExtension().deletingPathExtension().lastPathComponent.lowercased()) { found.append(url) }
        }
        for folder in ["Logs/DiagnosticReports", "Application Support/CrashReporter"] {
            for url in children(of: userLibrary.appendingPathComponent(folder))
            where isCrashReport(url.lastPathComponent.lowercased(), appName: appName) {
                found.append(url)
            }
        }

        var system: [URL] = []
        if !isApple {
            for folder in PathGuard.systemFolders {
                for url in children(of: systemRoot.appendingPathComponent(folder))
                where matches(url, in: folder) || (folder == "PrivilegedHelperTools" && helpers.contains(url.lastPathComponent.lowercased())) {
                    system.append(url)
                }
            }
            for folder in PathGuard.launchFolders {
                for url in children(of: systemRoot.appendingPathComponent(folder)) {
                    guard let job = LaunchJob(url: url), system.contains(url) || belongsToApp(job) else { continue }
                    system.append(url)
                    // A job's helper tool is named after the helper, not the app, so only the job links it to the app.
                    if let program = job.program { system.append(URL(fileURLWithPath: program)) }
                }
            }
        }
        // A job's program can point anywhere, so only what the guard accepts is listed.
        let systemGuard = PathGuard(home: home, systemRoot: systemRoot)
        let allowedSystem = system.filter {
            (try? systemGuard.checkSystemItem($0)) != nil && FileManager.default.fileExists(atPath: $0.path)
        }

        let userItems = unique(found).map { LeftoverItem(url: $0, size: FileWalker.allocatedSize(of: $0)) }
        let systemItems = unique(allowedSystem).map { LeftoverItem(url: $0, size: FileWalker.allocatedSize(of: $0), isSystem: true) }
        return (userItems + systemItems).sorted { $0.size > $1.size }
    }

    /// Helpers rarely carry the app's bundle ID ("com.docker.vmnetd" for "com.docker.docker"), so vendor
    /// prefixes would catch other products. These are the names the app's own bundle vouches for:
    /// its declared privileged helpers, and executables it ships under an identifier-style name.
    private static func declaredHelpers(of appURL: URL) -> Set<String> {
        let contents = appURL.appendingPathComponent("Contents")
        var names: [String] = []
        if let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
           let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let declared = info["SMPrivilegedExecutables"] as? [String: Any] {
            names += declared.keys
        }
        for folder in ["MacOS", "Library/LaunchServices"] {
            names += children(of: contents.appendingPathComponent(folder)).map(\.lastPathComponent)
                .filter { $0.split(separator: ".").count >= 3 }
        }
        return Set(names.map { $0.lowercased() })
    }

    /// Matches "<app>-2026-01-31-...ips", "<app>_2026-01-31-...crash" and "<app>_<UUID>.plist".
    /// The date or UUID has to follow directly, which keeps "foo-bar-2026..." away from an app named "foo".
    private static func isCrashReport(_ name: String, appName: String) -> Bool {
        guard appName.count >= 4, name.hasPrefix(appName) else { return false }
        let rest = name.dropFirst(appName.count)
        return rest.range(of: "^[-_]([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9a-f]{8}-[0-9a-f]{4}-)", options: .regularExpression) != nil
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static func children(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }
}

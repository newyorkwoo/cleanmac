import Foundation

public enum SafetyError: LocalizedError, Equatable {
    case protectedPath(String)

    public var errorDescription: String? {
        switch self {
        case .protectedPath(let path): return L("受保護的路徑，已拒絕處理：%@", path)
        }
    }
}

/// The single gate every delete goes through. It allow-lists where deletion may
/// happen, then refuses folders whose removal would damage the account.
public struct PathGuard: Sendable {
    public let home: String
    private let systemRoot: URL

    /// Folders in /Library whose direct children an uninstall may remove with an administrator password.
    static let launchFolders = ["LaunchAgents", "LaunchDaemons"]
    static let systemFolders = ["Application Support", "Caches", "Logs", "Preferences", "PrivilegedHelperTools"] + launchFolders

    /// The folder itself may not be removed, though items inside it may.
    private static let keepFolder = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
        ".Trash", "Library/Application Support", "Library/Caches", "Library/CloudStorage", "Library/Containers",
        "Library/Group Containers", "Library/LaunchAgents", "Library/Logs", "Library/Mobile Documents",
        "Library/Preferences", "Library/Developer",
    ]

    /// Neither the folder nor anything inside it may be removed.
    private static let neverTouch = [
        ".ssh", ".gnupg", "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Accounts",
    ]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemRoot: URL = URL(fileURLWithPath: "/Library")
    ) {
        self.home = Self.canonical(home)
        self.systemRoot = systemRoot
    }

    /// Kept apart from `check` so only an uninstall can reach these paths, never a scan's result.
    /// Allows direct children of `systemFolders` only, and nothing in Apple's namespace.
    public func checkSystemItem(_ url: URL) throws {
        let reject = SafetyError.protectedPath(url.path)
        if url.path.split(separator: "/").contains("..") { throw reject }
        let name = url.lastPathComponent.lowercased()
        if name.hasPrefix("com.apple.") { throw reject }
        let parent = Self.canonical(url.deletingLastPathComponent()).lowercased()
        guard let folder = Self.systemFolders.first(where: {
            Self.canonical(systemRoot.appendingPathComponent($0)).lowercased() == parent
        }) else { throw reject }
        if Self.launchFolders.contains(folder), !name.hasSuffix(".plist") { throw reject }
    }

    public func check(_ url: URL) throws {
        // The OS resolves "link/.." through the link, unlike a lexical cleanup, so the path
        // checked here could differ from the one acted on. No scan produces "..", so refuse it.
        if url.path.split(separator: "/").contains("..") { throw SafetyError.protectedPath(url.path) }
        let path = Self.canonical(url)
        let lower = path.lowercased()
        let reject = SafetyError.protectedPath(url.path)
        let homeLower = home.lowercased()

        if lower.hasPrefix(homeLower + "/") {
            for rel in Self.neverTouch {
                let protected = homeLower + "/" + rel.lowercased()
                if lower == protected || lower.hasPrefix(protected + "/") { throw reject }
            }
            // Rejecting an ancestor of a protected folder also covers e.g. ~/Library/Developer's parents.
            for rel in Self.keepFolder + Self.neverTouch {
                let protected = homeLower + "/" + rel.lowercased()
                if lower == protected || protected.hasPrefix(lower + "/") { throw reject }
            }
            return
        }

        // Outside home only three narrow shapes are allowed.
        if lower.hasPrefix("/applications/"), lower.hasSuffix(".app") { return }
        if lower.hasPrefix("/library/launchagents/") || lower.hasPrefix("/library/launchdaemons/"),
           lower.hasSuffix(".plist") { return }
        let parts = lower.split(separator: "/")
        if parts.first == "volumes", parts.count >= 3 { return }
        throw reject
    }

    /// Resolves symlinks in the parent only: a symlink being removed is the link, not its target.
    static func canonical(_ url: URL) -> String {
        let standard = url.standardizedFileURL
        guard standard.path != "/" else { return "/" }
        let parent = standard.deletingLastPathComponent().resolvingSymlinksInPath()
        let joined = parent.appendingPathComponent(standard.lastPathComponent).path
        return joined.hasSuffix("/") && joined != "/" ? String(joined.dropLast()) : joined
    }
}

public struct CleanResult: Sendable {
    public var count = 0
    public var bytes: Int64 = 0
    public var trashedURLs: [URL] = []
    /// Original paths of everything that is gone now, so other result lists can drop them.
    public var removedPaths: [String] = []
    public var failures: [Failure] = []

    public struct Failure: Sendable, Identifiable {
        public var id: String { path }
        public let path: String
        public let message: String
    }

    public init() {}

    public mutating func merge(_ other: CleanResult) {
        count += other.count
        bytes += other.bytes
        trashedURLs += other.trashedURLs
        removedPaths += other.removedPaths
        failures += other.failures
    }
}

public struct Cleaner: Sendable {
    public let pathGuard: PathGuard
    public let home: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemRoot: URL = URL(fileURLWithPath: "/Library")
    ) {
        self.home = home
        self.pathGuard = PathGuard(home: home, systemRoot: systemRoot)
    }

    /// Removes an app and its chosen leftovers. Everything needing a password goes first, so
    /// cancelling the prompt returns nil with nothing removed.
    public func uninstall(
        app: (url: URL, size: Int64),
        leftovers: [LeftoverItem],
        runAsAdmin: (String) -> Shell.Output = Shell.runAsAdmin
    ) -> CleanResult? {
        var adminItems = leftovers.filter(\.isSystem).map { (url: $0.url, size: $0.size) }
        var userItems = leftovers.filter { !$0.isSystem }.map { (url: $0.url, size: $0.size) }
        // Installer packages can leave an app owned by root.
        if FileManager.default.isWritableFile(atPath: app.url.path) {
            userItems.insert(app, at: 0)
        } else {
            adminItems.insert(app, at: 0)
        }

        var result = CleanResult()
        if !adminItems.isEmpty {
            guard let moved = moveToTrashAsAdmin(adminItems, run: runAsAdmin) else { return nil }
            result.merge(moved)
        }
        stopUserJobs(userItems.map(\.url))
        result.merge(moveToTrash(userItems))
        return result
    }

    /// One command, so there is one password prompt. Items stay owned by root in the Trash so
    /// they still work if put back. Returns nil when the prompt is cancelled.
    public func moveToTrashAsAdmin(_ items: [(url: URL, size: Int64)], run: (String) -> Shell.Output) -> CleanResult? {
        let trash = home.appendingPathComponent(".Trash")
        try? FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        var result = CleanResult()
        var commands: [String] = []
        var planned: [(url: URL, size: Int64, destination: URL)] = []
        var usedNames: Set<String> = []
        for item in items {
            do {
                if (try? pathGuard.checkSystemItem(item.url)) == nil { try pathGuard.check(item.url) }
            } catch {
                result.failures.append(.init(path: item.url.path, message: error.localizedDescription))
                continue
            }
            if let stop = stopCommand(for: item.url) { commands.append(stop) }
            var name = item.url.lastPathComponent
            if usedNames.contains(name) || FileManager.default.fileExists(atPath: trash.appendingPathComponent(name).path) {
                name += " " + UUID().uuidString.prefix(8)
            }
            usedNames.insert(name)
            let destination = trash.appendingPathComponent(name)
            commands.append("/bin/mv -n \(Self.shellQuoted(item.url.path)) \(Self.shellQuoted(destination.path)) 2>&1")
            planned.append((item.url, item.size, destination))
        }
        guard !planned.isEmpty else { return result }

        // The final true keeps one failed item from reading as a failure of the whole command.
        let output = run((commands + ["true"]).joined(separator: "; "))
        if !output.ok, output.err.contains("-128") { return nil }

        // The filesystem is the record of what moved, since the command's status covers no single item.
        let details = (output.err + output.out).trimmingCharacters(in: .whitespacesAndNewlines)
        for item in planned {
            var info = stat()
            if lstat(item.url.path, &info) != 0, errno == ENOENT {
                result.count += 1
                result.bytes += item.size
                result.removedPaths.append(item.url.path)
                result.trashedURLs.append(item.destination)
            } else {
                result.failures.append(.init(path: item.url.path, message: details.isEmpty ? L("無法移到垃圾桶。") : details))
            }
        }
        return result
    }

    /// launchd keeps a job running after its plist is gone, so it has to be stopped first.
    private func stopCommand(for url: URL) -> String? {
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard PathGuard.launchFolders.contains(folder), let job = LaunchJob(url: url), StartupManager.isSafeLabel(job.label) else { return nil }
        let domain = folder == "LaunchDaemons" ? "system" : "gui/\(getuid())"
        return "/bin/launchctl bootout \(domain)/\(job.label) >/dev/null 2>&1"
    }

    private func stopUserJobs(_ urls: [URL]) {
        let agents = PathGuard.canonical(home.appendingPathComponent("Library/LaunchAgents"))
        for url in urls where PathGuard.canonical(url.deletingLastPathComponent()) == agents {
            guard let job = LaunchJob(url: url), StartupManager.isSafeLabel(job.label) else { continue }
            _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(job.label)"])
        }
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Moves items to the Trash so that anything removed here can be put back.
    public func moveToTrash(_ items: [(url: URL, size: Int64)]) -> CleanResult {
        var result = CleanResult()
        for item in items {
            do {
                try pathGuard.check(item.url)
                var resulting: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &resulting)
                result.count += 1
                result.bytes += item.size
                result.removedPaths.append(item.url.path)
                if let url = resulting as URL? { result.trashedURLs.append(url) }
            } catch {
                result.failures.append(.init(path: item.url.path, message: error.localizedDescription))
            }
        }
        return result
    }

    /// Permanently removes direct children of the Trash folder. Not undoable.
    public func deleteFromTrash(_ items: [(url: URL, size: Int64)]) -> CleanResult {
        let trash = PathGuard.canonical(home.appendingPathComponent(".Trash"))
        var result = CleanResult()
        for item in items {
            do {
                try pathGuard.check(item.url)
                guard PathGuard.canonical(item.url.deletingLastPathComponent()) == trash else {
                    throw SafetyError.protectedPath(item.url.path)
                }
                try FileManager.default.removeItem(at: item.url)
                result.count += 1
                result.bytes += item.size
                result.removedPaths.append(item.url.path)
            } catch {
                result.failures.append(.init(path: item.url.path, message: error.localizedDescription))
            }
        }
        return result
    }

    public func trashContents() -> [(url: URL, size: Int64)] {
        let trash = home.appendingPathComponent(".Trash")
        let children = (try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)) ?? []
        return children
            .filter { $0.lastPathComponent != ".DS_Store" }
            .map { ($0, FileWalker.allocatedSize(of: $0)) }
    }
}

public enum EmptyTrashOutcome: Equatable, Sendable {
    case alreadyEmpty
    case emptied
    case cancelled
    case failed(String)
}

/// Empties the Trash through Finder, which works without Full Disk Access and covers every volume.
public enum TrashEmptier {
    static let countScript = "tell application \"Finder\" to get count of items of trash"
    /// Finder may show its own confirmation, so it comes to the front to keep that dialog
    /// from hiding behind this app. The long timeout leaves time to answer it.
    static let emptyScript = """
    tell application "Finder"
        activate
        with timeout of 3600 seconds
            empty trash
        end timeout
    end tell
    """

    public static func run(
        script: (String) -> Shell.Output = { Shell.run("/usr/bin/osascript", ["-e", $0], timeout: 3600) }
    ) -> EmptyTrashOutcome {
        func itemCount() -> Int? {
            let result = script(countScript)
            return result.ok ? Int(result.out.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        }

        if itemCount() == 0 { return .alreadyEmpty }
        let result = script(emptyScript)
        if result.ok { return .emptied }
        // -128 means the request was cancelled, usually in Finder's dialog. It is not a failure.
        if result.err.contains("-128") { return itemCount() == 0 ? .emptied : .cancelled }
        return .failed(result.err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

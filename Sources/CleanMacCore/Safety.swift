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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = Self.canonical(home)
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

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        self.pathGuard = PathGuard(home: home)
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

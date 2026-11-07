import Foundation

public struct WalkOptions: Sendable {
    public var skipHidden = true
    public var skipPackages = true
    /// Directory names that are not descended into, wherever they occur.
    public var prunedNames: Set<String> = []
    /// Absolute directory paths that are not descended into.
    public var prunedPaths: Set<String> = []

    public init() {}

    /// Personal files only: skips the app-data library and regenerable project output.
    public static func personalFiles(home: URL) -> WalkOptions {
        var options = WalkOptions()
        options.prunedNames = [
            "node_modules", ".git", ".build", "DerivedData", "Pods", "venv", ".venv", "__pycache__",
        ]
        options.prunedPaths = [home.appendingPathComponent("Library").path, home.appendingPathComponent(".Trash").path]
        return options
    }
}

public enum FileWalker {
    /// The same file can be reported as /private/var/... or /var/..., so paths are compared without the alias.
    public static func normalized(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst(8)) : path
    }

    public static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isVolumeKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey,
    ]

    /// Visits regular files. Symlinks are never followed. Stops if the current task is cancelled.
    public static func walk(root: URL, options: WalkOptions, visit: (URL, URLResourceValues) -> Void) {
        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if options.skipHidden { enumeratorOptions.insert(.skipsHiddenFiles) }
        if options.skipPackages { enumeratorOptions.insert(.skipsPackageDescendants) }

        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: enumeratorOptions, errorHandler: { _, _ in true }
        ) else { return }

        let prunedPaths = Set(options.prunedPaths.map(normalized))

        let keySet = Set(keys)
        for case let url as URL in enumerator {
            if Task.isCancelled { return }
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            if values.isDirectory == true {
                if options.prunedNames.contains(url.lastPathComponent)
                    || prunedPaths.contains(normalized(url.path))
                    || (values.isVolume == true) {
                    enumerator.skipDescendants()
                }
            } else if values.isRegularFile == true {
                visit(url, values)
            }
        }
    }

    /// Bytes on disk for a file or a whole folder, including hidden content.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isSymbolicLink == true || values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }
        ) else { return 0 }
        for case let child as URL in enumerator {
            if Task.isCancelled { break }
            if let size = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// True for cloud placeholders whose data is not on this Mac. Reading one would download it.
    public static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return true }
        return (info.st_flags & 0x4000_0000) != 0 // SF_DATALESS
    }
}

public enum LargeFileFinder {
    public static func scan(
        root: URL,
        options: WalkOptions,
        minimumBytes: Int64,
        limit: Int = 2000,
        progress: ProgressHandler? = nil
    ) -> [FileRecord] {
        var found: [FileRecord] = []
        var visited = 0
        FileWalker.walk(root: root, options: options) { url, values in
            visited += 1
            if visited % 2000 == 0 { progress?(L("已檢查 %@ 個檔案", visited)) }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            if size >= minimumBytes {
                found.append(FileRecord(url: url, size: size, modified: values.contentModificationDate))
            }
        }
        found.sort { $0.size > $1.size }
        return Array(found.prefix(limit))
    }
}

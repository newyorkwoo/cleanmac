import CryptoKit
import Foundation

public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String
    public let size: Int64
    public let files: [FileRecord]

    public init(id: String, size: Int64, files: [FileRecord]) {
        self.id = id
        self.size = size
        self.files = files
    }

    public var reclaimable: Int64 { size * Int64(files.count - 1) }

    /// The copy to keep when auto-selecting: oldest first, then the shortest path.
    public var suggestedKeeper: FileRecord? {
        files.min {
            let a = $0.modified ?? .distantFuture
            let b = $1.modified ?? .distantFuture
            return a == b ? $0.url.path.count < $1.url.path.count : a < b
        }
    }
}

public enum DuplicateFinder {
    /// Compares by size, then a sample of each file, then a full SHA-256, so most
    /// files are never read in full. Cloud placeholders are skipped to avoid downloads,
    /// and hard links count once because they use no extra space.
    public static func scan(
        root: URL,
        options: WalkOptions,
        minimumBytes: Int64,
        progress: ProgressHandler? = nil
    ) -> [DuplicateGroup] {
        var bySize: [Int64: [FileRecord]] = [:]
        var seenInodes = Set<String>()
        var visited = 0

        FileWalker.walk(root: root, options: options) { url, values in
            visited += 1
            if visited % 2000 == 0 { progress?(L("已檢查 %@ 個檔案", visited)) }
            let size = Int64(values.fileSize ?? 0)
            guard size >= minimumBytes, (values.totalFileAllocatedSize ?? 0) > 0 else { return }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_flags & 0x4000_0000) == 0 else { return }
            if info.st_nlink > 1, !seenInodes.insert("\(info.st_dev):\(info.st_ino)").inserted { return }
            bySize[size, default: []].append(FileRecord(url: url, size: size, modified: values.contentModificationDate))
        }

        let candidates = bySize.values.filter { $0.count > 1 }
        var groups: [DuplicateGroup] = []
        var done = 0
        for files in candidates {
            if Task.isCancelled { break }
            done += 1
            progress?(L("正在比對內容 %@/%@", done, candidates.count))
            for sampled in Dictionary(grouping: files, by: { sampleKey($0.url) ?? UUID().uuidString }).values
            where sampled.count > 1 {
                for (hash, same) in Dictionary(grouping: sampled, by: { fullHash($0.url) ?? UUID().uuidString })
                where same.count > 1 {
                    groups.append(DuplicateGroup(id: hash, size: same[0].size, files: same))
                }
            }
        }
        return groups.sorted { $0.reclaimable > $1.reclaimable }
    }

    private static func sampleKey(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if let end = try? handle.seekToEnd(), end > UInt64(chunk) {
            try? handle.seek(toOffset: end - UInt64(chunk))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fullHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if Task.isCancelled { return nil }
            enum Step { case more, end, failed }
            let step: Step = autoreleasepool {
                // A read error must not look like the end of the file: two files failing the
                // same way would otherwise share a partial hash and pass as duplicates.
                do {
                    guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return .end }
                    hasher.update(data: data)
                    return .more
                } catch {
                    return .failed
                }
            }
            if step == .failed { return nil }
            if step == .end { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

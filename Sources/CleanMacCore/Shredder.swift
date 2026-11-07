import Foundation

public enum ShredError: LocalizedError {
    case hardLinked(String)
    case notRegular(String)
    case posix(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .hardLinked(let path): return L("檔案有其他硬連結，覆寫會破壞其他位置的內容，已略過：%@", path)
        case .notRegular(let path): return L("不是一般檔案，已略過：%@", path)
        case .posix(let path, let code): return L("%@：%@", path, String(cString: strerror(code)))
        }
    }
}

/// Overwrites files with random data and unlinks them. Not undoable. On APFS and SSDs the
/// old blocks may survive because of copy-on-write, snapshots and wear levelling, so this
/// is best-effort; FileVault is what protects data at rest. The UI says so too.
public enum Shredder {
    public static func shred(_ urls: [URL], passes: Int = 1, pathGuard: PathGuard = PathGuard(), progress: ProgressHandler? = nil) -> CleanResult {
        var result = CleanResult()
        for url in urls {
            do {
                try pathGuard.check(url)
                shredItem(url, passes: passes, result: &result, progress: progress)
                if !FileManager.default.fileExists(atPath: url.path) { result.removedPaths.append(url.path) }
            } catch {
                result.failures.append(.init(path: url.path, message: error.localizedDescription))
            }
        }
        return result
    }

    private static func shredItem(_ url: URL, passes: Int, result: inout CleanResult, progress: ProgressHandler?) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            result.failures.append(.init(path: url.path, message: String(cString: strerror(errno))))
            return
        }
        do {
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                // Remove only the link. The target may be anywhere and was not chosen.
                try removeEntry(url)
                result.count += 1
            case S_IFDIR:
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                for child in children { shredItem(child, passes: passes, result: &result, progress: progress) }
                // A folder that still has failed children stays, and rmdir reports that.
                if rmdir(url.path) != 0 { throw ShredError.posix(url.path, errno) }
            case S_IFREG:
                progress?(L("正在粉碎 %@", url.lastPathComponent))
                let bytes = try overwriteAndRemove(url, passes: passes)
                result.count += 1
                result.bytes += bytes
            default:
                throw ShredError.notRegular(url.path)
            }
        } catch {
            result.failures.append(.init(path: url.path, message: error.localizedDescription))
        }
    }

    private static func overwriteAndRemove(_ url: URL, passes: Int) throws -> Int64 {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw ShredError.posix(url.path, errno) }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw ShredError.posix(url.path, errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ShredError.notRegular(url.path) }
        guard info.st_nlink == 1 else { throw ShredError.hardLinked(url.path) }

        let size = Int64(info.st_size)
        try overwrite(fd: fd, size: size, passes: passes, path: url.path)
        guard ftruncate(fd, 0) == 0 else { throw ShredError.posix(url.path, errno) }
        try removeEntry(url)
        return size
    }

    static func overwrite(fd: Int32, size: Int64, passes: Int, path: String) throws {
        let chunk = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        for _ in 0..<max(1, passes) {
            var offset: Int64 = 0
            while offset < size {
                let length = Int(min(Int64(chunk), size - offset))
                arc4random_buf(&buffer, length)
                let written = pwrite(fd, buffer, length, off_t(offset))
                guard written > 0 else { throw ShredError.posix(path, errno) }
                offset += Int64(written)
            }
            // Plain fsync may leave data in the drive's cache. F_FULLFSYNC pushes it to the media.
            if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        }
    }

    /// Renames first so the original file name does not linger in directory metadata.
    private static func removeEntry(_ url: URL) throws {
        let anonymous = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        let path = rename(url.path, anonymous.path) == 0 ? anonymous.path : url.path
        guard unlink(path) == 0 else { throw ShredError.posix(url.path, errno) }
    }
}

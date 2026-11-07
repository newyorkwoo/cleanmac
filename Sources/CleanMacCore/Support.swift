import Foundation

public typealias ProgressHandler = @Sendable (String) -> Void

public func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

public struct FileRecord: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let modified: Date?

    public init(url: URL, size: Int64, modified: Date?) {
        self.url = url
        self.size = size
        self.modified = modified
    }
}

public enum Shell {
    public struct Output: Sendable {
        public let status: Int32
        public let out: String
        public let err: String
        public var ok: Bool { status == 0 }

        public init(status: Int32, out: String, err: String) {
            self.status = status
            self.out = out
            self.err = err
        }
    }

    /// Runs a tool directly (never through a shell), so arguments are not re-parsed.
    public static func run(
        _ path: String,
        _ args: [String] = [],
        env: [String: String] = [:],
        timeout: TimeInterval = 60
    ) -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return Output(status: -1, out: "", err: error.localizedDescription)
        }

        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain both pipes concurrently so a chatty tool cannot block on a full pipe.
        let group = DispatchGroup()
        let box = PipeBox()
        group.enter()
        DispatchQueue.global().async {
            box.out = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            box.err = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        return Output(
            status: process.terminationStatus,
            out: String(decoding: box.out, as: UTF8.self),
            err: String(decoding: box.err, as: UTF8.self)
        )
    }

    /// Runs a command as root through the standard macOS password prompt.
    /// Callers must validate or quote anything interpolated into `command`.
    public static func runAsAdmin(_ command: String) -> Output {
        run("/usr/bin/osascript", ["-e", adminScript(for: command)], timeout: 300)
    }

    static func adminScript(for command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private final class PipeBox: @unchecked Sendable {
        var out = Data()
        var err = Data()
    }
}

/// Locations macOS refuses to open (EPERM) without Full Disk Access. There are several because
/// none exists everywhere: recent macOS versions have no per-user TCC.db at all.
public func fullDiskAccessProbes(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
    [
        "/Library/Application Support/com.apple.TCC/TCC.db",
        home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db").path,
        home.appendingPathComponent("Library/Safari").path,
    ]
}

/// True when the app can read TCC-protected data, i.e. has Full Disk Access.
/// A probe that is missing says nothing either way, so one successful open is enough.
public func hasFullDiskAccess(probes: [String] = fullDiskAccessProbes()) -> Bool {
    probes.contains { path in
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }
}

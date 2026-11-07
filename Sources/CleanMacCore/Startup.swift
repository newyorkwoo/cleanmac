import Foundation

public enum StartupDomain: String, Sendable {
    case userAgent, globalAgent, globalDaemon, loginItem

    public var title: String {
        switch self {
        case .userAgent: return L("使用者代理程式")
        case .globalAgent: return L("全域代理程式")
        case .globalDaemon: return L("系統背景程式")
        case .loginItem: return L("登入項目")
        }
    }
}

public struct StartupItem: Identifiable, Hashable, Sendable {
    public var id: String { domain.rawValue + ":" + label }
    public let label: String
    public let domain: StartupDomain
    public let plistURL: URL?
    public let program: String?
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public var disabled: Bool

    public var displayName: String {
        guard let program else { return label }
        let appName = program.split(separator: "/").first { $0.hasSuffix(".app") }
        return appName.map { String($0.dropLast(4)) } ?? label
    }
}

public enum StartupError: LocalizedError {
    case unsafeValue(String)
    case command(String)

    public var errorDescription: String? {
        switch self {
        case .unsafeValue(let value): return L("項目名稱含有不安全的字元，已拒絕處理：%@", value)
        case .command(let message): return message
        }
    }
}

public enum StartupManager {
    public static func list(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [StartupItem] {
        let uid = getuid()
        let userDisabled = parseDisabled(Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]).out)
        let systemDisabled = parseDisabled(Shell.run("/bin/launchctl", ["print-disabled", "system"]).out)

        let sources: [(URL, StartupDomain, [String: Bool])] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent, userDisabled),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent, userDisabled),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .globalDaemon, systemDisabled),
        ]

        var items: [StartupItem] = []
        for (folder, domain, disabled) in sources {
            let plists = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in plists where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url),
                      var item = parsePlist(data, url: url, domain: domain),
                      !item.label.hasPrefix("com.apple.") else { continue }
                item.disabled = disabled[item.label] ?? false
                items.append(item)
            }
        }
        return items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public static func parsePlist(_ data: Data, url: URL, domain: StartupDomain) -> StartupItem? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let label = plist["Label"] as? String else { return nil }
        let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
        let keepAlive: Bool
        switch plist["KeepAlive"] {
        case let flag as Bool: keepAlive = flag
        case is [String: Any]: keepAlive = true
        default: keepAlive = false
        }
        return StartupItem(
            label: label, domain: domain, plistURL: url, program: program,
            runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false, keepAlive: keepAlive,
            disabled: (plist["Disabled"] as? Bool) ?? false
        )
    }

    /// Parses `launchctl print-disabled`, whose lines look like `"com.foo" => disabled`
    /// on current systems and `"com.foo" => true` on older ones.
    public static func parseDisabled(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            if state == "disabled" || state == "true" {
                result[label] = true
            } else if state == "enabled" || state == "false" {
                result[label] = false
            }
        }
        return result
    }

    /// Labels come from third-party files and may reach a root command, so only plain identifiers pass.
    public static func isSafeLabel(_ label: String) -> Bool {
        !label.isEmpty && label.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }

    /// Disabling records an override in launchd and leaves the plist in place, so it can be turned back on.
    public static func setEnabled(_ item: StartupItem, enabled: Bool) throws {
        guard isSafeLabel(item.label) else { throw StartupError.unsafeValue(item.label) }
        switch item.domain {
        case .userAgent, .globalAgent:
            let target = "gui/\(getuid())/\(item.label)"
            let result = Shell.run("/bin/launchctl", [enabled ? "enable" : "disable", target])
            guard result.ok else { throw StartupError.command(result.err) }
            if enabled, let plist = item.plistURL {
                _ = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
            } else if !enabled {
                _ = Shell.run("/bin/launchctl", ["bootout", target])
            }
        case .globalDaemon:
            let target = "system/\(item.label)"
            var command = "/bin/launchctl \(enabled ? "enable" : "disable") \(target)"
            if enabled, let plist = item.plistURL {
                guard !plist.path.contains("'") else { throw StartupError.unsafeValue(plist.path) }
                command += "; /bin/launchctl bootstrap system '\(plist.path)' || true"
            } else if !enabled {
                command += "; /bin/launchctl bootout \(target) || true"
            }
            let result = Shell.runAsAdmin(command)
            guard result.ok else { throw StartupError.command(result.err) }
        case .loginItem:
            throw StartupError.command(L("登入項目請使用「移除」，或到系統設定調整。"))
        }
    }

    // MARK: - Login items (uses System Events, which asks for Automation permission once)

    public static func loginItems() throws -> [StartupItem] {
        let script = """
        tell application "System Events"
            set output to ""
            repeat with itemRef in login items
                set output to output & (name of itemRef) & tab & (path of itemRef) & linefeed
            end repeat
            return output
        end tell
        """
        let result = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 30)
        guard result.ok else { throw StartupError.command(result.err) }
        return parseLoginItems(result.out)
    }

    static func parseLoginItems(_ output: String) -> [StartupItem] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard let name = parts.first, !name.isEmpty else { return nil }
            return StartupItem(label: name, domain: .loginItem, plistURL: nil, program: parts.count > 1 ? parts[1] : nil,
                               runAtLoad: true, keepAlive: false, disabled: false)
        }
    }

    static func deleteLoginItemScript(named name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "tell application \"System Events\" to delete login item \"\(escaped)\""
    }

    public static func removeLoginItem(named name: String) throws {
        let result = Shell.run("/usr/bin/osascript", ["-e", deleteLoginItemScript(named: name)])
        guard result.ok else { throw StartupError.command(result.err) }
    }
}

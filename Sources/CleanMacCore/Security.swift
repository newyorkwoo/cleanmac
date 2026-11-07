import Foundation
import Security

public enum FindingSeverity: Int, Comparable, Sendable {
    case ok = 0, info, warning, critical
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct SecurityFinding: Identifiable, Sendable {
    public var id: String { group + ":" + title }
    public let group: String
    public let title: String
    public let detail: String
    public let severity: FindingSeverity
    public var settingsURL: String? = nil
    public var startupItem: StartupItem? = nil
}

public enum SignatureStatus: Equatable, Sendable {
    case developerSigned, adHoc, unsigned, invalid, missing
}

public enum SecurityAuditor {
    /// Names of known Mac adware and potentially unwanted programs. A match is a reason to
    /// look closer rather than proof of infection, and this list is no replacement for a
    /// malware database. macOS's built-in XProtect does that job.
    static let knownAdware = [
        "genieo", "pirrit", "shlayer", "bundlore", "crossrider", "advancedmaccleaner", "macautofixer",
        "mackeeper", "searchmine", "chumsearch", "safefinder",
    ]

    public static let privacySettings = "x-apple.systempreferences:com.apple.preference.security"
    public static let updateSettings = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"

    public static func audit(
        startupItems: [StartupItem],
        apps: [AppInfo],
        includeUpdates: Bool = true,
        progress: ProgressHandler? = nil
    ) -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        progress?(L("正在檢查系統防護設定"))
        findings += systemChecks()
        progress?(L("正在檢查開機項目"))
        findings += startupItems.compactMap(inspect)
        progress?(L("正在檢查 App 簽章"))
        findings += apps.compactMap(inspect)
        if includeUpdates, !Task.isCancelled {
            progress?(L("正在檢查軟體更新（可能需要一分鐘）"))
            findings += updateChecks()
        }
        return findings.sorted { $0.severity > $1.severity }
    }

    private static func systemChecks() -> [SecurityFinding] {
        var findings: [SecurityFinding] = []

        func add(_ title: String, on: Bool?, onText: String, offText: String, severity: FindingSeverity, settings: String? = privacySettings) {
            switch on {
            case true?: findings.append(.init(group: L("系統"), title: title, detail: onText, severity: .ok))
            case false?: findings.append(.init(group: L("系統"), title: title, detail: offText, severity: severity, settingsURL: settings))
            case nil: findings.append(.init(group: L("系統"), title: title, detail: L("無法判斷狀態。"), severity: .info))
            }
        }

        add(L("系統完整性保護 (SIP)"), on: parseOnOff(Shell.run("/usr/bin/csrutil", ["status"]).out, on: "status: enabled", off: "status: disabled"),
            onText: L("已啟用。"), offText: L("已關閉，系統檔案可能被惡意程式修改。"), severity: .critical, settings: nil)
        add("Gatekeeper", on: parseOnOff(Shell.run("/usr/sbin/spctl", ["--status"]).out + Shell.run("/usr/sbin/spctl", ["--status"]).err,
                                         on: "assessments enabled", off: "assessments disabled"),
            onText: L("已啟用，會阻擋來源不明的軟體。"), offText: L("已關閉，任何來源的軟體都能直接執行。"), severity: .critical)
        add(L("FileVault 磁碟加密"), on: parseOnOff(Shell.run("/usr/bin/fdesetup", ["status"]).out, on: "FileVault is On", off: "FileVault is Off"),
            onText: L("已啟用。"), offText: L("未啟用，Mac 遺失時資料可能被讀取。"), severity: .warning)
        add(L("防火牆"), on: parseOnOff(Shell.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).out, on: "enabled", off: "disabled"),
            onText: L("已啟用。"), offText: L("未啟用。"), severity: .warning)
        let autoCheck = Shell.run("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.SoftwareUpdate", "AutomaticCheckEnabled"])
        // The key is absent until changed, and the system default is on.
        add(L("自動檢查更新"), on: autoCheck.ok ? autoCheck.out.trimmingCharacters(in: .whitespacesAndNewlines) == "1" : true,
            onText: L("已啟用。"), offText: L("已關閉，可能錯過安全性更新。"), severity: .warning, settings: updateSettings)
        return findings
    }

    static func parseOnOff(_ output: String, on: String, off: String) -> Bool? {
        if output.contains(on) { return true }
        if output.contains(off) { return false }
        return nil
    }

    private static func updateChecks() -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let result = Shell.run("/usr/sbin/softwareupdate", ["-l"], timeout: 90)
        let text = result.out + result.err
        if result.ok {
            let labels = parseSoftwareUpdates(text)
            if labels.isEmpty {
                findings.append(.init(group: L("更新"), title: L("macOS 更新"), detail: L("已是最新版本。"), severity: .ok))
            } else {
                findings.append(.init(group: L("更新"), title: L("macOS 更新"), detail: L("有可用更新：") + labels.joined(separator: L("、")),
                                      severity: .warning, settingsURL: updateSettings))
            }
        } else {
            findings.append(.init(group: L("更新"), title: L("macOS 更新"), detail: L("無法檢查更新，請確認網路連線。"), severity: .info))
        }

        if let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile) {
            let outdated = Shell.run(brew, ["outdated", "--quiet"], env: ["HOMEBREW_NO_AUTO_UPDATE": "1"], timeout: 60)
            let names = outdated.out.split(separator: "\n").map(String.init)
            if outdated.ok, !names.isEmpty {
                let shown = names.prefix(15).joined(separator: L("、"))
                findings.append(.init(group: L("更新"), title: L("Homebrew 有 %@ 個套件可更新", names.count),
                                      detail: shown + (names.count > 15 ? "⋯" : "") + L("\n可在終端機執行 brew upgrade。"), severity: .info))
            }
        }
        return findings
    }

    static func parseSoftwareUpdates(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("* Label:") else { return nil }
            return trimmed.replacingOccurrences(of: "* Label:", with: "").trimmingCharacters(in: .whitespaces)
        }
    }

    static func inspect(_ item: StartupItem) -> SecurityFinding? {
        guard item.domain != .loginItem else { return nil }
        let haystack = (item.label + " " + (item.program ?? "") + " " + (item.plistURL?.lastPathComponent ?? ""))
            .lowercased().replacingOccurrences(of: " ", with: "")
        if let name = knownAdware.first(where: haystack.contains) {
            return .init(group: L("開機項目"), title: item.displayName,
                         detail: L("名稱符合已知的廣告軟體或不受歡迎程式（%@）。若不是你自己安裝的，建議停用。\n%@", name, item.label),
                         severity: .critical, startupItem: item)
        }
        guard !item.disabled, let program = item.program else { return nil }

        if !FileManager.default.fileExists(atPath: program) {
            return .init(group: L("開機項目"), title: item.displayName,
                         detail: L("指向不存在的程式，可能是已移除 App 的殘留。\n%@", program), severity: .info, startupItem: item)
        }
        let parts = program.lowercased().split(separator: "/")
        let hidden = parts.contains { $0.hasPrefix(".") }
        let temporary = program.hasPrefix("/tmp/") || program.hasPrefix("/private/tmp/")
            || program.hasPrefix("/var/tmp/") || program.hasPrefix("/Users/Shared/")
        if hidden || temporary {
            return .init(group: L("開機項目"), title: item.displayName,
                         detail: L("從隱藏或共用的暫存位置啟動，這是惡意程式常見的手法，請確認是否為你安裝。\n%@", program),
                         severity: .warning, startupItem: item)
        }
        switch signature(of: URL(fileURLWithPath: program)) {
        case .invalid:
            return .init(group: L("開機項目"), title: item.displayName,
                         detail: L("程式簽章無效，可能被修改過。\n%@", program), severity: .warning, startupItem: item)
        case .unsigned, .adHoc:
            return .init(group: L("開機項目"), title: item.displayName,
                         detail: L("程式沒有開發者簽章。腳本和 Homebrew 工具常是如此，若不認得再處理。\n%@", program),
                         severity: .info, startupItem: item)
        case .developerSigned, .missing:
            return nil
        }
    }

    private static func inspect(_ app: AppInfo) -> SecurityFinding? {
        let haystack = (app.name + app.bundleID).lowercased().replacingOccurrences(of: " ", with: "")
        if let name = knownAdware.first(where: haystack.contains) {
            return .init(group: "App", title: app.name, detail: L("名稱符合已知的廣告軟體或不受歡迎程式（%@）。\n%@", name, app.url.path), severity: .critical)
        }
        switch signature(of: app.url) {
        case .invalid:
            return .init(group: "App", title: app.name, detail: L("簽章無效，App 可能被修改過或已損毀。\n%@", app.url.path), severity: .warning)
        case .unsigned, .adHoc:
            return .init(group: "App", title: app.name, detail: L("沒有開發者簽章，無法確認來源。\n%@", app.url.path), severity: .info)
        case .developerSigned, .missing:
            return nil
        }
    }

    public static func signature(of url: URL) -> SignatureStatus {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return .unsigned
        }
        // A full check, including resource files: slower, but a modified or missing resource is
        // exactly what this needs to catch, and it matches what `codesign --verify` reports.
        let status = SecStaticCodeCheckValidity(code, [], nil)
        if status == errSecCSUnsigned { return .unsigned }
        guard status == errSecSuccess else { return .invalid }

        var information: CFDictionary?
        let signingInformation = SecCSFlags(rawValue: 1 << 1)
        guard SecCodeCopySigningInformation(code, signingInformation, &information) == errSecSuccess,
              let info = information as? [String: Any] else { return .unsigned }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        return (flags & 0x2) != 0 ? .adHoc : .developerSigned
    }
}

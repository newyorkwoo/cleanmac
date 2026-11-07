import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case japanese = "ja"
    case english = "en"
    case korean = "ko"
    case latin = "la"

    public var id: String { rawValue }

    /// Each language is listed in its own script so it can be found from any current language.
    public var nativeName: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        case .japanese: return "日本語"
        case .english: return "English"
        case .korean: return "한국어"
        case .latin: return "Latina"
        }
    }

    public var locale: Locale { Locale(identifier: rawValue) }

    static let storageKey = "appLanguage"

    /// Read on every lookup, so it is kept in memory rather than fetched from defaults each time.
    nonisolated(unsafe) public static var current: AppLanguage = loadSaved() ?? preferred(from: Locale.preferredLanguages)

    public static func loadSaved(_ defaults: UserDefaults = .standard) -> AppLanguage? {
        defaults.string(forKey: storageKey).flatMap(AppLanguage.init(rawValue:))
    }

    /// Applies a choice. AppleLanguages makes system panels follow it from the next launch;
    /// macOS has no Latin resources, so those panels fall back to English for Latin.
    public static func select(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        current = language
        defaults.set(language.rawValue, forKey: storageKey)
        defaults.set(language == .latin ? ["la", "en"] : [language.rawValue], forKey: "AppleLanguages")
    }

    /// Maps the system's language list to a supported language, using English when none match.
    public static func preferred(from languages: [String]) -> AppLanguage {
        for tag in languages.map({ $0.lowercased() }) {
            if tag.hasPrefix("zh") {
                let simplified = tag.contains("hans") || tag.hasSuffix("-cn") || tag.hasSuffix("-sg")
                return simplified ? .simplifiedChinese : .traditionalChinese
            }
            for language in [AppLanguage.japanese, .english, .korean, .latin] {
                if tag == language.rawValue || tag.hasPrefix(language.rawValue + "-") { return language }
            }
        }
        return .english
    }
}

/// Translates UI text. The Traditional Chinese source string is the key, and %@ marks each value.
public func L(_ key: String, _ args: Any...) -> String {
    let format = translation(of: key, in: AppLanguage.current)
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args.map { "\($0)" as NSString })
}

public func translation(of key: String, in language: AppLanguage) -> String {
    let index: Int
    switch language {
    case .traditionalChinese: return key
    case .simplifiedChinese: index = 0
    case .japanese: index = 1
    case .english: index = 2
    case .korean: index = 3
    case .latin: index = 4
    }
    return translationTable[key]?[index] ?? key
}

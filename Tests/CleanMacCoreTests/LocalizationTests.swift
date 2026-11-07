import XCTest
@testable import CleanMacCore

/// Guards against text being left untranslated as the UI changes.
final class LocalizationTests: XCTestCase {
    private var sources: [URL] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        return files.compactMap { $0 as? URL }.filter {
            $0.pathExtension == "swift" && !["Translations.swift", "Localization.swift"].contains($0.lastPathComponent)
        }
    }

    /// Source literals exactly as written, then with escapes turned into the characters they stand for.
    private func unescape(_ literal: String) -> String {
        literal.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }

    func testEveryLookupHasATranslation() throws {
        var checked = 0
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in try matches(#"\bL\("((?:[^"\\]|\\.)*)""#, in: text) {
                checked += 1
                XCTAssertNotNil(translationTable[unescape(literal)], "\(file.lastPathComponent): \(literal)")
            }
        }
        XCTAssertGreaterThan(checked, 200)
    }

    func testNoUntranslatedTextOutsideLookups() throws {
        for file in sources {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for line in lines {
                // Blank out lookups (and junk category keys, translated at display time), then look for leftovers.
                var rest = line.replacingOccurrences(of: #"\bL\("(?:[^"\\]|\\.)*""#, with: "", options: .regularExpression)
                if file.lastPathComponent == "JunkScanner.swift", rest.contains("category(\"") || rest.contains("JunkCategory(id:") {
                    for key in try matches(#""((?:[^"\\]|\\.)*)""#, in: rest) where key.range(of: #"[\x{4E00}-\x{9FFF}]"#, options: .regularExpression) != nil {
                        XCTAssertNotNil(translationTable[unescape(key)], "junk category key: \(key)")
                    }
                    rest = ""
                }
                XCTAssertNil(rest.range(of: #"[\x{4E00}-\x{9FFF}]"#, options: .regularExpression), "\(file.lastPathComponent): \(line)")
            }
        }
    }

    func testEveryEntryIsCompleteAndKeepsItsPlaceholders() throws {
        for (key, values) in translationTable {
            XCTAssertEqual(values.count, 5, key)
            let expected = try matches(#"(%(?:\d\$)?@)"#, in: key).count
            for value in values {
                XCTAssertFalse(value.isEmpty, key)
                XCTAssertEqual(try matches(#"(%(?:\d\$)?@)"#, in: value).count, expected, "\(key) -> \(value)")
                XCTAssertEqual(value.contains("%%"), key.contains("%%"), "\(key) -> \(value)")
            }
        }
    }

    func testTranslationsAreActuallyInEachLanguage() throws {
        XCTAssertEqual(translation(of: "垃圾桶", in: .traditionalChinese), "垃圾桶")
        XCTAssertEqual(translation(of: "垃圾桶", in: .simplifiedChinese), "废纸篓")
        XCTAssertEqual(translation(of: "垃圾桶", in: .japanese), "ゴミ箱")
        XCTAssertEqual(translation(of: "垃圾桶", in: .english), "Trash")
        XCTAssertEqual(translation(of: "垃圾桶", in: .korean), "휴지통")
        XCTAssertEqual(translation(of: "垃圾桶", in: .latin), "Cista")
        for (key, values) in translationTable {
            for index in [2, 4] where values[index].range(of: #"[\x{4E00}-\x{9FFF}]"#, options: .regularExpression) != nil {
                XCTFail("Han characters in a Latin-script translation: \(key) -> \(values[index])")
            }
        }
    }

    func testFormattingUsesCurrentLanguage() {
        let saved = AppLanguage.current
        defer { AppLanguage.current = saved }
        AppLanguage.current = .english
        XCTAssertEqual(L("已選取 %@ 個項目，共 %@", 3, "1 GB"), "3 items selected, 1 GB in total")
        XCTAssertEqual(L("%@%%（壓力：%@）", 64, "Normal"), "64% (pressure: Normal)")
        AppLanguage.current = .korean
        XCTAssertEqual(L("%@ 個檔案，共 %@", 2, "5 MB"), "파일 2개, 총 5 MB")
        XCTAssertEqual(L("not in table"), "not in table")
    }

    func testChoosingLanguagePersists() throws {
        let suite = "cleanmac.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = AppLanguage.current
        defer { AppLanguage.current = saved }

        XCTAssertNil(AppLanguage.loadSaved(defaults))
        AppLanguage.select(.japanese, defaults: defaults)
        XCTAssertEqual(AppLanguage.loadSaved(defaults), .japanese)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ja"])
        AppLanguage.select(.latin, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["la", "en"], "system panels need a real fallback")
    }

    func testSystemLanguageDetection() {
        let cases: [(String, AppLanguage)] = [
            ("zh-Hant-TW", .traditionalChinese), ("zh-TW", .traditionalChinese), ("zh-HK", .traditionalChinese),
            ("zh-Hans-CN", .simplifiedChinese), ("zh-CN", .simplifiedChinese), ("ja-JP", .japanese),
            ("en-US", .english), ("ko-KR", .korean), ("fr-FR", .english),
        ]
        for (tag, expected) in cases { XCTAssertEqual(AppLanguage.preferred(from: [tag]), expected, tag) }
        XCTAssertEqual(AppLanguage.preferred(from: ["fr-FR", "ja-JP"]), .japanese, "skips unsupported languages")
    }
}

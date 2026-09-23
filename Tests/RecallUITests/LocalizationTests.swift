import Foundation
import Testing
import RecallIntelligence
@testable import RecallUI

/// Covers the string catalog the app ships its translations in.
///
/// Nothing at runtime notices a missing translation — the English shows through, and it
/// looks deliberate. A mismatched placeholder is worse: `%@` where the English has `%lld`
/// reads an integer as an object pointer and takes the app down, in one language only.
/// Both are cheap to rule out here and expensive to find any other way.
@Suite("Localization catalog")
struct LocalizationTests {
    static let languages = ["fa", "ru", "zh-Hans"]

    /// The parts of the catalog's format these tests look at.
    private struct Catalog: Decodable {
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        var shouldTranslate: Bool?
        var localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        struct Unit: Decodable { let state: String; let value: String }
        struct Form: Decodable { let stringUnit: Unit }
        struct Variations: Decodable { let plural: [String: Form]? }

        var stringUnit: Unit?
        var variations: Variations?

        /// The translated text, or each translated plural form keyed by category.
        var forms: [String: String] {
            if let stringUnit, stringUnit.state == "translated" { return ["": stringUnit.value] }
            return (variations?.plural ?? [:]).compactMapValues { form in
                form.stringUnit.state == "translated" ? form.stringUnit.value : nil
            }
        }
    }

    private static func loadCatalog() -> [String: Entry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [:] }
        return catalog.strings
    }

    private let entries = Self.loadCatalog()

    private func forms(_ entry: Entry, _ language: String) -> [String: String] {
        entry.localizations?[language]?.forms ?? [:]
    }

    /// The placeholders in a string, in argument order, positional or not.
    static func placeholders(in text: String) -> [String] {
        let pattern = /%(?:(\d+)\$)?(@|lld|d)/
        let matches = text.matches(of: pattern)
        let positional = matches.contains { $0.output.1 != nil }
        let numbered = matches.enumerated().map { index, match in
            (position: positional ? Int(match.output.1 ?? "") ?? 0 : index + 1, kind: String(match.output.2))
        }
        return numbered.sorted { $0.position < $1.position }.map { "\($0.position):\($0.kind)" }
    }

    @Test("The catalog is there and has strings in it")
    func catalogLoads() {
        #expect(entries.count > 300)
    }

    @Test("Every string is translated into every language", arguments: languages)
    func everythingIsTranslated(language: String) {
        let untranslated = entries
            .filter { $0.value.shouldTranslate != false && forms($0.value, language).isEmpty }
            .map(\.key)
        #expect(untranslated.isEmpty, "Not translated into \(language): \(untranslated.sorted())")
    }

    @Test("Translations keep the English placeholders", arguments: languages + ["en"])
    func placeholdersMatch(language: String) {
        for (key, entry) in entries where entry.shouldTranslate != false {
            let expected = Self.placeholders(in: key)
            for (form, text) in forms(entry, language) {
                #expect(
                    Self.placeholders(in: text) == expected,
                    "\(language)\(form.isEmpty ? "" : "/\(form)") of \(key.debugDescription): \(text.debugDescription)"
                )
            }
        }
    }

    @Test("Russian plurals have all four forms")
    func russianPluralsAreComplete() {
        for (key, entry) in entries {
            let russian = forms(entry, "ru")
            guard russian[""] == nil, !russian.isEmpty else { continue }
            #expect(Set(russian.keys) == ["one", "few", "many", "other"], "\(key.debugDescription) has \(russian.keys.sorted())")
        }
    }

    @Test("The placeholder reader handles both styles")
    func placeholderReader() {
        #expect(Self.placeholders(in: "%@ is already used by “%@”.") == ["1:@", "2:@"])
        #expect(Self.placeholders(in: "%2$@ از %1$lld") == ["1:lld", "2:@"])
        #expect(Self.placeholders(in: "No placeholders") == [])
    }

    @Test("Every translation target language has a code, so its name is shown localized")
    func translationLanguagesHaveCodes() {
        for language in ClipTransform.translationLanguages {
            #expect(TransformSheet.languageCodes[language] != nil, "\(language)")
        }
    }
}

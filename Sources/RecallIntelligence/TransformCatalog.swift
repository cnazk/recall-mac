import Foundation
import RecallCore

/// A "Paste as…" action: the clip is run through the on-device model before it lands in
/// the destination app. Bound to `Option + Return` in the history panel.
public struct ClipTransform: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let instructions: String
    /// Kinds this transform makes sense for.
    public let kinds: Set<ClipKind>
    /// True when the transform needs an argument from the user before it can run.
    public var needsArgument: Bool { id == "translate" }

    public init(id: String, title: String, systemImage: String, instructions: String, kinds: Set<ClipKind>) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.instructions = instructions
        self.kinds = kinds
    }
}

public extension ClipTransform {
    private static let textual: Set<ClipKind> = [.text, .richText, .url]

    static let markdownTable = ClipTransform(
        id: "markdown-table",
        title: String(localized: "Paste as Markdown Table"),
        systemImage: "tablecells",
        instructions: """
        Convert the user's text into a GitHub-flavoured Markdown table. \
        Infer the columns from the data. Reply with the table only, no commentary.
        """,
        kinds: textual
    )

    static let summarize = ClipTransform(
        id: "summarize",
        title: String(localized: "Paste Summarized"),
        systemImage: "text.redaction",
        instructions: """
        Summarise the user's text in at most three sentences, preserving names, \
        numbers and dates exactly. Reply with the summary only.
        """,
        kinds: textual
    )

    /// Languages offered by the translate transform's picker.
    static let translationLanguages = [
        "English", "Spanish", "French", "German", "Portuguese",
        "Italian", "Dutch", "Japanese", "Korean", "Chinese (Simplified)",
    ]

    static let translate = ClipTransform(
        id: "translate",
        title: String(localized: "Paste Translated"),
        systemImage: "character.bubble",
        instructions: """
        Translate the user's text into the requested language, preserving formatting, \
        code and proper nouns. Reply with the translation only.
        """,
        kinds: textual
    )

    static let asPython = ClipTransform(
        id: "as-python",
        title: String(localized: "Paste as Python"),
        systemImage: "chevron.left.forwardslash.chevron.right",
        instructions: """
        Rewrite the user's code or pseudocode as idiomatic Python. \
        Reply with code only, no fences and no explanation.
        """,
        kinds: textual
    )

    static let asJSON = ClipTransform(
        id: "as-json",
        title: String(localized: "Paste as JSON"),
        systemImage: "curlybraces",
        instructions: """
        Convert the user's text into valid, minimal JSON. Reply with JSON only.
        """,
        kinds: textual
    )

    static let plainProse = ClipTransform(
        id: "clean-up",
        title: String(localized: "Paste Cleaned Up"),
        systemImage: "wand.and.sparkles",
        instructions: """
        Fix broken line wrapping, hyphenation and spacing in the user's text without \
        changing its wording. Reply with the cleaned text only.
        """,
        kinds: textual
    )

    static let builtIn: [ClipTransform] = [
        .summarize, .markdownTable, .plainProse, .translate, .asJSON, .asPython,
    ]

    static func available(for kind: ClipKind) -> [ClipTransform] {
        builtIn.filter { $0.kinds.contains(kind) }
    }
}

/// Runs transforms and the background AI enrichments (summary, tags).
public struct IntelligenceService: Sendable {
    private let model: any LanguageModelProviding
    private let settings: RecallSettings

    public init(model: any LanguageModelProviding = LanguageModelFactory.makeDefault(), settings: RecallSettings = .default) {
        self.model = model
        self.settings = settings
    }

    public var isModelAvailable: Bool { model.isAvailable }

    /// Hard ceiling on what is handed to the model. Past this, a transform is not
    /// something the user is waiting on — it is a hang.
    public static let maximumInputCharacters = 8_000

    public func apply(_ transform: ClipTransform, to text: String, argument: String? = nil) async throws -> String {
        try await model.respond(to: prompt(for: text, argument: argument), instructions: transform.instructions)
    }

    /// Incremental output for the "Paste as…" sheet.
    public func stream(_ transform: ClipTransform, over text: String, argument: String? = nil) -> AsyncThrowingStream<String, any Error> {
        model.stream(prompt: prompt(for: text, argument: argument), instructions: transform.instructions)
    }

    private func prompt(for text: String, argument: String?) -> String {
        let clipped = String(text.prefix(Self.maximumInputCharacters))
        return argument.map { "\($0)\n\n\(clipped)" } ?? clipped
    }

    /// One-sentence preview for a long clip, so the history row says what it is.
    public func summarize(_ text: String) async throws -> String? {
        guard settings.summarizeLongText, text.count >= settings.summaryThreshold else { return nil }
        let summary = try await model.respond(
            to: String(text.prefix(4_000)),
            instructions: """
            Describe what this copied text is in one short sentence, under 90 characters. \
            Start with a noun phrase, not "This is". Reply with the sentence only.
            """
        )
        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tags used by Smart Collections.
    ///
    /// Still a fixed vocabulary, and still for the original reason: a model free to invent
    /// labels gives you "code" and "coding" and "source-code" for the same three clips, and
    /// a collection keyed on any of them matches a third of what it should. The list is
    /// much longer than it was, though — eight labels meant most clips came back with
    /// nothing that fitted, which reads as tagging being broken rather than as the clip
    /// being unremarkable.
    ///
    /// The first eight are the originals, spelled exactly as they were. ``SmartCollection``
    /// stores tags by string, so renaming one would quietly empty any collection a user had
    /// built on it. That is also why the plurals here are inconsistent: matching the
    /// existing entries beats tidiness.
    public static let tagVocabulary = [
        // The original eight. Do not rename — saved collections reference these.
        "code", "links", "receipts", "emails", "addresses", "credentials", "notes", "data",
        // Kinds of code and machine text.
        "sql", "shell", "json", "markup", "config", "logs", "errors", "paths",
        // Things with a shape.
        "numbers", "dates", "names", "phones", "prices", "math", "lists", "tables",
        // What it was for.
        "invoices", "orders", "tracking", "quotes", "tasks", "messages",
        "documentation", "prose", "translations", "events",
    ]

    /// Every label that applies, not a sample of them.
    ///
    /// The instruction used to end "at most two", which was never enforced anywhere — the
    /// cap existed only as a sentence in a prompt, and the row then cut whatever survived
    /// to the first two alphabetically. Both are gone: a clip that is genuinely an invoice
    /// *and* a receipt *and* dated should say so, because every one of those is a
    /// collection someone might have built.
    ///
    /// What still bounds the result is the intersection with the vocabulary, which is the
    /// only guard worth keeping — it drops anything invented, so the tag space cannot
    /// grow without an edit to this file.
    public func tags(for text: String) async throws -> Set<String> {
        guard settings.autoTaggingEnabled else { return [] }
        let response = try await model.respond(
            to: String(text.prefix(2_000)),
            instructions: """
            Label the copied text using only these labels: \
            \(Self.tagVocabulary.joined(separator: ", ")). \
            List every label that clearly applies, as a comma-separated list, or "none". \
            Do not include a label that only loosely fits, and do not invent labels.
            """
        )
        return Self.parseTags(from: response)
    }

    /// Reads labels out of whatever shape the reply arrives in.
    ///
    /// Two passes, unioned, because a small model asked for a comma-separated list will
    /// sometimes give you a sentence, a numbered list, or bullets instead. The entry pass
    /// is what allows a label to contain a space; the word pass is what rescues
    /// "code and links" and "1. json". Prose around the labels is harmless: only exact
    /// vocabulary matches survive, and the vocabulary has no articles or verbs in it.
    static func parseTags(from response: String) -> Set<String> {
        let lowered = response.lowercased()

        let entries = lowered
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }

        let words = lowered
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)

        return Set(entries).union(words).intersection(tagVocabulary)
    }
}

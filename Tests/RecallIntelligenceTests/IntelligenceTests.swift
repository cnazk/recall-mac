import Foundation
import Testing
@testable import RecallCore
@testable import RecallIntelligence

@Suite("Vector maths")
struct VectorTests {
    @Test("Normalisation produces a unit vector")
    func normalises() {
        let unit = Vector.normalized([3, 4])
        #expect(abs(unit[0] - 0.6) < 0.0001)
        #expect(abs(unit[1] - 0.8) < 0.0001)
    }

    @Test("Identical vectors are maximally similar")
    func similarityBounds() {
        let a = Vector.normalized([1, 2, 3])
        #expect(abs(Vector.similarity(a, a) - 1.0) < 0.0001)

        let orthogonal = Vector.normalized([0, 1])
        #expect(abs(Vector.similarity(Vector.normalized([1, 0]), orthogonal)) < 0.0001)
    }

    @Test("Mismatched dimensions score zero rather than crashing")
    func guardsAgainstMismatch() {
        #expect(Vector.similarity([1, 0], [1, 0, 0]) == 0)
    }

    @Test("A zero vector normalises to itself")
    func handlesZero() {
        #expect(Vector.normalized([0, 0]) == [0, 0])
    }
}

@Suite("Transform catalog")
struct TransformCatalogTests {
    @Test("Text clips offer transforms; images do not")
    func filtersByKind() {
        #expect(!ClipTransform.available(for: .text).isEmpty)
        #expect(ClipTransform.available(for: .image).isEmpty)
    }

    @Test("Transform identifiers are unique")
    func uniqueIdentifiers() {
        let ids = ClipTransform.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

/// A scripted model, so the AI plumbing is testable without Apple Intelligence.
private struct StubModel: LanguageModelProviding {
    let response: String
    var isAvailable: Bool { true }
    func respond(to prompt: String, instructions: String) async throws -> String { response }
}

@Suite("Intelligence service")
struct IntelligenceServiceTests {
    @Test("Tags are constrained to the known vocabulary")
    func filtersTagVocabulary() async throws {
        let service = IntelligenceService(model: StubModel(response: "code, links, nonsense"))
        let tags = try await service.tags(for: "let x = 1")
        #expect(tags == ["code", "links"])
    }

    /// The old instruction said "at most two" and nothing enforced it. Now nothing asks
    /// for it either, and a clip that is honestly five things comes back as five.
    @Test("Every label that applies is kept, not the first two")
    func keepsEveryApplicableTag() async throws {
        let service = IntelligenceService(
            model: StubModel(response: "invoices, receipts, prices, dates, addresses")
        )
        let tags = try await service.tags(for: "Invoice 4021 — $30.00 — 12 May — 4 Privet Drive")
        #expect(tags == ["invoices", "receipts", "prices", "dates", "addresses"])
    }

    /// The vocabulary is the only thing bounding the result, so it has to be worth
    /// something. Eight labels left most clips with nothing that fitted.
    @Test("The vocabulary is wide enough to describe an ordinary clipboard")
    func vocabularyIsWide() {
        #expect(IntelligenceService.tagVocabulary.count > 20)
        #expect(Set(IntelligenceService.tagVocabulary).count == IntelligenceService.tagVocabulary.count)
    }

    /// Saved collections reference tags by string, so dropping or renaming one of the
    /// original labels would silently empty a collection the user built.
    @Test("The labels the built-in collections rely on are all still in the vocabulary")
    func keepsCollectionTags() {
        let vocabulary = Set(IntelligenceService.tagVocabulary)
        for collection in SmartCollection.builtIn {
            #expect(collection.tags.isSubset(of: vocabulary), "\(collection.name) is unreachable")
        }
    }

    @Test("Labels are read out of a reply that is not a clean list", arguments: [
        "code and links",
        "1. code\n2. links",
        "The applicable labels are: code, links.",
        "code;links",
        "CODE, LINKS",
    ])
    func parsesUntidyReplies(response: String) {
        #expect(IntelligenceService.parseTags(from: response) == ["code", "links"])
    }

    @Test("Nothing applicable stays nothing")
    func parsesNone() {
        #expect(IntelligenceService.parseTags(from: "none").isEmpty)
    }

    @Test("Auto-tagging off means no tags at all")
    func respectsTheSetting() async throws {
        var settings = RecallSettings.default
        settings.autoTaggingEnabled = false
        let service = IntelligenceService(model: StubModel(response: "code, links"), settings: settings)
        #expect(try await service.tags(for: "let x = 1").isEmpty)
    }

    @Test("Short clips are not summarised")
    func skipsShortText() async throws {
        let service = IntelligenceService(model: StubModel(response: "A summary."))
        #expect(try await service.summarize("short") == nil)
    }

    @Test("Long clips get a one-line summary")
    func summarisesLongText() async throws {
        let service = IntelligenceService(model: StubModel(response: "  A long article about ducks.  "))
        let summary = try await service.summarize(String(repeating: "a", count: 1_000))
        #expect(summary == "A long article about ducks.")
    }

    @Test("Features are hidden when no model is available")
    func degradesWithoutModel() async {
        let service = IntelligenceService(model: UnavailableLanguageModel())
        #expect(!service.isModelAvailable)
        await #expect(throws: LanguageModelUnavailable.self) {
            try await service.apply(.summarize, to: "anything")
        }
    }
}

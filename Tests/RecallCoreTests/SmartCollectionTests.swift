import Foundation
import Testing
@testable import RecallCore

@Suite("Smart collections")
struct SmartCollectionTests {
    @Test("A collection becomes the query it stands for")
    func buildsQuery() {
        let collection = SmartCollection(
            name: "Work code",
            systemImage: "folder",
            tags: ["code"],
            kinds: [.text],
            textContains: "func",
            sourceApp: "Xcode"
        )

        let query = collection.query()
        #expect(query.tags == ["code"])
        #expect(query.kinds == [.text])
        #expect(query.text == "func")
        #expect(query.sourceApp == "Xcode")
    }

    @Test("The built-in Pinned collection filters to pins")
    func pinnedCollection() {
        #expect(SmartCollection.pinned.query().pinnedOnly)
        #expect(SmartCollection.pinned.isWellFormed)
    }

    @Test("A collection with no conditions is rejected rather than matching everything")
    func rejectsEmptyCollections() {
        let empty = SmartCollection(name: "Everything", systemImage: "folder")
        #expect(!empty.isWellFormed)
    }

    @Test("Built-in collections all have conditions")
    func builtInsAreWellFormed() {
        let wellFormed = SmartCollection.builtIn.allSatisfy(\.isWellFormed)
        #expect(wellFormed)
    }

    @Test("Collections saved before a field existed still decode")
    func decodesOlderShape() throws {
        // The shape written before `pinnedOnly` and `isEnabled` were added.
        let json = Data("""
        {"id":"0000A11E-0000-4000-8000-000000000009","name":"Receipts","systemImage":"receipt","tags":["receipts"],"kinds":[]}
        """.utf8)

        let decoded = try JSONDecoder().decode(SmartCollection.self, from: json)
        #expect(decoded.name == "Receipts")
        #expect(decoded.tags == ["receipts"])
        #expect(decoded.isEnabled, "a missing flag must not hide the collection")
        #expect(!decoded.pinnedOnly)
    }

    @Test("Settings saved before collections existed still load, with the built-ins")
    func settingsSurviveNewFields() throws {
        let json = Data("""
        {"storageMode":"persistent","historyLimit":500,"secretTimeToLive":60,
         "normalizeWhitespace":true,"enrichLinks":false,"ocrImages":true,
         "semanticSearchEnabled":true,"summarizeLongText":true,"autoTaggingEnabled":true,
         "activation":"hotkeyOnly","screenEdge":"left","userExcludedBundleIDs":["com.example.app"],
         "summaryThreshold":600}
        """.utf8)

        let decoded = try JSONDecoder().decode(RecallSettings.self, from: json)
        #expect(decoded.historyLimit == 500, "existing preferences must survive")
        #expect(decoded.enrichLinks == false)
        #expect(decoded.userExcludedBundleIDs == ["com.example.app"])
        #expect(decoded.collections == SmartCollection.builtIn, "a new field falls back to its default")
        #expect(decoded.retention == nil)
    }
}

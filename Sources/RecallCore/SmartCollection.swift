import Foundation

/// A saved view over history.
///
/// Built-in collections are backed by the AI's auto-tags; user-defined ones add their own
/// conditions. They are stored in settings rather than the database because a collection
/// describes a *question*, not data — and because they should survive "clear history".
public struct SmartCollection: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var systemImage: String
    /// Any of these tags puts an item in the collection.
    public var tags: Set<String>
    public var kinds: Set<ClipKind>
    /// Free text the item must match.
    public var textContains: String?
    /// App the item must have been copied from.
    public var sourceApp: String?
    /// Restricts the collection to pinned items.
    public var pinnedOnly: Bool
    /// False hides it from the sidebar without deleting it.
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        systemImage: String,
        tags: Set<String> = [],
        kinds: Set<ClipKind> = [],
        textContains: String? = nil,
        sourceApp: String? = nil,
        pinnedOnly: Bool = false,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.systemImage = systemImage
        self.tags = tags
        self.kinds = kinds
        self.textContains = textContains
        self.sourceApp = sourceApp
        self.pinnedOnly = pinnedOnly
        self.isEnabled = isEnabled
    }

    /// The query this collection stands for.
    public func query(base: HistoryQuery = .recent) -> HistoryQuery {
        var query = base
        if !tags.isEmpty { query.tags = tags }
        if !kinds.isEmpty { query.kinds = kinds }
        if let textContains, !textContains.isEmpty { query.text = textContains }
        if let sourceApp, !sourceApp.isEmpty { query.sourceApp = sourceApp }
        if pinnedOnly { query.pinnedOnly = true }
        return query
    }

    /// The name to show. The built-in collections are named in the user's language;
    /// a collection the user named keeps exactly what they typed.
    ///
    /// Matched on the stored English name rather than stored translated, so switching the
    /// Mac's language renames them too, and a user's own "Links" is not second-guessed —
    /// it is shown translated, which is what they would have typed anyway.
    public var displayName: String {
        switch name {
        case "Pinned": String(localized: "Pinned")
        case "Code": String(localized: "Code", comment: "A collection of copied source code")
        case "Links": String(localized: "Links")
        case "Receipts": String(localized: "Receipts")
        case "Emails": String(localized: "Emails")
        case "Images": String(localized: "Images")
        default: name
        }
    }

    /// A collection with no conditions matches everything, which is never what the user
    /// meant and would quietly look like a bug.
    public var isWellFormed: Bool {
        pinnedOnly || !tags.isEmpty || !kinds.isEmpty || !(textContains ?? "").isEmpty || !(sourceApp ?? "").isEmpty
    }

    /// The built-in "Pinned" view. Fixed id so the sidebar selection is stable.
    public static let pinned = SmartCollection(
        id: UUID(uuidString: "0000A11E-0000-4000-8000-000000000001")!,
        name: "Pinned",
        systemImage: "pin",
        pinnedOnly: true
    )

    /// The collections every install starts with.
    ///
    /// A handful of the auto-tag vocabulary, not all of it: a fresh install with one folder
    /// per label would be a filter menu nobody reads. The rest of the vocabulary is still
    /// tagged and still shows on the row — build a collection on any of it in Settings.
    public static let builtIn: [SmartCollection] = [
        SmartCollection(name: "Code", systemImage: "chevron.left.forwardslash.chevron.right", tags: ["code"]),
        SmartCollection(name: "Links", systemImage: "link", tags: ["links"], kinds: [.url]),
        SmartCollection(name: "Receipts", systemImage: "receipt", tags: ["receipts"]),
        SmartCollection(name: "Emails", systemImage: "envelope", tags: ["emails"]),
        SmartCollection(name: "Images", systemImage: "photo", kinds: [.image]),
    ]
}

public extension SmartCollection {
    /// Tolerant decoding, for the same reason as ``RecallSettings``: one added field must
    /// not cost the user their saved collections.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decode(String.self, forKey: .name),
            systemImage: try container.decodeIfPresent(String.self, forKey: .systemImage) ?? "folder",
            tags: try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? [],
            kinds: try container.decodeIfPresent(Set<ClipKind>.self, forKey: .kinds) ?? [],
            textContains: try container.decodeIfPresent(String.self, forKey: .textContains),
            sourceApp: try container.decodeIfPresent(String.self, forKey: .sourceApp),
            pinnedOnly: try container.decodeIfPresent(Bool.self, forKey: .pinnedOnly) ?? false,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        )
    }
}

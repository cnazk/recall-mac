import Foundation

/// One entry in the Todos tab.
///
/// A todo carries its own text rather than pointing at a clip for it. History is
/// transient by design — retention, the item limit and secret expiry all delete clips on
/// their own — and a todo that went blank because the clip it came from aged out would
/// be a todo lost without anyone deciding to lose it. ``sourceItemID`` is the way back to
/// that clip while it still exists, and nothing more.
public struct TodoItem: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var title: String
    public var createdAt: Date
    /// When it was ticked off; `nil` while it is still to do.
    public var completedAt: Date?
    /// Position among the open todos. Sparse, like pin ordinals, so moving one rewrites
    /// one row. Only ever compared, never displayed.
    public var order: Int
    /// The clip this todo was made from, if any.
    public var sourceItemID: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        completedAt: Date? = nil,
        order: Int = 0,
        sourceItemID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.order = order
        self.sourceItemID = sourceItemID
    }

    public var isDone: Bool { completedAt != nil }

    /// Gap between adjacent todos' ordinals.
    public static let orderSpacing = 1_000

    /// The longest title a todo is given from a clip. The clip itself stays linked, so
    /// nothing is lost by cutting the title short — and a 2,000-line log is not a todo.
    public static let maximumTitleLength = 200

    /// The order the list is shown in: open todos in the order the user put them, then
    /// finished ones, most recently finished first.
    public static func displayOrder(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        switch (lhs.completedAt, rhs.completedAt) {
        case (nil, nil):
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.createdAt > rhs.createdAt
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (let left?, let right?):
            return left > right
        }
    }

    /// A title for a todo made from `text`: whitespace folded to single spaces, then cut
    /// to ``maximumTitleLength``. `nil` when nothing is left to make a title of.
    public static func title(from text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !folded.isEmpty else { return nil }
        guard folded.count > maximumTitleLength else { return folded }
        return String(folded.prefix(maximumTitleLength - 1)) + "…"
    }
}

public extension TodoItem {
    /// Tolerant decoding, for the same reason as ``ClipItem``'s: a row sealed before a
    /// field existed must still open.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast,
            completedAt: try container.decodeIfPresent(Date.self, forKey: .completedAt),
            order: try container.decodeIfPresent(Int.self, forKey: .order) ?? 0,
            sourceItemID: try container.decodeIfPresent(UUID.self, forKey: .sourceItemID)
        )
    }
}

import Foundation

/// Parses search operators out of what the user typed.
///
/// `kind:image app:Xcode since:yesterday rounding` narrows to images copied from Xcode
/// since yesterday, matching "rounding". Anything that is not a recognised operator stays
/// part of the free text, so typing a colon in an ordinary search never swallows words.
public struct QueryParser: Sendable {
    public init() {}

    public struct Parsed: Sendable, Equatable {
        public var text: String?
        public var kinds: Set<ClipKind>?
        public var sourceApp: String?
        public var since: Date?
        public var pinnedOnly: Bool

        public func applied(to base: HistoryQuery = .recent) -> HistoryQuery {
            var query = base
            query.text = text
            query.kinds = kinds
            query.sourceApp = sourceApp
            query.since = since
            query.pinnedOnly = pinnedOnly || base.pinnedOnly
            return query
        }
    }

    public func parse(_ input: String, now: Date = .now, calendar: Calendar = .current) -> Parsed {
        var kinds: Set<ClipKind> = []
        var sourceApp: String?
        var since: Date?
        var pinnedOnly = false
        var words: [String] = []

        for token in input.split(separator: " ", omittingEmptySubsequences: true) {
            let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else {
                words.append(String(token))
                continue
            }

            let name = parts[0].lowercased()
            let value = String(parts[1])

            switch name {
            case "kind", "type":
                if let kind = Self.kind(named: value) {
                    kinds.insert(kind)
                } else {
                    words.append(String(token))
                }
            case "app", "from":
                sourceApp = value
            case "since":
                if let date = Self.date(named: value, now: now, calendar: calendar) {
                    since = date
                } else {
                    words.append(String(token))
                }
            case "is":
                if value.lowercased() == "pinned" {
                    pinnedOnly = true
                } else {
                    words.append(String(token))
                }
            default:
                words.append(String(token))
            }
        }

        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Parsed(
            text: text.isEmpty ? nil : text,
            kinds: kinds.isEmpty ? nil : kinds,
            sourceApp: sourceApp,
            since: since,
            pinnedOnly: pinnedOnly
        )
    }

    /// Accepts both the singular and the plural of each kind, because users type both.
    static func kind(named value: String) -> ClipKind? {
        switch value.lowercased() {
        case "text", "texts": .text
        case "rich", "richtext", "formatted": .richText
        case "image", "images", "img", "screenshot", "screenshots": .image
        case "file", "files": .file
        case "url", "urls", "link", "links": .url
        case "color", "colors", "colour", "colours": .color
        default: nil
        }
    }

    static func date(named value: String, now: Date, calendar: Calendar) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        switch value.lowercased() {
        case "today": return startOfToday
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: startOfToday)
        case "week", "thisweek": return calendar.date(byAdding: .day, value: -7, to: startOfToday)
        case "month", "thismonth": return calendar.date(byAdding: .month, value: -1, to: startOfToday)
        case "hour": return now.addingTimeInterval(-3_600)
        default:
            // An explicit ISO date, for anyone who wants one.
            return try? Date(value, strategy: .iso8601.year().month().day())
        }
    }
}

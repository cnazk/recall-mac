import Foundation

/// The native shape of a captured clipboard item.
///
/// The kind is decided once, at capture time, by ``ClipPayload`` classification and is
/// what the UI uses to pick a renderer and what search uses to scope a query.
public enum ClipKind: String, Codable, Sendable, CaseIterable {
    case text
    case richText
    case image
    case file
    case url
    case color
}

/// A 6- or 8-digit hex colour recognised inside otherwise plain text.
public struct HexColor: Codable, Sendable, Hashable {
    public let raw: String
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(raw: String, red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.raw = raw
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Parses `#RGB`, `#RRGGBB` and `#RRGGBBAA` (the leading `#` is optional).
    public init?(parsing string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.allSatisfy(\.isHexDigit) else { return nil }

        let expanded: String
        switch text.count {
        case 3: expanded = text.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = text
        default: return nil
        }

        func channel(_ offset: Int) -> Double {
            let start = expanded.index(expanded.startIndex, offsetBy: offset * 2)
            let end = expanded.index(start, offsetBy: 2)
            return Double(UInt8(expanded[start..<end], radix: 16) ?? 0) / 255
        }

        self.init(
            raw: "#" + expanded,
            red: channel(0),
            green: channel(1),
            blue: channel(2),
            alpha: expanded.count == 8 ? channel(3) : 1
        )
    }
}

/// An image captured from the pasteboard.
///
/// `data` holds the original bytes so we never re-encode (and never lose) what was
/// copied. Large images are moved out to the blob store: `data` is then empty, `blobID`
/// points at the file, and `thumbnail` keeps the history row renderable without reading
/// megabytes back off the disk for every row on screen.
public struct ImagePayload: Codable, Sendable, Hashable {
    public let data: Data
    /// A small inline preview, kept even when the full bytes are offloaded.
    public let thumbnail: Data?
    /// Set once the full bytes live in the blob store.
    public let blobID: String?
    public let uti: String
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        data: Data,
        thumbnail: Data? = nil,
        blobID: String? = nil,
        uti: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.data = data
        self.thumbnail = thumbnail
        self.blobID = blobID
        self.uti = uti
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// True when the full bytes are on disk rather than in this value.
    public var isOffloaded: Bool { blobID != nil && data.isEmpty }

    /// The bytes a view should render: the thumbnail if there is one, else the original.
    public var previewData: Data? {
        if let thumbnail { return thumbnail }
        return data.isEmpty ? nil : data
    }

    /// A copy with the full bytes dropped, once they are safely in the blob store.
    public func offloaded(blobID: String) -> ImagePayload {
        ImagePayload(
            data: Data(),
            thumbnail: thumbnail,
            blobID: blobID,
            uti: uti,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    /// A copy with the full bytes restored from the blob store.
    public func hydrated(with data: Data) -> ImagePayload {
        ImagePayload(
            data: data,
            thumbnail: thumbnail,
            blobID: blobID,
            uti: uti,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}

/// A file or folder reference captured from the pasteboard.
public struct FileReference: Codable, Sendable, Hashable {
    public let url: URL
    public let byteSize: Int64?
    public let isDirectory: Bool

    public init(url: URL, byteSize: Int64? = nil, isDirectory: Bool = false) {
        self.url = url
        self.byteSize = byteSize
        self.isDirectory = isDirectory
    }
}

/// The captured content itself, kept separate from ``ClipItem`` metadata so that large
/// payloads can be loaded lazily and dropped from memory independently of the row.
public enum ClipPayload: Codable, Sendable, Hashable {
    case text(String)
    /// Rich text keeps the RTF bytes *and* the flattened plain text, so "paste as plain
    /// text" and search never have to re-parse the RTF.
    case richText(rtf: Data, plain: String)
    case image(ImagePayload)
    case files([FileReference])
    case url(URL)
    case color(HexColor)

    public var kind: ClipKind {
        switch self {
        case .text: .text
        case .richText: .richText
        case .image: .image
        case .files: .file
        case .url: .url
        case .color: .color
        }
    }

    /// The text a query should match against, if this payload has any.
    public var searchableText: String? {
        switch self {
        case .text(let value): value
        case .richText(_, let plain): plain
        case .url(let url): url.absoluteString
        case .color(let color): color.raw
        case .files(let refs): refs.map { $0.url.path }.joined(separator: "\n")
        case .image: nil
        }
    }
}

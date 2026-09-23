import Foundation
import RecallCore
import UniformTypeIdentifiers

/// What Quick Look should do with an item, decided before any file is touched.
///
/// Separated from the panel machinery so the interesting part — *what gets written to
/// disk, and whether anything is written at all* — can be tested without a running app.
public enum QuickLookPlan: Equatable, Sendable {
    /// Preview a file that already exists. Nothing is written.
    case existingFile(URL)
    /// Write the payload to a temporary file with this name, then preview it.
    case temporaryFile(name: String, contentType: String)
    /// Refuse. Sensitive items are not previewed in the clear, here or anywhere else.
    case refused

    public static func plan(for item: ClipItem) -> QuickLookPlan {
        guard item.sensitivity != .secret else { return .refused }

        switch item.payload {
        case .files(let refs):
            guard let url = refs.first?.url else { return .refused }
            return .existingFile(url)

        case .image(let image):
            let type = UTType(image.uti) ?? .png
            return .temporaryFile(
                name: "\(safeName(item)).\(type.preferredFilenameExtension ?? "png")",
                contentType: type.identifier
            )

        case .richText:
            return .temporaryFile(name: "\(safeName(item)).rtf", contentType: UTType.rtf.identifier)

        case .text, .url, .color:
            return .temporaryFile(name: "\(safeName(item)).txt", contentType: UTType.plainText.identifier)
        }
    }

    /// A filename Quick Look will show in its title bar, derived from the content but
    /// stripped of anything that could escape the directory it is written into.
    static func safeName(_ item: ClipItem) -> String {
        let base = item.railTitle
            .components(separatedBy: .newlines).first ?? String(localized: "Clipping", comment: "File name for a clip previewed in Quick Look")
        let cleaned = base
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let trimmed = String(cleaned.prefix(40)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "Clipping", comment: "File name for a clip previewed in Quick Look") : trimmed
    }
}

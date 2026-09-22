import AppKit
import Foundation
import RecallCore
import UniformTypeIdentifiers

/// Reads the pasteboard into a ``PasteboardSnapshot``.
public struct PasteboardReader: Sendable {
    /// Images above this size are still captured, but the plan is to move them to a
    /// content-addressed file store rather than inline them in the database.
    public static let inlineImageByteLimit = 8 * 1024 * 1024

    public init() {}

    public func snapshot(of pasteboard: NSPasteboard, changeCount: Int) -> PasteboardSnapshot {
        let types = (pasteboard.types ?? []).map(\.rawValue)

        var snapshot = PasteboardSnapshot(
            changeCount: changeCount,
            types: types,
            source: SourceAppResolver.current()
        )

        // Bail out early on concealed content: don't even read the bytes.
        let concealed = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        if types.contains(where: concealed.contains) {
            return snapshot
        }

        snapshot.plainText = pasteboard.string(forType: .string)
        snapshot.rtf = pasteboard.data(forType: .rtf)

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            snapshot.files = urls.map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                return FileReference(
                    url: url,
                    byteSize: values?.fileSize.map(Int64.init),
                    isDirectory: values?.isDirectory ?? false
                )
            }
        }

        snapshot.image = readImage(from: pasteboard)
        return snapshot
    }

    private func readImage(from pasteboard: NSPasteboard) -> ImagePayload? {
        let candidates: [(NSPasteboard.PasteboardType, String)] = [
            (.png, UTType.png.identifier),
            (.tiff, UTType.tiff.identifier),
        ]
        for (type, uti) in candidates {
            guard let data = pasteboard.data(forType: type), !data.isEmpty else { continue }
            let rep = NSBitmapImageRep(data: data)
            return ImagePayload(
                data: data,
                thumbnail: Self.thumbnail(from: rep),
                uti: uti,
                pixelWidth: rep?.pixelsWide ?? 0,
                pixelHeight: rep?.pixelsHigh ?? 0
            )
        }
        return nil
    }

    /// Longest side of a history-row thumbnail, in pixels.
    static let thumbnailPixelSize = 256

    /// Builds the small preview that stays inline when the full image is offloaded.
    ///
    /// Done at capture because this is the one moment the bitmap is already decoded; it
    /// costs a couple of milliseconds and saves reading a multi-megabyte file back off
    /// the disk every time the panel opens.
    static func thumbnail(from source: NSBitmapImageRep?) -> Data? {
        guard let source else { return nil }
        let longest = max(source.pixelsWide, source.pixelsHigh)
        guard longest > thumbnailPixelSize else { return nil }

        let scale = Double(thumbnailPixelSize) / Double(longest)
        let width = max(Int((Double(source.pixelsWide) * scale).rounded()), 1)
        let height = max(Int((Double(source.pixelsHigh) * scale).rounded()), 1)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ), let cgImage = source.cgImage else { return nil }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }
}

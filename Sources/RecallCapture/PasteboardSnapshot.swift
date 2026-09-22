import Foundation
import RecallCore

/// One reading of the system pasteboard, decoupled from AppKit so that the capture
/// pipeline can be exercised in tests without a running app.
public struct PasteboardSnapshot: Sendable {
    public var changeCount: Int
    public var types: [String]
    public var plainText: String?
    public var rtf: Data?
    public var image: ImagePayload?
    public var files: [FileReference]
    public var source: SourceApp?

    public init(
        changeCount: Int,
        types: [String] = [],
        plainText: String? = nil,
        rtf: Data? = nil,
        image: ImagePayload? = nil,
        files: [FileReference] = [],
        source: SourceApp? = nil
    ) {
        self.changeCount = changeCount
        self.types = types
        self.plainText = plainText
        self.rtf = rtf
        self.image = image
        self.files = files
        self.source = source
    }
}

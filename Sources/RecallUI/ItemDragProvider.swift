import AppKit
import RecallCore
import SwiftUI
import UniformTypeIdentifiers

/// Makes a history row draggable into other apps.
///
/// Images are the interesting case: list rows are not hydrated, so the full bytes may be
/// a sealed blob on disk. The provider promises the data and loads it when the drop
/// actually happens, which keeps opening the panel cheap.
struct ItemDragProvider: ViewModifier {
    let item: ClipItem
    let model: AppModel

    func body(content: Content) -> some View {
        content.onDrag {
            // Dragging a clip out is the same intent as pasting one: you are done with
            // the panel. It does not close by itself, because a drag never moves key
            // away from it — the pointer leaves, the keyboard focus does not — so the
            // panel sat there over the app the clip had just been dropped into.
            //
            // Not immediately, though. The drag session has to take ownership of the
            // pointer before the source window goes away; pulling the window out from
            // under a session that has not started yet can cancel the drag outright.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                model.dismissPanel?()
            }

            // A sensitive value must not be draggable in the clear, any more than it is
            // shown in the clear.
            guard item.sensitivity != .secret else {
                return NSItemProvider(object: NSString(string: String(localized: "Sensitive value")))
            }

            switch item.payload {
            case .files(let refs):
                guard let url = refs.first?.url else { break }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)

            case .url(let url):
                return NSItemProvider(object: url as NSURL)

            case .image(let image):
                return Self.imageProvider(for: item, image: image, model: model)

            case .text(let text), .richText(_, let text):
                return NSItemProvider(object: NSString(string: text))

            case .color(let color):
                return NSItemProvider(object: NSString(string: color.raw))
            }

            return NSItemProvider(object: NSString(string: item.railTitle))
        }
    }

    /// Registers the image as a promise, resolved from the blob store on drop.
    private static func imageProvider(for item: ClipItem, image: ImagePayload, model: AppModel) -> NSItemProvider {
        let provider = NSItemProvider()
        let type = image.uti == UTType.png.identifier ? UTType.png : UTType.tiff

        provider.registerDataRepresentation(for: type) { completion in
            // The completion is not `Sendable`, but the system calls it once; the box
            // carries it to the main actor where the store can be asked for the bytes.
            let completion = UncheckedSendableBox(completion)
            let thumbnail = image.previewData

            Task { @MainActor in
                let full = await model.hydratedPayloadData(for: item) ?? thumbnail
                completion.value(full, nil)
            }
            return nil
        }
        provider.suggestedName = "\(item.railTitle).\(type.preferredFilenameExtension ?? "png")"
        return provider
    }
}

extension View {
    /// Lets an item be dragged out of Recall and dropped into another app.
    func itemDragProvider(_ item: ClipItem, model: AppModel) -> some View {
        modifier(ItemDragProvider(item: item, model: model))
    }
}

/// Carries a non-`Sendable` system callback across an actor hop.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

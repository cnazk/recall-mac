import AppKit
import QuickLookUI
import RecallCore
import SwiftUI

/// Drives the system Quick Look panel.
///
/// Files preview where they already are. Everything else has to be written somewhere
/// Quick Look can read it — which is a hole straight through encryption at rest unless
/// the temporary copy is short-lived and locked down. So: a private directory at `0700`,
/// files at `0600`, and every one of them deleted the moment the panel closes, when the
/// next preview replaces it, and at quit.
@MainActor
public final class QuickLookPresenter: NSObject {
    public static let shared = QuickLookPresenter()

    private var currentURL: URL?
    /// Set when the URL belongs to us and must be cleaned up; a user's own file must not.
    private var currentIsTemporary = false

    private override init() {
        super.init()
    }

    /// Prepares and shows a preview. Silently does nothing for an item that must not be
    /// previewed, which is the correct amount of ceremony for pressing space on a secret.
    public func preview(_ item: ClipItem, using model: AppModel) async {
        let plan = QuickLookPlan.plan(for: item)

        switch plan {
        case .refused:
            NSSound.beep()
            return

        case .existingFile(let url):
            discardTemporaryFile()
            currentURL = url
            currentIsTemporary = false

        case .temporaryFile(let name, _):
            guard let data = await model.hydratedPayloadData(for: item) else { return }
            discardTemporaryFile()
            guard let url = writeTemporaryFile(named: name, data: data) else { return }
            currentURL = url
            currentIsTemporary = true
        }

        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    public func toggle(_ item: ClipItem, using model: AppModel) async {
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
            return
        }
        await preview(item, using: model)
    }

    /// Called when the panel goes away.
    public func panelDidClose() {
        discardTemporaryFile()
    }

    // MARK: - Temporary files

    private func writeTemporaryFile(named name: String, data: Data) -> URL? {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("recall-quicklook-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            Log.ui.error("Quick Look could not stage a preview: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func discardTemporaryFile() {
        defer {
            currentURL = nil
            currentIsTemporary = false
        }
        guard currentIsTemporary, let url = currentURL else { return }
        // The whole directory, so nothing of ours is left behind.
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// `@preconcurrency`: Quick Look's data source and delegate are not annotated for
// concurrency, but the panel only ever calls them on the main thread.
extension QuickLookPresenter: @preconcurrency QLPreviewPanelDataSource {
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL == nil ? 0 : 1
    }

    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        currentURL as (any QLPreviewItem)?
    }
}

extension QuickLookPresenter: @preconcurrency QLPreviewPanelDelegate {
    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Space and Escape close the panel, as they do in Finder.
        guard event.type == .keyDown else { return false }
        if event.keyCode == 49 || event.keyCode == 53 {
            panel.orderOut(nil)
            return true
        }
        return false
    }
}

/// Hosting view that hands control of the Quick Look panel to the presenter.
///
/// `QLPreviewPanel` asks the responder chain who owns it; a plain `NSHostingView` answers
/// no, and the panel opens empty. This is the smallest object that can answer yes.
final class QuickLookHostingView<Content: View>: NSHostingView<Content> {
    /// Act on the first click, rather than spending it on focus.
    ///
    /// Recall's windows are non-activating panels belonging to an `.accessory` agent, so
    /// the app is never the active one. By default AppKit treats a click into an inactive
    /// application's window as an activating click and swallows it — which is why a code
    /// took two clicks to copy: the first one only moved focus.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookPresenter.shared
        panel.delegate = QuickLookPresenter.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLookPresenter.shared.panelDidClose()
    }
}

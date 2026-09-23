import AppKit
import RecallCore
import SwiftUI

/// A detached, always-on-top history window.
///
/// The panel is built to disappear the moment you look away, which is right for "grab one
/// thing and go" and wrong for an hour of moving text between two documents. The
/// scratchpad is the same list with the opposite instinct: it stays until dismissed,
/// floats above the documents being worked on, and remembers where it was put.
@MainActor
public final class ScratchpadController: NSObject, NSWindowDelegate {
    /// Where the window was last left. Stored in defaults rather than settings: it is
    /// window state, not a preference.
    private static let frameKey = "com.recall.scratchpad.frame"

    /// Unlike the panel, the scratchpad is meant to be on every Space — it is a second
    /// window you work alongside, not something you summon. Only one of the two Space
    /// options may ever be set; see `PanelController.collectionBehavior` for what setting
    /// both costs.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
    ]

    private var window: NSPanel?
    private let content: () -> AnyView

    public init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        self.content = { AnyView(content()) }
    }

    public var isVisible: Bool { window?.isVisible ?? false }

    public func toggle() {
        isVisible ? hide() : show()
    }

    public func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.title = String(localized: "Recall Scratchpad")
        // The glass runs to the top edge, so the title bar has to be out of its way —
        // otherwise the rounded content corners sit *below* an opaque bar and read as
        // notches. The close button stays: nothing else dismisses this window.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.level = .floating
        // Unlike the panel, this one survives losing focus — that is the whole point.
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        // As with the panel: the glass surface is the window's appearance.
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = Self.collectionBehavior
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hosting = QuickLookHostingView(rootView: content())
        PanelController.roundCorners(of: hosting)
        window.contentView = hosting

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            window.center()
        }
        return window
    }

    public func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    public func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    private func saveFrame() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }
}

import AppKit
import RecallCore
import SwiftUI

/// Owns the floating history panel.
///
/// The panel is an `NSPanel`, not the menu-bar popover, for one reason: pasting has to
/// put text into the app the user was *already* in. That means remembering which app that
/// was before we take focus, and handing focus back before the ⌘V goes out.
@MainActor
public final class PanelController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let content: () -> AnyView
    /// The app that was frontmost when the panel opened.
    private(set) var previousApplication: NSRunningApplication?

    public init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        self.content = { AnyView(content()) }
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func toggle() {
        Log.ui.info("Panel toggle (visible: \(self.isVisible, privacy: .public))")
        isVisible ? hide() : show()
    }

    public func show() {
        // Captured before we activate, or it will be Recall itself.
        previousApplication = NSWorkspace.shared.frontmostApplication

        Log.ui.info("Panel show: building")
        let panel = panel ?? makePanel()
        self.panel = panel
        Log.ui.info("Panel show: built")

        position(panel)
        // `activate(ignoringOtherApps:)` is deprecated and the system is free to ignore
        // it; the panel is non-activating and becomes key on its own, so this is only a
        // nudge for the cases where Recall may legitimately come forward.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        Log.ui.info("Panel shown (visible: \(panel.isVisible, privacy: .public), key: \(panel.isKeyWindow, privacy: .public))")
        // Key status is not always granted by the time `makeKeyAndOrderFront` returns, so
        // the useful reading is the settled one.
        onShow?()

        Task { @MainActor [weak panel] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let panel else { return }
            Log.ui.info("Panel settled (key: \(panel.isKeyWindow, privacy: .public), firstResponder: \(String(describing: panel.firstResponder), privacy: .public))")
        }
    }

    /// Called whenever the panel is shown, including every reopen.
    ///
    /// The panel and its hosting view are built once and reused, so SwiftUI's `task` and
    /// `onAppear` run on the *first* open and never again. Anything that has to happen
    /// every time — putting the caret back in the search field — needs telling.
    public var onShow: (@MainActor () -> Void)?

    /// Called whenever the panel goes away, however it went.
    public var onHide: (@MainActor () -> Void)?

    public func hide() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
        onHide?()
    }

    /// Hides the panel and puts the previous app back in front, so the synthesized ⌘V
    /// lands where the user was typing. The completion runs once the app has actually
    /// come forward — activation is asynchronous, and pasting into a window that is not
    /// yet key silently does nothing.
    public func hideAndRestoreFocus(completion: @escaping () -> Void) {
        hide()

        guard let previous = previousApplication, !previous.isTerminated else {
            completion()
            return
        }

        previous.activate()
        // 60ms is the smallest delay that reliably survives Stage Manager and Spaces
        // switches in testing; shorter, and the keystroke can outrun the activation.
        //
        // A task, not `DispatchQueue.main.asyncAfter`: handing a main-actor closure to
        // libdispatch makes the compiler check isolation dynamically on entry, and that
        // check faults in this app (see EdgeTrigger.installMonitor).
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            completion()
        }
    }

    /// The panel's corner radius, and the one the glass surface is cut to.
    ///
    /// A number rather than `.concentric()`: concentric corners match whatever container
    /// the view sits in, and a borderless window is not a container with a radius — so it
    /// resolved to zero and squared off the top, while the bottom kept the rounding the
    /// window server was still applying to the frame. AppKit does not publish the system
    /// radius anywhere readable (`NSThemeFrame`'s layer reports 0; the shape is drawn out
    /// of process), so the panel owns its own and this is it.
    static let cornerRadius: CGFloat = 16

    private func makePanel() -> NSPanel {
        // Taller than it is wide: one column of results wants vertical room, and a
        // narrower frame keeps the whole list within one eye movement.
        //
        // Borderless: there is no title bar to hide buttons in, and the glass surface
        // draws every edge itself. That needs `KeyablePanel`, because a borderless panel
        // refuses to become key — and the search field is useless if it cannot.
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        // The window draws nothing of its own: the Liquid Glass surface in
        // `HistoryPanelView` is the panel's whole appearance, and an opaque window
        // background behind it would flatten the material into a grey slab.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // With no frame of its own, the shadow is derived from what the content actually
        // paints — so it follows the rounded glass rather than a square bounding box.
        panel.hasShadow = true
        // The only way to move a window with no title bar.
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = Self.collectionBehavior
        // Deliberately false, though "click away and it is gone" is still the behaviour
        // we want — `windowDidResignKey` below does that.
        //
        // `hidesOnDeactivate` hides the panel whenever the *application* is inactive, and
        // Recall is an `.accessory` agent that is essentially never the active app. With
        // it set, AppKit hid the panel the instant it was ordered front, so the hot key
        // looked like it did nothing at all. A non-activating panel becomes key without
        // its app becoming active, which is exactly what is wanted here.
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        // A hosting view that will answer the Quick Look panel's question about who owns
        // it; a plain NSHostingView says no, and the preview opens empty.
        let hosting = QuickLookHostingView(rootView: content())
        Self.roundCorners(of: hosting)
        panel.contentView = hosting
        return panel
    }

    /// How the panel behaves across Spaces.
    ///
    /// `.canJoinAllSpaces` and `.moveToActiveSpace` are **mutually exclusive**, and
    /// setting both makes `-[NSWindow setCollectionBehavior:]` raise
    /// `NSInternalInconsistencyException`. This had both.
    ///
    /// AppKit does not let that crash: HIServices catches the exception and *suspends the
    /// thread that raised it*. That thread was running a main-actor job, so the main actor
    /// was never released — every later `Task { @MainActor in … }` queued behind it
    /// forever. The app kept running, kept drawing its menu, and silently stopped doing
    /// anything: no hot keys, no menu items, no capture. Nothing appeared in the crash
    /// reports, because nothing crashed.
    ///
    /// A summoned panel wants `.moveToActiveSpace` — come to the Space I am on — rather
    /// than `.canJoinAllSpaces`, which is for windows that live on every Space at once.
    static let collectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .fullScreenAuxiliary,
    ]

    /// Where the panel was last left. In defaults rather than settings: it is window
    /// state, not a preference, which is the same call the scratchpad makes.
    private static let frameKey = "com.recall.panel.frame"

    /// Puts the panel where the user left it, or centres it if they never moved it.
    ///
    /// A window you can drag has to stay dragged. Recentring on every summon would undo
    /// the move a second after it was made.
    private func position(_ panel: NSPanel) {
        if let saved = Self.savedFrame(), Self.isOnAScreen(saved) {
            panel.setFrame(saved, display: false)
            return
        }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.12
        )
        panel.setFrameOrigin(origin)
    }

    private static func savedFrame() -> NSRect? {
        guard let string = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let frame = NSRectFromString(string)
        return frame.isEmpty ? nil : frame
    }

    /// A frame from a display that is no longer attached would put the panel nowhere.
    /// Enough of it has to be visible to grab.
    private static func isOnAScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let overlap = screen.visibleFrame.intersection(frame)
            return overlap.width > 120 && overlap.height > 60
        }
    }

    private func saveFrame() {
        guard let panel, panel.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    public func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    public func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    /// Set while something modal belonging to Recall is on screen — a Touch ID prompt,
    /// say. Such a prompt takes key from the panel, and a panel that hides itself the
    /// instant it loses key would vanish out from under the very thing it asked for.
    public var suppressesAutoHide = false {
        didSet {
            guard oldValue, !suppressesAutoHide else { return }
            reclaimKey()
        }
    }

    /// Takes the keyboard back after a prompt has finished with it.
    ///
    /// The prompt leaves the panel visible but no longer key, and a panel that is not key
    /// is inert: Escape does not reach it, and clicking away produces no `resignKey` to
    /// hide it on — because it had already resigned, to the prompt. It just sat there.
    private func reclaimKey() {
        guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
        Log.ui.info("Taking the keyboard back after a prompt")
        panel.makeKeyAndOrderFront(nil)
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard !suppressesAutoHide else {
            Log.ui.info("Panel resigned key during a prompt; staying put")
            return
        }

        // Presenting a sheet takes key *from* the panel that is presenting it. Hiding on
        // that notification took the panel and the sheet off screen together, one frame
        // after the sheet appeared — which is why "Enter Manually" looked like a dead
        // button. The check is deferred because the sheet is not attached yet at the
        // moment key is resigned.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, let panel = self.panel, panel.isVisible else { return }
            guard !self.suppressesAutoHide else { return }

            if panel.attachedSheet != nil {
                Log.ui.info("Panel resigned key to its own sheet; staying put")
                return
            }
            guard !panel.isKeyWindow else { return }

            Log.ui.info("Panel resigned key; hiding")
            self.hide()
        }
    }
}

extension PanelController {
    /// Clips a hosting view to the panel's rounded shape.
    ///
    /// SwiftUI draws the glass rounded, but the `NSView` hosting it is still a rectangle
    /// with a backing layer, and that layer's square corners show as dark notches just
    /// outside the rounding — the "black line on the border".
    ///
    /// `.continuous` matters as much as the radius: macOS rounds windows with a squircle,
    /// and a circular arc against a squircle reads as a crease rather than a curve.
    static func roundCorners(of view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}

/// An `NSPanel` that will take the keyboard.
///
/// A borderless window returns false from `canBecomeKey`, which leaves the search field
/// unfocusable and the whole panel inert. Overriding it is the entire reason this class
/// exists.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Still not the main window: Recall is an agent, and taking main from the app the
    /// user is actually working in is what `.nonactivatingPanel` exists to avoid.
    override var canBecomeMain: Bool { false }
}

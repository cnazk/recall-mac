import AppKit
import RecallCore
import SwiftUI

/// Recall's Settings window, as a plain `NSWindow`.
///
/// SwiftUI's `Settings` scene is opened with `SettingsLink` from inside SwiftUI, and the
/// only way to open it from anywhere else is
/// `NSApp.sendAction(Selector(("showSettingsWindow:")), …)` — an undocumented selector
/// that does nothing here. Once the menu bar stopped being a `MenuBarExtra`, there was no
/// SwiftUI view left to put a `SettingsLink` in, and Settings became unreachable.
///
/// So Recall owns the window. Everything else it shows — the panel, the scratchpad, the
/// paste-stack readout, the menu — is already an `NSWindow` or an `NSMenu` hosting SwiftUI
/// views, and this is the last piece that was not.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let content: () -> AnyView

    public init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        self.content = { AnyView(content()) }
    }

    /// Shows the window, on `tab` when one is asked for.
    public func show(tab: SettingsTab? = nil) {
        if let tab {
            SettingsNavigator.shared.requestedTab = tab
        }

        let window = window ?? makeWindow()
        self.window = window

        // Settings is a window you read and type into, so unlike the panel, Recall does
        // come forward for it.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
        Log.ui.info("Settings window shown")
    }

    private func makeWindow() -> NSWindow {
        // An ordinary window, deliberately.
        //
        // It briefly wore the panel's glass surface and looked wrong: a `TabView` draws
        // its tab bar *outside* the view it is applied to, so the glass covered only the
        // form below, leaving the tabs floating on a transparent strip with the desktop
        // showing through and the settings sitting in an inset card. macOS already gives
        // a standard window its own Liquid Glass chrome; the panel and the scratchpad are
        // the ones that need to draw their own, because they have no chrome at all.
        let window = EscapableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recall Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let hosting = NSHostingView(rootView: content())
        window.contentView = hosting

        // `fittingSize` reports the height of the *shortest* tab, so the longest one was
        // cut off with a scroll bar the moment the window opened. Take whichever is
        // taller, and stay inside the screen.
        let fitting = hosting.fittingSize
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 80
        window.setContentSize(
            NSSize(width: 640, height: min(max(fitting.height, 640), available))
        )
        return window
    }
}

/// A window that closes on Escape.
///
/// `NSWindow` does not: Escape is `cancelOperation(_:)`, and a plain window ignores it.
/// Settings is a window you open, glance at and dismiss, so the key that means "I am done
/// here" everywhere else in Recall should mean it here too.
private final class EscapableWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

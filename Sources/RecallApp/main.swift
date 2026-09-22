import AppKit
import RecallUI

/// Recall — a local-first, AI-integrated clipboard manager.
///
/// A plain AppKit entry point rather than a SwiftUI `App`. Recall is a menu-bar agent:
/// no Dock icon, no main window, and every surface it does show — the history panel, the
/// scratchpad, the paste-stack readout, Settings — is an `NSWindow` hosting a SwiftUI
/// view, with an `NSMenu` in the menu bar.
///
/// It was a SwiftUI `App`, and the scene machinery only ever got in the way: `MenuBarExtra`
/// crashed on every menu click, `@Environment(\.dismiss)` was a silent no-op in a panel,
/// and the `Settings` scene could not be opened at all once there was no SwiftUI view left
/// to hold a `SettingsLink`. There is nothing a Scene was doing for this app that an
/// `NSWindow` does not do more plainly. See PLAN §7.8.
let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()

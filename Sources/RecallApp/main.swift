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

// Right to left, when the language Recall is running in reads that way.
//
// AppKit does not do this by itself for Persian: macOS has no Persian translation of its
// own, and a Persian Recall came up as Persian text in a left-to-right window — search
// icon on the wrong side, footer in the wrong order. These are the switches that mirror
// it, registered as defaults rather than set, so anything the user set explicitly wins.
// Before `NSApplication.shared`, because AppKit settles the direction as it starts.
if let language = Bundle.main.preferredLocalizations.first,
   Locale.Language(identifier: language).characterDirection == .rightToLeft {
    let defaults = UserDefaults.standard
    var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["AppleTextDirection"] = arguments["AppleTextDirection"] ?? true
    arguments["NSForceRightToLeftWritingDirection"] = arguments["NSForceRightToLeftWritingDirection"] ?? true
    defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
}

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.run()

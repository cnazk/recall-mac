import AppKit

/// The app's main menu, which exists purely so text editing shortcuts work.
///
/// ⌘A, ⌘C, ⌘X, ⌘V and ⌘Z are not built into `NSTextView`. The views implement the
/// actions, but the *keystrokes* come from the Edit menu's key equivalents — AppKit
/// matches a key event against `NSApp.mainMenu` before handing it to the responder chain.
/// No menu, no shortcuts: typing in the search field worked, but selecting all of what you
/// had typed did nothing.
///
/// A SwiftUI `App` builds this for you, which is why the problem only appeared once the
/// entry point became plain AppKit (see `main.swift`). Recall is an `.accessory` agent so
/// none of it is ever drawn; it is here to be matched against, not read.
public enum MainMenu {
    /// Kept alive for as long as the menu is: `NSMenuItem.target` is a weak reference,
    /// and an action whose target has gone is an action that silently does nothing.
    private nonisolated(unsafe) static let actions = MainMenuActions()

    public static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(applicationMenuItem())
        main.addItem(editMenuItem())
        return main
    }

    /// The application menu, which exists for ⌘, .
    ///
    /// Settings was only reachable from the menu-bar item, so the standard shortcut did
    /// nothing from the panel, the scratchpad, or Settings itself. A key equivalent in
    /// the main menu is checked whichever of Recall's windows has the keyboard.
    private static func applicationMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Recall")
        add(to: menu, String(localized: "Settings…"), #selector(MainMenuActions.showSettings(_:)), ",")
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: String(localized: "Edit"))

        add(to: menu, String(localized: "Undo"), #selector(UndoManager.undo), "z")
        add(to: menu, String(localized: "Redo"), #selector(UndoManager.redo), "Z", [.command, .shift])
        menu.addItem(.separator())
        add(to: menu, String(localized: "Cut"), #selector(NSText.cut(_:)), "x")
        add(to: menu, String(localized: "Copy"), #selector(NSText.copy(_:)), "c")
        add(to: menu, String(localized: "Paste"), #selector(NSText.paste(_:)), "v")
        add(to: menu, String(localized: "Delete"), #selector(NSText.delete(_:)), "")
        add(to: menu, String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")

        item.submenu = menu
        return item
    }

    /// Editing items carry no target, so they travel the responder chain to whatever is
    /// focused — which is how a text field ends up handling them. Items that are *not*
    /// about the focused view get an explicit one.
    private static func add(
        to menu: NSMenu,
        _ title: String,
        _ selector: Selector,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if selector == #selector(MainMenuActions.showSettings(_:)) {
            item.target = actions
        }
        menu.addItem(item)
    }
}

/// The main menu's target. **Not** `@MainActor`, for the reason `StatusMenu` gives: a
/// `@MainActor` class's `@objc` methods carry a compiler-inserted isolation check, and
/// asserting isolation at an AppKit dispatch boundary is what crashed this app.
private final class MainMenuActions: NSObject, @unchecked Sendable {
    @objc func showSettings(_ sender: Any?) {
        Task { @MainActor in SettingsNavigator.shared.open() }
    }
}

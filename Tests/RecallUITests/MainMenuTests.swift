import AppKit
import Testing
@testable import RecallUI

/// ⌘A and friends are not built into NSTextView — the keystrokes come from the Edit
/// menu's key equivalents, which AppKit matches before the responder chain sees the event.
/// A SwiftUI `App` builds that menu for you; a plain AppKit entry point does not, and the
/// symptom is silent: typing works, selecting all of it does nothing.
@Suite("Main menu")
@MainActor
struct MainMenuTests {
    private func editMenu() throws -> NSMenu {
        try submenu(titled: "Edit")
    }

    private func submenu(titled title: String) throws -> NSMenu {
        let main = MainMenu.make()
        let menus = main.items.compactMap(\.submenu)
        return try #require(menus.first { $0.title == title }, "no \(title) menu")
    }

    @Test("Every standard editing shortcut is bound")
    func shortcutsAreBound() throws {
        let expected: [(title: String, key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("Select All", "a", .command),
            ("Copy", "c", .command),
            ("Cut", "x", .command),
            ("Paste", "v", .command),
            ("Undo", "z", .command),
            ("Redo", "Z", [.command, .shift]),
        ]
        let items = try editMenu().items

        for expectation in expected {
            let item = try #require(
                items.first { $0.title == expectation.title },
                "\(expectation.title) is missing from the Edit menu"
            )
            #expect(item.keyEquivalent == expectation.key)
            #expect(item.keyEquivalentModifierMask == expectation.modifiers)
            #expect(item.action != nil, "\(expectation.title) has no action to send")
        }
    }

    @Test("Items have no target, so they travel the responder chain to whatever is focused")
    func itemsAreUntargeted() throws {
        for item in try editMenu().items where !item.isSeparatorItem {
            #expect(item.target == nil, "\(item.title) would only work for one specific object")
        }
    }

    @Test("Select All really is wired to selectAll:")
    func selectAllUsesTheRightSelector() throws {
        let item = try #require(try editMenu().items.first { $0.title == "Select All" })
        #expect(item.action == #selector(NSText.selectAll(_:)))
    }

    @Test("⌘, opens Settings from whichever window has the keyboard")
    func settingsShortcutExists() throws {
        let item = try #require(try submenu(titled: "Recall").items.first { $0.title == "Settings…" })
        #expect(item.keyEquivalent == ",")
        #expect(item.keyEquivalentModifierMask == .command)
        // Unlike the editing items, this one is not about the focused view, so it needs a
        // target of its own — an untargeted action would find no responder and do nothing.
        #expect(item.target != nil)
        #expect(item.action != nil)
    }
}

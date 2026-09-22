import Foundation
import Testing
@testable import RecallCore
@testable import RecallUI

/// Covers the panel's keyboard model.
///
/// Not XCUITest — that needs an Xcode project the package does not have yet (§9). The
/// mapping from keystroke to action was pulled out of the view so at least the part that
/// can be wrong in an interesting way is covered by real tests.
@Suite("Panel keyboard model")
struct PanelKeyboardTests {
    private func command(_ key: PanelKey, _ modifiers: PanelModifiers = [], searching: Bool = false) -> PanelCommand? {
        PanelKeyboard.command(for: key, modifiers: modifiers, isSearching: searching)
    }

    @Test("Arrows move the selection")
    func arrowsMove() {
        #expect(command(.down) == .moveSelection(by: 1))
        #expect(command(.up) == .moveSelection(by: -1))
    }

    @Test("Tab cycles kinds, Shift-Tab goes back")
    func tabCycles() {
        #expect(command(.tab) == .cycleKind(by: 1))
        #expect(command(.tab, .shift) == .cycleKind(by: -1))
    }

    @Test("Return pastes; Shift-Return strips formatting; Option-Return transforms")
    func returnVariants() {
        #expect(command(.return) == .paste(plainText: false))
        #expect(command(.return, .shift) == .paste(plainText: true))
        #expect(command(.return, .option) == .transform)
    }

    @Test("Escape dismisses")
    func escapeDismisses() {
        #expect(command(.escape) == .dismiss)
    }

    @Test("Backspace deletes an item only when the search field is empty")
    func deleteRespectsTheSearchField() {
        #expect(command(.delete) == .delete)
        // Deleting someone's clipboard entry because they backspaced over a typo would
        // be unforgivable.
        #expect(command(.delete, searching: true) == nil)
    }

    @Test("Command-digit pastes a pinned slot")
    func commandDigitPastesSlot() {
        #expect(command(.digit(3), .command) == .pasteSlot(3))
        #expect(command(.digit(9), .command) == .pasteSlot(9))
    }

    @Test("Option-Command-digit assigns a slot instead of pasting one")
    func optionCommandDigitAssignsSlot() {
        #expect(command(.digit(2), [.command, .option]) == .assignSlot(2))
    }

    @Test("A bare digit is typing, not a shortcut")
    func bareDigitsAreText() {
        #expect(command(.digit(4)) == nil)
        #expect(command(.digit(0), .command) == nil, "there is no slot zero")
    }

    @Test("Command-P toggles the pin")
    func commandPTogglesPin() {
        #expect(command(.character("p"), .command) == .togglePin)
        #expect(command(.character("P"), .command) == .togglePin)
        #expect(command(.character("p")) == nil, "plain p is typing")
    }

    @Test("Unclaimed combinations are left alone")
    func ignoresEverythingElse() {
        #expect(command(.character("z"), .command) == nil)
        #expect(command(.character("a")) == nil)
    }
}

/// ⌃⇥ swaps between history and two-factor codes, the chord every Mac app uses for
/// changing tab — which leaves plain ⇥ free to go on cycling the kind filter.
@Suite("Switching panel tabs")
struct SwitchTabTests {
    private func command(_ modifiers: PanelModifiers, isSearching: Bool = false) -> PanelCommand? {
        PanelKeyboard.command(for: .tab, modifiers: modifiers, isSearching: isSearching)
    }

    @Test("Control-Tab switches tab")
    func controlTabSwitches() {
        #expect(command([.control]) == .switchTab)
    }

    @Test("Plain Tab still cycles the kind filter, in both directions")
    func plainTabStillCyclesKinds() {
        #expect(command([]) == .cycleKind(by: 1))
        #expect(command([.shift]) == .cycleKind(by: -1))
    }

    @Test("It works while a search is in progress — switching tab is not editing text")
    func worksWhileSearching() {
        #expect(command([.control], isSearching: true) == .switchTab)
    }

    @Test("Control wins over Shift, so ⌃⇧⇥ switches rather than cycling backwards")
    func controlBeatsShift() {
        #expect(command([.control, .shift]) == .switchTab)
    }
}

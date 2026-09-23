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

    @Test("Command-arrows jump to the first and last item")
    func commandArrowsJump() {
        #expect(command(.up, .command) == .moveToFirst)
        #expect(command(.down, .command) == .moveToLast)
        // The search field is single-line, so the caret has nowhere for ⌘↑ to take it.
        #expect(command(.up, .command, searching: true) == .moveToFirst)
    }

    @Test("Page Up and Page Down move a page, even while searching")
    func pageKeysPage() {
        #expect(command(.pageDown) == .movePage(direction: 1))
        #expect(command(.pageUp) == .movePage(direction: -1))
        #expect(command(.pageDown, searching: true) == .movePage(direction: 1))
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

    @Test("Escape clears a search before it closes anything")
    func escapeClearsTheSearchFirst() {
        #expect(command(.escape, searching: true) == .clearSearch)
        #expect(PanelKeyboard.command(for: .escape, modifiers: [], isSearching: true, isComparing: true) == .clearSearch)
        #expect(PanelKeyboard.command(for: .escape, modifiers: [], isSearching: false, isComparing: true) == .cancelComparison)
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

/// Page Up and Page Down move the selection by what fits in the window, not by a fixed
/// count — rows are one or two lines, and the window is resizable.
@Suite("Paging through history")
struct PagingTests {
    private let spacing = PanelKeyboard.rowSpacing

    private func target(from index: Int, _ direction: Int, heights: [CGFloat?], viewport: CGFloat) -> Int {
        PanelKeyboard.pageTarget(from: index, direction: direction, rowHeights: heights, viewportHeight: viewport)
    }

    @Test("A page is as many rows as fit in the list")
    func pageFitsTheViewport() {
        let heights = [CGFloat?](repeating: 32, count: 50)
        // Room for exactly five rows with their spacing.
        let viewport = (32 + spacing) * 5
        #expect(target(from: 0, 1, heights: heights, viewport: viewport) == 5)
        #expect(target(from: 20, -1, heights: heights, viewport: viewport) == 15)
    }

    @Test("Taller rows make a shorter page")
    func tallRowsShortenThePage() {
        let heights: [CGFloat?] = [32, 32, 64, 64, 32, 32, 32, 32]
        // Rows 1–3 take 32 + 64 + 64 plus spacing; row 4 would not fit.
        let viewport = 160 + spacing * 3
        #expect(target(from: 0, 1, heights: heights, viewport: viewport) == 3)
    }

    @Test("Rows the lazy list never laid out count as the average")
    func unmeasuredRowsUseTheAverage() {
        let heights: [CGFloat?] = [40, 40, nil, nil, nil, nil, nil, nil]
        let viewport = (40 + spacing) * 4
        #expect(target(from: 0, 1, heights: heights, viewport: viewport) == 4)
    }

    @Test("It stops at either end")
    func stopsAtTheEnds() {
        let heights = [CGFloat?](repeating: 32, count: 10)
        #expect(target(from: 7, 1, heights: heights, viewport: 1_000) == 9)
        #expect(target(from: 2, -1, heights: heights, viewport: 1_000) == 0)
        #expect(target(from: 9, 1, heights: heights, viewport: 1_000) == 9)
        #expect(target(from: 0, -1, heights: heights, viewport: 1_000) == 0)
    }

    @Test("It always moves at least one row, even when a row is taller than the window")
    func alwaysMovesAtLeastOne() {
        let heights: [CGFloat?] = [32, 500, 32]
        #expect(target(from: 0, 1, heights: heights, viewport: 200) == 1)
        // Before the list has been measured at all.
        #expect(target(from: 0, 1, heights: [nil, nil, nil], viewport: 0) == 1)
    }

    @Test("An empty list has nowhere to go")
    func emptyList() {
        #expect(target(from: 0, 1, heights: [], viewport: 400) == 0)
    }
}

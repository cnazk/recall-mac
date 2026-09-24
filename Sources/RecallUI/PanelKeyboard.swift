import SwiftUI

/// Everything the panel does in response to a keystroke.
///
/// Pulled out of the view as a pure function on purpose: XCUITest needs an Xcode project
/// (see the plan, §9), and until that exists a keyboard model buried in a `View` is
/// untestable. This way the bindings are covered by ordinary unit tests, and the view is
/// left with nothing but the doing.
public enum PanelCommand: Equatable, Sendable {
    case moveSelection(by: Int)
    /// Page Up / Page Down: a screenful of rows at a time, backwards for a negative
    /// direction. How many rows that is depends on the window, so the view works it out
    /// with ``PanelKeyboard/pageTarget(from:direction:rowHeights:viewportHeight:)``.
    case movePage(direction: Int)
    /// ⌘↑ / ⌘↓: the first or the last item.
    case moveToFirst
    case moveToLast
    case cycleKind(by: Int)
    /// Return, or Shift-Return for the plain-text variant.
    case paste(plainText: Bool)
    /// Option-Return: open the "Paste as…" sheet.
    case transform
    case delete
    case dismiss
    case togglePin
    /// ⌘1–9: paste the pinned item in that slot.
    case pasteSlot(Int)
    /// ⌥⌘1–9: move the selected pin into that slot.
    case assignSlot(Int)
    /// Space (or ⌘Y): preview the selection in Quick Look.
    case quickLook
    /// ⌃⇥: move on to the next tab — history, two-factor codes, todos.
    case switchTab
    /// ⌘T: make a todo from the selection.
    case addToTodos
    /// ⌘D: mark the selection as the clip to compare against, or — with one already
    /// marked — open the comparison.
    case compare
    /// Escape, while a clip is marked for comparison.
    case cancelComparison
    /// Escape, while there is a query.
    case clearSearch
}

/// The keys the panel cares about, independent of SwiftUI's `KeyPress`.
public enum PanelKey: Equatable, Sendable {
    case up, down, pageUp, pageDown, tab, escape, `return`, delete, space
    case digit(Int)
    case character(Character)
}

public struct PanelModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = PanelModifiers(rawValue: 1 << 0)
    public static let option = PanelModifiers(rawValue: 1 << 1)
    public static let command = PanelModifiers(rawValue: 1 << 2)
    public static let control = PanelModifiers(rawValue: 1 << 3)
}

public enum PanelKeyboard {
    /// - Parameter isSearching: whether the search field has text, which is what decides
    ///   if ⌫ deletes the selected item or edits the query. Deleting someone's clipboard
    ///   entry because they backspaced over a typo would be unforgivable.
    /// - Parameter isComparing: whether a clip is already marked to compare against,
    ///   which Escape backs out of before it closes the panel.
    public static func command(
        for key: PanelKey,
        modifiers: PanelModifiers,
        isSearching: Bool,
        isComparing: Bool = false
    ) -> PanelCommand? {
        switch key {
        case .down:
            return modifiers.contains(.command) ? .moveToLast : .moveSelection(by: 1)
        case .up:
            return modifiers.contains(.command) ? .moveToFirst : .moveSelection(by: -1)
        case .pageDown:
            return .movePage(direction: 1)
        case .pageUp:
            return .movePage(direction: -1)
        case .tab:
            // ⌃⇥ is what every Mac app uses to change tab, and it leaves plain ⇥ free to
            // go on cycling the kind filter.
            if modifiers.contains(.control) { return .switchTab }
            return .cycleKind(by: modifiers.contains(.shift) ? -1 : 1)
        case .escape:
            // Escape backs out one step at a time, the most recent first: the query, then
            // a comparison, and only then the panel. Closing the whole panel because
            // someone wanted to retype a search loses the comparison they set up too.
            if isSearching { return .clearSearch }
            return isComparing ? .cancelComparison : .dismiss
        case .return:
            if modifiers.contains(.option) { return .transform }
            return .paste(plainText: modifiers.contains(.shift))
        case .delete:
            return isSearching ? nil : .delete
        case .space:
            // Space types a space while there is a query. Quick Look gets ⌘Y for the
            // times the search field is in use — the same compromise Finder makes with
            // renaming.
            return isSearching ? nil : .quickLook
        case .digit(let digit):
            guard modifiers.contains(.command), (1...9).contains(digit) else { return nil }
            return modifiers.contains(.option) ? .assignSlot(digit) : .pasteSlot(digit)
        case .character(let character):
            guard modifiers.contains(.command) else { return nil }
            switch character.lowercased() {
            case "p": return .togglePin
            case "y": return .quickLook
            case "d": return .compare
            case "t": return .addToTodos
            default: return nil
            }
        }
    }

    /// Room the list itself puts around every row. The row can only measure its own
    /// content, so this is added to each one; erring high makes a page slightly short,
    /// which is the safe way round — a long page skips rows that were never on screen.
    public static let rowSpacing: CGFloat = 8

    /// Where Page Up or Page Down leaves the selection: the furthest row whose way there
    /// still fits in one window's height. After the list scrolls to it, it sits at the
    /// edge the page moved towards, which is where the next page starts from.
    ///
    /// - Parameters:
    ///   - index: the selected row.
    ///   - direction: positive for Page Down, negative for Page Up.
    ///   - rowHeights: every row's measured height, in list order. `nil` for a row that
    ///     has never been laid out — the list is lazy — which counts as the average.
    ///   - viewportHeight: the visible height of the list.
    public static func pageTarget(
        from index: Int,
        direction: Int,
        rowHeights: [CGFloat?],
        viewportHeight: CGFloat
    ) -> Int {
        let count = rowHeights.count
        guard count > 0 else { return 0 }
        let step = direction < 0 ? -1 : 1
        let start = min(max(index, 0), count - 1)

        let known = rowHeights.compactMap { $0 }
        let fallback = known.isEmpty ? 44 : known.reduce(0, +) / CGFloat(known.count)

        var target = start
        var used: CGFloat = 0
        var next = start + step
        while next >= 0, next < count {
            used += (rowHeights[next] ?? fallback) + rowSpacing
            guard used <= viewportHeight else { break }
            target = next
            next += step
        }
        // Always at least one row, so a key press never does nothing while there is
        // somewhere to go — rows taller than the window would otherwise pin it in place.
        if target == start {
            target = min(max(start + step, 0), count - 1)
        }
        return target
    }
}

public extension PanelKey {
    /// Bridges SwiftUI's `KeyPress` into the testable model.
    init?(_ keyPress: KeyPress) {
        switch keyPress.key {
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        case .tab: self = .tab
        case .escape: self = .escape
        case .return: self = .return
        case .delete, .deleteForward: self = .delete
        case .space: self = .space
        default:
            guard let character = keyPress.characters.first else { return nil }
            if let digit = character.wholeNumberValue, (0...9).contains(digit) {
                self = .digit(digit)
            } else {
                self = .character(character)
            }
        }
    }
}

public extension PanelModifiers {
    init(_ modifiers: EventModifiers) {
        var result: PanelModifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        self = result
    }
}

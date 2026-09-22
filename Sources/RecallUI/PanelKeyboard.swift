import SwiftUI

/// Everything the panel does in response to a keystroke.
///
/// Pulled out of the view as a pure function on purpose: XCUITest needs an Xcode project
/// (see the plan, §9), and until that exists a keyboard model buried in a `View` is
/// untestable. This way the bindings are covered by ordinary unit tests, and the view is
/// left with nothing but the doing.
public enum PanelCommand: Equatable, Sendable {
    case moveSelection(by: Int)
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
    /// ⌃⇥: swap between history and two-factor codes.
    case switchTab
    /// ⌘D: mark the selection as the clip to compare against, or — with one already
    /// marked — open the comparison.
    case compare
    /// Escape, while a clip is marked for comparison.
    case cancelComparison
}

/// The keys the panel cares about, independent of SwiftUI's `KeyPress`.
public enum PanelKey: Equatable, Sendable {
    case up, down, tab, escape, `return`, delete, space
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
    ///   which is what Escape backs out of before it closes the panel.
    public static func command(
        for key: PanelKey,
        modifiers: PanelModifiers,
        isSearching: Bool,
        isComparing: Bool = false
    ) -> PanelCommand? {
        switch key {
        case .down:
            return .moveSelection(by: 1)
        case .up:
            return .moveSelection(by: -1)
        case .tab:
            // ⌃⇥ is what every Mac app uses to change tab, and it leaves plain ⇥ free to
            // go on cycling the kind filter.
            if modifiers.contains(.control) { return .switchTab }
            return .cycleKind(by: modifiers.contains(.shift) ? -1 : 1)
        case .escape:
            // Escape backs out of a comparison first. Closing the whole panel because
            // someone changed their mind about a diff loses the search they typed too.
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
            default: return nil
            }
        }
    }
}

public extension PanelKey {
    /// Bridges SwiftUI's `KeyPress` into the testable model.
    init?(_ keyPress: KeyPress) {
        switch keyPress.key {
        case .upArrow: self = .up
        case .downArrow: self = .down
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

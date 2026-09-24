/// Everything the Todos tab does in response to a keystroke.
///
/// A pure function for the same reason as ``PanelKeyboard``: a keyboard model inside a
/// `View` cannot be tested without a running app.
public enum TodoCommand: Equatable, Sendable {
    case moveSelection(by: Int)
    case moveToFirst
    case moveToLast
    /// Return, with something typed in the new-todo field.
    case add
    /// Return, with the field empty: tick the selected todo off, or back on.
    case toggleDone
    /// ⌘Return: paste the clip the selected todo was made from.
    case pasteClip
    case delete
    /// Escape, with something typed in the field.
    case clearDraft
    case dismiss
}

public enum TodoKeyboard {
    /// - Parameter hasDraft: whether the new-todo field has text in it. It decides what
    ///   Return and ⌫ mean, the way a query does in ``PanelKeyboard``: backspacing over
    ///   a typo must never delete a todo.
    public static func command(for key: PanelKey, modifiers: PanelModifiers, hasDraft: Bool) -> TodoCommand? {
        switch key {
        case .down:
            return modifiers.contains(.command) ? .moveToLast : .moveSelection(by: 1)
        case .up:
            return modifiers.contains(.command) ? .moveToFirst : .moveSelection(by: -1)
        case .return:
            if modifiers.contains(.command) { return .pasteClip }
            return hasDraft ? .add : .toggleDone
        case .delete:
            return hasDraft ? nil : .delete
        case .escape:
            return hasDraft ? .clearDraft : .dismiss
        case .pageUp, .pageDown, .tab, .space, .digit, .character:
            return nil
        }
    }
}

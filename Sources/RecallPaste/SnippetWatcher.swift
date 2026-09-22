import AppKit
import Carbon.HIToolbox
import Foundation
import RecallCore

/// Watches typing for snippet shortcodes and expands them in place.
///
/// This is the one feature that needs an event tap, and therefore Accessibility
/// permission. It is off until the user turns it on, it listens rather than intercepts,
/// and it keeps only ``TypedBuffer``'s handful of characters. If permission is missing or
/// revoked the watcher reports that and does nothing — it never degrades into asking
/// repeatedly.
@MainActor
public final class SnippetWatcher {
    public enum State: Equatable, Sendable {
        case stopped
        case running
        case needsAccessibilityPermission
    }

    public private(set) var state: State = .stopped

    /// Looks up the text for a matched shortcode. Returning nil cancels the expansion.
    public var textForSnippet: ((UUID) -> String?)?

    private var expander: SnippetExpander
    private var buffer = TypedBuffer()
    private let paste: PasteService
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public init(paste: PasteService, expander: SnippetExpander = SnippetExpander(snippets: [:])) {
        self.paste = paste
        self.expander = expander
    }

    /// Replaces the shortcode table, e.g. after the user assigns a new one.
    public func update(expander: SnippetExpander) {
        self.expander = expander
        buffer.reset()
    }

    @discardableResult
    public func start() -> State {
        guard state != .running else { return state }

        guard AXIsProcessTrusted() else {
            state = .needsAccessibilityPermission
            return state
        }

        guard let tap = Self.createTap(for: self) else {
            state = .needsAccessibilityPermission
            return state
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        state = .running
        Log.paste.info("Snippet watcher started")
        return state
    }

    public func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        buffer.reset()
        state = .stopped
    }

    // MARK: - Event handling

    /// Creates the event tap from a **nonisolated** context, on purpose.
    ///
    /// A `@convention(c)` callback written inside this `@MainActor` class still inherits
    /// the isolation, and the compiler puts a dynamic check in its prologue. That check
    /// is what crashes this app — see `EdgeTrigger.installMonitor` for the full story —
    /// so the callback is built somewhere it is never inferred in the first place.
    private nonisolated static func createTap(for watcher: SnippetWatcher) -> CFMachPort? {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Listen only: Recall must never be able to swallow or alter a keystroke on
            // its way to the app the user is typing into.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let watcher = Unmanaged<SnippetWatcher>.fromOpaque(userInfo).takeUnretainedValue()

                // The event is only valid for the length of this callback, so everything
                // the watcher needs is copied out here and handed over as plain values.
                // Enqueueing preserves order: main-actor tasks run in enqueue order.
                guard type == .keyDown else { return Unmanaged.passUnretained(event) }
                let keystroke = Keystroke(
                    keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                    flags: event.flags,
                    characters: event.unicodeString
                )
                Task { @MainActor in watcher.handle(keystroke) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(watcher).toOpaque()
        )
    }

    /// One key down, lifted out of the `CGEvent` while it is still alive.
    ///
    /// A modifier change on its own does not break a word, so only key downs are
    /// forwarded; a click or a command shortcut arrives as one and is handled below.
    struct Keystroke: Sendable {
        let keyCode: Int
        let flags: CGEventFlags
        let characters: String?
    }

    private func handle(_ keystroke: Keystroke) {
        let keyCode = keystroke.keyCode
        let flags = keystroke.flags

        // Anything with a command or control modifier is a shortcut, not typing.
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer.reset()
            return
        }

        switch keyCode {
        case kVK_Delete:
            buffer.deleteBackward()
            return
        case kVK_Escape, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            buffer.reset()
            return
        default:
            break
        }

        guard let characters = keystroke.characters, !characters.isEmpty else { return }
        buffer.append(characters)

        guard let match = expander.match(typedBuffer: buffer.text) else { return }
        guard let text = textForSnippet?(match.itemID) else { return }

        buffer.reset()
        expand(text, deleting: match.charactersToDelete)
    }

    /// Removes the shortcode the user typed and puts the snippet in its place.
    private func expand(_ text: String, deleting count: Int) {
        for _ in 0..<count {
            paste.synthesizeKey(CGKeyCode(kVK_Delete))
        }
        // Restoring the clipboard afterwards matters: expanding a snippet should not cost
        // the user whatever they had copied.
        paste.pasteRestoringPasteboard(text)
    }
}

private extension CGEvent {
    /// The characters this key event produces, respecting the active layout.
    var unicodeString: String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}

import AppKit
import Foundation
import RecallCore

/// How an item should be put on the pasteboard.
public enum PasteStyle: Sendable, Equatable {
    /// Exactly what was copied, all representations intact.
    case original
    /// Formatting stripped — `Shift + Return` in the panel.
    case plainText
    /// The result of a "Paste as…" transform.
    case transformed(String)
}

/// Writes an item to the pasteboard and, when permitted, synthesises the paste keystroke.
///
/// Synthesising `Cmd+V` needs Accessibility permission. Without it, Recall still copies
/// the item and the user pastes by hand — the app must stay useful before the permission
/// is granted, not nag until it is.
@MainActor
public final class PasteService {
    /// Called just before we write, so the monitor can skip the changes we are about to
    /// cause. Paired with ``didWriteToPasteboard`` — a write can bump the pasteboard's
    /// change count more than once, so the monitor is told when we start and when we stop
    /// rather than being asked to predict a number.
    public var willWriteToPasteboard: (() -> Void)?
    /// Called once the write is complete.
    public var didWriteToPasteboard: (() -> Void)?

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Whether we are allowed to synthesise keystrokes.
    public var canSynthesizePaste: Bool {
        AXIsProcessTrusted()
    }

    /// Opens the system prompt for Accessibility access. Only call in response to the
    /// user choosing to enable auto-paste.
    public func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Puts the item on the pasteboard. Returns false if there was nothing to write.
    @discardableResult
    public func write(_ item: ClipItem, style: PasteStyle = .original) -> Bool {
        willWriteToPasteboard?()
        defer { didWriteToPasteboard?() }

        pasteboard.clearContents()

        switch style {
        case .transformed(let text):
            return pasteboard.setString(text, forType: .string)

        case .plainText:
            guard let text = item.payload.searchableText else { return writeOriginal(item) }
            return pasteboard.setString(text, forType: .string)

        case .original:
            return writeOriginal(item)
        }
    }

    /// Writes the item and then presses `Cmd+V` in the frontmost app.
    @discardableResult
    public func paste(_ item: ClipItem, style: PasteStyle = .original) -> Bool {
        guard write(item, style: style) else { return false }
        guard canSynthesizePaste else {
            Log.paste.info("Accessibility not granted; item copied without auto-paste")
            return true
        }
        synthesizeCommandV()
        return true
    }

    private func writeOriginal(_ item: ClipItem) -> Bool {
        switch item.payload {
        case .text(let text):
            return pasteboard.setString(text, forType: .string)

        case .richText(let rtf, let plain):
            // Declare both, richest first, so each destination picks what it can take.
            pasteboard.declareTypes([.rtf, .string], owner: nil)
            let wroteRTF = pasteboard.setData(rtf, forType: .rtf)
            let wrotePlain = pasteboard.setString(plain, forType: .string)
            return wroteRTF || wrotePlain

        case .image(let image):
            return pasteboard.setData(image.data, forType: image.uti == "public.png" ? .png : .tiff)

        case .files(let refs):
            return pasteboard.writeObjects(refs.map { $0.url as NSURL })

        case .url(let url):
            // NSURL writes both the URL and string representations, so a destination that
            // only understands text still gets something useful.
            return pasteboard.writeObjects([url as NSURL])

        case .color(let color):
            return pasteboard.setString(color.raw, forType: .string)
        }
    }

    /// Puts a value on the pasteboard that must not become history.
    ///
    /// Used for generated two-factor codes: the monitor is muted for the write, and the
    /// value is marked concealed so *other* clipboard managers leave it alone too.
    public func writeTransient(_ text: String) {
        willWriteToPasteboard?()
        defer { didWriteToPasteboard?() }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    /// Types `text` into the frontmost app, then puts back whatever was on the clipboard.
    ///
    /// Used by snippet expansion: expanding `:sig` should not cost the user the thing
    /// they had copied a moment ago.
    public func pasteRestoringPasteboard(_ text: String) {
        let saved = pasteboard.string(forType: .string)

        willWriteToPasteboard?()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didWriteToPasteboard?()

        guard canSynthesizePaste else { return }
        synthesizeCommandV()

        guard let saved else { return }
        // Long enough for the destination app to have read the pasteboard.
        //
        // A `Task` rather than `DispatchQueue.main.asyncAfter`: a main-actor closure
        // handed to libdispatch is called from non-isolated code, so the compiler puts a
        // dynamic isolation check in its prologue, and that check is what crashes this
        // app (see EdgeTrigger.installMonitor). A task is already on the actor and is
        // never asked to prove it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            willWriteToPasteboard?()
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
            didWriteToPasteboard?()
        }
    }

    /// Posts a single key press, used to delete the typed shortcode before expanding it.
    public func synthesizeKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Posts a synthetic `Cmd+V` to the session event tap.
    private func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCodeV: CGKeyCode = 9

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}

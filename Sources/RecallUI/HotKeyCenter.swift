import AppKit
import Carbon.HIToolbox
import Foundation
import RecallCore

/// A system-wide keyboard shortcut.
public struct HotKey: Sendable, Hashable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let commandShift = UInt32(cmdKey | shiftKey)

    /// ⌘⇧V — open the history panel.
    public static let showPanel = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: commandShift)

    /// ⌃⌥⌘C — add the current clipboard to the paste stack.
    ///
    /// Control is in there because ⌥⌘V is already the scratchpad, and a chord bound twice
    /// is a coin toss: the menu item and the Carbon hot key both fire. The C/V mnemonic is
    /// worth keeping, so the stack takes the longer chord rather than the shorter one.
    public static let addToStack = HotKey(keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey | optionKey | controlKey))

    /// ⌃⌥⌘V — paste the next item from the stack.
    public static let pasteFromStack = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey | controlKey))

    /// ⌥⌘V — the scratchpad.
    ///
    /// It needs a real system-wide registration: the menu item's `.keyboardShortcut` only
    /// fires while Recall is the active app, and an agent with no windows never is. The
    /// menu has advertised this chord since Phase 6 while nothing listened for it.
    public static let showScratchpad = HotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey))

    /// ⌘⇧A — open straight to the two-factor codes.
    public static let showCodes = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: commandShift)

    /// ⌘⇧2 — drag out a region of the screen and put the text in it on the clipboard.
    public static let captureText = HotKey(keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey | optionKey))

    /// ⌥⌘⇧P — pause or resume recording. Reachable in the moment before copying
    /// something you would rather Recall did not keep, without going to the menu bar.
    public static let togglePause = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | shiftKey | optionKey))

    /// ⌘⇧1…⌘⇧9 — paste pinned slot 1–9 without opening the panel, which is the whole
    /// point of pinning something.
    public static func pinnedSlot(_ slot: Int) -> HotKey? {
        let codes = [
            kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
            kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9,
        ]
        guard (1...codes.count).contains(slot) else { return nil }
        return HotKey(keyCode: UInt32(codes[slot - 1]), modifiers: commandShift)
    }
}

/// Registers system-wide shortcuts through Carbon's `RegisterEventHotKey`.
///
/// Carbon rather than a `CGEventTap` on purpose: an event tap needs Accessibility
/// permission, and a clipboard manager that demands to watch every keystroke before it
/// will open its own window has earned the suspicion it gets. `RegisterEventHotKey` needs
/// no permission at all — the app only learns that *its* shortcut was pressed.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// Registers `hotKey`, returning an id that can be passed to ``unregister(_:)``.
    @discardableResult
    public func register(_ hotKey: HotKey, action: @escaping () -> Void) -> UInt32? {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            // Another app already owns this combination. Not fatal: the menu-bar item
            // and the panel still work, and the user can pick a different shortcut.
            Log.ui.error("Could not register hot key \(hotKey.keyCode, privacy: .public)")
            return nil
        }

        handlers[id] = action
        registrations[id] = reference
        Log.ui.info("Registered hot key \(id, privacy: .public) (key code \(hotKey.keyCode, privacy: .public))")
        return id
    }

    public func unregister(_ id: UInt32) {
        if let reference = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(reference)
        }
        handlers.removeValue(forKey: id)
    }

    public func unregisterAll() {
        for id in registrations.keys { unregister(id) }
    }

    fileprivate func handle(id: UInt32) {
        guard let action = handlers[id] else {
            Log.ui.error("Hot key \(id, privacy: .public) fired with no handler registered")
            return
        }
        Log.ui.info("Hot key \(id, privacy: .public) fired")
        action()
    }

    private static let signature: OSType = 0x5243_4C4C // 'RCLL'

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        eventHandler = Self.installCarbonHandler()
    }

    /// Installs the Carbon handler from a **nonisolated** context, on purpose.
    ///
    /// A `@convention(c)` callback written inside this `@MainActor` class inherits the
    /// isolation and gets a dynamic check in its prologue, and that check is what crashes
    /// this app — see `EdgeTrigger.installMonitor`.
    private nonisolated static func installCarbonHandler() -> EventHandlerRef? {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return status }

                // The Carbon callback is a bare C function pointer and cannot capture, so
                // it hops to the main actor and looks the handler up there.
                let id = hotKeyID.id
                // Logged here, before the hop, so a hot key that arrives but never
                // reaches the handler is distinguishable from one that never arrives.
                Log.ui.info("Carbon hot key event \(id, privacy: .public)")
                Task { @MainActor in HotKeyCenter.shared.handle(id: id) }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handler
        )
        return handler
    }
}

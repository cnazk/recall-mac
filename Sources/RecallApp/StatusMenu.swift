import AppKit
import RecallCore
import RecallUI

/// The menu-bar item and its menu, built with AppKit rather than `MenuBarExtra`.
///
/// SwiftUI's version crashed on every use. Activating one of its buttons goes through
/// `ButtonAction.callAsFunction`, which calls `MainActor.assumeIsolated`, and that check
/// faults inside a menu tracking session — the crash reports contain no Recall code at
/// all, so there was nothing to fix on our side of it.
///
/// Everything here is deliberately plain: an `NSStatusItem`, an `NSMenu`, and a target
/// whose actions are `@objc` methods on a **nonisolated** object. A `@MainActor` class's
/// `@objc` methods carry the same compiler-inserted isolation check that SwiftUI's button
/// tripped over, so the target must not be one; each action hops to the main actor itself.
@MainActor
final class StatusMenu {
    private let statusItem: NSStatusItem
    private let actions: MenuActions
    private weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
        self.actions = MenuActions(owner: owner)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.image(named: "doc.on.clipboard")
        statusItem.button?.image?.isTemplate = true
        rebuild()
    }

    /// Paused wins over everything: the icon is the only signal when the menu is shut, so
    /// it has to be a different shape and not just a different fill.
    func refreshIcon(isPaused: Bool, isStarting: Bool) {
        let name = if isPaused {
            "pause.circle"
        } else if isStarting {
            "doc.on.clipboard.fill"
        } else {
            "doc.on.clipboard"
        }
        statusItem.button?.image = Self.image(named: name)
        statusItem.button?.image?.isTemplate = true
    }

    private static func image(named name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Recall")
    }

    /// Rebuilds the menu from current state.
    ///
    /// Called whenever something it shows changes, rather than from `menuNeedsUpdate`:
    /// that delegate callback would have to read main-actor state synchronously from an
    /// AppKit callback, which is the shape being avoided here.
    func rebuild() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if let message = owner?.startupMessage {
            let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        add(to: menu, "Show Recall", #selector(MenuActions.showPanel(_:)), key: "v", modifiers: [.command, .shift])

        if owner?.loginItemNeedsApproval == true {
            add(to: menu, "Approve “Open at Login”…", #selector(MenuActions.approveLoginItem(_:)))
            menu.addItem(.separator())
        }

        add(to: menu, "Scratchpad", #selector(MenuActions.toggleScratchpad(_:)), key: "v", modifiers: [.command, .option])
        add(to: menu, "Two-Factor Codes", #selector(MenuActions.showCodes(_:)), key: "a", modifiers: [.command, .shift])
        add(to: menu, "Capture Text from Screen", #selector(MenuActions.captureText(_:)),
            key: "2", modifiers: [.command, .shift, .option])

        menu.addItem(.separator())
        addPauseSection(to: menu)
        menu.addItem(.separator())

        add(to: menu, "Settings…", #selector(MenuActions.showSettings(_:)), key: ",", modifiers: .command)
        add(to: menu, "Clear History…", #selector(MenuActions.clearHistory(_:)))

        menu.addItem(.separator())
        add(to: menu, "Quit Recall", #selector(MenuActions.quit(_:)), key: "q", modifiers: .command)

        statusItem.menu = menu
    }

    /// While paused the menu says so in words as well as changing the icon.
    private func addPauseSection(to menu: NSMenu) {
        guard let model = owner?.model else { return }

        guard model.isCapturePaused else {
            let pause = NSMenuItem(title: "Pause Capture", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            add(to: submenu, PauseDuration.fifteenMinutes.menuTitle, #selector(MenuActions.pauseFifteenMinutes(_:)))
            add(to: submenu, PauseDuration.oneHour.menuTitle, #selector(MenuActions.pauseOneHour(_:)))
            add(to: submenu, PauseDuration.indefinitely.menuTitle, #selector(MenuActions.pauseIndefinitely(_:)))
            pause.submenu = submenu
            menu.addItem(pause)
            return
        }

        if let status = model.capturePauseStatus {
            let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        add(to: menu, "Resume Capture", #selector(MenuActions.resumeCapture(_:)))
    }

    private func add(
        to menu: NSMenu,
        _ title: String,
        _ selector: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = actions
        item.isEnabled = true
        menu.addItem(item)
    }
}

/// The menu's target. **Not** `@MainActor`, on purpose — see ``StatusMenu``.
///
/// Every action hops to the main actor rather than claiming to be on it, so no isolation
/// check runs while AppKit is dispatching the menu item.
private final class MenuActions: NSObject {
    private weak var owner: AppDelegate?

    init(owner: AppDelegate) {
        self.owner = owner
    }

    private func onMain(_ body: @escaping @MainActor (AppDelegate) -> Void) {
        let owner = owner
        Task { @MainActor in
            guard let owner else { return }
            body(owner)
        }
    }

    @objc func showPanel(_ sender: Any?) { onMain { $0.showPanel() } }
    @objc func toggleScratchpad(_ sender: Any?) { onMain { $0.toggleScratchpad() } }
    @objc func showCodes(_ sender: Any?) { onMain { $0.showCodes() } }
    @objc func approveLoginItem(_ sender: Any?) { onMain { _ in LoginItem.openSystemSettings() } }
    @objc func clearHistory(_ sender: Any?) { onMain { $0.confirmClearHistory() } }
    @objc func captureText(_ sender: Any?) {
        onMain { owner in Task { await owner.model?.captureTextFromScreen() } }
    }

    @objc func pauseFifteenMinutes(_ sender: Any?) { onMain { $0.pauseCapture(.fifteenMinutes) } }
    @objc func pauseOneHour(_ sender: Any?) { onMain { $0.pauseCapture(.oneHour) } }
    @objc func pauseIndefinitely(_ sender: Any?) { onMain { $0.pauseCapture(.indefinitely) } }
    @objc func resumeCapture(_ sender: Any?) { onMain { $0.resumeCapture() } }

    @objc func showSettings(_ sender: Any?) {
        onMain { _ in SettingsNavigator.shared.open() }
    }

    @objc func quit(_ sender: Any?) {
        Task { @MainActor in NSApp.terminate(nil) }
    }
}

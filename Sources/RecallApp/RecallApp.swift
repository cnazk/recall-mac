import AppKit
import RecallCapture
import RecallCore
import RecallIntelligence
import RecallOTP
import RecallPaste
import RecallSecurity
import RecallStorage
import RecallUI
import SwiftUI

/// Recall — a local-first, AI-integrated clipboard manager.
///
/// The app is a menu-bar agent: no Dock icon, no main window. History lives in a floating
/// panel summoned with ⌘⇧V; the menu-bar item is for the things you do once a month.
/// Composition root: builds the store, wires the pasteboard monitor to the model, owns
/// the panel and the global shortcuts, and starts the expiry reaper.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var model: AppModel?
    private(set) var settingsController: SettingsController?
    /// Shown in the menu when the app is not fully up — most often because opening the
    /// history database is waiting on Keychain access.
    private(set) var startupMessage: String?
    private var monitor: PasteboardMonitor?
    private var reaper: ExpiryReaper?
    private var store: (any HistoryStore)?
    private var panel: PanelController?
    private var snippetWatcher: SnippetWatcher?
    private var scratchpad: ScratchpadController?
    private var edgeTrigger: EdgeTrigger?
    private var onboardingWindow: NSWindow?
    private var pasteStackHUD: PasteStackHUD?
    private var statusMenu: StatusMenu?
    private var settingsWindow: SettingsWindowController?
    /// Hot-key registrations held only while the paste stack is switched on.
    private var pasteStackHotKeys: [UInt32] = []
    private(set) var otpModel: OTPModel?
    private var todoModel: TodoModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no menu bar of its own.
        NSApp.setActivationPolicy(.accessory)
        // Never drawn, but AppKit matches key events against it — which is the only way
        // ⌘A, ⌘C, ⌘X and ⌘Z reach a focused text field.
        NSApp.mainMenu = MainMenu.make()

        let settingsController = SettingsController()
        self.settingsController = settingsController

        startupMessage = String(localized: "Starting…")
        statusMenu = StatusMenu(owner: self)
        refreshStatusMenu()
        probeMainActorExecutor()
        Task { await start(with: settingsController) }
    }

    /// Checks that main-actor tasks actually run in this process.
    ///
    /// Almost everything Recall does is dispatched with `Task { @MainActor in … }` — every
    /// hot key, every menu item, every captured clip. If the main executor is not
    /// servicing them the app looks alive and does nothing at all, which is a very
    /// expensive thing to diagnose from the outside. One line in the log settles it.
    private func probeMainActorExecutor() {
        let ran = ExecutorProbe()
        Task { @MainActor in
            ran.value = true
            Log.ui.info("Main-actor task ran")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if !ran.value {
                Log.ui.fault("Main-actor tasks are NOT running; the app will appear dead")
            }
        }

        // `--heartbeat` keeps checking, because the failure seen in the field was tasks
        // dying *later* rather than never starting.
        guard CommandLine.arguments.contains("--heartbeat") else { return }
        Task { @MainActor in
            var beat = 0
            while true {
                try? await Task.sleep(for: .seconds(5))
                beat += 1
                Log.ui.info("Heartbeat \(beat, privacy: .public)")
            }
        }
    }

    /// Brings the menu and its icon back in step with the app's state.
    func refreshStatusMenu() {
        statusMenu?.refreshIcon(
            isPaused: model?.isCapturePaused == true,
            isStarting: startupMessage != nil
        )
        statusMenu?.rebuild()
    }

    /// Pausing and resuming go through here so the menu is rebuilt with them.
    func pauseCapture(_ duration: PauseDuration) {
        model?.pauseCapture(for: duration)
        refreshStatusMenu()
    }

    func resumeCapture() {
        model?.resumeCapture()
        refreshStatusMenu()
    }

    /// Brings the app up.
    ///
    /// The store is opened off the main thread on purpose: unlocking the encryption key
    /// can put a Keychain dialog in front of the user, and doing that synchronously in
    /// `applicationDidFinishLaunching` wedges the whole app — no menu, no capture, no way
    /// to answer the prompt. Found by running the app, not by a test.
    private func start(with settingsController: SettingsController) async {
        var settings = settingsController.settings
        // `--in-memory` forces RAM-only storage for a run. Useful for testing without
        // touching the encryption key, and strictly the safer of the two modes.
        if CommandLine.arguments.contains("--in-memory") {
            settings.storageMode = .inMemory
            Log.ui.info("Forced in-memory storage for this run")
        }
        // `--demo-store` is for recording: a throwaway history that is still disk-backed.
        // Not a `StorageMode` case, because that enum is a persisted user setting and this
        // is a switch for one run.
        let demo = CommandLine.arguments.contains("--demo-store")
        if demo {
            Log.ui.info("Using a throwaway demo store for this run")
        }
        let watchdog = startWatchdog()

        do {
            let opened = try await Self.openStore(mode: settings.storageMode, demo: demo)

            watchdog.cancel()
            finishLaunching(opened: opened, settings: settings, settingsController: settingsController)
            startupMessage = nil
            refreshStatusMenu()
        } catch {
            watchdog.cancel()
            Log.ui.fault("Launch failed: \(String(describing: error), privacy: .public)")
            startupMessage = String(localized: "Recall could not open its history: \(String(describing: error))")
            refreshStatusMenu()
        }
    }

    /// A real thread of its own for opening the store, and it has to be.
    ///
    /// This used to be `Task.detached`, which runs on Swift's **cooperative** pool. That
    /// pool is sized to the core count and must never be blocked: unlocking the
    /// encryption key can sit in a synchronous Keychain call for as long as it takes the
    /// user to answer a dialog, and parking a cooperative thread there wedged the whole
    /// concurrency runtime. The symptom was an app that launched, drew its menu, and then
    /// silently did nothing — every hot key, menu item and captured clip goes through
    /// `Task { @MainActor in … }`, and none of them ever ran again.
    ///
    /// A plain GCD queue is built for exactly this: blocking calls on threads that are
    /// allowed to block.
    private static let storeQueue = DispatchQueue(label: "com.recall.store-open", qos: .userInitiated)

    private static func openStore(mode: StorageMode, demo: Bool = false) async throws -> OpenedStore {
        try await withCheckedThrowingContinuation { continuation in
            storeQueue.async {
                do {
                    if demo {
                        // A temporary database with an ephemeral key: real history is not
                        // touched, the Keychain is not consulted, and it goes away with the
                        // temporary directory.
                        //
                        // Deliberately *not* `.inMemory`, which looks like the obvious
                        // choice for a throwaway run and is a trap: `SemanticSearch` is only
                        // built when there is a `SQLiteHistoryStore`, so in-memory mode
                        // silently downgrades search to literal matching — with no warning
                        // anywhere, which cost a demo recording to find.
                        let sqlite = try SQLiteHistoryStore(url: nil, keyStore: EphemeralKeyStore())
                        continuation.resume(returning: OpenedStore(store: sqlite, todos: sqlite, sqlite: sqlite))
                        return
                    }
                    switch mode {
                    case .persistent:
                        let sqlite = try SQLiteHistoryStore(url: try SQLiteHistoryStore.defaultURL())
                        continuation.resume(returning: OpenedStore(store: sqlite, todos: sqlite, sqlite: sqlite))
                    case .inMemory:
                        // In-Memory Mode: no database file, no blob directory, no key.
                        // There is nothing to encrypt because there is nothing on disk.
                        let memory = InMemoryHistoryStore()
                        continuation.resume(returning: OpenedStore(store: memory, todos: memory, sqlite: nil))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// If opening the store takes this long, it is almost certainly sitting on a Keychain
    /// prompt. Say so in the menu rather than looking broken.
    private func startWatchdog() -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.startupMessage = String(localized: "Waiting for permission to use your keychain…")
            self?.refreshStatusMenu()
        }
    }

    private struct OpenedStore: Sendable {
        let store: any HistoryStore
        /// The same store as ``store``: todos follow the storage mode, so they are sealed
        /// in the same database or held in the same RAM.
        let todos: any TodoStore
        let sqlite: SQLiteHistoryStore?
    }

    private func finishLaunching(
        opened: OpenedStore,
        settings: RecallSettings,
        settingsController: SettingsController
    ) {
        let store = opened.store
        self.store = store

        var semanticSearch: SemanticSearch?
        if let sqlite = opened.sqlite, settings.semanticSearchEnabled, let provider = try? NLEmbeddingProvider() {
            // Expansion is what makes "CSS rounding" find border-radius: sentence
            // embeddings alone score that pair below unrelated code. Measured in
            // RankingEvalTests.
            semanticSearch = SemanticSearch(
                store: sqlite,
                provider: provider,
                expander: LanguageModelQueryExpander()
            )
            Log.ui.info("Semantic search is on")
        }

        // Search silently degrading to literal matching is invisible from the outside: the
        // panel still returns results, they are just worse. Say which of the three
        // conditions failed, because guessing costs more than the line.
        if semanticSearch == nil {
            let reason: String
            if opened.sqlite == nil {
                reason = "no SQLite store (in-memory mode disables semantic search)"
            } else if !settings.semanticSearchEnabled {
                reason = "turned off in settings"
            } else {
                reason = "no embedding provider available"
            }
            Log.ui.info("Semantic search is OFF: \(reason, privacy: .public)")
        }

        let capture = CaptureService(settings: settings)
        let monitor = PasteboardMonitor { [weak self] snapshot in
            Task { @MainActor in
                await self?.model?.handle(snapshot: snapshot, using: capture)
            }
        }

        // One PasteService, shared: the monitor has to be told about the writes we make
        // ourselves, or Recall re-captures everything it pastes.
        let pasteService = PasteService()
        pasteService.willWriteToPasteboard = { [weak monitor] in monitor?.beginSelfWrite() }
        pasteService.didWriteToPasteboard = { [weak monitor] in monitor?.endSelfWrite() }

        let model = AppModel(
            store: store,
            semanticSearch: semanticSearch,
            intelligence: IntelligenceService(settings: settings),
            paste: pasteService,
            settings: settings
        )
        self.model = model

        // Snippet expansion is the one feature behind an event tap, so it stays off until
        // the user asks for it and stops the moment they change their mind.
        let watcher = SnippetWatcher(paste: pasteService)
        watcher.textForSnippet = { [weak model] id in model?.snippetText(for: id) }
        self.snippetWatcher = watcher

        model.onSnippetsChanged = { [weak watcher] items in
            Log.paste.info("Shortcode table now has \(items.count, privacy: .public) code(s)")
            watcher?.update(expander: SnippetExpander(items: items))
        }
        if settings.snippetExpansionEnabled {
            applySnippetSetting(true)
        }

        // Load the shortcode table now.
        //
        // `onSnippetsChanged` only fires from a reload, and nothing reloaded at launch —
        // the first one was whenever the user happened to open the panel or copy
        // something. Until then the watcher was running with an empty table, so a
        // shortcode typed straight after login expanded into nothing. It also warms the
        // pins, which the rail wants before it is first drawn.
        Task { @MainActor in await model.reload() }

        // Settings changes reach the running app immediately; only the storage mode
        // needs a relaunch, and the Settings window says so.
        settingsController.onChange = { [weak self, weak model] updated in
            model?.apply(updated)
            self?.applySnippetSetting(updated.snippetExpansionEnabled)
            self?.applyEdgeSetting(updated)
            if let model {
                self?.applyPasteStackSetting(updated.pasteStackEnabled, model: model)
            }
        }

        // The two-factor helper is a separate, sandboxed process: seeds live there and
        // never cross into Recall, which is unsandboxed by necessity (ADR 0003) and can
        // hold an event tap. Recall only ever receives six digits.
        let otpModel = OTPModel(paste: pasteService)
        self.otpModel = otpModel

        model.onTwoFactorLinkCopied = { [weak otpModel] uri in
            otpModel?.pendingImportURI = uri
        }

        // Settings is Recall's window like every other surface it shows.
        let settingsWindow = SettingsWindowController { [weak self] in
            SettingsView(
                controller: settingsController,
                otp: otpModel,
                usageProvider: { await self?.model?.usage() },
                snippetProvider: {
                    (self?.model?.snippets ?? []).compactMap { item in
                        item.snippetCode.map { (code: $0, title: item.railTitle) }
                    }
                }
            )
        }
        self.settingsWindow = settingsWindow
        SettingsNavigator.shared.presenter = { [weak settingsWindow] tab in
            settingsWindow?.show(tab: tab)
        }

        let todoModel = TodoModel(store: opened.todos, isInMemory: opened.sqlite == nil)
        todoModel.pasteClip = { [weak model] id in await model?.pasteClip(id: id) ?? false }
        self.todoModel = todoModel

        let panel = PanelController { HistoryPanelView(model: model, otp: otpModel, todos: todoModel) }
        self.panel = panel

        // Pasting has to land in the app the user was in, not in Recall. The model asks
        // the panel to step aside and hand focus back first.
        model.dismissPanel = { [weak panel] in panel?.hide() }
        // Closing the panel spends the authentication that revealed a code.
        panel.onHide = { [weak otpModel] in otpModel?.forgetCodes() }
        panel.onShow = { [weak model] in model?.panelDidOpen() }
        otpModel.dismissPanel = { [weak panel] in panel?.hide() }
        todoModel.dismissPanel = { [weak panel] in panel?.hide() }
        // A Touch ID prompt takes key from the panel; without this the panel hides
        // itself mid-prompt and the app looks like it fell over.
        otpModel.onAuthenticationPrompt = { [weak panel] isPrompting in
            panel?.suppressesAutoHide = isPrompting
        }

        model.pasteCoordinator = { [weak panel] paste in
            guard let panel, panel.isVisible else {
                paste()
                return
            }
            panel.hideAndRestoreFocus(completion: paste)
        }

        monitor.start()
        self.monitor = monitor

        // The scratchpad is the same list with the opposite instinct to the panel: it
        // stays put for an hour of moving text between two documents.
        let scratchpad = ScratchpadController { ScratchpadView(model: model) }
        self.scratchpad = scratchpad

        let edgeTrigger = EdgeTrigger(
            policy: Self.edgePolicy(for: settings),
            isPanelVisible: { [weak panel, weak scratchpad] in
                (panel?.isVisible ?? false) || (scratchpad?.isVisible ?? false)
            },
            action: { [weak panel] in panel?.show() }
        )
        self.edgeTrigger = edgeTrigger
        applyEdgeSetting(settings)

        // The stack's readout follows the stack: visible while it has anything in it,
        // gone the moment it drains or expires.
        let hud = PasteStackHUD { PasteStackHUDView(model: model) }
        self.pasteStackHUD = hud
        // A timed pause ends on its own, so the icon has to follow the model rather
        // than only the menu actions that started it.
        model.onCapturePauseChanged = { [weak self, weak monitor] pause in
            pause.isPaused ? monitor?.pause() : monitor?.resume()
            self?.refreshStatusMenu()
        }

        model.onPasteStackChanged = { [weak hud] stack in
            stack.isEmpty ? hud?.hide() : hud?.show()
        }

        registerHotKeys(model: model, panel: panel)

        let reaper = ExpiryReaper(store: store, interval: 5)
        Task { await reaper.start() }
        self.reaper = reaper

        presentOnboardingIfNeeded(settingsController: settingsController, paste: pasteService)

        // `--show-panel` opens the panel a moment after launch. The panel is otherwise
        // only reachable by a global hot key or a menu click, neither of which a test can
        // drive without Accessibility, and "the hot key does nothing" has been the hardest
        // thing on this project to observe.
        // `--show-settings` exists for the same reason as `--show-panel`: Settings is
        // only reachable through a menu click, which cannot be driven without
        // Accessibility, so without this the window could not be tested at all.
        if CommandLine.arguments.contains("--show-settings") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                SettingsNavigator.shared.open(.intelligence)
            }
        }

        // Exercises the import path end to end with a throwaway account — everything
        // the Add button does except the click. The secret is the public RFC test
        // vector, and the account is removed again immediately.
        if CommandLine.arguments.contains("--test-import") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let otp = self.otpModel else { return }
                let uri = "otpauth://totp/selftest%40example.com?secret=JBSWY3DPEHPK3PXP"
                    + "&issuer=RecallSelfTest&algorithm=SHA1&digits=6&period=30"
                Log.ui.info("Import self-test: calling importURI")
                let count = await otp.importURI(uri)
                Log.ui.info("Import self-test: imported \(count, privacy: .public), failure: \(otp.failure ?? "none", privacy: .public)")
                if let added = otp.accounts.first(where: { $0.issuer == "RecallSelfTest" }) {
                    await otp.remove(added)
                    Log.ui.info("Import self-test: cleaned up")
                }
            }
        }

        // `--show-todos` opens the panel on the Todos tab, for the same reason.
        if CommandLine.arguments.contains("--show-todos") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                Log.ui.info("Opening the todos tab because --show-todos was passed")
                self.showTodos()
            }
        }

        if CommandLine.arguments.contains("--show-codes") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                Log.ui.info("Opening the codes tab because --show-codes was passed")
                self.showCodes()
            }
        }

        // Pins the newest clip, reports what the store then thinks, and puts it back.
        // Exercises everything ⌘P does except the keystroke — which is the part that
        // cannot be driven without Accessibility, and the part a unit test cannot reach.
        if CommandLine.arguments.contains("--test-pin") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                guard let model = self.model else { return }
                await model.reload()
                guard let item = model.items.first else {
                    Log.ui.error("Pin self-test: no items")
                    return
                }
                Log.ui.info("Pin self-test: pinning \(item.id, privacy: .public)")
                await model.togglePin(item)
                Log.ui.info("Pin self-test: pins now \(model.pins.count, privacy: .public)")

                if let pinned = model.pins.first(where: { $0.id == item.id }) {
                    await model.togglePin(pinned)
                    Log.ui.info("Pin self-test: cleaned up, pins now \(model.pins.count, privacy: .public)")
                } else {
                    Log.ui.error("Pin self-test: the pin did not take")
                }
            }
        }

        // `--show-diff` opens the panel and compares the two most recent clips that can
        // be compared. Same reason as the flags above: a sheet reached by selecting one
        // row, pressing a shortcut, selecting another and pressing it again is not
        // something that can be driven without Accessibility.
        if CommandLine.arguments.contains("--show-diff") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.showPanel()
                // Hold the panel open. A script that drives this flag gives focus back to
                // its own shell as soon as it has launched the app, and the panel hides on
                // losing key — which it did, 0.3 seconds before this ran, leaving the
                // sheet nothing to attach to and the flag doing nothing at all.
                self.panel?.suppressesAutoHide = true
                try? await Task.sleep(for: .seconds(1))
                guard let model = self.model else { return }
                let comparable = model.items.filter(\.isComparable).prefix(2)
                guard comparable.count == 2 else {
                    Log.ui.error("Diff self-test: needs two comparable clips, found \(comparable.count, privacy: .public)")
                    return
                }
                Log.ui.info("Diff self-test: comparing the two most recent clips")
                model.compare(comparable[comparable.startIndex], with: comparable[comparable.index(after: comparable.startIndex)])
            }
        }

        // Shows the panel, closes it, and shows it again. The difference between a first
        // open and a reopen is where several bugs have lived — `task` and `onAppear` fire
        // only the first time — and one open on its own never shows them.
        if CommandLine.arguments.contains("--reopen-panel") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                self.panel?.suppressesAutoHide = true
                self.showPanel()
                try? await Task.sleep(for: .seconds(2))
                Log.ui.info("Reopen test: hiding")
                self.panel?.hide()
                try? await Task.sleep(for: .seconds(1))
                Log.ui.info("Reopen test: showing again")
                self.showPanel()
            }
        }

        if CommandLine.arguments.contains("--show-panel") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                Log.ui.info("Opening the panel because --show-panel was passed")
                self.showPanel()
            }
        }

        Task {
            // Anything left over from a previous run that has since expired goes now.
            try? await store.purgeExpired(asOf: .now)
            try? await store.enforceRetention(
                limit: settings.historyLimit,
                olderThan: settings.retention.map { Date.now.addingTimeInterval(-$0) }
            )
            await model.backfillEmbeddings(limit: 500)
        }
    }

    /// ⌘⇧V opens the panel; ⌘⇧1–9 paste pinned slots without opening anything, which is
    /// the fastest path in the app and the main reason to pin something.
    private func registerHotKeys(model: AppModel, panel: PanelController) {
        HotKeyCenter.shared.register(.showPanel) { [weak panel] in
            guard let panel else {
                Log.ui.error("Show-panel hot key fired but the panel controller is gone")
                return
            }
            panel.toggle()
        }

        // ⌥⌘V — the scratchpad, from anywhere.
        HotKeyCenter.shared.register(.showScratchpad) { [weak self] in
            self?.toggleScratchpad()
        }

        // ⌘⇧A — straight to the codes, without going through history first.
        HotKeyCenter.shared.register(.showCodes) { [weak self] in
            self?.showCodes()
        }

        // ⌥⌘⇧2 — region capture straight to text. Sits beside the system's own
        // screenshot shortcuts rather than on top of one of them.
        HotKeyCenter.shared.register(.captureText) { [weak model] in
            Task { @MainActor in await model?.captureTextFromScreen() }
        }

        // ⌃⌥⌘C queues, ⌃⌥⌘V pastes the next one — registered only while the feature is
        // on, so a switched-off feature is not holding a system-wide chord hostage.
        applyPasteStackSetting(model.settings.pasteStackEnabled, model: model)

        // ⌥⇧⌘P — pause and resume without going to the menu bar, for the moment just
        // before you copy something you would rather Recall did not keep.
        HotKeyCenter.shared.register(.togglePause) { [weak model] in
            Task { @MainActor in model?.toggleCapturePause() }
        }

        for slot in 1...9 {
            guard let hotKey = HotKey.pinnedSlot(slot) else { continue }
            HotKeyCenter.shared.register(hotKey) { [weak model] in
                Task { @MainActor in await model?.pastePinnedSlot(slot) }
            }
        }
    }

    /// Claims or releases the paste stack's two shortcuts.
    private func applyPasteStackSetting(_ isEnabled: Bool, model: AppModel) {
        guard isEnabled != !pasteStackHotKeys.isEmpty else { return }

        for id in pasteStackHotKeys { HotKeyCenter.shared.unregister(id) }
        pasteStackHotKeys = []

        guard isEnabled else { return }

        let add = HotKeyCenter.shared.register(.addToStack) { [weak model] in
            Task { @MainActor in await model?.addMostRecentToPasteStack() }
        }
        let paste = HotKeyCenter.shared.register(.pasteFromStack) { [weak model] in
            Task { @MainActor in await model?.pasteNextFromStack() }
        }
        pasteStackHotKeys = [add, paste].compactMap { $0 }
    }

    /// Turns edge triggering on or off, and keeps its policy in step with settings.
    private func applyEdgeSetting(_ settings: RecallSettings) {
        guard let edgeTrigger else { return }

        guard settings.activation == .hotkeyAndScreenEdge else {
            edgeTrigger.stop()
            return
        }
        edgeTrigger.update(policy: Self.edgePolicy(for: settings))
        edgeTrigger.start()
    }

    private static func edgePolicy(for settings: RecallSettings) -> EdgeTriggerPolicy {
        var policy = EdgeTriggerPolicy()
        policy.edge = settings.screenEdge
        policy.dwell = settings.edgeTriggerDwell
        return policy
    }

    /// Starts or stops the snippet watcher, and asks for Accessibility the first time —
    /// only ever in response to the user turning the feature on.
    private func applySnippetSetting(_ isEnabled: Bool) {
        guard let snippetWatcher else { return }

        guard isEnabled else {
            snippetWatcher.stop()
            return
        }

        if snippetWatcher.start() == .needsAccessibilityPermission {
            model?.paste.requestAccessibilityPermission()
            startupMessage = String(localized: "Snippet expansion needs Accessibility permission.")
        }
    }

    func showPanel() {
        guard let panel else {
            Log.ui.error("Show panel asked for before the panel existed")
            return
        }
        panel.show()
    }

    /// True when the user asked for launch at login but macOS is still waiting on them.
    var loginItemNeedsApproval: Bool {
        LoginItem.state == .awaitingApproval
    }

    func toggleScratchpad() {
        scratchpad?.toggle()
    }

    /// Explains the two permissions before macOS asks for either of them.
    private func presentOnboardingIfNeeded(settingsController: SettingsController, paste: PasteService) {
        guard !settingsController.settings.hasCompletedOnboarding else { return }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Welcome to Recall")
        window.contentView = NSHostingView(
            rootView: OnboardingView(controller: settingsController, paste: paste)
        )
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    func showCodes() {
        model?.panelTab = .codes
        panel?.show()
        Task { [weak otpModel] in await otpModel?.refresh() }
    }

    func showTodos() {
        model?.panelTab = .todos
        panel?.show()
    }

    func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear clipboard history?")
        alert.informativeText = String(localized: "Everything except pinned items will be deleted. This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Clear"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.alertStyle = .warning

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { [weak model] in await model?.clearUnpinned() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        edgeTrigger?.stop()
        HotKeyCenter.shared.unregisterAll()
        // In-Memory Mode's guarantee: history dies with the process. A persistent store
        // gets one last expiry sweep on the way out.
        if let store {
            Task { try? await store.purgeExpired(asOf: .now) }
        }
    }
}

/// A box so the probe's two halves can share one flag without capturing the delegate.
private final class ExecutorProbe: @unchecked Sendable {
    var value = false
}

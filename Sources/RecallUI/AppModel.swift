import AppKit
import Foundation
import Observation
import RecallCapture
import RecallCore
import RecallEnrichment
import RecallIntelligence
import RecallPaste
import RecallStorage
import SwiftUI

/// The single object the UI observes: it owns the store, drives capture, and exposes the
/// visible slice of history.
///
/// Everything here is main-actor; the stores and services it talks to are actors, so the
/// UI never blocks on SQLite or on the model.
@MainActor
@Observable
public final class AppModel {
    public private(set) var items: [ClipItem] = []
    /// The pinned group, in the order the user put them in. Kept separate from ``items``
    /// because the rail stays visible while a search filters the list below it.
    public private(set) var pins: [ClipItem] = []
    public var searchText: String = "" {
        didSet { scheduleReload() }
    }
    public var selectedKind: ClipKind? {
        didSet { scheduleReload() }
    }
    /// The Smart Collection being viewed, if any.
    public var selectedCollection: SmartCollection? {
        didSet { scheduleReload() }
    }
    /// Items currently being enriched in the background, so a row can say it is thinking
    /// rather than sitting there looking like it has no summary.
    public private(set) var enrichingItemIDs: Set<UUID> = []
    public var selection: UUID?
    public private(set) var settings: RecallSettings
    public private(set) var isModelAvailable: Bool
    /// Called when the user copies a two-factor setup link, so the Codes tab can offer
    /// to import it. The link itself is never stored.
    public var onTwoFactorLinkCopied: ((String) -> Void)?
    /// Items queued for sequential pasting. Empty unless the user turned the feature on
    /// and explicitly added something.
    public private(set) var pasteStack = PasteStack()
    /// Called when the stack changes, so the HUD can appear and disappear with it.
    public var onPasteStackChanged: ((PasteStack) -> Void)?

    /// Bumped every time the panel is shown.
    ///
    /// A counter, not a flag: two opens in a row have to register as two, and a flag that
    /// has to be reset afterwards is a flag that will one day not be.
    public private(set) var panelOpenCount = 0

    /// Which half of the panel is showing. Held here so ⌘⇧A can switch a panel that is
    /// already open rather than building a second one.
    public var panelTab: PanelTab = .history
    /// Set to open the shortcode sheet for an item, from wherever the user asked.
    public var snippetSheetTarget: ClipItem?
    /// Items carrying a snippet shortcode.
    public private(set) var snippets: [ClipItem] = []
    /// Called when the shortcode table changes, so the watcher can be rebuilt.
    public var onSnippetsChanged: (([ClipItem]) -> Void)?
    /// Progress of the background embedding backfill, for the panel's quiet indicator.
    public private(set) var indexingRemaining = 0
    /// Set when the user pins something while history is RAM-only, so the panel can say
    /// once that the pin will not survive a quit.
    public var showsInMemoryPinNotice = false
    /// Supplied by the app: hides the panel and restores focus to the previous app before
    /// the paste goes out. Without it, pasting still copies — it just does not type.
    public var pasteCoordinator: (@MainActor (@escaping @MainActor () -> Void) -> Void)?
    /// Supplied by the app: closes the panel.
    ///
    /// `@Environment(\.dismiss)` does nothing here — the panel is an `NSPanel` hosting a
    /// SwiftUI view, not a presented one, so there is nothing for SwiftUI to dismiss. The
    /// view has to be handed the real thing.
    public var dismissPanel: (@MainActor () -> Void)?

    /// Whether recording is paused, and until when. Starts every launch as recording:
    /// see ``CapturePause``.
    public private(set) var capturePause = CapturePause()
    /// Supplied by the app: starts and stops the pasteboard monitor to match.
    public var onCapturePauseChanged: ((CapturePause) -> Void)?

    private let store: any HistoryStore
    private let semanticSearch: SemanticSearch?
    private let queryParser = QueryParser()
    private let intelligence: IntelligenceService
    private let enrichment: EnrichmentPipeline
    /// Exposed so the app can ask for Accessibility when the user turns on expansion.
    public let paste: PasteService
    private let regionCapture = RegionCapture()
    private var reloadTask: Task<Void, Never>?
    /// Fires when a timed pause runs out.
    private var resumeTask: Task<Void, Never>?

    public init(
        store: any HistoryStore,
        semanticSearch: SemanticSearch? = nil,
        intelligence: IntelligenceService = IntelligenceService(),
        enrichment: EnrichmentPipeline = EnrichmentPipeline(enrichers: [LinkEnricher(), ImageTextEnricher()]),
        paste: PasteService,
        settings: RecallSettings = .default
    ) {
        self.store = store
        self.semanticSearch = semanticSearch
        self.intelligence = intelligence
        self.enrichment = enrichment
        self.paste = paste
        self.settings = settings
        self.isModelAvailable = intelligence.isModelAvailable
    }

    // MARK: - Loading

    public var isInMemoryMode: Bool {
        settings.storageMode == .inMemory
    }

    /// Picks up a settings change without a relaunch. Storage mode is the exception and
    /// is flagged in the Settings window as needing one.
    public func apply(_ settings: RecallSettings) {
        self.settings = settings
        if let selectedCollection, !settings.collections.contains(where: { $0.id == selectedCollection.id }),
           selectedCollection.id != SmartCollection.pinned.id {
            self.selectedCollection = nil
        }
        scheduleReload()
    }

    public func reload() async {
        // `kind:image app:Xcode since:yesterday` is lifted out first; whatever is left is
        // the actual search text.
        let parsed = queryParser.parse(searchText)
        var query = parsed.applied(to: selectedCollection?.query() ?? HistoryQuery())
        query.limit = 200
        if let selectedKind {
            query.kinds = [selectedKind]
        }

        do {
            if let semanticSearch, settings.semanticSearchEnabled, let text = parsed.text {
                var base = query
                base.text = nil
                items = try await semanticSearch.search(text, base: base).map(\.item)
            } else {
                items = try await store.items(matching: query)
            }
            pins = try await store.items(matching: HistoryQuery(pinnedOnly: true, limit: 50))
            let currentSnippets = try await store.snippets()
            if currentSnippets.map(\.snippetCode) != snippets.map(\.snippetCode) {
                snippets = currentSnippets
                onSnippetsChanged?(currentSnippets)
            } else {
                snippets = currentSnippets
            }
            if selection == nil || !items.contains(where: { $0.id == selection }) {
                selection = items.first?.id
            }
        } catch {
            Log.ui.error("Reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Debounces reloads so typing in the search field does not run a query per keystroke.
    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    // MARK: - Capture

    /// Entry point for the pasteboard monitor.
    public func handle(snapshot: PasteboardSnapshot, using capture: CaptureService) async {
        switch capture.makeItem(from: snapshot) {
        case .failure(.twoFactorSecret):
            // Not stored anywhere. Offered to the helper, which is the only process that
            // may hold a seed.
            if let text = snapshot.plainText?.trimmingCharacters(in: .whitespacesAndNewlines) {
                onTwoFactorLinkCopied?(text)
            }
        case .failure(let reason):
            Log.capture.debug("Ignored clip: \(reason.rawValue, privacy: .public)")
        case .success(let item):
            do {
                let outcome = try await store.capture(item)
                await reload()
                // Kind and counts only — never content. Enough to tell from a log whether
                // capture is alive, which has been worth a great deal to know.
                Log.capture.info("Captured a \(item.kind.rawValue, privacy: .public) clip")
                if case .inserted(let stored) = outcome {
                    enrichInBackground(stored)
                }
            } catch {
                Log.capture.error("Capture failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Metadata, OCR, summary, tags and the embedding, all after the item is already
    /// visible. Secrets are skipped: they are about to be deleted anyway, and running a
    /// model over them would be exactly the wrong thing to do.
    private func enrichInBackground(_ item: ClipItem) {
        guard item.sensitivity == .normal else { return }
        enrichingItemIDs.insert(item.id)

        // Read here, on the main actor, and carried into the detached task. Both of these
        // preferences were being ignored entirely: "Fetch titles and icons for copied
        // links" and "Read text in copied images" were wired to nothing, so the network
        // request happened whatever the user had chosen.
        let disabled = disabledEnrichers

        Task.detached(priority: .utility) { [store, enrichment, intelligence, semanticSearch] in
            var enriched = await enrichment.enrich(item, disabled: disabled)

            if let text = enriched.payload.searchableText ?? enriched.ocrText {
                enriched.summary = try? await intelligence.summarize(text)
                if let tags = try? await intelligence.tags(for: text) {
                    enriched.tags.formUnion(tags)
                }
            }

            // Merged onto the row as it stands, not written over it. `enriched` grew
            // from a copy taken before the pass started, and by now it can be a minute
            // old — writing it whole put back `isPinned: false` and `snippetCode: nil`
            // from before the user had touched either. That is why a pin set on a clip
            // you had just copied did not survive: enrichment landed a few seconds later
            // and quietly undid it.
            try? await store.applyEnrichment(ClipEnrichment(of: enriched), to: item.id)
            await semanticSearch?.indexPending()
            await MainActor.run { [weak self] in
                self?.enrichingItemIDs.remove(item.id)
                Task { await self?.reload() }
            }
        }
    }

    // MARK: - Comparing two clips

    /// The clip a comparison is anchored to, once one has been marked with ⌘D.
    ///
    /// Held rather than derived, because the two halves of a comparison are chosen one
    /// after the other: there is a moment where the user has said "this one" and not yet
    /// said what to compare it against. The panel shows a banner for exactly that moment.
    public var comparisonAnchor: ClipItem?

    /// The pair being shown in the diff sheet: older first, whichever order they were
    /// picked in.
    public var comparison: ClipComparison?

    public var isComparing: Bool { comparisonAnchor != nil }

    /// ⌘D. Marks the selection, or compares it against what is already marked.
    ///
    /// - Returns: false when there is nothing to do, so the key can fall through rather
    ///   than being swallowed with no visible effect.
    @discardableResult
    public func compareSelection() -> Bool {
        guard let item = selectedItem, item.isComparable else { return false }

        guard let anchor = comparisonAnchor else {
            comparisonAnchor = item
            return true
        }
        // ⌘D twice on the same clip un-marks it, rather than opening a diff of something
        // against itself.
        guard anchor.id != item.id else {
            comparisonAnchor = nil
            return true
        }

        comparison = ClipComparison(anchor, item)
        comparisonAnchor = nil
        return true
    }

    /// Compares two clips chosen directly, which is what the context menu does.
    public func compare(_ one: ClipItem, with other: ClipItem) {
        guard one.isComparable, other.isComparable, one.id != other.id else { return }
        comparison = ClipComparison(one, other)
        comparisonAnchor = nil
    }

    public func cancelComparison() {
        comparisonAnchor = nil
    }

    /// Told by the panel controller on every open, including reopens.
    public func panelDidOpen() {
        panelOpenCount += 1
    }

    /// Enrichers the current settings switch off.
    private var disabledEnrichers: Set<String> {
        var disabled: Set<String> = []
        if !settings.enrichLinks { disabled.insert(EnricherID.link) }
        if !settings.ocrImages { disabled.insert(EnricherID.imageText) }
        return disabled
    }

    // MARK: - Actions

    public var selectedItem: ClipItem? {
        items.first { $0.id == selection }
    }

    public func paste(_ item: ClipItem, style: PasteStyle = .original) async {
        // The full payload may be a blob on disk; the list rows are not hydrated.
        let full = (try? await store.item(id: item.id)) ?? item

        if let pasteCoordinator {
            await withCheckedContinuation { continuation in
                pasteCoordinator {
                    self.paste.paste(full, style: style)
                    continuation.resume()
                }
            }
        } else {
            paste.paste(full, style: style)
        }

        try? await store.markUsed(id: item.id, at: .now)
        Log.paste.info("Pasted a \(item.kind.rawValue, privacy: .public) clip")
        await reload()
    }

    /// Pastes pinned slot `slot` (1-based), for ⌘1–9 in the panel and ⌘⇧1–9 globally.
    public func pastePinnedSlot(_ slot: Int) async {
        guard slot >= 1, slot <= pins.count else { return }
        await paste(pins[slot - 1])
    }

    /// Moves `item` into pinned slot `slot` (1-based), pinning it first if needed.
    ///
    /// Slots are positions in the pinned group, not a fixed grid: assigning slot 3 to an
    /// item moves it there and shuffles the rest along, which is what dragging it would
    /// have done.
    public func assignPinnedSlot(_ slot: Int, to item: ClipItem) async {
        guard slot >= 1 else { return }

        if !item.isPinned {
            try? await store.setPinned(true, id: item.id)
            await reload()
        }

        var order = pins.map(\.id)
        order.removeAll { $0 == item.id }
        order.insert(item.id, at: min(slot - 1, order.count))
        await reorderPins(order)
    }

    /// Moves the pinned group into `order`.
    public func reorderPins(_ order: [UUID]) async {
        try? await store.reorderPins(order)
        await reload()
    }

    public func applyTransform(_ transform: ClipTransform, to item: ClipItem) async {
        guard item.sensitivity != .secret else { return }
        guard let text = item.payload.searchableText ?? item.ocrText else { return }
        do {
            let result = try await intelligence.apply(transform, to: text)
            await paste(item, style: .transformed(result))
        } catch {
            Log.intelligence.error("Transform \(transform.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Pinning is the user overruling the app: a pinned item is never removed
    /// automatically, so pinning a detected secret cancels its countdown rather than
    /// deleting it out from under them. Unpinning starts a fresh countdown instead of
    /// deleting on the spot — no action should destroy data as a side effect.
    public func togglePin(_ item: ClipItem) async {
        let pinning = !item.isPinned

        if var updated = try? await store.item(id: item.id) {
            if pinning, updated.sensitivity == .secret {
                updated.expiresAt = nil
                try? await store.update(updated)
            } else if !pinning, updated.sensitivity == .secret, updated.expiresAt == nil {
                updated.expiresAt = Date.now.addingTimeInterval(settings.secretTimeToLive)
                try? await store.update(updated)
            }
        }

        do {
            try await store.setPinned(pinning, id: item.id)
        } catch {
            // This was `try?`. Pinning is a thing the user asked for and can see the
            // result of, so a failure that leaves no trace anywhere is the worst possible
            // way for it to go wrong.
            Log.ui.error("Pinning failed: \(String(describing: error), privacy: .public)")
        }

        if pinning, isInMemoryMode {
            showsInMemoryPinNotice = true
        }
        await reload()
    }

    public func delete(_ item: ClipItem) async {
        try? await store.delete(id: item.id)
        await reload()
    }

    public func deleteAll() async {
        try? await store.deleteAll()
        await reload()
    }

    /// Clears history but keeps pins — "clear history" must never be the thing that
    /// deletes something the user explicitly kept.
    public func clearUnpinned() async {
        do {
            let everything = try await store.items(matching: HistoryQuery(limit: .max))
            for item in everything where !item.isPinned {
                try await store.delete(id: item.id)
            }
        } catch {
            Log.ui.error("Clearing history failed: \(String(describing: error), privacy: .public)")
        }
        await reload()
    }

    /// Streams a transform's output for the "Paste as…" sheet.
    public func streamTransform(
        _ transform: ClipTransform,
        for item: ClipItem,
        argument: String? = nil
    ) -> AsyncThrowingStream<String, any Error> {
        // Guardrail: a detected credential never reaches the model.
        guard item.sensitivity != .secret, let text = item.payload.searchableText ?? item.ocrText else {
            return AsyncThrowingStream { $0.finish() }
        }
        return intelligence.stream(transform, over: text, argument: argument)
    }

    public enum SnippetAssignment: Equatable, Sendable {
        case assigned
        case invalidCode
        case alreadyUsed(by: String)
    }

    /// Gives `item` a shortcode, or clears it when `code` is nil.
    ///
    /// A shortcode has to be unique, and taking one silently from another item would mean
    /// a snippet the user set up stops working with no explanation — so a clash is
    /// reported rather than resolved.
    @discardableResult
    public func assignSnippetCode(_ code: String?, to item: ClipItem) async -> SnippetAssignment {
        guard var updated = try? await store.item(id: item.id) else { return .invalidCode }

        guard let code else {
            updated.snippetCode = nil
            try? await store.update(updated)
            await reload()
            return .assigned
        }

        let normalized = code.trimmingCharacters(in: .whitespaces)
        guard SnippetExpander.isValid(code: normalized) else { return .invalidCode }

        if let clash = snippets.first(where: { $0.snippetCode == normalized && $0.id != item.id }) {
            return .alreadyUsed(by: clash.railTitle)
        }

        updated.snippetCode = normalized
        try? await store.update(updated)
        await reload()
        return .assigned
    }

    // MARK: - Pausing capture

    public var isCapturePaused: Bool { capturePause.isPaused }

    /// What the menu bar says while paused, or nil while recording.
    public var capturePauseStatus: String? { capturePause.statusText(at: .now) }

    /// Stops recording for `duration`.
    public func pauseCapture(for duration: PauseDuration, now: Date = .now) {
        var pause = capturePause
        pause.pause(duration, now: now)
        applyCapturePause(pause, now: now)
    }

    public func resumeCapture() {
        var pause = capturePause
        pause.resume()
        applyCapturePause(pause, now: .now)
    }

    public func toggleCapturePause() {
        capturePause.isPaused ? resumeCapture() : pauseCapture(for: .indefinitely)
    }

    private func applyCapturePause(_ pause: CapturePause, now: Date) {
        resumeTask?.cancel()
        resumeTask = nil

        capturePause = pause
        onCapturePauseChanged?(pause)

        // A timed pause ends on its own. The deadline is the source of truth — the task
        // only re-reads it — so a sleep that wakes late or early cannot leave the app
        // paused for the wrong length of time.
        guard let remaining = pause.remaining(at: now) else { return }
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            guard let self, self.capturePause.isPaused else { return }
            self.resumeCapture()
        }
    }

    // MARK: - Paste stack

    public var pasteStackCount: Int { pasteStack.count }

    /// Label for the next item, for the HUD.
    public var pasteStackNextTitle: String? {
        guard let id = pasteStack.next else { return nil }
        return items.first { $0.id == id }?.railTitle
    }

    /// Queues an item. Off unless the setting is on, so ⌃⌥⌘C does nothing surprising to
    /// someone who never asked for a stack.
    public func addToPasteStack(_ item: ClipItem) {
        guard settings.pasteStackEnabled else { return }
        // A detected credential is not something to queue up and fire later.
        guard item.sensitivity != .secret else { return }

        pasteStack.add(item.id)
        onPasteStackChanged?(pasteStack)
    }

    /// Queues whatever was copied most recently — what ⌃⌥⌘C means when the panel is shut.
    public func addMostRecentToPasteStack() async {
        guard settings.pasteStackEnabled else { return }
        await reload()
        guard let newest = items.first else { return }
        addToPasteStack(newest)
    }

    /// Pastes the next queued item, removing it from the stack.
    public func pasteNextFromStack() async {
        guard settings.pasteStackEnabled else { return }
        guard let id = pasteStack.takeNext() else {
            onPasteStackChanged?(pasteStack)
            return
        }
        onPasteStackChanged?(pasteStack)

        guard let item = try? await store.item(id: id) else { return }
        await paste(item)
    }

    public func clearPasteStack() {
        pasteStack.clear()
        onPasteStackChanged?(pasteStack)
    }

    /// How much history there is, and what it occupies on disk.
    public func usage() async -> (count: Int, bytes: Int64)? {
        guard let count = try? await store.count, let bytes = try? await store.footprint else { return nil }
        return (count, bytes)
    }

    /// Full bytes for an item whose payload may have been offloaded to the blob store.
    /// Used by drag-and-drop, which must hand over the real image rather than a thumbnail.
    public func hydratedPayloadData(for item: ClipItem) async -> Data? {
        guard let full = try? await store.item(id: item.id) else { return nil }
        if case .image(let image) = full.payload {
            return image.data.isEmpty ? image.previewData : image.data
        }
        return full.payload.searchableText.map { Data($0.utf8) }
    }

    /// Text a snippet expands to, looked up by the watcher.
    public func snippetText(for id: UUID) -> String? {
        snippets.first { $0.id == id }?.payload.searchableText
    }

    /// Drags out a region of the screen, reads the text in it, and puts that on the
    /// clipboard *and* into history.
    ///
    /// The captured image is kept alongside the text: OCR is a guess, and when it guesses
    /// wrong the user still needs the picture.
    public func captureTextFromScreen() async {
        do {
            let result = try await regionCapture.captureRegion()

            let payload: ClipPayload = if let text = result.text, !text.isEmpty {
                .text(text)
            } else {
                .image(result.image)
            }

            var item = ClipItem(
                payload: payload,
                contentHash: ContentHash(payload),
                source: SourceApp(bundleIdentifier: nil, localizedName: String(localized: "Screen Capture")),
                createdAt: .now
            )
            // Text lifted off the screen keeps the image it came from, so the row can show
            // what was actually captured.
            if case .text = payload {
                item.ocrText = result.text
            }

            // Paused means paused: the text still reaches the clipboard, because the
            // user asked for it explicitly, but nothing is written to history while the
            // menu bar is saying Recall is not recording.
            if capturePause.isCapturing(at: .now) {
                try await store.capture(item)
            }
            // Written with the monitor muted: this is already in history, and capturing it
            // a second time from our own write would duplicate it.
            paste.write(item, style: .original)
            await reload()
        } catch RegionCapture.Failure.cancelled {
            // A cancel is a decision. Nothing to report, nothing left behind.
        } catch {
            Log.capture.error("Screen capture failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Runs the embedding backfill and keeps the progress figure current.
    public func backfillEmbeddings(limit: Int = 200) async {
        guard let semanticSearch else { return }
        await semanticSearch.indexPending(limit: limit)
        indexingRemaining = await semanticSearch.indexingProgress.remaining
        await reload()
    }

    /// The collections to show in the sidebar.
    public var collections: [SmartCollection] {
        settings.collections.filter(\.isEnabled)
    }

    public func isEnriching(_ item: ClipItem) -> Bool {
        enrichingItemIDs.contains(item.id)
    }

    public func transforms(for item: ClipItem) -> [ClipTransform] {
        guard isModelAvailable, item.sensitivity != .secret else { return [] }
        return ClipTransform.available(for: item.kind)
    }
}

/// Which half of the panel is showing.
public enum PanelTab: String, Hashable, Sendable {
    case history
    case codes
}

import RecallCore
import RecallPaste
import SwiftUI

/// The history panel: one search field, one list, and the selected item opening in place.
///
/// Single column on purpose. This is a window you summon, glance at and dismiss inside two
/// seconds, and the previous three-pane layout spent most of a 720×480 frame on chrome —
/// a tab picker, a search bar, a pinned rail and a row of filter chips stacked above a
/// list that had to share what was left with a sidebar and a detail pane. Everything that
/// is not the list is now either one control in the search bar or one line in the footer.
public struct HistoryPanelView: View {
    @Bindable private var model: AppModel
    private let otp: OTPModel?
    private let todos: TodoModel?
    @FocusState private var searchFocused: Bool
    @State private var transformTarget: ClipItem?
    @State private var pageMetrics = PageMetrics()
    /// The row whose detail is open. Usually the selection, but a click opens it a moment
    /// later than it selects — see ``selectionChanged(to:proxy:)``.
    @State private var expandedID: UUID?
    /// Set by a click on a row just before it changes the selection, so the change can
    /// tell a click from an arrow key.
    @State private var clickedID: UUID?
    @State private var pendingExpansion: Task<Void, Never>?
    /// Replaces the item count in the footer for a moment, to confirm something that
    /// happened out of sight — a todo made from a clip lands in another tab.
    @State private var footerNotice: String?
    @State private var footerNoticeTask: Task<Void, Never>?

    public init(model: AppModel, otp: OTPModel? = nil, todos: TodoModel? = nil) {
        self.model = model
        self.otp = otp
        self.todos = todos
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar

            if model.panelTab == .codes, let otp {
                Divider()
                CodesView(model: otp)
            } else if model.panelTab == .todos, let todos {
                Divider()
                TodosView(model: todos, openCount: model.panelOpenCount)
            } else {
                history
            }
        }
        // One surface for the whole panel, because that is what the panel *is*: a sheet
        // floating over whatever you were working in. Controls inside stay standard —
        // stacking glass on glass muddies both layers and is the usual way this material
        // is overdone.
        .glassSurface(settings: model.settings)
        // Above the branch, so ⌃⇥ works from every tab. The per-tab handlers below only
        // ever see their own part.
        .onKeyPress(phases: .down) { handle($0) }
        // …and a real shortcut as well, because `onKeyPress` never sees Tab: SwiftUI
        // takes it for focus navigation before any handler runs. A keyboard shortcut goes
        // through the menu system instead, which gets first refusal on the event.
        .background(tabShortcut)
        .frame(minWidth: 520, minHeight: 420)
        .task {
            await model.reload()
            searchFocused = true
        }
        .sheet(item: $transformTarget) { item in
            TransformSheet(item: item, model: model)
        }
        .sheet(item: $model.snippetSheetTarget) { item in
            SnippetSheet(item: item, model: model)
        }
        .sheet(item: $model.comparison) { comparison in
            DiffView(comparison: comparison, model: model) { model.comparison = nil }
        }
    }

    /// ⌃⇥, as an invisible command rather than a key handler. See ``body``.
    @ViewBuilder
    private var tabShortcut: some View {
        if hasTabs {
            Button("Switch Tab") { toggleTab() }
                .keyboardShortcut(.tab, modifiers: .control)
                .hidden()
        }
    }

    private var hasTabs: Bool {
        otp != nil || todos != nil
    }

    private func toggleTab() {
        guard hasTabs else { return }
        model.panelTab = model.panelTab.next(hasCodes: otp != nil, hasTodos: todos != nil)
    }

    private var history: some View {
        VStack(spacing: 0) {
            if model.isCapturePaused {
                pausedBanner
            }
            if let anchor = model.comparisonAnchor {
                comparisonBanner(anchor)
            }

            // Pins stay out of the way of a search: once you are typing, the thing you
            // are looking for is in the results, not the rail.
            if !model.pins.isEmpty, model.searchText.isEmpty {
                Divider()
                PinnedRailView(model: model)
            }

            Divider()
            list
            Divider()
            footer
        }
        // The caret belongs in the search field on *every* open, not just the first.
        //
        // `task` and `onAppear` run once: the panel and its hosting view are built once
        // and reused, so after a single click on a row the focus stayed in the list for
        // the rest of the session and reopening gave you nowhere to type.
        .onChange(of: model.panelOpenCount) { focusSearch() }
        // The search field only exists on this tab, so coming back to it is another
        // moment the caret has to be put back.
        .onChange(of: model.panelTab) { _, tab in
            if tab == .history { focusSearch() }
        }
        // Also on the container: once a click moves focus into the list, key presses stop
        // reaching the search field's handler.
        .onKeyPress(phases: .down) { handle($0) }
    }

    /// Puts the caret in the search field, in two steps and not immediately.
    ///
    /// Two steps because `FocusState` can still read `true` while the real first responder
    /// is the list — AppKit moved it without telling SwiftUI — and setting a flag to the
    /// value it already holds does nothing at all. Not immediately because the panel is
    /// not reliably key at the moment `show()` returns, and a focus request made before
    /// then is dropped on the floor.
    private func focusSearch() {
        searchFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            searchFocused = true
        }
    }

    /// Pastes whatever is selected. The Return key, and the double-click that used to be
    /// the only way to act on a row.
    private func pasteSelection() {
        guard let item = model.selectedItem else { return }
        Task { await paste(item) }
    }

    // MARK: - Search bar

    /// One bar, tall enough to be the obvious place to start typing.
    private var searchBar: some View {
        HStack(spacing: 10) {
            // History's own controls, on History only. On the other tabs a search field
            // would filter a list nobody can see, and each of them has a field of its own.
            if model.panelTab == .history {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.tertiary)

                TextField("Search history", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onKeyPress(phases: .down) { handle($0) }
                    // A TextField swallows Return before `onKeyPress` sees it, so the most
                    // important key in the panel needs its own hook.
                    .onSubmit { pasteSelection() }

                if model.indexingRemaining > 0 {
                    ProgressView()
                        .controlSize(.small)
                        .help("Indexing \(model.indexingRemaining) item(s) for search by meaning")
                }
                if model.isModelAvailable {
                    // A button, not a badge. It sits in a row of controls and is shaped like
                    // one, so doing nothing when clicked reads as broken.
                    Button {
                        SettingsNavigator.shared.open(.intelligence)
                    } label: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Search by meaning and AI actions are on. Click for Intelligence settings.")
                }

                filterMenu
            } else {
                Spacer()
            }

            if hasTabs {
                Picker("", selection: $model.panelTab) {
                    Image(systemName: "clock.arrow.circlepath").tag(PanelTab.history)
                    if otp != nil {
                        Image(systemName: "lock.shield").tag(PanelTab.codes)
                    }
                    if todos != nil {
                        Image(systemName: "checklist").tag(PanelTab.todos)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("History, two-factor codes or todos (⌃⇥)")
            }
        }
        // The same height on every tab, so switching does not move everything below.
        .frame(minHeight: 26)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        // The search bar is the panel's title bar — there is no other, since the window
        // is borderless. `isMovableByWindowBackground` only catches the gaps between
        // controls; this makes the whole strip a handle.
        .contentShape(.rect)
        .gesture(WindowDragGesture())
    }

    /// Kinds and collections in one control.
    ///
    /// They were a row of chips and a sidebar — two bands of chrome for two filters that
    /// are almost never changed, and never both at once.
    private var filterMenu: some View {
        Menu {
            Picker("Collection", selection: collectionSelection) {
                Label("All", systemImage: "tray.full").tag(UUID?.none)
                ForEach(model.collections) { collection in
                    Label(collection.displayName, systemImage: collection.systemImage)
                        .tag(Optional(collection.id))
                }
                Label(SmartCollection.pinned.displayName, systemImage: SmartCollection.pinned.systemImage)
                    .tag(Optional(SmartCollection.pinned.id))
            }
            .pickerStyle(.inline)

            Picker("Kind", selection: $model.selectedKind) {
                Text("Any Kind").tag(ClipKind?.none)
                ForEach(ClipKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: kind.systemImage)
                        .tag(Optional(kind))
                }
            }
            .pickerStyle(.inline)

            if isFiltered {
                Divider()
                Button("Clear Filters") {
                    model.selectedKind = nil
                    model.selectedCollection = nil
                }
            }
        } label: {
            Label(filterLabel, systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill"
                                                       : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter by collection or kind")
    }

    private var isFiltered: Bool {
        model.selectedKind != nil || model.selectedCollection != nil
    }

    private var filterLabel: String {
        if let collection = model.selectedCollection { return collection.displayName }
        if let kind = model.selectedKind { return kind.displayName }
        return String(localized: "All")
    }

    private var collectionSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedCollection?.id },
            set: { id in
                guard let id else {
                    model.selectedCollection = nil
                    return
                }
                if id == SmartCollection.pinned.id {
                    model.selectedCollection = .pinned
                    return
                }
                model.selectedCollection = model.collections.first { $0.id == id }
            }
        )
    }

    /// The panel is where you would first notice history has stopped growing, so it says
    /// why, and offers the way out without a trip to the menu bar.
    private var pausedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
            Text(model.capturePauseStatus ?? String(localized: "Paused"))
                .font(.callout)
            Spacer()
            Button("Resume") { model.resumeCapture() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.yellow.opacity(0.15))
    }

    /// Shown between marking a clip and choosing what to compare it against.
    ///
    /// The marked clip leaves no trace in the list itself — a second highlight beside the
    /// selection would be two kinds of "chosen" on screen at once — so this line is the
    /// only thing saying the panel is in the middle of something, and it says what to do
    /// next rather than only what has happened.
    private func comparisonBanner(_ anchor: ClipItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
            Text("Comparing with “\(Self.shortLabel(for: anchor))” — pick another clip and press ⌘D")
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Button("Cancel") { model.cancelComparison() }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.blue.opacity(0.15))
    }

    /// Enough of a clip to recognise which one it is, on one line.
    static func shortLabel(for item: ClipItem) -> String {
        let text = ItemRowView.singleLine(item.comparableText) ?? item.kind.rawValue
        return text.count > 32 ? String(text.prefix(32)) + "…" : text
    }

    // MARK: - List

    private var list: some View {
        // A List does not follow a selection that changed programmatically, so arrowing
        // past the bottom of the window moved an invisible selection. The proxy scrolls
        // it back into view.
        ScrollViewReader { proxy in
            rows
                // Reopening should show where the arrows will start from. The selection
                // survives a close, but the scroll position does not necessarily point at
                // it any more, and an arrow key that appears to jump from nowhere reads
                // as the selection having been lost.
                .onChange(of: model.panelOpenCount) {
                    guard let selected = model.selection else { return }
                    proxy.scrollTo(selected)
                }
                .onChange(of: model.selection, initial: true) { _, selected in
                    selectionChanged(to: selected, proxy: proxy)
                }
        }
    }

    /// Opens the selected row's detail — at once from the keyboard, and after the
    /// double-click interval from a click.
    ///
    /// Opening it at once on a click moved the row out from under the pointer before the
    /// second click of a double-click arrived: the detail that was open above collapsed,
    /// up to 220 points of list went with it, and the new detail opened where the row had
    /// been. The second click landed in that detail's text and did nothing. Waiting out
    /// the interval keeps the layout still until a double-click can no longer be coming.
    private func selectionChanged(to selected: UUID?, proxy: ScrollViewProxy) {
        pendingExpansion?.cancel()
        let byClick = selected != nil && selected == clickedID
        clickedID = nil

        guard byClick else {
            expandedID = selected
            reveal(selected, proxy: proxy)
            return
        }
        pendingExpansion = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, model.selection == selected else { return }
            expandedID = selected
            reveal(selected, proxy: proxy)
        }
    }

    /// No anchor: scroll the least that brings the row into view, rather than recentring
    /// the list under the pointer on every keystroke.
    private func reveal(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            proxy.scrollTo(id)
        }
    }

    private var rows: some View {
        List(model.items, selection: $model.selection) { item in
            VStack(alignment: .leading, spacing: 0) {
                // The tap gesture belongs to the row itself, not to the row *and* the
                // detail under it. Covering both meant a click anywhere in the open
                // detail pasted and closed the panel — so text in there could be read
                // but never selected.
                ItemRowView(
                    item: item,
                    isThinking: model.isEnriching(item),
                    density: model.settings.rowDensity,
                    showsSourceIcon: model.settings.showsSourceIcons
                )
                .contentShape(.rect)
                // The row alone, not the detail under it: paging walks over rows that are
                // closed, and only the selected one is open.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    pageMetrics.rowHeights[item.id] = height
                }
                .itemDragProvider(item, model: model)
                // First click selects and opens the detail below; the second pastes.
                //
                // Pasting on the first click was quicker and gave no chance to look
                // before committing — and a clipboard manager is mostly used when you are
                // *not* certain which of five similar-looking clips you want.
                // `.contentShape` is what makes the whole row clickable rather than just
                // the pixels the text happens to cover.
                .onTapGesture {
                    guard model.selection == item.id else {
                        clickedID = item.id
                        model.selection = item.id
                        return
                    }
                    Task { await paste(item) }
                }

                // The detail opens under the row it belongs to rather than in a pane that
                // is empty most of the time.
                if item.id == expandedID {
                    DetailView(item: item, model: model, isEmbedded: true)
                        .frame(maxHeight: 220, alignment: .top)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            .tag(item.id)
            .id(item.id)
            .contextMenu { contextMenu(for: item) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            pageMetrics.viewportHeight = height
        }
        .animation(.easeOut(duration: 0.12), value: expandedID)
        .overlay {
            if model.items.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? "Nothing copied yet" : "No matches",
                    systemImage: "doc.on.clipboard",
                    description: Text(model.searchText.isEmpty
                        ? "Copy something and it will show up here."
                        : "Try describing what you copied instead of quoting it.")
                )
            }
        }
    }

    // MARK: - Footer

    /// The shortcuts that were scattered through the old chrome, in one quiet line.
    private var footer: some View {
        HStack(spacing: 12) {
            Text(countText)
            Spacer()
            ForEach(Self.hints, id: \.keys) { hint in
                HStack(spacing: 3) {
                    // Monospaced for key glyphs only. The monospaced face has no Persian
                    // or Chinese letters, and falling back glyph by glyph spaced a word
                    // out letter by letter.
                    Text(hint.keys).monospaced(hint.isGlyphs)
                    Text(hint.action)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private static let hints: [(keys: String, action: String, isGlyphs: Bool)] = [
        ("↩", String(localized: "paste", comment: "Footer hint: what Return does"), true),
        // Worth saying out loud: the second click used to be the first.
        (String(localized: "click ×2", comment: "Footer hint: a double click"), String(localized: "paste", comment: "Footer hint: what Return does"), false),
        ("⌘Y", String(localized: "preview", comment: "Footer hint: what ⌘Y does"), true),
        ("⌘P", String(localized: "pin", comment: "Footer hint: what ⌘P does"), true),
        ("⌘D", String(localized: "compare", comment: "Footer hint: what ⌘D does"), true),
        ("⇥", String(localized: "kind", comment: "Footer hint: Tab cycles the kind filter"), true),
        ("⌃⇥", String(localized: "codes", comment: "Footer hint: ⌃⇥ switches to two-factor codes"), true),
    ]

    private var countText: String {
        footerNotice ?? String(localized: "\(model.items.count) items")
    }

    private func showFooterNotice(_ notice: String) {
        footerNotice = notice
        footerNoticeTask?.cancel()
        footerNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            footerNotice = nil
        }
    }

    /// ⌘T. Makes a todo from the clip, and says so, since the todo appears in a tab that
    /// is not the one on screen.
    private func addToTodos(_ item: ClipItem) {
        guard let todos else { return }
        Task {
            switch await todos.add(from: item) {
            case .added:
                showFooterNotice(String(localized: "Added to Todos"))
            case .alreadyThere:
                showFooterNotice(String(localized: "Already in Todos"))
            case .refused:
                break
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button("Paste") { Task { await paste(item) } }
        Button("Paste as Plain Text") { Task { await paste(item, style: .plainText) } }

        if item.sensitivity != .secret {
            Button("Quick Look") {
                Task { await QuickLookPresenter.shared.toggle(item, using: model) }
            }
            .keyboardShortcut("y", modifiers: .command)
        }

        let transforms = model.transforms(for: item)
        if !transforms.isEmpty {
            Menu("Paste as…") {
                ForEach(transforms) { transform in
                    Button(transform.title, systemImage: transform.systemImage) {
                        Task { await model.applyTransform(transform, to: item) }
                    }
                }
            }
        }

        if todos != nil, item.sensitivity == .normal {
            Button("Add to Todos") { addToTodos(item) }
                .keyboardShortcut("t", modifiers: .command)
        }

        if model.settings.pasteStackEnabled {
            Button("Add to Paste Stack") { model.addToPasteStack(item) }
                .keyboardShortcut("c", modifiers: [.command, .option, .control])
        }

        if item.isComparable {
            if let anchor = model.comparisonAnchor, anchor.id != item.id {
                Button("Compare with \(Self.shortLabel(for: anchor))") {
                    model.compare(anchor, with: item)
                }
            } else if let selected = model.selectedItem, selected.id != item.id, selected.isComparable {
                Button("Compare with \(Self.shortLabel(for: selected))") {
                    model.compare(selected, with: item)
                }
            } else {
                Button("Compare With…") { model.comparisonAnchor = item }
                    .keyboardShortcut("d", modifiers: .command)
            }
        }

        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") { Task { await model.togglePin(item) } }
            .keyboardShortcut("p", modifiers: .command)
        Button(item.snippetCode == nil ? "Add Shortcode…" : "Edit Shortcode (\(item.snippetCode ?? ""))…") {
            model.snippetSheetTarget = item
        }
        .disabled(item.payload.searchableText == nil)
        Button("Delete", role: .destructive) { Task { await model.delete(item) } }
    }

    // MARK: - Keyboard

    /// Turns a keystroke into a ``PanelCommand`` and performs it. The mapping itself
    /// lives in ``PanelKeyboard`` so it can be tested without a running app.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let key = PanelKey(press) else { return .ignored }
        let command = PanelKeyboard.command(
            for: key,
            modifiers: PanelModifiers(press.modifiers),
            isSearching: !model.searchText.isEmpty,
            isComparing: model.isComparing
        )
        guard let command else { return .ignored }
        // Above the branch, this handler sees keys from every tab. The others deal with
        // their own, and from here only get ⌃⇥ — or ⌘P on the Codes tab pins a clip
        // nobody can see.
        guard model.panelTab == .history || command == .switchTab else { return .ignored }
        return perform(command)
    }

    private func perform(_ command: PanelCommand) -> KeyPress.Result {
        switch command {
        case .moveSelection(let offset):
            return moveSelection(by: offset)

        case .movePage(let direction):
            return movePage(direction: direction)

        case .moveToFirst:
            return moveSelection(to: 0)

        case .moveToLast:
            return moveSelection(to: model.items.count - 1)

        case .cycleKind(let offset):
            return cycleKind(by: offset)

        case .dismiss:
            model.dismissPanel?()
            return .handled

        case .paste(let plainText):
            guard let item = model.selectedItem else { return .ignored }
            Task { await paste(item, style: plainText ? .plainText : .original) }
            return .handled

        case .transform:
            guard let item = model.selectedItem else { return .ignored }
            transformTarget = item
            return .handled

        case .compare:
            return model.compareSelection() ? .handled : .ignored

        case .cancelComparison:
            model.cancelComparison()
            return .handled

        case .clearSearch:
            model.searchText = ""
            return .handled

        case .delete:
            guard let item = model.selectedItem else { return .ignored }
            Task { await model.delete(item) }
            return .handled

        case .togglePin:
            guard let item = model.selectedItem else { return .ignored }
            Task { await model.togglePin(item) }
            return .handled

        case .pasteSlot(let slot):
            Task {
                await model.pastePinnedSlot(slot)
                model.dismissPanel?()
            }
            return .handled

        case .assignSlot(let slot):
            guard let item = model.selectedItem else { return .ignored }
            Task { await model.assignPinnedSlot(slot, to: item) }
            return .handled

        case .quickLook:
            guard let item = model.selectedItem else { return .ignored }
            Task { await QuickLookPresenter.shared.toggle(item, using: model) }
            return .handled

        case .switchTab:
            guard hasTabs else { return .ignored }
            toggleTab()
            return .handled

        case .addToTodos:
            guard todos != nil, let item = model.selectedItem, item.sensitivity == .normal else { return .ignored }
            addToTodos(item)
            return .handled
        }
    }

    private func paste(_ item: ClipItem, style: PasteStyle = .original) async {
        await model.paste(item, style: style)
        model.dismissPanel?()
    }

    private var selectedIndex: Int {
        model.items.firstIndex { $0.id == model.selection } ?? 0
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        moveSelection(to: selectedIndex + offset)
    }

    private func moveSelection(to index: Int) -> KeyPress.Result {
        guard !model.items.isEmpty else { return .ignored }
        let next = min(max(index, 0), model.items.count - 1)
        model.selection = model.items[next].id
        return .handled
    }

    private func movePage(direction: Int) -> KeyPress.Result {
        let target = PanelKeyboard.pageTarget(
            from: selectedIndex,
            direction: direction,
            rowHeights: model.items.map { pageMetrics.rowHeights[$0.id] },
            viewportHeight: pageMetrics.viewportHeight
        )
        return moveSelection(to: target)
    }

    private func cycleKind(by offset: Int) -> KeyPress.Result {
        // nil ("Any Kind") is the first stop in the cycle, then each kind in turn.
        let stops: [ClipKind?] = [nil] + ClipKind.allCases.map { $0 }
        let current = stops.firstIndex { $0 == model.selectedKind } ?? 0
        let next = (current + offset + stops.count) % stops.count
        model.selectedKind = stops[next]
        return .handled
    }
}

/// What a page is made of: the list's height and the rows' heights.
///
/// A plain class rather than state. Both change on every layout pass, and nothing on
/// screen depends on them — storing them in observed state would redraw the whole list
/// each time a row was measured, which is every time one scrolls into view.
@MainActor
private final class PageMetrics {
    var viewportHeight: CGFloat = 0
    /// Keyed by item rather than position, so a height survives the list reloading.
    var rowHeights: [UUID: CGFloat] = [:]
}

extension ClipKind {
    var displayName: String {
        switch self {
        case .text: String(localized: "Text", comment: "The kind filter: plain text clips")
        case .richText: String(localized: "Rich Text")
        case .image: String(localized: "Images")
        case .file: String(localized: "Files")
        case .url: String(localized: "Links")
        case .color: String(localized: "Colors")
        }
    }

    var systemImage: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .file: "doc"
        case .url: "link"
        case .color: "paintpalette"
        }
    }
}

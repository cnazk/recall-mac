import RecallCore
import SwiftUI

/// The Todos tab: a field to write one in, the open ones in the order you put them, and
/// the finished ones underneath until you clear them.
public struct TodosView: View {
    @Bindable private var model: TodoModel
    /// Bumped on every panel open, so the caret goes back into the field each time — the
    /// panel is built once and reused, and `task` alone would only focus it the first time.
    private let openCount: Int
    @FocusState private var draftFocused: Bool
    @FocusState private var renameFocused: Bool
    /// The todo being renamed in place, and the text it is being renamed to.
    @State private var renamingID: UUID?
    @State private var renameText = ""

    public init(model: TodoModel, openCount: Int = 0) {
        self.model = model
        self.openCount = openCount
    }

    public var body: some View {
        VStack(spacing: 0) {
            newTodoField
            Divider()
            list
            Divider()
            footer
        }
        .onKeyPress(phases: .down) { handle($0) }
        .background(pasteClipShortcut)
        .task {
            await model.reload()
            focusDraft()
        }
        .onChange(of: openCount) { focusDraft() }
    }

    // MARK: - New todo

    private var newTodoField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.title3)
                .foregroundStyle(.tertiary)
            TextField("New todo", text: $model.draft)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($draftFocused)
                .onKeyPress(phases: .down) { handle($0) }
                // A TextField swallows Return before `onKeyPress` sees it.
                .onSubmit { perform(model.draft.isEmpty ? .toggleDone : .add) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// See ``HistoryPanelView/focusSearch()`` for why this takes two steps and a pause.
    private func focusDraft() {
        draftFocused = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            draftFocused = true
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            List(selection: $model.selection) {
                Section {
                    ForEach(model.openTodos) { todo in
                        row(todo)
                    }
                    .onMove { source, destination in
                        Task { await model.moveOpen(fromOffsets: source, toOffset: destination) }
                    }
                }

                if !model.doneTodos.isEmpty {
                    Section {
                        ForEach(model.doneTodos) { todo in
                            row(todo)
                        }
                    } header: {
                        HStack {
                            Text("Done")
                            Spacer()
                            Button("Clear") { Task { await model.clearCompleted() } }
                                .buttonStyle(.link)
                                .help("Delete every finished todo")
                        }
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .onChange(of: model.selection) { _, selected in
                guard let selected else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(selected) }
            }
            .overlay {
                if model.todos.isEmpty {
                    ContentUnavailableView(
                        "Nothing to do",
                        systemImage: "checklist",
                        description: Text("Type a todo above, or press ⌘T on a clip in History.")
                    )
                }
            }
        }
    }

    private func row(_ todo: TodoItem) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await model.toggleDone(todo) }
            } label: {
                Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.isDone ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isDone ? Text("Mark as Not Done") : Text("Mark as Done"))

            if renamingID == todo.id {
                TextField("Todo", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(todo) }
                    .onKeyPress(.escape) {
                        endRename()
                        return .handled
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename(todo) }
                    }
            } else {
                Text(todo.title)
                    .lineLimit(2)
                    .strikethrough(todo.isDone)
                    .foregroundStyle(todo.isDone ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { beginRename(todo) }
            }

            if todo.sourceItemID != nil {
                Button {
                    Task { await model.pasteLinkedClip(of: todo) }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Paste the clip this came from (⌘↩)")
            }
        }
        .padding(.vertical, 2)
        .tag(todo.id)
        .id(todo.id)
        .contextMenu { contextMenu(for: todo) }
    }

    @ViewBuilder
    private func contextMenu(for todo: TodoItem) -> some View {
        Button(todo.isDone ? "Mark as Not Done" : "Mark as Done") {
            Task { await model.toggleDone(todo) }
        }
        Button("Rename") { beginRename(todo) }
        if todo.sourceItemID != nil {
            Button("Paste Clip") { Task { await model.pasteLinkedClip(of: todo) } }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.delete(todo) } }
    }

    private func beginRename(_ todo: TodoItem) {
        model.selection = todo.id
        renameText = todo.title
        renamingID = todo.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            renameFocused = true
        }
    }

    private func commitRename(_ todo: TodoItem) {
        guard renamingID == todo.id else { return }
        let text = renameText
        endRename()
        Task { await model.rename(todo, to: text) }
    }

    private func endRename() {
        renamingID = nil
        focusDraft()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.openTodos.count) to do")
            }
            if model.isInMemory {
                Image(systemName: "memorychip")
                    .help("In-Memory Mode is on: todos are erased when Recall quits.")
            }
            Spacer()
            ForEach(hints, id: \.keys) { hint in
                HStack(spacing: 3) {
                    Text(hint.keys).monospaced()
                    Text(hint.action)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// Only the keys that would do something right now: Return means "add" while there
    /// is something typed and "done" otherwise, and ⌘↩ is only offered for a todo that
    /// has a clip to paste.
    private var hints: [(keys: String, action: String)] {
        if !model.draft.isEmpty {
            return [("↩", String(localized: "add", comment: "Todos footer hint: Return adds the typed todo"))]
        }
        guard let selected = model.selectedTodo else { return [] }

        var hints = [("↩", String(localized: "done", comment: "Todos footer hint: Return ticks off the selected todo"))]
        if selected.sourceItemID != nil {
            hints.append(("⌘↩", String(localized: "paste clip", comment: "Todos footer hint: ⌘Return pastes the clip a todo came from")))
        }
        hints.append(("⌫", String(localized: "delete", comment: "Todos footer hint: what ⌫ does")))
        return hints
    }

    // MARK: - Keyboard

    /// ⌘↩, as a command rather than a key handler: the field swallows Return, modified or
    /// not, before `onKeyPress` runs.
    private var pasteClipShortcut: some View {
        Button("Paste Clip") { perform(.pasteClip) }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Renaming owns the keyboard until it ends.
        guard renamingID == nil, let key = PanelKey(press) else { return .ignored }
        let command = TodoKeyboard.command(
            for: key,
            modifiers: PanelModifiers(press.modifiers),
            hasDraft: !model.draft.isEmpty
        )
        guard let command else { return .ignored }
        perform(command)
        return .handled
    }

    private func perform(_ command: TodoCommand) {
        let todos = model.todos
        let index = todos.firstIndex { $0.id == model.selection } ?? 0

        switch command {
        case .moveSelection(let offset):
            guard !todos.isEmpty else { return }
            model.selection = todos[min(max(index + offset, 0), todos.count - 1)].id
        case .moveToFirst:
            model.selection = todos.first?.id
        case .moveToLast:
            model.selection = todos.last?.id
        case .add:
            Task { await model.addDraft() }
        case .toggleDone:
            guard let todo = model.selectedTodo else { return }
            Task { await model.toggleDone(todo) }
        case .pasteClip:
            guard let todo = model.selectedTodo else { return }
            Task { await model.pasteLinkedClip(of: todo) }
        case .delete:
            guard let todo = model.selectedTodo else { return }
            Task { await model.delete(todo) }
        case .clearDraft:
            model.draft = ""
        case .dismiss:
            model.dismissPanel?()
        }
    }
}

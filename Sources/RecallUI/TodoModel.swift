import Foundation
import Observation
import RecallCore
import RecallStorage

/// What the Todos tab observes: the list, the new-todo field, and the selection.
@MainActor
@Observable
public final class TodoModel {
    public private(set) var todos: [TodoItem] = []
    /// The new-todo field.
    public var draft = ""
    public var selection: UUID?
    /// One line for the footer when something did not go as asked — said out loud rather
    /// than leaving a click that looks like it did nothing.
    public private(set) var notice: String?
    /// Whether the todos will be gone at quit, which the tab says once, in the footer.
    public let isInMemory: Bool
    /// Supplied by the app: pastes the clip with this id, or returns false when history
    /// no longer has it.
    public var pasteClip: (@MainActor (UUID) async -> Bool)?
    /// Supplied by the app: closes the panel.
    public var dismissPanel: (@MainActor () -> Void)?

    private let store: any TodoStore
    private var noticeTask: Task<Void, Never>?

    public init(store: any TodoStore, isInMemory: Bool = false) {
        self.store = store
        self.isInMemory = isInMemory
    }

    public var openTodos: [TodoItem] { todos.filter { !$0.isDone } }
    public var doneTodos: [TodoItem] { todos.filter(\.isDone) }

    public var selectedTodo: TodoItem? {
        todos.first { $0.id == selection }
    }

    public func reload() async {
        do {
            todos = try await store.todos()
        } catch {
            Log.ui.error("Loading todos failed: \(String(describing: error), privacy: .public)")
        }
        if selection == nil || !todos.contains(where: { $0.id == selection }) {
            selection = todos.first?.id
        }
    }

    // MARK: - Adding

    /// Adds whatever is in the new-todo field, and empties it.
    @discardableResult
    public func addDraft() async -> Bool {
        guard await add(title: draft) != nil else { return false }
        draft = ""
        return true
    }

    /// Adds a todo at the top of the open ones — where the field it was typed into is —
    /// and selects it.
    @discardableResult
    public func add(title: String, sourceItemID: UUID? = nil, now: Date = .now) async -> TodoItem? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let top = openTodos.map(\.order).min() ?? TodoItem.orderSpacing
        let todo = TodoItem(
            title: title,
            createdAt: now,
            order: top - TodoItem.orderSpacing,
            sourceItemID: sourceItemID
        )
        guard await save(todo) else { return nil }
        selection = todo.id
        return todo
    }

    public enum ClipAddition: Equatable, Sendable {
        case added
        /// An open todo was already made from this clip; it is selected instead.
        case alreadyThere
        /// A detected credential, or a clip with nothing to call it by.
        case refused
    }

    /// Makes a todo from a clip, linked back to it.
    ///
    /// A detected secret is refused, as it is by the transforms and the paste stack: a
    /// credential is not something to leave lying in a list for later, and the clip it
    /// would point at is due to delete itself within the minute.
    @discardableResult
    public func add(from clip: ClipItem) async -> ClipAddition {
        guard clip.sensitivity == .normal, let title = TodoItem.title(from: clip.railTitle) else {
            return .refused
        }
        await reload()
        if let existing = openTodos.first(where: { $0.sourceItemID == clip.id }) {
            selection = existing.id
            return .alreadyThere
        }
        return await add(title: title, sourceItemID: clip.id) == nil ? .refused : .added
    }

    // MARK: - Changing

    /// Ticks a todo off, or back on. Put back, it returns to the place it held.
    public func toggleDone(_ todo: TodoItem, now: Date = .now) async {
        var updated = todo
        updated.completedAt = todo.isDone ? nil : now
        await save(updated)
    }

    public func rename(_ todo: TodoItem, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != todo.title else { return }
        var updated = todo
        updated.title = title
        await save(updated)
    }

    /// Moves open todos, for a drag in the list. Offsets are into ``openTodos``.
    public func moveOpen(fromOffsets source: IndexSet, toOffset destination: Int) async {
        var ids = openTodos.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        do {
            try await store.reorderTodos(ids)
        } catch {
            Log.ui.error("Reordering todos failed: \(String(describing: error), privacy: .public)")
        }
        await reload()
    }

    /// Deletes a todo, and moves the selection to whatever took its place.
    public func delete(_ todo: TodoItem) async {
        let wasSelected = selection == todo.id
        let index = todos.firstIndex { $0.id == todo.id }
        do {
            try await store.deleteTodo(id: todo.id)
        } catch {
            Log.ui.error("Deleting a todo failed: \(String(describing: error), privacy: .public)")
        }
        await reload()
        if wasSelected, let index, !todos.isEmpty {
            selection = todos[min(index, todos.count - 1)].id
        }
    }

    public func clearCompleted() async {
        do {
            try await store.deleteCompletedTodos()
        } catch {
            Log.ui.error("Clearing finished todos failed: \(String(describing: error), privacy: .public)")
        }
        await reload()
    }

    // MARK: - The linked clip

    /// Pastes the clip a todo was made from.
    ///
    /// If history has since let it go, the link is dropped and the footer says why, so
    /// the next attempt is not another click that silently does nothing.
    public func pasteLinkedClip(of todo: TodoItem) async {
        guard let clipID = todo.sourceItemID, let pasteClip else { return }
        guard await pasteClip(clipID) else {
            var unlinked = todo
            unlinked.sourceItemID = nil
            await save(unlinked)
            show(String(localized: "The clip this came from is no longer in history."))
            return
        }
    }

    // MARK: - Private

    @discardableResult
    private func save(_ todo: TodoItem) async -> Bool {
        do {
            try await store.saveTodo(todo)
        } catch {
            // Not `try?`. A todo that looked saved and was not is the worst way for this
            // to go wrong.
            Log.ui.error("Saving a todo failed: \(String(describing: error), privacy: .public)")
            show(String(localized: "Recall could not save that todo."))
            return false
        }
        await reload()
        return true
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}

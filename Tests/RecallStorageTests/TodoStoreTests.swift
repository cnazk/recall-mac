import CryptoKit
import Foundation
import RecallCore
import Testing
@testable import RecallStorage

private func temporaryURL(_ suffix: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("recall-\(suffix)-\(UUID().uuidString)")
}

private let key = SymmetricKey(data: Data(repeating: 5, count: 32))

/// Both stores, so In-Memory Mode's todos behave exactly like the persistent ones.
enum TodoStoreKind: String, CaseIterable, CustomTestStringConvertible {
    case sqlite, inMemory

    var testDescription: String { rawValue }

    func make() throws -> any HistoryStore & TodoStore {
        switch self {
        case .sqlite:
            try SQLiteHistoryStore(url: nil, keyStore: EphemeralKeyStore(key: key))
        case .inMemory:
            InMemoryHistoryStore()
        }
    }
}

@Suite("Todo storage")
struct TodoStoreTests {
    @Test("Saved todos come back in display order", arguments: TodoStoreKind.allCases)
    func savesAndOrders(kind: TodoStoreKind) async throws {
        let store = try kind.make()
        try await store.saveTodo(TodoItem(title: "second", order: 2_000))
        try await store.saveTodo(TodoItem(title: "first", order: 1_000))
        try await store.saveTodo(TodoItem(title: "done", completedAt: .now, order: 0))

        #expect(try await store.todos().map(\.title) == ["first", "second", "done"])
    }

    @Test("Saving a todo again replaces it", arguments: TodoStoreKind.allCases)
    func saveReplaces(kind: TodoStoreKind) async throws {
        let store = try kind.make()
        var todo = TodoItem(title: "draft")
        try await store.saveTodo(todo)
        todo.title = "final"
        try await store.saveTodo(todo)

        #expect(try await store.todos().map(\.title) == ["final"])
    }

    @Test("Reordering moves open todos and leaves finished ones alone", arguments: TodoStoreKind.allCases)
    func reorders(kind: TodoStoreKind) async throws {
        let store = try kind.make()
        let a = TodoItem(title: "a", order: 1_000)
        let b = TodoItem(title: "b", order: 2_000)
        let done = TodoItem(title: "done", completedAt: .now, order: 3_000)
        for todo in [a, b, done] { try await store.saveTodo(todo) }

        try await store.reorderTodos([b.id, a.id, done.id])

        let todos = try await store.todos()
        #expect(todos.map(\.title) == ["b", "a", "done"])
        #expect(todos.last?.order == 3_000, "a finished todo has no place among the open ones")
    }

    @Test("Deleting one todo, and clearing the finished ones", arguments: TodoStoreKind.allCases)
    func deletes(kind: TodoStoreKind) async throws {
        let store = try kind.make()
        let keep = TodoItem(title: "keep")
        let drop = TodoItem(title: "drop")
        for todo in [keep, drop, TodoItem(title: "done 1", completedAt: .now), TodoItem(title: "done 2", completedAt: .now)] {
            try await store.saveTodo(todo)
        }

        try await store.deleteTodo(id: drop.id)
        #expect(try await store.deleteCompletedTodos() == 2)
        #expect(try await store.todos().map(\.title) == ["keep"])
    }

    @Test("Clearing history and retention never touch todos", arguments: TodoStoreKind.allCases)
    func historyPathsLeaveTodos(kind: TodoStoreKind) async throws {
        let store = try kind.make()
        let clip = ClipItem(payload: .text("call the bank"), contentHash: ContentHash(.text("call the bank")))
        try await store.capture(clip)
        try await store.saveTodo(TodoItem(title: "call the bank", sourceItemID: clip.id))

        try await store.enforceRetention(limit: 0, olderThan: .distantFuture)
        try await store.purgeExpired(asOf: .distantFuture)
        try await store.deleteAll()

        #expect(try await store.count == 0)
        let todos = try await store.todos()
        #expect(todos.map(\.title) == ["call the bank"], "a todo outlives the clip it came from")
        #expect(todos.first?.sourceItemID == clip.id)
    }

    @Test("Todos survive the store being reopened")
    func survivesReopen() async throws {
        let url = temporaryURL("todos")
        let blobs = temporaryURL("todo-blobs")
        defer { try? FileManager.default.removeItem(at: url) }

        let todo = TodoItem(title: "renew passport", completedAt: nil, order: 1_000, sourceItemID: UUID())
        do {
            let store = try SQLiteHistoryStore(url: url, keyStore: EphemeralKeyStore(key: key), blobDirectory: blobs)
            try await store.saveTodo(todo)
            try await store.checkpoint()
        }

        let reopened = try SQLiteHistoryStore(url: url, keyStore: EphemeralKeyStore(key: key), blobDirectory: blobs)
        #expect(try await reopened.todos() == [todo])
    }

    @Test("No todo text is readable in the database file")
    func sealedOnDisk() async throws {
        let url = temporaryURL("todo-sealed")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SQLiteHistoryStore(url: url, keyStore: EphemeralKeyStore(key: key), blobDirectory: temporaryURL("blobs"))
        let source = UUID()
        try await store.saveTodo(TodoItem(title: "ask-for-a-raise", sourceItemID: source))
        try await store.checkpoint()

        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("ask-for-a-raise".utf8)) == nil, "the todo must not be on disk")
        #expect(raw.range(of: Data(source.uuidString.utf8)) == nil, "nor which clip it came from")
    }
}

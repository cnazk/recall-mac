import Foundation
import RecallCore

/// Persistence for the Todos tab.
///
/// Implemented by both history stores rather than by a store of its own, so todos follow
/// the storage mode the user chose: sealed in the same database under the same key, or —
/// in In-Memory Mode — held in RAM and gone at quit, like everything else.
public protocol TodoStore: Actor {
    /// Every todo, in ``TodoItem/displayOrder(_:_:)``.
    func todos() throws -> [TodoItem]

    /// Inserts a todo, or replaces the one with the same id.
    func saveTodo(_ todo: TodoItem) throws

    /// Rewrites the order of the open todos. `ids` is the new order, first to last.
    func reorderTodos(_ ids: [UUID]) throws

    func deleteTodo(id: UUID) throws

    /// Deletes every finished todo.
    @discardableResult
    func deleteCompletedTodos() throws -> Int
}

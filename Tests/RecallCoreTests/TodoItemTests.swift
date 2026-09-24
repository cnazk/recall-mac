import Foundation
import Testing
@testable import RecallCore

@Suite("Todo items")
struct TodoItemTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Open todos come first, in the order the user put them")
    func openTodosFollowTheirOrder() {
        let second = TodoItem(title: "second", createdAt: start, order: 2_000)
        let first = TodoItem(title: "first", createdAt: start, order: 1_000)
        let done = TodoItem(title: "done", createdAt: start, completedAt: start, order: 0)

        let sorted = [done, second, first].sorted(by: TodoItem.displayOrder)
        #expect(sorted.map(\.title) == ["first", "second", "done"])
    }

    @Test("Finished todos are most recently finished first")
    func doneTodosAreNewestFirst() {
        let earlier = TodoItem(title: "earlier", completedAt: start)
        let later = TodoItem(title: "later", completedAt: start.addingTimeInterval(60))

        #expect([earlier, later].sorted(by: TodoItem.displayOrder).map(\.title) == ["later", "earlier"])
    }

    @Test("A title from a clip is one line and not a novel")
    func titleFromClip() {
        #expect(TodoItem.title(from: "  call\n\nthe   bank\t") == "call the bank")
        #expect(TodoItem.title(from: " \n ") == nil)
        #expect(TodoItem.title(from: nil) == nil)

        let long = TodoItem.title(from: String(repeating: "a", count: 5_000))
        #expect(long?.count == TodoItem.maximumTitleLength)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test("A todo sealed before a field existed still opens")
    func tolerantDecoding() throws {
        let id = UUID()
        let json = Data(#"{"id":"\#(id.uuidString)","title":"old"}"#.utf8)
        let todo = try JSONDecoder().decode(TodoItem.self, from: json)
        #expect(todo.id == id)
        #expect(todo.title == "old")
        #expect(!todo.isDone)
        #expect(todo.sourceItemID == nil)
    }
}

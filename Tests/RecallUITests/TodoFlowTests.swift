import Foundation
import RecallCore
import RecallStorage
import Testing
@testable import RecallUI

/// The part between a keystroke in the Todos tab and the store.
@Suite("Todos through the model")
@MainActor
struct TodoFlowTests {
    private func makeModel() -> (TodoModel, InMemoryHistoryStore) {
        let store = InMemoryHistoryStore()
        return (TodoModel(store: store, isInMemory: true), store)
    }

    private func clip(_ text: String, sensitivity: Sensitivity = .normal) -> ClipItem {
        var item = ClipItem(payload: .text(text), contentHash: ContentHash(.text(text)))
        item.sensitivity = sensitivity
        return item
    }

    @Test("A new todo goes on top, selected, and empties the field")
    func addsOnTop() async {
        let (model, _) = makeModel()
        model.draft = "first"
        #expect(await model.addDraft())
        model.draft = "  second \n"
        #expect(await model.addDraft())

        #expect(model.todos.map(\.title) == ["second", "first"])
        #expect(model.selection == model.todos.first?.id)
        #expect(model.draft.isEmpty)
    }

    @Test("A blank todo is not added, and the field keeps what was typed")
    func refusesBlank() async {
        let (model, _) = makeModel()
        model.draft = "   "
        #expect(await model.addDraft() == false)
        #expect(model.todos.isEmpty)
        #expect(model.draft == "   ")
    }

    @Test("Ticked off and back on, a todo returns to where it was")
    func toggleKeepsPlace() async throws {
        let (model, _) = makeModel()
        for title in ["c", "b", "a"] { await model.add(title: title) }
        let b = try #require(model.todos.first { $0.title == "b" })

        await model.toggleDone(b)
        #expect(model.openTodos.map(\.title) == ["a", "c"])
        #expect(model.doneTodos.map(\.title) == ["b"])

        await model.toggleDone(try #require(model.todos.first { $0.title == "b" }))
        #expect(model.openTodos.map(\.title) == ["a", "b", "c"])
    }

    @Test("Dragging reorders the open todos")
    func dragReorders() async {
        let (model, _) = makeModel()
        for title in ["c", "b", "a"] { await model.add(title: title) }

        await model.moveOpen(fromOffsets: [0], toOffset: 3)
        #expect(model.openTodos.map(\.title) == ["b", "c", "a"])
    }

    @Test("Deleting the selected todo selects the one that took its place")
    func deleteMovesSelection() async throws {
        let (model, _) = makeModel()
        for title in ["c", "b", "a"] { await model.add(title: title) }
        let b = try #require(model.todos.first { $0.title == "b" })
        model.selection = b.id

        await model.delete(b)
        #expect(model.todos.map(\.title) == ["a", "c"])
        #expect(model.selectedTodo?.title == "c")
    }

    @Test("A clip becomes a linked todo, once")
    func addsFromClip() async {
        let (model, _) = makeModel()
        let item = clip("send Dana the\ninvoice")

        #expect(await model.add(from: item) == .added)
        #expect(model.todos.map(\.title) == ["send Dana the invoice"])
        #expect(model.todos.first?.sourceItemID == item.id)

        #expect(await model.add(from: item) == .alreadyThere)
        #expect(model.todos.count == 1)
    }

    @Test("A detected secret never becomes a todo")
    func refusesSecrets() async {
        let (model, _) = makeModel()
        #expect(await model.add(from: clip("sk-live-abc123", sensitivity: .secret)) == .refused)
        #expect(model.todos.isEmpty)
    }

    @Test("Pasting a clip that has gone drops the link and says so")
    func missingClipUnlinks() async throws {
        let (model, _) = makeModel()
        var asked: UUID?
        model.pasteClip = { id in
            asked = id
            return false
        }
        let item = clip("call the bank")
        await model.add(from: item)

        await model.pasteLinkedClip(of: try #require(model.todos.first))
        #expect(asked == item.id)
        #expect(model.todos.first?.sourceItemID == nil)
        #expect(model.notice != nil)
    }

    @Test("Pasting a clip that is still there keeps the link")
    func presentClipStaysLinked() async throws {
        let (model, _) = makeModel()
        model.pasteClip = { _ in true }
        await model.add(from: clip("call the bank"))

        await model.pasteLinkedClip(of: try #require(model.todos.first))
        #expect(model.todos.first?.sourceItemID != nil)
        #expect(model.notice == nil)
    }
}

@Suite("Todos keyboard model")
struct TodoKeyboardTests {
    private func command(_ key: PanelKey, _ modifiers: PanelModifiers = [], draft: Bool = false) -> TodoCommand? {
        TodoKeyboard.command(for: key, modifiers: modifiers, hasDraft: draft)
    }

    @Test("Return adds what was typed, or ticks off the selection")
    func returnKey() {
        #expect(command(.return, draft: true) == .add)
        #expect(command(.return) == .toggleDone)
        #expect(command(.return, .command) == .pasteClip)
        #expect(command(.return, .command, draft: true) == .pasteClip)
    }

    @Test("Backspace only deletes a todo when nothing is typed")
    func deleteKey() {
        #expect(command(.delete) == .delete)
        #expect(command(.delete, draft: true) == nil)
    }

    @Test("Escape clears the field first, then closes the panel")
    func escapeKey() {
        #expect(command(.escape, draft: true) == .clearDraft)
        #expect(command(.escape) == .dismiss)
    }

    @Test("Arrows move the selection, with or without a draft")
    func arrows() {
        #expect(command(.down) == .moveSelection(by: 1))
        #expect(command(.up, draft: true) == .moveSelection(by: -1))
        #expect(command(.up, .command) == .moveToFirst)
        #expect(command(.down, .command) == .moveToLast)
    }

    @Test("Letters and Space are left for typing")
    func typingIsLeftAlone() {
        #expect(command(.space) == nil)
        #expect(command(.character("p"), .command) == nil)
        #expect(command(.digit(1), .command) == nil)
    }

    @Test("⌘T in History makes a todo")
    func commandT() {
        #expect(PanelKeyboard.command(for: .character("t"), modifiers: .command, isSearching: false) == .addToTodos)
        #expect(PanelKeyboard.command(for: .character("t"), modifiers: [], isSearching: false) == nil)
    }

    @Test("⌃⇥ walks every tab and wraps round")
    func tabCycle() {
        #expect(PanelTab.history.next(hasCodes: true, hasTodos: true) == .codes)
        #expect(PanelTab.codes.next(hasCodes: true, hasTodos: true) == .todos)
        #expect(PanelTab.todos.next(hasCodes: true, hasTodos: true) == .history)
    }

    @Test("⌃⇥ skips a tab the panel was built without")
    func tabCycleSkips() {
        #expect(PanelTab.history.next(hasCodes: false, hasTodos: true) == .todos)
        #expect(PanelTab.todos.next(hasCodes: false, hasTodos: true) == .history)
        #expect(PanelTab.history.next(hasCodes: true, hasTodos: false) == .codes)
        #expect(PanelTab.codes.next(hasCodes: true, hasTodos: false) == .history)
    }
}

import Foundation
import Testing
@testable import RecallPaste

@Suite("Paste stack")
struct PasteStackTests {
    private let a = UUID(), b = UUID(), c = UUID()
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Items come back in the order they were added")
    func drainsFirstInFirstOut() {
        var stack = PasteStack()
        stack.add(a, at: start)
        stack.add(b, at: start)
        stack.add(c, at: start)

        #expect(stack.takeNext(at: start) == a)
        #expect(stack.takeNext(at: start) == b)
        #expect(stack.takeNext(at: start) == c)
        #expect(stack.takeNext(at: start) == nil)
    }

    @Test("Pasting removes the item, so the next paste is the next thing")
    func pastingDrains() {
        var stack = PasteStack()
        stack.add(a, at: start)
        stack.add(b, at: start)

        _ = stack.takeNext(at: start)
        #expect(stack.count == 1)
        #expect(stack.next == b)
    }

    @Test("An empty stack behaves exactly like no stack")
    func emptyIsHarmless() {
        var stack = PasteStack()
        #expect(stack.isEmpty)
        #expect(stack.takeNext(at: start) == nil)
        #expect(stack.secondsUntilExpiry(at: start) == nil)
    }

    @Test("Re-adding a queued item moves it to the back rather than duplicating it")
    func reAddingMoves() {
        var stack = PasteStack()
        stack.add(a, at: start)
        stack.add(b, at: start)
        stack.add(a, at: start)

        #expect(stack.count == 2)
        #expect(stack.takeNext(at: start) == b)
        #expect(stack.takeNext(at: start) == a)
    }

    @Test("A stale stack clears itself rather than pasting something from ages ago")
    func expiresWhenIdle() {
        var stack = PasteStack()
        stack.add(a, at: start)

        let late = start.addingTimeInterval(PasteStack.idleTimeout + 1)
        #expect(stack.takeNext(at: late) == nil, "the stale item must not paste")
        #expect(stack.isEmpty)
    }

    @Test("Using the stack keeps it alive")
    func activityPostponesExpiry() {
        var stack = PasteStack()
        stack.add(a, at: start)
        stack.add(b, at: start.addingTimeInterval(PasteStack.idleTimeout - 10))

        let later = start.addingTimeInterval(PasteStack.idleTimeout + 10)
        #expect(stack.takeNext(at: later) == a, "the second add refreshed the clock")
    }

    @Test("Draining the last item stops the clock")
    func emptyingClearsTheTimestamp() {
        var stack = PasteStack()
        stack.add(a, at: start)
        _ = stack.takeNext(at: start)
        #expect(stack.secondsUntilExpiry(at: start) == nil)
    }

    @Test("The stack has a ceiling, dropping the oldest")
    func capacityIsBounded() {
        var stack = PasteStack()
        let ids = (0..<(PasteStack.capacity + 5)).map { _ in UUID() }
        for id in ids { stack.add(id, at: start) }

        #expect(stack.count == PasteStack.capacity)
        #expect(stack.next == ids[5], "the oldest fall off the front")
    }

    @Test("Removing a specific item leaves the order intact")
    func removesOne() {
        var stack = PasteStack()
        stack.add(a, at: start)
        stack.add(b, at: start)
        stack.add(c, at: start)

        stack.remove(b)
        #expect(stack.itemIDs == [a, c])
    }

    @Test("The countdown reports what the HUD should show")
    func reportsTimeRemaining() {
        var stack = PasteStack()
        stack.add(a, at: start)
        let remaining = stack.secondsUntilExpiry(at: start.addingTimeInterval(100))
        #expect(remaining == PasteStack.idleTimeout - 100)
    }
}

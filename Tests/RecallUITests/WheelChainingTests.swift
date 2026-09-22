import AppKit
import Foundation
import Testing
@testable import RecallUI

@Suite("Wheel chaining")
struct WheelChainingTests {
    /// A flipped document view, which is what `NSHostingView` gives you: y grows downward,
    /// so `visible.minY == 0` is the top.
    private func visible(at offset: CGFloat, height: CGFloat = 200) -> CGRect {
        CGRect(x: 0, y: offset, width: 300, height: height)
    }

    private let content = CGRect(x: 0, y: 0, width: 300, height: 1_000)

    @Test("Scrolling down through the middle of the text is ours")
    func keepsGestureWithRoomBelow() {
        #expect(!WheelChaining.shouldYield(
            deltaX: 0, deltaY: -10, visible: visible(at: 400), content: content, isFlipped: true
        ))
    }

    @Test("Scrolling up through the middle of the text is ours")
    func keepsGestureWithRoomAbove() {
        #expect(!WheelChaining.shouldYield(
            deltaX: 0, deltaY: 10, visible: visible(at: 400), content: content, isFlipped: true
        ))
    }

    /// The whole point: at the bottom of the text, scrolling further down is the list's.
    @Test("At the end of the text, the list gets the gesture")
    func yieldsAtTheBottom() {
        #expect(WheelChaining.shouldYield(
            deltaX: 0, deltaY: -10, visible: visible(at: 800), content: content, isFlipped: true
        ))
    }

    @Test("At the start of the text, scrolling up is the list's")
    func yieldsAtTheTop() {
        #expect(WheelChaining.shouldYield(
            deltaX: 0, deltaY: 10, visible: visible(at: 0), content: content, isFlipped: true
        ))
    }

    /// Being at the bottom must not take away scrolling back up.
    @Test("At the end, scrolling the other way is still ours")
    func keepsTheOppositeDirectionAtAnEdge() {
        #expect(!WheelChaining.shouldYield(
            deltaX: 0, deltaY: 10, visible: visible(at: 800), content: content, isFlipped: true
        ))
    }

    @Test("Text that fits never takes the wheel", arguments: [-10.0, 10.0])
    func yieldsWhenNothingToScroll(deltaY: CGFloat) {
        let short = CGRect(x: 0, y: 0, width: 300, height: 120)
        #expect(WheelChaining.shouldYield(
            deltaX: 0, deltaY: deltaY, visible: visible(at: 0, height: 200), content: short, isFlipped: true
        ))
    }

    @Test("A sideways gesture is never ours")
    func yieldsHorizontal() {
        #expect(WheelChaining.shouldYield(
            deltaX: 30, deltaY: 2, visible: visible(at: 400), content: content, isFlipped: true
        ))
    }

    /// The same decisions on an unflipped document view, where y grows upward and the
    /// edges are the other way round.
    @Test("An unflipped document view reaches the same answers")
    func handlesUnflippedGeometry() {
        // Top of the content is `content.maxY` when unflipped.
        let atTop = CGRect(x: 0, y: 800, width: 300, height: 200)
        let atBottom = CGRect(x: 0, y: 0, width: 300, height: 200)
        #expect(WheelChaining.shouldYield(
            deltaX: 0, deltaY: 10, visible: atTop, content: content, isFlipped: false
        ))
        #expect(WheelChaining.shouldYield(
            deltaX: 0, deltaY: -10, visible: atBottom, content: content, isFlipped: false
        ))
        #expect(!WheelChaining.shouldYield(
            deltaX: 0, deltaY: -10, visible: atTop, content: content, isFlipped: false
        ))
    }

    // MARK: - Gesture latching

    @Test("A trackpad gesture is decided at its first event")
    func startsOnBegan() {
        #expect(WheelChaining.isStartOfGesture(phase: .began, momentumPhase: []))
    }

    /// Re-deciding here is what would let one flick scroll the text and then carry on
    /// into the list.
    @Test("The rest of a gesture, and its momentum, is not a new decision", arguments: [
        (NSEvent.Phase.changed, NSEvent.Phase()),
        (NSEvent.Phase.ended, NSEvent.Phase()),
        (NSEvent.Phase(), NSEvent.Phase.began),
        (NSEvent.Phase(), NSEvent.Phase.changed),
        (NSEvent.Phase(), NSEvent.Phase.ended),
    ])
    func doesNotRestartMidGesture(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) {
        #expect(!WheelChaining.isStartOfGesture(phase: phase, momentumPhase: momentumPhase))
    }

    /// An old mouse wheel sends no phases at all, so every notch stands alone.
    @Test("A phaseless mouse wheel is decided every notch")
    func decidesEveryNotchForAMouse() {
        #expect(WheelChaining.isStartOfGesture(phase: [], momentumPhase: []))
    }
}

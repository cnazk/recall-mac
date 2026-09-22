import Foundation
import Testing
@testable import RecallCore
@testable import RecallUI

@Suite("Edge trigger")
struct EdgeTriggerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)

    private func sample(
        x: Double,
        y: Double = 540,
        time: TimeInterval,
        dragging: Bool = false,
        panelVisible: Bool = false
    ) -> EdgeTriggerPolicy.Sample {
        EdgeTriggerPolicy.Sample(
            location: CGPoint(x: x, y: y),
            screen: screen,
            time: time,
            isDragging: dragging,
            isPanelVisible: panelVisible
        )
    }

    @Test("Resting at the edge past the dwell time fires once")
    func firesAfterDwell() {
        var policy = EdgeTriggerPolicy()
        policy.edge = .right
        var state = EdgeTriggerPolicy.State()

        #expect(!policy.evaluate(sample(x: 1_919, time: 0), state: &state), "arriving is not enough")
        #expect(!policy.evaluate(sample(x: 1_919, time: 0.05), state: &state), "too soon")
        #expect(policy.evaluate(sample(x: 1_919, time: 0.2), state: &state), "dwell satisfied")
    }

    @Test("It does not fire again while the pointer stays there")
    func doesNotRepeat() {
        var policy = EdgeTriggerPolicy()
        var state = EdgeTriggerPolicy.State()

        _ = policy.evaluate(sample(x: 1_919, time: 0), state: &state)
        #expect(policy.evaluate(sample(x: 1_919, time: 0.2), state: &state))
        #expect(!policy.evaluate(sample(x: 1_919, time: 0.5), state: &state), "cooldown")
        #expect(!policy.evaluate(sample(x: 1_919, time: 0.9), state: &state), "still cooling down")
    }

    @Test("Dragging never fires it")
    func deadZoneWhileDragging() {
        var policy = EdgeTriggerPolicy()
        var state = EdgeTriggerPolicy.State()

        // Someone dragging a file to the edge to scroll is not asking for the clipboard.
        #expect(!policy.evaluate(sample(x: 1_919, time: 0, dragging: true), state: &state))
        #expect(!policy.evaluate(sample(x: 1_919, time: 1.0, dragging: true), state: &state))
    }

    @Test("A drag that starts mid-dwell cancels it")
    func dragCancelsDwell() {
        var policy = EdgeTriggerPolicy()
        var state = EdgeTriggerPolicy.State()

        _ = policy.evaluate(sample(x: 1_919, time: 0), state: &state)
        _ = policy.evaluate(sample(x: 1_919, time: 0.05, dragging: true), state: &state)
        #expect(!policy.evaluate(sample(x: 1_919, time: 0.2), state: &state), "the dwell restarts")
    }

    @Test("Leaving the edge re-arms it")
    func leavingReArms() {
        var policy = EdgeTriggerPolicy()
        var state = EdgeTriggerPolicy.State()

        _ = policy.evaluate(sample(x: 1_919, time: 0), state: &state)
        _ = policy.evaluate(sample(x: 900, time: 0.1), state: &state)
        #expect(!policy.evaluate(sample(x: 1_919, time: 0.2), state: &state), "dwell starts over")
        #expect(policy.evaluate(sample(x: 1_919, time: 0.4), state: &state))
    }

    @Test("Hot corners are left to macOS", arguments: [10.0, 1_070.0])
    func ignoresCorners(y: Double) {
        var policy = EdgeTriggerPolicy()
        var state = EdgeTriggerPolicy.State()

        _ = policy.evaluate(sample(x: 1_919, y: y, time: 0), state: &state)
        #expect(!policy.evaluate(sample(x: 1_919, y: y, time: 1.0), state: &state))
    }

    @Test("It does not fire while the panel is already open")
    func ignoresWhenPanelVisible() {
        var policy = EdgeTriggerPolicy()
        var state = EdgeTriggerPolicy.State()

        _ = policy.evaluate(sample(x: 1_919, time: 0, panelVisible: true), state: &state)
        #expect(!policy.evaluate(sample(x: 1_919, time: 1.0, panelVisible: true), state: &state))
    }

    @Test("The left edge works the same way")
    func leftEdge() {
        var policy = EdgeTriggerPolicy()
        policy.edge = .left
        var state = EdgeTriggerPolicy.State()

        _ = policy.evaluate(sample(x: 1, time: 0), state: &state)
        #expect(policy.evaluate(sample(x: 1, time: 0.2), state: &state))

        // …and the other edge is not it.
        var other = EdgeTriggerPolicy.State()
        _ = policy.evaluate(sample(x: 1_919, time: 0), state: &other)
        #expect(!policy.evaluate(sample(x: 1_919, time: 0.2), state: &other))
    }

    @Test("After the cooldown it can fire again")
    func firesAgainAfterCooldown() {
        var policy = EdgeTriggerPolicy()
        var state = EdgeTriggerPolicy.State()

        _ = policy.evaluate(sample(x: 1_919, time: 0), state: &state)
        #expect(policy.evaluate(sample(x: 1_919, time: 0.2), state: &state))

        _ = policy.evaluate(sample(x: 900, time: 1.5), state: &state)
        _ = policy.evaluate(sample(x: 1_919, time: 1.6), state: &state)
        #expect(policy.evaluate(sample(x: 1_919, time: 1.8), state: &state))
    }
}

/// A pointer resting at the edge must not keep opening the panel.
///
/// It used to: firing cleared the arrival time, the cooldown lapsed a second later, and
/// the next sample started the dwell again — so anything emitting mouse-moved events
/// while the pointer sat near an edge reopened the panel on a loop. The window server
/// does exactly that during a Space switch, which is how the panel appeared unbidden in
/// the middle of changing desktop.
@Suite("Edge trigger re-arming")
struct EdgeTriggerRearmTests {
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private var policy: EdgeTriggerPolicy {
        var policy = EdgeTriggerPolicy()
        policy.edge = .right
        return policy
    }

    private func sample(x: Double, at time: TimeInterval) -> EdgeTriggerPolicy.Sample {
        EdgeTriggerPolicy.Sample(
            location: CGPoint(x: x, y: 400),
            screen: screen,
            time: time,
            isDragging: false,
            isPanelVisible: false
        )
    }

    /// x=999 is inside the 2pt threshold of the right edge; x=500 is nowhere near it.
    private let atEdge = 999.0
    private let awayFromEdge = 500.0

    @Test("Resting at the edge fires once, not once per cooldown")
    func restingFiresOnce() {
        var state = EdgeTriggerPolicy.State()
        let policy = policy

        #expect(!policy.evaluate(sample(x: atEdge, at: 0), state: &state))
        #expect(policy.evaluate(sample(x: atEdge, at: 0.5), state: &state), "the dwell should fire")

        // Every later sample is still at the edge — the pointer never left.
        for time in stride(from: 1.0, through: 10.0, by: 0.5) {
            #expect(
                !policy.evaluate(sample(x: atEdge, at: time), state: &state),
                "fired again at \(time) without the pointer ever leaving"
            )
        }
    }

    @Test("Leaving the edge and coming back fires again")
    func leavingRearms() {
        var state = EdgeTriggerPolicy.State()
        let policy = policy

        _ = policy.evaluate(sample(x: atEdge, at: 0), state: &state)
        #expect(policy.evaluate(sample(x: atEdge, at: 0.5), state: &state))

        #expect(!policy.evaluate(sample(x: awayFromEdge, at: 2), state: &state))
        #expect(!policy.evaluate(sample(x: atEdge, at: 3), state: &state))
        #expect(policy.evaluate(sample(x: atEdge, at: 3.5), state: &state), "a real return should fire")
    }

    @Test("A fresh state is armed, so the first throw at the edge still works")
    func freshStateIsArmed() {
        var state = EdgeTriggerPolicy.State()
        #expect(!policy.evaluate(sample(x: atEdge, at: 0), state: &state))
        #expect(policy.evaluate(sample(x: atEdge, at: 0.2), state: &state))
    }
}

/// With more than one display, throwing the pointer at the right-hand side of a middle
/// monitor is how you get to the monitor on its right. That is travel, not a gesture —
/// and treating it as one made the panel appear whenever the pointer crossed screens.
@Suite("Edge trigger across displays")
struct EdgeTriggerMultiScreenTests {
    // Three side by side, the layout that reported this.
    private let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    private let middle = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    private var all: [CGRect] { [left, middle, right] }

    @Test("Only the rightmost screen has an outer right edge")
    func rightEdgeIsOuterOnlyAtTheEnd() {
        #expect(!EdgeTriggerPolicy.isOuterEdge(.right, of: left, among: all))
        #expect(!EdgeTriggerPolicy.isOuterEdge(.right, of: middle, among: all))
        #expect(EdgeTriggerPolicy.isOuterEdge(.right, of: right, among: all))
    }

    @Test("Only the leftmost screen has an outer left edge")
    func leftEdgeIsOuterOnlyAtTheStart() {
        #expect(EdgeTriggerPolicy.isOuterEdge(.left, of: left, among: all))
        #expect(!EdgeTriggerPolicy.isOuterEdge(.left, of: middle, among: all))
        #expect(!EdgeTriggerPolicy.isOuterEdge(.left, of: right, among: all))
    }

    @Test("A single display is outer on both sides")
    func singleScreenIsAlwaysOuter() {
        #expect(EdgeTriggerPolicy.isOuterEdge(.right, of: middle, among: [middle]))
        #expect(EdgeTriggerPolicy.isOuterEdge(.left, of: middle, among: [middle]))
    }

    @Test("A display stacked above does not block the edge beside it")
    func verticallyStackedScreensDoNotCount() {
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        #expect(EdgeTriggerPolicy.isOuterEdge(.right, of: middle, among: [middle, above]))
    }

    @Test("An inner edge never fires, however long the pointer rests on it")
    func innerEdgeNeverFires() {
        var policy = EdgeTriggerPolicy()
        policy.edge = .right
        var state = EdgeTriggerPolicy.State()

        for time in stride(from: 0.0, through: 5.0, by: 0.25) {
            let sample = EdgeTriggerPolicy.Sample(
                location: CGPoint(x: middle.maxX - 1, y: 500),
                screen: middle,
                time: time,
                isDragging: false,
                isPanelVisible: false,
                isOuterEdge: false
            )
            #expect(!policy.evaluate(sample, state: &state), "fired on an inner edge at \(time)")
        }
    }
}

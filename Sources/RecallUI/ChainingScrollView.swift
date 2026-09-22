import AppKit
import SwiftUI

/// Long text in an open row: scrollable, selectable, and it gives the wheel back.
///
/// Two problems, one view.
///
/// **The wheel.** AppKit sends `scrollWheel(with:)` to the deepest view under the pointer,
/// and `NSScrollView` does not pass it on: at its own edge it rubber-bands and keeps the
/// event. Nested in a list row that is exactly what you feel — the history stops scrolling
/// the moment the pointer crosses an open item, for as long as it is over it. It is why
/// the embedded detail was clipped at a fixed height rather than scrolled.
/// ``WheelChainingScrollView`` decides per gesture who the wheel belongs to.
///
/// **What is inside it.** An `NSTextView`, not an `NSHostingView` wrapping SwiftUI. That
/// was the first attempt and it aborted the process: hosting a second SwiftUI graph inside
/// the first and measuring it during layout trips `AG::precondition_failure` in
/// `NSHostingView.layout()`. A text view has no view graph to re-enter, and it brings
/// native selection and Find with it, which `Text` does not.
struct ScrollableTextView: NSViewRepresentable {
    let text: String
    var isMonospaced = false

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = WheelChainingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        // Elasticity is the opposite of what is wanted here. A bounce at the edge is the
        // scroll view insisting it still owns a gesture that should already have moved on,
        // and it reads as the list being stuck for a moment.
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        context.coordinator.textView = textView
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        apply(to: textView)
    }

    /// Without this the row would be empty.
    ///
    /// An `NSScrollView` has no intrinsic size — it is meant to be given one — so SwiftUI
    /// proposes nothing and lays it out at zero height. The height comes from measuring
    /// the string, which is arithmetic over fonts and touches no view, so unlike the
    /// hosting-view version it cannot re-enter a layout pass.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.frame.width
        guard width > 0 else { return nil }

        let ideal = Self.height(of: text, font: font, width: width)
        let limit = proposal.height ?? .infinity
        return CGSize(width: width, height: min(ideal, limit))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var textView: NSTextView?
    }

    private var font: NSFont {
        let size = NSFont.preferredFont(forTextStyle: .callout).pointSize
        return isMonospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }

    private func apply(to textView: NSTextView) {
        guard textView.string != text || textView.font != font else { return }
        textView.string = text
        textView.font = font
        textView.textColor = .labelColor
    }

    /// Measured with `boundingRect` rather than a layout manager, because an `NSTextView`
    /// on this system is TextKit 2 and reaching for `layoutManager` silently drops it back
    /// to TextKit 1. The wrapping rules are the same either way.
    static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty, width > 0 else { return 0 }
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(bounds.height)
    }
}

/// The scroll view itself. Everything with a decision in it is in ``WheelChaining``.
private final class WheelChainingScrollView: NSScrollView {
    /// Decided once when a gesture starts and held for the rest of it, momentum included.
    ///
    /// Deciding per event would hand the gesture over mid-flick the instant the text hit
    /// its end, so one flick would scroll the text and then carry on into the list — which
    /// is precisely the overscroll a Mac does not do.
    private var yieldsToEnclosingScrollView = false

    override func scrollWheel(with event: NSEvent) {
        if WheelChaining.isStartOfGesture(phase: event.phase, momentumPhase: event.momentumPhase) {
            yieldsToEnclosingScrollView = WheelChaining.shouldYield(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                visible: documentVisibleRect,
                content: documentView?.bounds ?? .zero,
                isFlipped: documentView?.isFlipped ?? true
            )
        }

        if yieldsToEnclosingScrollView {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Who a scroll gesture belongs to.
///
/// Pulled out of the view because it is the only part with a decision in it, and a wheel
/// event is not something a test can deliver to a view in a panel that is not on screen.
enum WheelChaining {
    /// True for the first event of a trackpad gesture, and for every event of an old
    /// mouse wheel.
    ///
    /// A wheel with no phases at all gets to be re-decided each notch, which is right:
    /// there is no gesture to stay inside of. Momentum events are never a start — they
    /// carry `phase == []` like a mouse wheel does, and are told apart by their
    /// `momentumPhase`.
    static func isStartOfGesture(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Bool {
        if phase.contains(.began) { return true }
        return phase.isEmpty && momentumPhase.isEmpty
    }

    /// True when the enclosing scroll view should get this gesture instead.
    static func shouldYield(
        deltaX: CGFloat,
        deltaY: CGFloat,
        visible: CGRect,
        content: CGRect,
        isFlipped: Bool,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        // A sideways gesture is never ours: there is one column of text here, and taking
        // it would break a horizontal swipe meant for something else.
        guard abs(deltaY) > abs(deltaX) else { return true }
        // Nothing to scroll: the text fits.
        guard content.height > visible.height + tolerance else { return true }
        guard deltaY != 0 else { return true }

        // A positive `scrollingDeltaY` moves the content down the screen, which shows what
        // is *above* — so it is only ours if there is anything above.
        let towardsStart = deltaY > 0
        let room: CGFloat = if isFlipped {
            towardsStart ? visible.minY - content.minY : content.maxY - visible.maxY
        } else {
            towardsStart ? content.maxY - visible.maxY : visible.minY - content.minY
        }
        return room <= tolerance
    }
}

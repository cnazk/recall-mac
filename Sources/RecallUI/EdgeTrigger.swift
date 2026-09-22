import AppKit
import Foundation
import RecallCore

/// Decides whether a pointer position should open the panel.
///
/// Pulled out as a pure state machine because "throw the cursor at the edge" has a
/// surprising number of ways to be wrong — firing mid-drag, firing on a hot corner,
/// firing again the instant you dismiss it — and none of those are testable through a
/// live `NSEvent` monitor.
public struct EdgeTriggerPolicy: Sendable {
    /// How close to the edge counts as "at" it.
    public var threshold: Double = 2
    /// How long the pointer must rest there.
    public var dwell: TimeInterval = 0.12
    /// Quiet period after firing, so dismissing the panel does not immediately reopen it.
    public var cooldown: TimeInterval = 1.0
    /// Corner height excluded at top and bottom, where macOS hot corners live.
    public var cornerExclusion: Double = 80
    public var edge: ScreenEdge = .right

    public init() {}

    /// Everything the policy needs to know about a moment.
    public struct Sample: Sendable {
        public let location: CGPoint
        public let screen: CGRect
        public let time: TimeInterval
        public let isDragging: Bool
        public let isPanelVisible: Bool
        /// Whether this screen's trigger edge is the outside of the desktop.
        ///
        /// False when another display sits beyond it. Throwing the pointer at the right
        /// side of a middle monitor is how you get to the monitor on its right — it is
        /// travel, not a gesture, and treating it as one made the panel appear whenever
        /// the pointer crossed between screens.
        public let isOuterEdge: Bool

        public init(
            location: CGPoint,
            screen: CGRect,
            time: TimeInterval,
            isDragging: Bool,
            isPanelVisible: Bool,
            isOuterEdge: Bool = true
        ) {
            self.location = location
            self.screen = screen
            self.time = time
            self.isDragging = isDragging
            self.isPanelVisible = isPanelVisible
            self.isOuterEdge = isOuterEdge
        }
    }

    /// Mutable part: when the pointer arrived at the edge, when we last fired, and
    /// whether the pointer has been away from the edge since.
    public struct State: Sendable, Equatable {
        var arrivedAt: TimeInterval?
        var lastFiredAt: TimeInterval?
        /// False from the moment it fires until the pointer leaves the edge again.
        ///
        /// Without this a pointer simply *resting* at the edge re-opens the panel every
        /// time the cooldown lapses, for as long as anything keeps emitting mouse-moved
        /// events — which the window server does during a Space switch, so the panel
        /// would appear out of nowhere while you were changing desktop.
        var isArmed = true

        public init() {}
    }

    /// - Returns: true when the panel should open.
    public func evaluate(_ sample: Sample, state: inout State) -> Bool {
        // A drag is someone moving a file, not asking for the clipboard. This is the
        // dead zone, and it is the whole reason edge triggering is tolerable.
        guard !sample.isDragging else {
            state.arrivedAt = nil
            return false
        }
        guard !sample.isPanelVisible else {
            state.arrivedAt = nil
            return false
        }

        // An edge with another display behind it is a doorway, not a wall.
        guard sample.isOuterEdge else {
            state.arrivedAt = nil
            state.isArmed = true
            return false
        }

        guard isAtEdge(sample) else {
            // Leaving the edge is what re-arms the trigger. Opening the panel has to be
            // something you *do*, not something that happens to you because the pointer
            // was parked in the wrong place.
            state.arrivedAt = nil
            state.isArmed = true
            return false
        }

        guard state.isArmed else { return false }

        if let lastFiredAt = state.lastFiredAt, sample.time - lastFiredAt < cooldown {
            return false
        }

        guard let arrivedAt = state.arrivedAt else {
            state.arrivedAt = sample.time
            return false
        }

        guard sample.time - arrivedAt >= dwell else { return false }

        state.arrivedAt = nil
        state.lastFiredAt = sample.time
        state.isArmed = false
        return true
    }

    /// Whether `edge` of `screen` faces the outside of the desktop rather than another
    /// display.
    ///
    /// The neighbour has to overlap vertically to matter: a monitor stacked above this
    /// one does not make its right-hand side a doorway.
    public static func isOuterEdge(
        _ edge: ScreenEdge,
        of screen: CGRect,
        among screens: [CGRect],
        tolerance: CGFloat = 2
    ) -> Bool {
        !screens.contains { other in
            guard other != screen else { return false }
            let overlapsVertically = other.minY < screen.maxY - tolerance
                && other.maxY > screen.minY + tolerance
            guard overlapsVertically else { return false }

            return switch edge {
            case .right: other.minX >= screen.maxX - tolerance
            case .left: other.maxX <= screen.minX + tolerance
            }
        }
    }

    func isAtEdge(_ sample: Sample) -> Bool {
        let screen = sample.screen
        let x = sample.location.x
        let y = sample.location.y

        // Hot corners belong to macOS; firing there would fight the system.
        guard y > screen.minY + cornerExclusion, y < screen.maxY - cornerExclusion else { return false }

        return switch edge {
        case .left: x <= screen.minX + threshold
        case .right: x >= screen.maxX - threshold
        }
    }
}

/// Watches the pointer and applies ``EdgeTriggerPolicy``.
///
/// Global *mouse* monitoring needs no special permission — unlike keyboard monitoring —
/// so this costs the user nothing to turn on.
@MainActor
public final class EdgeTrigger {
    private var policy: EdgeTriggerPolicy
    private var state = EdgeTriggerPolicy.State()
    private var monitor: Any?
    private var spaceObserver: (any NSObjectProtocol)?
    /// Samples before this moment are ignored. See ``ignoreAfterSpaceChange``.
    private var suppressedUntil: TimeInterval = 0
    private let action: () -> Void
    private let isPanelVisible: () -> Bool

    public init(
        policy: EdgeTriggerPolicy = EdgeTriggerPolicy(),
        isPanelVisible: @escaping () -> Bool,
        action: @escaping () -> Void
    ) {
        self.policy = policy
        self.isPanelVisible = isPanelVisible
        self.action = action
    }

    public var isRunning: Bool { monitor != nil }

    public func update(policy: EdgeTriggerPolicy) {
        self.policy = policy
        state = EdgeTriggerPolicy.State()
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = Self.installMonitor(for: self)
        observeSpaceChanges()
        Log.ui.info("Edge trigger started")
    }

    /// How long to ignore the edge after the desktop changes under the pointer.
    ///
    /// Switching Space with ⌃← leaves the pointer exactly where it was, but the window
    /// server emits mouse-moved events as the new desktop comes in. If the pointer
    /// happened to be resting near an edge, that read as a deliberate throw at it and the
    /// panel appeared in the middle of changing desktop. Nothing the user did with the
    /// mouse caused those events, so they are not theirs to act on.
    private static let ignoreAfterSpaceChange: TimeInterval = 1.0

    private func observeSpaceChanges() {
        guard spaceObserver == nil else { return }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A task, not `MainActor.assumeIsolated`. This notification arrives from
            // AppKit, and that assertion is the one that crashed the app all over —
            // asserting isolation at a boundary like this is exactly the shape that fails.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.suppressedUntil = ProcessInfo.processInfo.systemUptime + Self.ignoreAfterSpaceChange
                // The pointer is wherever it was; treat it as needing to leave and come
                // back before the edge counts again.
                self.state = EdgeTriggerPolicy.State()
                self.state.isArmed = false
            }
        }
    }

    /// Installs the global monitor from a **nonisolated** context, on purpose.
    ///
    /// A closure written inside this `@MainActor` class inherits that isolation, and the
    /// compiler then puts a dynamic isolation check in its prologue — `MainActor.shared`,
    /// `unownedExecutor`, `swift_task_isCurrentExecutor` — because AppKit calls it from
    /// non-isolated code. That check is what crashed: it faults reading the main
    /// executor's identity, and the same fault turns up inside SwiftUI's own hit testing,
    /// so it is not something this class can assert its way out of.
    ///
    /// Declaring it nonisolated removes the check instead of trying to satisfy it.
    /// Verified by disassembling the release binary — the prologue no longer touches the
    /// executor.
    ///
    /// The event is read here, while it is still alive, and handed on as plain values.
    private nonisolated static func installMonitor(for trigger: EdgeTrigger) -> Any? {
        NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak trigger] event in
            let isDragging = event.type == .leftMouseDragged || event.type == .rightMouseDragged
            let location = NSEvent.mouseLocation
            let time = ProcessInfo.processInfo.systemUptime

            Task { @MainActor in
                trigger?.handle(location: location, time: time, isDragging: isDragging)
            }
        }
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
        state = EdgeTriggerPolicy.State()
    }

    private func handle(location: CGPoint, time: TimeInterval, isDragging: Bool) {
        guard time >= suppressedUntil else { return }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) }) else { return }

        let sample = EdgeTriggerPolicy.Sample(
            location: location,
            screen: screen.frame,
            time: time,
            isDragging: isDragging,
            isPanelVisible: isPanelVisible(),
            isOuterEdge: EdgeTriggerPolicy.isOuterEdge(
                policy.edge,
                of: screen.frame,
                among: NSScreen.screens.map(\.frame)
            )
        )

        if policy.evaluate(sample, state: &state) {
            Log.ui.info("Edge trigger fired at the \(String(describing: self.policy.edge), privacy: .public) edge")
            action()
        }
    }
}

import Foundation

/// How long capture stays paused.
public enum PauseDuration: String, CaseIterable, Hashable, Sendable {
    case fifteenMinutes
    case oneHour
    case indefinitely

    public var seconds: TimeInterval? {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .oneHour: 60 * 60
        case .indefinitely: nil
        }
    }

    public var menuTitle: String {
        switch self {
        case .fifteenMinutes: "For 15 Minutes"
        case .oneHour: "For 1 Hour"
        case .indefinitely: "Until I Turn It Back On"
        }
    }
}

/// Whether Recall is recording, and until when it is not.
///
/// A value type with no timer in it, so the rules can be tested without waiting: the
/// owner asks ``resolved(at:)`` for the state at a given moment and gets back a pause
/// that has already expired if its time is up.
///
/// Deliberately **not** persisted. A clipboard manager that quietly stopped recording
/// three days ago is a bug report, not a feature, so every launch starts recording.
public struct CapturePause: Equatable, Sendable {
    /// When capture resumes by itself. `nil` while recording *and* while paused with no
    /// end — ``isPaused`` is what distinguishes those.
    public private(set) var resumesAt: Date?
    public private(set) var isPaused: Bool

    public init() {
        self.resumesAt = nil
        self.isPaused = false
    }

    public static let capturing = CapturePause()

    public mutating func pause(_ duration: PauseDuration, now: Date) {
        isPaused = true
        resumesAt = duration.seconds.map { now.addingTimeInterval($0) }
    }

    public mutating func resume() {
        isPaused = false
        resumesAt = nil
    }

    /// This pause as it stands at `now`, with a timed pause that has run out already
    /// turned back into recording.
    public func resolved(at now: Date) -> CapturePause {
        guard isPaused, let resumesAt, now >= resumesAt else { return self }
        return .capturing
    }

    public func isCapturing(at now: Date) -> Bool {
        !resolved(at: now).isPaused
    }

    /// Seconds left, or nil when recording or paused with no end.
    public func remaining(at now: Date) -> TimeInterval? {
        guard isPaused, let resumesAt, now < resumesAt else { return nil }
        return resumesAt.timeIntervalSince(now)
    }

    /// What the menu says while paused: "Paused for 14 more minutes", or that it is
    /// paused until the user says otherwise.
    public func statusText(at now: Date) -> String? {
        let current = resolved(at: now)
        guard current.isPaused else { return nil }
        guard let remaining = current.remaining(at: now) else {
            return "Paused until you resume"
        }
        let minutes = Int((remaining / 60).rounded(.up))
        return minutes <= 1 ? "Paused — resumes in under a minute"
                            : "Paused — resumes in \(minutes) minutes"
    }
}

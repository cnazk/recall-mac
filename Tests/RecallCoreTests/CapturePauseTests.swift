import Foundation
import Testing
@testable import RecallCore

@Suite("Pausing capture")
struct CapturePauseTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A fresh app is recording")
    func startsCapturing() {
        let pause = CapturePause()
        #expect(!pause.isPaused)
        #expect(pause.isCapturing(at: now))
        #expect(pause.statusText(at: now) == nil)
    }

    @Test("A timed pause ends by itself", arguments: [PauseDuration.fifteenMinutes, .oneHour])
    func timedPauseExpires(duration: PauseDuration) throws {
        let seconds = try #require(duration.seconds)
        var pause = CapturePause()
        pause.pause(duration, now: now)

        #expect(!pause.isCapturing(at: now))
        #expect(!pause.isCapturing(at: now.addingTimeInterval(seconds - 1)))
        // The deadline itself is already over: a pause "for 15 minutes" is not a
        // sixteenth minute of not recording.
        #expect(pause.isCapturing(at: now.addingTimeInterval(seconds)))
        #expect(pause.isCapturing(at: now.addingTimeInterval(seconds + 3600)))
    }

    @Test("An indefinite pause never expires on its own")
    func indefinitePauseHolds() {
        var pause = CapturePause()
        pause.pause(.indefinitely, now: now)

        #expect(pause.resumesAt == nil)
        #expect(!pause.isCapturing(at: now.addingTimeInterval(86_400 * 7)))
        #expect(pause.remaining(at: now) == nil)
        #expect(pause.statusText(at: now) == "Paused until you resume")
    }

    @Test("Resuming clears the deadline")
    func resumeClears() {
        var pause = CapturePause()
        pause.pause(.oneHour, now: now)
        pause.resume()

        #expect(!pause.isPaused)
        #expect(pause.resumesAt == nil)
        #expect(pause.isCapturing(at: now))
    }

    @Test("Pausing again replaces the deadline rather than extending it")
    func repausingReplaces() throws {
        var pause = CapturePause()
        pause.pause(.oneHour, now: now)
        pause.pause(.fifteenMinutes, now: now)

        #expect(pause.resumesAt == now.addingTimeInterval(900))
        #expect(pause.isCapturing(at: now.addingTimeInterval(901)))
    }

    @Test("resolved() hands back a plain recording state once the time is up")
    func resolvedNormalises() {
        var pause = CapturePause()
        pause.pause(.fifteenMinutes, now: now)

        #expect(pause.resolved(at: now) == pause)
        #expect(pause.resolved(at: now.addingTimeInterval(900)) == .capturing)
    }

    @Test("The status counts down, and rounds up so it never reads zero")
    func statusCountsDown() {
        var pause = CapturePause()
        pause.pause(.fifteenMinutes, now: now)

        #expect(pause.statusText(at: now) == "Paused — resumes in 15 minutes")
        #expect(pause.statusText(at: now.addingTimeInterval(60)) == "Paused — resumes in 14 minutes")
        #expect(pause.statusText(at: now.addingTimeInterval(870)) == "Paused — resumes in under a minute")
        // Expired: no status at all, because the menu is no longer showing a pause.
        #expect(pause.statusText(at: now.addingTimeInterval(900)) == nil)
    }

    @Test("Remaining time is nil unless a deadline is actually pending")
    func remainingOnlyWhenPending() {
        var pause = CapturePause()
        #expect(pause.remaining(at: now) == nil)

        pause.pause(.oneHour, now: now)
        #expect(pause.remaining(at: now) == 3600)
        #expect(pause.remaining(at: now.addingTimeInterval(3600)) == nil)
    }

    @Test("Every duration has a menu title, and only the open-ended one has no length")
    func durationsAreComplete() {
        #expect(PauseDuration.allCases.count == 3)
        for duration in PauseDuration.allCases {
            #expect(!duration.menuTitle.isEmpty)
        }
        #expect(PauseDuration.indefinitely.seconds == nil)
        #expect(PauseDuration.fifteenMinutes.seconds == 900)
        #expect(PauseDuration.oneHour.seconds == 3600)
    }
}

import Foundation
import Testing
@testable import RecallCore

@Suite("Relative time labels")
struct RelativeTimeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func label(secondsAgo: TimeInterval) -> String {
        RelativeTime.label(for: now.addingTimeInterval(-secondsAgo), now: now)
    }

    @Test("Anything under a minute reads as now, so the label never ticks per second")
    func subMinuteIsStable() {
        for seconds in stride(from: 0.0, through: 59.0, by: 7.0) {
            #expect(label(secondsAgo: seconds) == "now")
        }
    }

    @Test("A clip dated slightly in the future still reads as now")
    func futureIsNow() {
        #expect(RelativeTime.label(for: now.addingTimeInterval(30), now: now) == "now")
    }

    @Test("Minutes, hours and days each get their own unit", arguments: [
        (60.0, "1m"), (90.0, "1m"), (599.0, "9m"), (3_540.0, "59m"),
        (3_600.0, "1h"), (7_200.0, "2h"), (86_340.0, "23h"),
        (86_400.0, "1d"), (259_200.0, "3d"), (604_799.0, "6d"),
    ])
    func unitsStepUp(secondsAgo: TimeInterval, expected: String) {
        #expect(label(secondsAgo: secondsAgo) == expected)
    }

    @Test("A week or more falls back to a date rather than a growing day count")
    func oldClipsShowADate() {
        let label = label(secondsAgo: 604_800)
        #expect(label != "7d")
        #expect(!label.isEmpty)
        // A date, not a duration.
        #expect(!label.hasSuffix("m"))
        #expect(!label.hasSuffix("h"))
        #expect(!label.hasSuffix("d"))
    }

    @Test("The label only ever shortens or holds as a minute passes")
    func labelIsStableWithinAMinute() {
        let created = now.addingTimeInterval(-300)
        let first = RelativeTime.label(for: created, now: now)
        let later = RelativeTime.label(for: created, now: now.addingTimeInterval(59))
        #expect(first == later, "the label must not change within the same minute")
    }

    @Test("The tooltip still carries the full date the short label drops")
    func exactIsDetailed() {
        #expect(RelativeTime.exact(for: now).count > 8)
    }
}

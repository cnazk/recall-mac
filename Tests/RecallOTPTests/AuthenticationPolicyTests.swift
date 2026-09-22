import Foundation
import Testing
@testable import RecallOTP

@Suite("Two-factor authentication policy")
struct AuthenticationPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Deciding

    @Test("Always asks, even a moment after the last success")
    func alwaysAlwaysAsks() {
        let policy = OTPAuthenticationPolicy.always
        #expect(!policy.allowsWithoutAuthenticating(lastAuthenticated: nil, now: now))
        #expect(!policy.allowsWithoutAuthenticating(lastAuthenticated: now, now: now))
    }

    @Test("Never never asks, even having never authenticated")
    func neverNeverAsks() {
        #expect(OTPAuthenticationPolicy.never.allowsWithoutAuthenticating(lastAuthenticated: nil, now: now))
    }

    @Test("A grace period asks the first time, whatever its length")
    func graceAsksBeforeAnySuccess() {
        for minutes in OTPAuthenticationPolicy.graceOptions {
            let policy = OTPAuthenticationPolicy.afterGrace(minutes: minutes)
            #expect(!policy.allowsWithoutAuthenticating(lastAuthenticated: nil, now: now))
        }
    }

    @Test("Inside the window it stays quiet; on the boundary it asks again")
    func graceWindowBoundaries() {
        let policy = OTPAuthenticationPolicy.afterGrace(minutes: 5)
        let authenticated = now

        #expect(policy.allowsWithoutAuthenticating(lastAuthenticated: authenticated, now: now))
        #expect(policy.allowsWithoutAuthenticating(
            lastAuthenticated: authenticated, now: now.addingTimeInterval(299)
        ))
        // Five minutes exactly is over, not still inside.
        #expect(!policy.allowsWithoutAuthenticating(
            lastAuthenticated: authenticated, now: now.addingTimeInterval(300)
        ))
        #expect(!policy.allowsWithoutAuthenticating(
            lastAuthenticated: authenticated, now: now.addingTimeInterval(3_000)
        ))
    }

    @Test("A clock that jumped backwards does not extend the grace period")
    func backwardsClockAsks() {
        let policy = OTPAuthenticationPolicy.afterGrace(minutes: 5)
        // "Last authenticated" in the future: the only safe reading is to ask.
        #expect(!policy.allowsWithoutAuthenticating(
            lastAuthenticated: now.addingTimeInterval(600), now: now
        ))
    }

    // MARK: - Wire format

    @Test("Every policy survives the round trip through XPC")
    func rawValueRoundTrips() throws {
        let policies: [OTPAuthenticationPolicy] = [.always, .never]
            + OTPAuthenticationPolicy.graceOptions.map { .afterGrace(minutes: $0) }

        for policy in policies {
            let restored = try #require(OTPAuthenticationPolicy(rawValue: policy.rawValue))
            #expect(restored == policy)
        }
    }

    @Test("Nonsense on the wire is rejected rather than guessed at")
    func rejectsNonsense() {
        for raw in ["", "sometimes", "grace:", "grace:zero", "grace:0", "grace:-5", "GRACE:5"] {
            #expect(OTPAuthenticationPolicy(rawValue: raw) == nil, "accepted “\(raw)”")
        }
    }

    @Test("An over-long grace period is clamped, not rejected")
    func clampsLongGrace() {
        let policy = OTPAuthenticationPolicy(rawValue: "grace:100000")
        #expect(policy == .afterGrace(minutes: OTPAuthenticationPolicy.maximumGraceMinutes))
    }

    @Test("The default is the strict one")
    func defaultIsStrict() {
        #expect(OTPAuthenticationPolicy.default == .always)
        #expect(!OTPAuthenticationPolicy.default.allowsWithoutAuthenticating(lastAuthenticated: now, now: now))
    }

    @Test("Each choice explains itself")
    func summariesAreDistinct() {
        let summaries = [
            OTPAuthenticationPolicy.always.summary,
            OTPAuthenticationPolicy.never.summary,
            OTPAuthenticationPolicy.afterGrace(minutes: 5).summary,
        ]
        #expect(Set(summaries).count == 3)
        #expect(OTPAuthenticationPolicy.afterGrace(minutes: 1).summary.contains("1 minute"))
        #expect(OTPAuthenticationPolicy.afterGrace(minutes: 5).summary.contains("5 minutes"))
    }
}

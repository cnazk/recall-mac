import Foundation
import Observation
import RecallCore
import RecallEnrichment
import RecallOTP
import RecallPaste

/// Recall's view of the two-factor helper.
///
/// Holds summaries and codes, never seeds. Every code here was handed over by the helper
/// one at a time, after whatever authentication the helper demanded.
@MainActor
@Observable
public final class OTPModel {
    public struct LiveCode: Sendable, Equatable {
        public let code: String
        public let secondsRemaining: Int
        public let period: Int
        public let fetchedAt: Date

        /// How much of the current step is left, for the drain ring.
        public func fraction(at date: Date = .now) -> Double {
            let elapsed = date.timeIntervalSince(fetchedAt)
            let remaining = Double(secondsRemaining) - elapsed
            return max(0, min(1, remaining / Double(max(period, 1))))
        }

        public var hasExpired: Bool {
            Date.now.timeIntervalSince(fetchedAt) >= Double(secondsRemaining)
        }
    }

    public private(set) var accounts: [OTPAccountSummary] = []
    public private(set) var codes: [UUID: LiveCode] = [:]
    public private(set) var failure: String?

    /// Forgets every revealed code.
    ///
    /// A code was authenticated for the moment it was asked for, not for the rest of the
    /// session. Once the panel is gone the authentication is spent, so the next look
    /// starts locked — and no stale number is waiting on screen when it reopens.
    public func forgetCodes() {
        codes.removeAll()
    }

    /// Dismisses whatever went wrong, once the user has read it.
    public func clearFailure() { failure = nil }
    public private(set) var isHelperAvailable = true
    public var searchText = ""
    /// A setup link the user copied, waiting for them to confirm the import.
    public var pendingImportURI: String?

    /// Supplied by the app: closes the panel. `@Environment(\.dismiss)` does nothing in
    /// an `NSPanel` — see ``AppModel/dismissPanel``.
    public var dismissPanel: (@MainActor () -> Void)?
    /// Supplied by the app: raised while the helper is asking for Touch ID, so the panel
    /// does not hide itself when the prompt takes the keyboard.
    public var onAuthenticationPrompt: (@MainActor (Bool) -> Void)?

    private let client: OTPClient
    private let paste: PasteService
    private let barcodes = BarcodeReader()

    public init(client: OTPClient = OTPClient(), paste: PasteService) {
        self.client = client
        self.paste = paste
    }

    public var visibleAccounts: [OTPAccountSummary] {
        guard !searchText.isEmpty else { return accounts }
        return accounts.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    public func refresh() async {
        do {
            accounts = try await client.accounts()
            isHelperAvailable = true
            failure = nil
        } catch {
            isHelperAvailable = false
            report(error, doing: "reach the two-factor helper")
            Log.ui.error("Two-factor helper unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks the helper for a code. This is the call that triggers Touch ID.
    public func requestCode(for account: OTPAccountSummary) async {
        // The helper puts a Touch ID prompt on screen for this, which takes key from the
        // panel. Without the guard the panel hides itself mid-prompt and the whole thing
        // looks like the app fell over.
        onAuthenticationPrompt?(true)
        defer { onAuthenticationPrompt?(false) }

        do {
            let result = try await client.code(for: account.id)
            codes[account.id] = LiveCode(
                code: result.code,
                secondsRemaining: result.secondsRemaining,
                period: account.period,
                fetchedAt: .now
            )
            failure = nil
        } catch {
            report(error, doing: "generate a code")
        }
    }

    /// Copies a code, refreshing first when the one on screen is about to rotate — a code
    /// pasted with two seconds left is a code that fails.
    public func pasteCode(for account: OTPAccountSummary) async {
        if codes[account.id] == nil || (codes[account.id]?.secondsRemaining ?? 0) <= 5 || codes[account.id]?.hasExpired == true {
            await requestCode(for: account)
        }
        guard let live = codes[account.id] else { return }

        // Written straight to the pasteboard with the monitor muted: a generated code is
        // not history, and must never become a clip.
        paste.writeTransient(live.code)
    }

    @discardableResult
    public func importURI(_ uri: String) async -> Int {
        // Importing can ask the helper to authenticate, which takes key from the panel.
        onAuthenticationPrompt?(true)
        defer { onAuthenticationPrompt?(false) }

        do {
            let count = try await client.importAccounts(fromURI: uri)
            pendingImportURI = nil
            failure = nil
            await refresh()
            Log.ui.info("Imported \(count, privacy: .public) two-factor account(s)")
            return count
        } catch {
            report(error, doing: "import a two-factor setup link")
            return 0
        }
    }

    /// Records a failure where the user can see it *and* where the log can.
    ///
    /// These used to be assigned to `failure` and nothing else, and `failure` is only
    /// rendered when the helper is entirely unreachable — so an import that failed for
    /// any other reason set a string nobody ever read, and the button looked dead.
    private func report(_ error: any Error, doing action: String) {
        failure = String(describing: error)
        Log.ui.error("Could not \(action, privacy: .public): \(String(describing: error), privacy: .public)")
    }

    /// Reads a QR code off the screen — the fastest way to add an account, with no phone
    /// involved.
    public func importFromScreen() async {
        do {
            let capture = try await RegionCapture().captureRegion()
            guard let uri = try barcodes.twoFactorURI(in: capture.image.data) else {
                failure = String(localized: "No two-factor QR code was found in that region.")
                return
            }
            await importURI(uri)
        } catch RegionCapture.Failure.cancelled {
            // A cancel is a decision, not a failure.
        } catch {
            report(error, doing: "read a QR code from the screen")
        }
    }

    public func remove(_ account: OTPAccountSummary) async {
        do {
            try await client.remove(id: account.id)
            codes[account.id] = nil
            await refresh()
        } catch {
            report(error, doing: "remove that account")
        }
    }

    /// Every seed back out as `otpauth://` URIs, Touch ID gated by the helper.
    public func exportURIs() async -> [String] {
        do {
            return try await client.exportURIs()
        } catch {
            report(error, doing: "export your accounts")
            return []
        }
    }

    public func setAuthenticationPolicy(_ policy: OTPAuthenticationPolicy) async {
        do {
            try await client.setAuthenticationPolicy(policy)
        } catch {
            report(error, doing: "change when codes ask for authentication")
        }
    }

    public func authenticationPolicy() async -> OTPAuthenticationPolicy {
        // Unreadable means ask every time. Never the other way round.
        (try? await client.authenticationPolicy()) ?? .default
    }
}

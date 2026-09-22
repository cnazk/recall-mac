import Foundation
import RecallCore
import RecallSecurity

/// Turns a raw pasteboard snapshot into a stored ``ClipItem``.
///
/// The order of the steps is the privacy contract: exclusions and concealed-type checks
/// run *before* any content is read into a long-lived value, and secret detection runs
/// before anything is handed to the store.
public struct CaptureService: Sendable {
    private let normalizer: TextNormalizer
    private let classifier: PayloadClassifier
    private let detector: SecretDetector
    private let exclusions: AppExclusionPolicy
    private let clock: any DateProviding
    private let settings: RecallSettings

    public init(
        settings: RecallSettings = .default,
        detector: SecretDetector? = nil,
        exclusions: AppExclusionPolicy? = nil,
        clock: any DateProviding = SystemClock()
    ) {
        self.settings = settings
        self.normalizer = TextNormalizer(options: settings.normalizeWhitespace ? .default : .none)
        self.classifier = PayloadClassifier()
        // Rules the user switched off are not applied.
        self.detector = detector ?? SecretDetector(settings: settings)
        self.exclusions = exclusions ?? AppExclusionPolicy(settings: settings)
        self.clock = clock
    }

    /// Builds the item a snapshot should produce, or explains why it produces none.
    public func makeItem(from snapshot: PasteboardSnapshot) -> Result<ClipItem, IgnoreReason> {
        if exclusions.isExcluded(snapshot.source) {
            Log.capture.info("Ignored clip from excluded app")
            return .failure(.excludedApp)
        }
        if exclusions.isConcealed(pasteboardTypes: snapshot.types) {
            Log.capture.info("Ignored clip marked concealed/transient")
            return .failure(.concealedPasteboard)
        }

        guard let (payload, plainText) = payload(from: snapshot) else {
            return .failure(snapshot.types.isEmpty ? .emptyContent : .unsupportedType)
        }

        // A two-factor setup link is a permanent secret, not a clip. It is handed to the
        // helper for import and never reaches history — storing it for sixty seconds and
        // then deleting it would still have written a seed to disk.
        if let plainText, Self.isTwoFactorSetupLink(plainText) {
            Log.capture.info("Ignored a two-factor setup link; offering it for import")
            return .failure(.twoFactorSecret)
        }

        // Detection runs against the raw text, not the classified payload: a clip can be
        // classified as, say, a colour and still be a one-time code.
        let verdict = detector.inspect(plainText ?? payload.searchableText ?? "")
        let now = clock.now

        return .success(ClipItem(
            payload: payload,
            contentHash: ContentHash(payload),
            source: snapshot.source,
            createdAt: now,
            sensitivity: verdict.isSecret ? .secret : .normal,
            expiresAt: verdict.isSecret ? now.addingTimeInterval(settings.secretTimeToLive) : nil,
            detectedRules: verdict.isSecret ? verdict.matchedRules.sorted() : []
        ))
    }

    /// Picks the richest representation the snapshot offers.
    ///
    /// Files beat images beat rich text beats plain text: a Finder copy carries both file
    /// URLs and a text fallback, and the file reference is the useful one.
    /// `otpauth://` and `otpauth-migration://` carry seeds that mint codes forever.
    public static func isTwoFactorSetupLink(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lowered.hasPrefix("otpauth://") || lowered.hasPrefix("otpauth-migration://")
    }

    /// - Returns: the payload and the normalised plain text it came from, if any.
    private func payload(from snapshot: PasteboardSnapshot) -> (ClipPayload, String?)? {
        if !snapshot.files.isEmpty {
            return (.files(snapshot.files), nil)
        }
        if let image = snapshot.image {
            return (.image(image), nil)
        }

        let plain = snapshot.plainText.map(normalizer.normalize)

        // What the text *is* outranks how it was styled.
        //
        // Rich text is the richer representation of prose, and it was being preferred
        // unconditionally — but a browser puts RTF on the pasteboard for everything,
        // including a bare `#FF0000` or a lone link. Those took the rich-text branch and
        // never reached the classifier, so a colour copied from Safari showed as text
        // with no swatch while the same six characters copied from a terminal did not.
        //
        // Only for payloads that are a single value. A styled paragraph stays rich text:
        // there the formatting is the thing you would lose.
        if let plain, !plain.isEmpty {
            let classified = classifier.classify(text: plain)
            if classified.kind == .color || classified.kind == .url {
                return (classified, plain)
            }
        }

        if let rtf = snapshot.rtf, !rtf.isEmpty {
            return (.richText(rtf: rtf, plain: plain ?? ""), plain)
        }
        guard let plain, !plain.isEmpty else { return nil }
        return (classifier.classify(text: plain), plain)
    }
}

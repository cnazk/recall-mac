import Foundation
import Testing
@testable import RecallCapture
@testable import RecallCore

@Suite("Text normalization")
struct TextNormalizerTests {
    let normalizer = TextNormalizer()

    @Test("Trims edges and normalises line endings")
    func cleansMessyText() {
        #expect(normalizer.normalize("   hello  \n\n ") == "hello")
        #expect(normalizer.normalize("a\r\nb") == "a\nb")
        #expect(normalizer.normalize("a\rb") == "a\nb")
    }

    @Test("Strips invisible characters pasted from the web")
    func stripsZeroWidth() {
        #expect(normalizer.normalize("he\u{200B}llo") == "hello")
        #expect(normalizer.normalize("a\u{00A0}b") == "a b")
    }

    @Test("Collapses runs of blank lines")
    func collapsesBlankLines() {
        #expect(normalizer.normalize("a\n\n\n\n\nb") == "a\n\nb")
    }

    @Test("Leaves interior indentation alone by default")
    func preservesCodeIndentation() {
        let code = "func f() {\n    return 1\n}"
        #expect(normalizer.normalize(code) == code)
    }

    @Test("Dedent removes a shared indent when asked")
    func dedents() {
        let indented = "    a\n    b"
        let normalizer = TextNormalizer(options: .init(
            trimEdges: false, normalizeLineEndings: false, stripZeroWidth: false,
            collapseBlankLines: false, dedent: true
        ))
        #expect(normalizer.normalize(indented) == "a\nb")
    }

    @Test("Disabled options are a no-op")
    func noneIsIdentity() {
        let raw = "  messy \r\n text  "
        #expect(TextNormalizer(options: .none).normalize(raw) == raw)
    }
}

@Suite("Payload classification")
struct PayloadClassifierTests {
    let classifier = PayloadClassifier()

    @Test("A bare link becomes a URL clip")
    func detectsURL() {
        #expect(classifier.classify(text: "https://example.com/a?b=c").kind == .url)
    }

    @Test("A sentence containing a link stays text")
    func prosePrevails() {
        #expect(classifier.classify(text: "see https://example.com for details").kind == .text)
    }

    @Test("Hex codes become colours")
    func detectsColor() {
        #expect(classifier.classify(text: "#ff8800").kind == .color)
        #expect(classifier.classify(text: "  #F80 ").kind == .color)
    }

    @Test("Plain words stay text")
    func fallsBackToText() {
        #expect(classifier.classify(text: "deadbeefcafe").kind == .text)
        #expect(classifier.classify(text: "hello").kind == .text)
    }

    @Test("A six-digit number is not mistaken for a colour")
    func digitsAreNotColours() {
        // Every character is a valid hex digit, but this is far more likely a 2FA code.
        #expect(classifier.classify(text: "483920").kind == .text)
        #expect(classifier.classify(text: "#483920").kind == .color)
    }
}

@Suite("Capture pipeline")
struct CaptureServiceTests {
    let clock = MutableClock()

    func service(settings: RecallSettings = .default) -> CaptureService {
        CaptureService(settings: settings, clock: clock)
    }

    @Test("Normalises text on the way in")
    func normalisesOnCapture() throws {
        let snapshot = PasteboardSnapshot(changeCount: 1, types: ["public.utf8-plain-text"], plainText: "  hello  ")
        let item = try service().makeItem(from: snapshot).get()
        #expect(item.payload == .text("hello"))
    }

    @Test("Refuses to capture from an excluded app")
    func dropsExcludedApps() {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.utf8-plain-text"],
            plainText: "hunter2",
            source: SourceApp(bundleIdentifier: "com.1password.1password", localizedName: "1Password")
        )
        #expect(service().makeItem(from: snapshot) == .failure(.excludedApp))
    }

    @Test("Honours the concealed-type marker")
    func dropsConcealedClips() {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"],
            plainText: "secret"
        )
        #expect(service().makeItem(from: snapshot) == .failure(.concealedPasteboard))
    }

    @Test("Secrets are flagged and given a deadline")
    func secretsExpire() throws {
        let snapshot = PasteboardSnapshot(changeCount: 1, types: ["public.utf8-plain-text"], plainText: "483920")
        let item = try service().makeItem(from: snapshot).get()
        #expect(item.sensitivity == .secret)
        #expect(item.expiresAt == clock.now.addingTimeInterval(60))
    }

    @Test("A hex-digit-only 2FA code is still treated as a secret")
    func detectsSecretsRegardlessOfClassification() throws {
        let snapshot = PasteboardSnapshot(changeCount: 1, types: ["public.utf8-plain-text"], plainText: "483920")
        #expect(try service().makeItem(from: snapshot).get().sensitivity == .secret)
    }

    @Test("Ordinary clips never expire")
    func ordinaryClipsPersist() throws {
        let snapshot = PasteboardSnapshot(changeCount: 1, types: ["public.utf8-plain-text"], plainText: "meeting notes")
        let item = try service().makeItem(from: snapshot).get()
        #expect(item.sensitivity == .normal)
        #expect(item.expiresAt == nil)
    }

    @Test("Files win over the text fallback Finder also puts on the pasteboard")
    func prefersRichestRepresentation() throws {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.file-url", "public.utf8-plain-text"],
            plainText: "/Users/me/report.pdf",
            files: [FileReference(url: URL(fileURLWithPath: "/Users/me/report.pdf"))]
        )
        #expect(try service().makeItem(from: snapshot).get().kind == .file)
    }

    /// The bug: a browser puts RTF on the pasteboard for everything it copies, so a
    /// colour copied from a web page took the rich-text branch and never reached the
    /// classifier. It showed as plain text with no swatch, while the same six characters
    /// copied from a terminal were recognised.
    @Test("A colour copied from a browser is still a colour")
    func classifiesColourDespiteRichText() throws {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.rtf", "public.utf8-plain-text"],
            plainText: "#FF0000",
            rtf: Data("{\\rtf1 #FF0000}".utf8)
        )
        #expect(try service().makeItem(from: snapshot).get().kind == .color)
    }

    @Test("A link copied from a browser is still a link")
    func classifiesURLDespiteRichText() throws {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.rtf", "public.utf8-plain-text"],
            plainText: "https://example.com/a",
            rtf: Data("{\\rtf1 https://example.com/a}".utf8)
        )
        #expect(try service().makeItem(from: snapshot).get().kind == .url)
    }

    /// The other half of the rule. Formatting is the whole point of a styled paragraph,
    /// so that must still arrive as rich text.
    @Test("Styled prose is still rich text")
    func keepsRichTextForProse() throws {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.rtf", "public.utf8-plain-text"],
            plainText: "a paragraph of prose, with a link https://example.com in it",
            rtf: Data("{\\rtf1 styled}".utf8)
        )
        #expect(try service().makeItem(from: snapshot).get().kind == .richText)
    }

    @Test("An empty pasteboard produces nothing")
    func ignoresEmpty() {
        #expect(service().makeItem(from: PasteboardSnapshot(changeCount: 1)) == .failure(.emptyContent))
    }
}

extension Result: @retroactive Equatable where Success == ClipItem, Failure == IgnoreReason {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.success(let a), .success(let b)): a == b
        case (.failure(let a), .failure(let b)): a == b
        default: false
        }
    }
}

@Suite("Two-factor setup links")
struct TwoFactorCaptureTests {
    let service = CaptureService()

    @Test("A setup link is never written to history")
    func refusesToStoreSeeds() {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.utf8-plain-text"],
            plainText: "otpauth://totp/GitHub:alex?secret=GEZDGNBVGY3TQOJQ&issuer=GitHub"
        )
        // Storing it as a secret with a 60-second countdown would still have written a
        // permanent seed to disk.
        #expect(service.makeItem(from: snapshot) == .failure(.twoFactorSecret))
    }

    @Test("An export link is refused too")
    func refusesMigrationLinks() {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.utf8-plain-text"],
            plainText: "otpauth-migration://offline?data=CjEKCkhlbGxvId6tvu8"
        )
        #expect(service.makeItem(from: snapshot) == .failure(.twoFactorSecret))
    }

    @Test("Ordinary links are unaffected")
    func leavesNormalLinksAlone() throws {
        let snapshot = PasteboardSnapshot(
            changeCount: 1,
            types: ["public.utf8-plain-text"],
            plainText: "https://github.com/settings/security"
        )
        #expect(try service.makeItem(from: snapshot).get().kind == .url)
    }

    @Test("Recognises both link types")
    func recognisesSetupLinks() {
        #expect(CaptureService.isTwoFactorSetupLink("otpauth://totp/x?secret=A"))
        #expect(CaptureService.isTwoFactorSetupLink("OTPAUTH-MIGRATION://offline?data=A"))
        #expect(!CaptureService.isTwoFactorSetupLink("https://example.com"))
    }
}

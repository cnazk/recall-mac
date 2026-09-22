import AppKit
import Foundation
import Testing
@testable import RecallCore
@testable import RecallUI

@Suite("Quick Look plans")
struct QuickLookPlanTests {
    private func item(_ payload: ClipPayload, sensitivity: Sensitivity = .normal) -> ClipItem {
        ClipItem(payload: payload, contentHash: ContentHash(payload), sensitivity: sensitivity)
    }

    @Test("A file previews where it already is, with nothing written")
    func previewsFilesInPlace() {
        let url = URL(fileURLWithPath: "/Users/someone/report.pdf")
        let plan = QuickLookPlan.plan(for: item(.files([FileReference(url: url)])))
        #expect(plan == .existingFile(url))
    }

    @Test("A sensitive item is refused rather than previewed in the clear")
    func refusesSecrets() {
        let secret = item(.text("483920"), sensitivity: .secret)
        #expect(QuickLookPlan.plan(for: secret) == .refused)
    }

    @Test("A sensitive file is refused too, even though previewing it writes nothing")
    func refusesSensitiveFiles() {
        let url = URL(fileURLWithPath: "/tmp/credentials.json")
        let secret = item(.files([FileReference(url: url)]), sensitivity: .secret)
        #expect(QuickLookPlan.plan(for: secret) == .refused)
    }

    @Test("Text is staged as a .txt file")
    func stagesText() {
        guard case .temporaryFile(let name, let type) = QuickLookPlan.plan(for: item(.text("hello there"))) else {
            Issue.record("expected a temporary file")
            return
        }
        #expect(name.hasSuffix(".txt"))
        #expect(type == "public.plain-text")
    }

    @Test("Rich text keeps its formatting")
    func stagesRichText() {
        let payload = ClipPayload.richText(rtf: Data("{\\rtf1 hello}".utf8), plain: "hello")
        guard case .temporaryFile(let name, let type) = QuickLookPlan.plan(for: item(payload)) else {
            Issue.record("expected a temporary file")
            return
        }
        #expect(name.hasSuffix(".rtf"))
        #expect(type == "public.rtf")
    }

    @Test("An image is staged with the extension its own type implies")
    func stagesImages() {
        let image = ImagePayload(data: Data([1, 2, 3]), uti: "public.png", pixelWidth: 10, pixelHeight: 10)
        guard case .temporaryFile(let name, _) = QuickLookPlan.plan(for: item(.image(image))) else {
            Issue.record("expected a temporary file")
            return
        }
        #expect(name.hasSuffix(".png"))
    }

    @Test("Filenames cannot escape the directory they are written into")
    func sanitisesNames() {
        let nasty = item(.text("../../etc/passwd"))
        guard case .temporaryFile(let name, _) = QuickLookPlan.plan(for: nasty) else {
            Issue.record("expected a temporary file")
            return
        }
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
    }

    @Test("An empty or unprintable clip still gets a usable name")
    func alwaysNamesSomething() {
        guard case .temporaryFile(let name, _) = QuickLookPlan.plan(for: item(.text("•••"))) else {
            Issue.record("expected a temporary file")
            return
        }
        #expect(name.hasPrefix("Clipping"))
    }

    @Test("A colour previews as text rather than being refused")
    func handlesColours() {
        let colour = HexColor(parsing: "#ff8800")!
        guard case .temporaryFile(let name, _) = QuickLookPlan.plan(for: item(.color(colour))) else {
            Issue.record("expected a temporary file")
            return
        }
        #expect(name.hasSuffix(".txt"))
    }
}

@Suite("Quick Look key bindings")
struct QuickLookKeyTests {
    @Test("Space previews when the search field is empty")
    func spacePreviews() {
        #expect(PanelKeyboard.command(for: .space, modifiers: [], isSearching: false) == .quickLook)
    }

    @Test("Space types a space while searching, rather than previewing")
    func spaceTypesWhileSearching() {
        // Otherwise the space bar would be unusable in the one field that needs it.
        #expect(PanelKeyboard.command(for: .space, modifiers: [], isSearching: true) == nil)
    }

    @Test("⌘Y previews regardless, for when the search field is in use")
    func commandYAlwaysPreviews() {
        #expect(PanelKeyboard.command(for: .character("y"), modifiers: .command, isSearching: true) == .quickLook)
        #expect(PanelKeyboard.command(for: .character("y"), modifiers: [], isSearching: false) == nil)
    }
}

/// `NSWindow` raises `NSInternalInconsistencyException` when a collection behavior sets
/// two mutually exclusive Space options, and AppKit answers that by suspending the thread
/// that raised it rather than crashing — which, on a main-actor job, wedges the whole app
/// silently. Cheaper to assert the constant than to find that again.
@Suite("Window collection behaviour")
@MainActor
struct CollectionBehaviorTests {
    private static let spaceOptions: [NSWindow.CollectionBehavior] = [
        .canJoinAllSpaces, .moveToActiveSpace,
    ]

    private func spaceOptionCount(_ behavior: NSWindow.CollectionBehavior) -> Int {
        Self.spaceOptions.filter { behavior.contains($0) }.count
    }

    @Test("The panel picks at most one Space behaviour")
    func panelBehaviourIsValid() {
        #expect(spaceOptionCount(PanelController.collectionBehavior) <= 1)
    }

    @Test("The scratchpad picks at most one Space behaviour")
    func scratchpadBehaviourIsValid() {
        #expect(spaceOptionCount(ScratchpadController.collectionBehavior) <= 1)
    }
}

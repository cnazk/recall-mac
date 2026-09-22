import AppKit
import Foundation
import Testing
@testable import RecallCapture
@testable import RecallCore
@testable import RecallPaste
@testable import RecallStorage

/// End-to-end coverage of the real capture path: a write to `NSPasteboard.general`, the
/// live `PasteboardMonitor`, `CaptureService`, and a store.
///
/// This exists because the unit tests all passed while the shipped app captured nothing —
/// the bug was in the wiring, which is exactly what unit tests do not cover.
@Suite("Capture pipeline, end to end", .serialized)
struct PipelineIntegrationTests {
    /// Restores whatever the user had on the clipboard when we are done.
    private func withBorrowedPasteboard(_ body: (NSPasteboard) async throws -> Void) async throws {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            if let saved {
                pasteboard.clearContents()
                pasteboard.setString(saved, forType: .string)
            }
        }
        try await body(pasteboard)
    }

    /// Waits for `condition`, polling, so the test does not depend on a fixed sleep.
    private func eventually(
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test("Copying text reaches the store through the live monitor")
    func capturesRealPasteboardWrite() async throws {
        try await withBorrowedPasteboard { pasteboard in
            let store = InMemoryHistoryStore()
            let capture = CaptureService()

            let monitor = PasteboardMonitor(interval: 0.05) { snapshot in
                Task {
                    guard let item = try? capture.makeItem(from: snapshot).get() else { return }
                    try? await store.capture(item)
                }
            }
            monitor.start()
            defer { monitor.stop() }

            let marker = "recall-integration-\(UUID().uuidString)"
            pasteboard.clearContents()
            pasteboard.setString(marker, forType: .string)

            let captured = await eventually {
                let items = (try? await store.items(matching: .recent)) ?? []
                return items.contains { $0.payload.searchableText == marker }
            }
            #expect(captured, "the monitor should have picked the write up")
        }
    }

    @Test("A write Recall makes itself is not captured back")
    func ignoresOwnWrites() async throws {
        try await withBorrowedPasteboard { pasteboard in
            let store = InMemoryHistoryStore()
            let capture = CaptureService()

            let monitor = PasteboardMonitor(interval: 0.05) { snapshot in
                Task {
                    guard let item = try? capture.makeItem(from: snapshot).get() else { return }
                    try? await store.capture(item)
                }
            }
            monitor.start()
            defer { monitor.stop() }

            // The real writer, wired the way the app wires it — mimicking the brackets
            // here would test the test rather than the app.
            let paste = await MainActor.run {
                let service = PasteService(pasteboard: .general)
                service.willWriteToPasteboard = { monitor.beginSelfWrite() }
                service.didWriteToPasteboard = { monitor.endSelfWrite() }
                return service
            }

            // Let the monitor settle on the current change count first.
            try? await Task.sleep(for: .milliseconds(150))

            let marker = "recall-self-write-\(UUID().uuidString)"
            let item = ClipItem(payload: .text(marker), contentHash: ContentHash(.text(marker)))
            await MainActor.run { _ = paste.write(item) }

            try? await Task.sleep(for: .milliseconds(400))
            let items = (try? await store.items(matching: .recent)) ?? []
            #expect(
                !items.contains { $0.payload.searchableText == marker },
                "Recall must not re-capture what it pastes"
            )
        }
    }

    @Test("A rich-text write is not captured back either")
    func ignoresOwnRichTextWrites() async throws {
        try await withBorrowedPasteboard { _ in
            let store = InMemoryHistoryStore()
            let capture = CaptureService()

            let monitor = PasteboardMonitor(interval: 0.05) { snapshot in
                Task {
                    guard let item = try? capture.makeItem(from: snapshot).get() else { return }
                    try? await store.capture(item)
                }
            }
            monitor.start()
            defer { monitor.stop() }

            let paste = await MainActor.run {
                let service = PasteService(pasteboard: .general)
                service.willWriteToPasteboard = { monitor.beginSelfWrite() }
                service.didWriteToPasteboard = { monitor.endSelfWrite() }
                return service
            }
            try? await Task.sleep(for: .milliseconds(150))

            // Rich text bumps the change count twice, once for clearContents and once for
            // declareTypes. Suppressing a single predicted count missed the second.
            let marker = "recall-rich-\(UUID().uuidString)"
            let rtf = Data("{\\rtf1\\ansi \(marker)}".utf8)
            let payload = ClipPayload.richText(rtf: rtf, plain: marker)
            let item = ClipItem(payload: payload, contentHash: ContentHash(payload))
            await MainActor.run { _ = paste.write(item) }

            try? await Task.sleep(for: .milliseconds(400))
            let items = (try? await store.items(matching: .recent)) ?? []
            #expect(items.isEmpty, "neither change count may be captured")
        }
    }

    @Test("Nothing copied during a pause is captured, then or on resume")
    func pauseDropsWhatIsCopiedWhilePaused() async throws {
        try await withBorrowedPasteboard { pasteboard in
            let store = InMemoryHistoryStore()
            let capture = CaptureService()

            let monitor = PasteboardMonitor(interval: 0.05) { snapshot in
                Task {
                    guard let item = try? capture.makeItem(from: snapshot).get() else { return }
                    try? await store.capture(item)
                }
            }
            monitor.start()
            defer { monitor.stop() }

            monitor.pause()
            // The pause is applied on the monitor's own queue; give it a moment to land
            // before writing, or the race is with the test rather than the feature.
            try? await Task.sleep(for: .milliseconds(200))

            let secret = "recall-paused-\(UUID().uuidString)"
            pasteboard.clearContents()
            pasteboard.setString(secret, forType: .string)
            try? await Task.sleep(for: .milliseconds(400))

            var items = (try? await store.items(matching: .recent)) ?? []
            #expect(items.isEmpty, "a paused monitor must not record")

            // The real trap: resuming re-baselines the change count. Without that, the
            // first poll after resuming sees a change it never saw and sweeps in whatever
            // was copied while paused — which is exactly what the user paused to avoid.
            monitor.resume()
            try? await Task.sleep(for: .milliseconds(400))

            items = (try? await store.items(matching: .recent)) ?? []
            #expect(
                !items.contains { $0.payload.searchableText == secret },
                "resuming must not backfill what was copied during the pause"
            )

            // And capture is genuinely working again.
            let marker = "recall-resumed-\(UUID().uuidString)"
            pasteboard.clearContents()
            pasteboard.setString(marker, forType: .string)

            let captured = await eventually {
                let items = (try? await store.items(matching: .recent)) ?? []
                return items.contains { $0.payload.searchableText == marker }
            }
            #expect(captured, "capture should resume")
        }
    }
}

import AppKit
import RecallCore
import SwiftUI

/// A small floating readout of what the stack will paste next.
///
/// A stack you cannot see is a stack you stop trusting after the first surprising paste,
/// so this appears whenever the stack has anything in it and disappears the moment it
/// empties. It never takes focus and never accepts clicks that matter.
@MainActor
public final class PasteStackHUD {
    private var window: NSPanel?
    private let content: () -> AnyView

    public init<Content: View>(@ViewBuilder content: @escaping () -> Content) {
        self.content = { AnyView(content()) }
    }

    public func show() {
        let window = window ?? makeWindow()
        self.window = window
        position(window)
        // `orderFrontRegardless`: the HUD must appear without stealing focus from
        // whatever the user is typing into.
        window.orderFrontRegardless()
    }

    public func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = true
        window.contentView = NSHostingView(rootView: content())
        return window
    }

    /// Bottom centre of the screen the pointer is on: visible, and out of the way of the
    /// text being edited.
    private func position(_ window: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.minY + 80
        ))
    }
}

/// The HUD's contents.
public struct PasteStackHUDView: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.22))
                Text("\(model.pasteStackCount)")
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Next: \(model.pasteStackNextTitle ?? "—")")
                    .font(.callout)
                    .lineLimit(1)
                Text("⌃⌥⌘V to paste · ⌥⌘⌫ to clear")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 280, alignment: .leading)
        // A readout that floats over whatever you are pasting into — exactly what this
        // material is for.
        .glassSurface(Capsule(), settings: model.settings)
    }
}

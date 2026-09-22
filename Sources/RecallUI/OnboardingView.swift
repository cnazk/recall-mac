import RecallCore
import RecallPaste
import SwiftUI

/// Shown once, on first launch.
///
/// Its job is to explain the two permissions Recall may ask for *before* macOS asks, and
/// to make clear that both are optional. An app that demands Accessibility on first launch
/// with no explanation has earned the refusal it gets.
public struct OnboardingView: View {
    @Bindable private var controller: SettingsController
    private let paste: PasteService
    @State private var loginItemState = LoginItem.state
    @Environment(\.dismiss) private var dismiss

    public init(controller: SettingsController, paste: PasteService) {
        self.controller = controller
        self.paste = paste
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recall is running").font(.title2.weight(.semibold))
                Text("Press ⌘⇧V for your clipboard history. It is already recording.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: Binding(
                get: { loginItemState.isOn },
                set: { loginItemState = LoginItem.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Recall at login").font(.callout.weight(.medium))
                    Text("It only records while it is running, so it needs to come back after a restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Two things Recall may ask for later")
                .font(.headline)

            permission(
                icon: "keyboard",
                title: "Accessibility",
                detail: """
                Only needed to paste for you automatically and to expand snippet \
                shortcodes. Without it, Recall still copies the item and you paste it \
                yourself — nothing else changes.
                """,
                action: "Grant Now",
                perform: { paste.requestAccessibilityPermission() }
            )

            permission(
                icon: "camera.viewfinder",
                title: "Screen Recording",
                detail: """
                Only needed for ⌥⌘⇧2, which reads text out of a region of the screen. \
                macOS asks the first time you use it, not before.
                """,
                action: nil,
                perform: nil
            )

            Divider()

            Label(
                "Everything stays on this Mac. Your history is encrypted, and all AI runs on device.",
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Done") {
                    controller.update { $0.hasCompletedOnboarding = true }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder
    private func permission(
        icon: String,
        title: String,
        detail: String,
        action: String?,
        perform: (() -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let action, let perform {
                Button(action, action: perform)
                    .controlSize(.small)
            }
        }
    }
}

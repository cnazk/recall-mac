import RecallCore
import RecallIntelligence
import RecallPaste
import SwiftUI

/// The "Paste as…" sheet (⌥⏎).
///
/// The result is previewed before it goes anywhere. A transform is a guess about intent,
/// and pasting a guess straight into someone's document is how you lose their trust.
struct TransformSheet: View {
    let item: ClipItem
    @Bindable var model: AppModel

    @State private var selected: ClipTransform?
    @State private var output = ""
    @State private var isRunning = false
    @State private var failure: String?
    @State private var language = "English"
    @State private var task: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if item.sensitivity == .secret {
                // Guardrail: a detected credential is never handed to the model.
                Label(
                    "AI actions are turned off for items that look like credentials.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else {
                transformPicker
                if selected?.needsArgument == true {
                    Picker("Into", selection: $language) {
                        ForEach(ClipTransform.translationLanguages, id: \.self) { Text(Self.displayName(ofLanguage: $0)).tag($0) }
                    }
                    .onChange(of: language) { _, _ in run() }
                }
                resultBox
            }

            footer
        }
        .padding(16)
        .frame(width: 520, height: 420)
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Paste as…").font(.headline)
            Text(item.railTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var transformPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(model.transforms(for: item)) { transform in
                    Button {
                        selected = transform
                        run()
                    } label: {
                        Label(transform.title, systemImage: transform.systemImage)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selected?.id == transform.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var resultBox: some View {
        ScrollView {
            if let failure {
                Text(failure).font(.callout).foregroundStyle(.red)
            } else if output.isEmpty && isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working on device…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(output)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        HStack {
            if isRunning {
                Button("Stop") { task?.cancel(); isRunning = false }
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Paste") {
                Task {
                    await model.paste(item, style: .transformed(output))
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(output.isEmpty || isRunning)
        }
    }

    private func run() {
        guard let transform = selected, item.sensitivity != .secret else { return }
        task?.cancel()
        output = ""
        failure = nil
        isRunning = true

        task = Task {
            do {
                for try await partial in model.streamTransform(
                    transform,
                    for: item,
                    argument: transform.needsArgument ? language : nil
                ) {
                    if Task.isCancelled { break }
                    output = partial
                }
            } catch {
                failure = String(describing: error)
            }
            isRunning = false
        }
    }

    /// The picker's values stay in English, because that is what the model is told. What
    /// is shown is each language named in the user's own: "Allemand", "Немецкий", "德语".
    static func displayName(ofLanguage english: String) -> String {
        guard let code = languageCodes[english] else { return english }
        return Locale.current.localizedString(forIdentifier: code) ?? english
    }

    static let languageCodes: [String: String] = [
        "English": "en", "Spanish": "es", "French": "fr", "German": "de", "Portuguese": "pt",
        "Italian": "it", "Dutch": "nl", "Japanese": "ja", "Korean": "ko", "Chinese (Simplified)": "zh-Hans",
    ]
}

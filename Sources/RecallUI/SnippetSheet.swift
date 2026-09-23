import RecallCore
import RecallPaste
import SwiftUI

/// Assigns a shortcode to an item.
///
/// Offered straight after pinning, because "I want this to hand" and "I want to type
/// three characters to get this" are the same intent arriving a moment apart.
struct SnippetSheet: View {
    let item: ClipItem
    @Bindable var model: AppModel

    @State private var code: String
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    init(item: ClipItem, model: AppModel) {
        self.item = item
        self.model = model
        self._code = State(initialValue: item.snippetCode ?? ":")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.snippetCode == nil ? "Add a shortcode" : "Edit shortcode")
                .font(.headline)

            Text("Type this anywhere and Recall replaces it with the item.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Shortcode", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit { save() }

            Text("Starts with \(Text(":").monospaced()), \(Text(";").monospaced()), \(Text("/").monospaced()) or \(Text("!").monospaced()), then letters, numbers, - or _.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !model.settings.snippetExpansionEnabled {
                Label(
                    "Shortcodes are saved, but expansion is turned off in Settings › Snippets.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                if item.snippetCode != nil {
                    Button("Remove", role: .destructive) {
                        Task {
                            await model.assignSnippetCode(nil, to: item)
                            dismiss()
                        }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func save() {
        Task {
            switch await model.assignSnippetCode(code, to: item) {
            case .assigned:
                dismiss()
            case .invalidCode:
                problem = String(localized: "That shortcode will not work. Try something like :sig.")
            case .alreadyUsed(let owner):
                problem = String(localized: "\(code) is already used by “\(owner)”.")
            }
        }
    }
}

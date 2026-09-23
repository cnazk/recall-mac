import AppKit
import RecallCore
import SwiftUI

/// What changed between two clips.
///
/// Deliberately one column rather than two panes side by side. The panel is 620 points
/// wide and a clip is usually a line of config or a paragraph — split in half, both halves
/// wrap so hard that the alignment a two-pane view exists to show is lost. A single
/// stacked run of removals and insertions reads the way a `git diff` does.
struct DiffView: View {
    let comparison: ClipComparison
    @Bindable var model: AppModel
    var onClose: () -> Void

    @State private var copied: Copied?

    private enum Copied { case diff, newer }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: comparison.diff)
            Divider()
            footer(for: comparison.diff)
        }
        .frame(width: 620, height: 460)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Comparing two clips").font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    /// Says which way round the two clips are, because the sign of every line depends on
    /// it and the user picked them in whatever order they happened to be in the list.
    ///
    /// Falls back to clock times when the relative labels match. Comparing a config with
    /// the version you copied a moment later is the common case, and "from now to now"
    /// is the one reading that tells you nothing at all.
    private var subtitle: String {
        let older = RelativeTime.label(for: comparison.older.createdAt)
        let newer = RelativeTime.label(for: comparison.newer.createdAt)
        guard older != newer else {
            return String(localized: "from \(clockTime(comparison.older)) to \(clockTime(comparison.newer))")
        }
        return String(localized: "from \(older) to \(newer)")
    }

    private func clockTime(_ item: ClipItem) -> String {
        item.createdAt.formatted(date: .omitted, time: .standard)
    }

    @ViewBuilder
    private func body(for diff: TextDiff.Result) -> some View {
        if diff.isIdentical {
            ContentUnavailableView(
                "No differences",
                systemImage: "equal.circle",
                description: Text("These two clips have the same text.")
            )
        } else {
            ScrollView {
                switch diff.granularity {
                case .line: lines(of: diff)
                case .word: words(of: diff)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// One row per line, each tinted by what happened to it.
    private func lines(of diff: TextDiff.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diff.segments) { segment in
                HStack(alignment: .top, spacing: 8) {
                    // A sign as well as a colour: a red/green diff is unreadable to a
                    // good number of people, and unprintable for everyone.
                    Text(sign(for: segment.change))
                        .foregroundStyle(.secondary)
                    Text(segment.text.isEmpty ? " " : segment.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 1)
                .background(tint(for: segment.change))
            }
        }
        .padding(.vertical, 6)
    }

    /// Words run together as flowing text, with the changed ones marked in place.
    ///
    /// A word diff shown one word per row would be unreadable — the point of it is to see
    /// a corrected word inside the sentence it belongs to.
    private func words(of diff: TextDiff.Result) -> some View {
        Text(attributed(diff))
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }

    private func attributed(_ diff: TextDiff.Result) -> AttributedString {
        var result = AttributedString()
        for segment in diff.segments {
            var piece = AttributedString(segment.text + " ")
            switch segment.change {
            case .unchanged:
                piece.foregroundColor = .secondary
            case .inserted:
                piece.backgroundColor = .green.opacity(0.22)
                piece.foregroundColor = .primary
            case .removed:
                piece.backgroundColor = .red.opacity(0.18)
                piece.foregroundColor = .primary
                piece.strikethroughStyle = .single
            }
            result += piece
        }
        return result
    }

    private func sign(for change: TextDiff.Change) -> String {
        switch change {
        case .inserted: "+"
        case .removed: "−"
        case .unchanged: " "
        }
    }

    private func tint(for change: TextDiff.Change) -> Color {
        switch change {
        case .inserted: .green.opacity(0.14)
        case .removed: .red.opacity(0.12)
        case .unchanged: .clear
        }
    }

    /// The two actions the roadmap calls out as what makes this more than a curiosity.
    private func footer(for diff: TextDiff.Result) -> some View {
        HStack(spacing: 10) {
            Text(summary(of: diff))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(copied == .diff ? "Copied" : "Copy the Diff") {
                copy(diff.unifiedText(), as: .diff)
            }
            .disabled(diff.isIdentical)
            Button(copied == .newer ? "Copied" : "Copy the Newer Version") {
                copy(comparison.newer.comparableText ?? "", as: .newer)
            }
        }
        .padding(12)
    }

    private func summary(of diff: TextDiff.Result) -> String {
        guard !diff.isIdentical else { return String(localized: "Identical") }
        let added = diff.insertedCount
        let removed = diff.removedCount
        // Four whole phrases rather than a unit spliced into one: the noun has to agree
        // with its own count, and in most languages that changes more than an "s".
        let parts = diff.granularity == .line
            ? [String(localized: "\(added) lines added"), String(localized: "\(removed) lines removed")]
            : [String(localized: "\(added) words added"), String(localized: "\(removed) words removed")]
        return parts.joined(separator: " · ")
    }

    private func copy(_ text: String, as what: Copied) {
        // The plain pasteboard rather than `PasteService`: this is the user copying
        // something, so it should land in history like any other copy.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        copied = what
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = nil
        }
    }
}

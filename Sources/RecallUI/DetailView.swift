import AppKit
import RecallCapture
import RecallCore
import SwiftUI

/// The detail pane: the full item, where it came from, and the warnings that apply to it.
struct DetailView: View {
    let item: ClipItem?
    @Bindable var model: AppModel
    /// True when this is opened inside a row rather than standing in a pane of its own.
    ///
    /// An embedded detail is bounded and does not scroll as a whole. An ordinary
    /// `ScrollView` in a list row swallows the wheel for as long as the pointer is over
    /// it, so scrolling the history stalls the moment you cross the open item.
    ///
    /// The long text *inside* it does scroll, because that is the part worth reading in
    /// place and ``ScrollableTextView`` hands the wheel back to the list at its own edge.
    /// Everything else here — a warning, a colour swatch, the metadata line — is short
    /// enough to fit, and Quick Look (space, or ⌘Y) is still the way to read something
    /// long properly.
    var isEmbedded: Bool = false

    var body: some View {
        if let item {
            let content = VStack(alignment: .leading, spacing: isEmbedded ? 6 : 12) {
                warnings(for: item)
                preview(for: item)
                metadata(for: item)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(isEmbedded ? 8 : 12)

            if isEmbedded {
                content.clipped()
            } else {
                ScrollView { content }
            }
        } else {
            ContentUnavailableView("Nothing selected", systemImage: "sidebar.right")
        }
    }

    @ViewBuilder
    private func warnings(for item: ClipItem) -> some View {
        if item.sensitivity == .secret {
            if item.isPinned {
                // Pinned means kept: say so plainly, and say what was detected, or the
                // warning teaches people to ignore warnings.
                CautionBox(
                    icon: "exclamationmark.shield",
                    tint: .orange,
                    title: "Pinned — kept until you remove it",
                    message: "This looks like a credential\(detectionSuffix(item)). Recall would normally delete it automatically; pinning it turned that off."
                )
            } else {
                CautionBox(
                    icon: "timer",
                    tint: .orange,
                    title: "Deletes itself shortly",
                    message: "This looks like a credential\(detectionSuffix(item)). Pin it if you need to keep it."
                )
            }
        }

        if item.isPinned, model.isInMemoryMode {
            CautionBox(
                icon: "internaldrive",
                tint: .secondary,
                title: "This pin is temporary",
                message: "In-Memory Mode keeps nothing on disk. Pins are cleared when Recall quits."
            )
        }
    }

    /// Names the rules that actually fired, so a false positive is obvious as one.
    private func detectionSuffix(_ item: ClipItem) -> String {
        guard !item.detectedRules.isEmpty else { return "" }
        let names = item.detectedRules.map { Self.ruleNames[$0] ?? $0 }
        return " — matched \(names.formatted(.list(type: .and)))"
    }

    /// Plain-language names for the detector's rule identifiers.
    private static let ruleNames: [String: String] = [
        "otp": "a one-time code",
        "credit-card": "a card number",
        "aws.access-key": "an AWS access key",
        "aws.secret-key": "an AWS secret key",
        "github.token": "a GitHub token",
        "generic.api-key": "an API key",
        "pem.private-key": "a private key",
        "jwt": "a JSON web token",
        "password.assignment": "a password assignment",
    ]

    @ViewBuilder
    private func preview(for item: ClipItem) -> some View {
        switch item.payload {
        case .image(let image):
            if let data = image.previewData, let nsImage = NSImage(data: data) {
                // Embedded, the whole detail is capped at 220pt — an image allowed to
                // take all of it would push the extracted text out of the row entirely.
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: isEmbedded ? 96 : 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if let ocr = item.ocrText, !ocr.isEmpty {
                LabeledBlock(title: "Text in image", text: ocr, isCopyable: true, isScrollable: isEmbedded)
            }

        case .color(let color):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: color.red, green: color.green, blue: color.blue).opacity(color.alpha))
                    .frame(width: 64, height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                Text(color.raw).font(.title3.monospaced())
            }

        case .files(let refs):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(refs, id: \.url) { ref in
                    Label(ref.url.path, systemImage: ref.isDirectory ? "folder" : "doc")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

        case .url(let url):
            VStack(alignment: .leading, spacing: 4) {
                if let title = item.link?.title {
                    Text(title).font(.headline)
                }
                Link(url.absoluteString, destination: url)
                    .font(.callout)
                    .lineLimit(2)
            }

        case .text(let text), .richText(_, let text):
            if item.sensitivity == .secret {
                Text("Hidden while this is marked sensitive.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isEmbedded {
                ScrollableTextView(text: text, isMonospaced: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// One line, not a table.
    ///
    /// It was a divider and a label/value grid — six rows of chrome under a preview that
    /// is capped at 220pt, so the metadata routinely took more room than the clip. The
    /// row above already says where a clip came from and when, so this says the rest and
    /// repeats only the exact timestamp the row shortens to "26m".
    @ViewBuilder
    private func metadata(for item: ClipItem) -> some View {
        let facts = facts(for: item)
        if !facts.isEmpty {
            Text(facts.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // Pinning and assigning a shortcode are the same intent arriving a moment apart,
        // so the offer sits here rather than interrupting the pin with a sheet.
        if item.isPinned, item.snippetCode == nil, item.payload.searchableText != nil {
            Button("Add a shortcode…") {
                model.snippetSheetTarget = item
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
    }

    private func facts(for item: ClipItem) -> [String] {
        var facts = [item.createdAt.formatted(date: .abbreviated, time: .shortened)]

        if item.useCount > 0 {
            facts.append("pasted \(item.useCount)×")
        }
        if item.isPinned {
            facts.append("pinned")
        }
        if !item.tags.isEmpty {
            facts.append(item.tags.sorted().map { "#\($0)" }.joined(separator: " "))
        }
        if let code = item.snippetCode {
            facts.append(code)
        }
        return facts
    }
}

private struct LabeledBlock: View {
    let title: String
    let text: String
    /// Offers a button that copies the whole block.
    ///
    /// Selecting by hand works, but the embedded detail is height-capped, so text past
    /// the fold cannot be dragged over. The button does not care what is visible.
    var isCopyable: Bool = false
    /// Scrolls in place rather than being cut off by the row's height.
    var isScrollable: Bool = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if isCopyable {
                    Button(didCopy ? "Copied" : "Copy") { copy() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(didCopy ? .secondary : Color.accentColor)
                }
                Spacer()
            }
            if isScrollable {
                ScrollableTextView(text: text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func copy() {
        // The plain pasteboard, not `PasteService`: this is the user copying something,
        // so it should land in history like any other copy rather than be suppressed as
        // one of Recall's own writes.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}

private struct CautionBox: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

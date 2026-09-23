import AppKit
import RecallCapture
import RecallCore
import SwiftUI

/// One row of history: an icon for the kind, the preview, and the provenance line.
public struct ItemRowView: View {
    let item: ClipItem
    /// True while the background pass is still fetching metadata or writing a summary.
    let isThinking: Bool
    let density: RowDensity
    let showsSourceIcon: Bool

    public init(
        item: ClipItem,
        isThinking: Bool = false,
        density: RowDensity = .comfortable,
        showsSourceIcon: Bool = true
    ) {
        self.item = item
        self.isThinking = isThinking
        self.density = density
        self.showsSourceIcon = showsSourceIcon
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 11) {
            leading
                .frame(width: 30, height: 30)
                // Clipped *after* the frame, not before. A `.fill` image is deliberately
                // larger than the box it is measured into, and SwiftUI does not clip on
                // its own — so a wide screenshot drew itself straight across the row and
                // over the text. The clip shape has to come after the frame that defines
                // what it is clipping to.
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(previewText)
                    .lineLimit(density.previewLineLimit)
                    .font(.system(size: 13, design: fontDesign))
                    .foregroundStyle(item.sensitivity == .secret ? .secondary : .primary)

                metadata
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, density.verticalPadding)
    }

    /// Monospace is for things whose *characters* matter — a hex colour, a file path.
    ///
    /// It used to be everything except plain text, which meant the words read out of a
    /// screenshot were set as if they were code. They are prose that happened to arrive
    /// as pixels.
    private var fontDesign: Font.Design {
        switch item.kind {
        case .color, .file: .monospaced
        case .text, .richText, .image, .url: .default
        }
    }

    /// One quiet line: where it came from, when, and every tag it carries — in that
    /// order, because that is the order you recognise a clip in.
    ///
    /// Tags used to be cut to the first two, so a clip the model gave four of showed two
    /// and gave no sign there were more. They are all here now; what keeps the line honest
    /// is layout priority rather than a cut. The source and the timestamp are asked for
    /// their space first, so a long run of tags truncates at the right-hand edge instead
    /// of shouldering the timestamp off the row.
    private var metadata: some View {
        HStack(spacing: 5) {
            if isThinking {
                // Say what is happening rather than leaving a row that will silently
                // rewrite itself a second later.
                ProgressView().controlSize(.mini).scaleEffect(0.7)
                Text("Reading…")
            }
            if let source = item.source?.localizedName {
                Text(source)
                Text("·")
            }
            Text(RelativeTime.label(for: item.createdAt))
                .monospacedDigit()
                .help(RelativeTime.exact(for: item.createdAt))

            ForEach(item.tags.sorted(), id: \.self) { tag in
                Text(tag)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
            // Only the tags give way when the row runs out of room.
            .layoutPriority(-1)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help(item.tags.isEmpty ? "" : item.tags.sorted().joined(separator: ", "))
    }

    /// State markers, right-aligned so they line up down the list instead of floating
    /// wherever the preview text happens to end.
    @ViewBuilder
    private var trailing: some View {
        HStack(spacing: 6) {
            if let code = item.snippetCode {
                Text(code)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
                    .help("Type this to expand the clip")
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .foregroundStyle(.secondary)
            }
            if item.sensitivity == .secret {
                // The countdown is the whole point: the user should see it disappearing.
                Image(systemName: "timer")
                    .foregroundStyle(.orange)
                    .help("Sensitive — deletes itself automatically")
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var leading: some View {
        switch item.payload {
        case .image(let image):
            // `previewData` is the thumbnail when the full image has been offloaded.
            if let data = image.previewData, let nsImage = NSImage(data: data) {
                // No clip here: it would clip to the oversized image's own bounds and
                // achieve nothing. The row clips to the 30×30 frame instead.
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
            }

        case .color(let color):
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: color.red, green: color.green, blue: color.blue).opacity(color.alpha))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))

        case .url:
            if let data = item.link?.faviconData, let icon = NSImage(data: data) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "link")
            }

        default:
            if showsSourceIcon, let icon = SourceAppResolver.icon(for: item.source) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: item.kind.systemImage)
            }
        }
    }

    /// Secrets are never previewed in the clear; long text prefers the AI summary.
    private var previewText: String {
        if item.sensitivity == .secret {
            return String(localized: "Sensitive value — hidden")
        }
        if let summary = item.summary, !summary.isEmpty {
            return summary
        }
        switch item.payload {
        case .text(let text), .richText(_, let text):
            return Self.singleLine(text) ?? ""
        case .url(let url):
            return item.link?.title ?? url.absoluteString
        case .color(let color):
            return color.raw
        case .image(let image):
            // Text lifted off a screenshot arrives with its layout still in it. One line
            // of it is a label; several are a mess in a 13pt row.
            if let text = Self.singleLine(item.ocrText), !text.isEmpty {
                return text
            }
            return String(localized: "Image — \(image.pixelWidth)×\(image.pixelHeight)")
        case .files(let refs):
            return refs.count == 1
                ? refs[0].url.lastPathComponent
                : String(localized: "\(refs.count) files")
        }
    }

    /// Collapses every run of whitespace — newlines included — into single spaces.
    static func singleLine(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

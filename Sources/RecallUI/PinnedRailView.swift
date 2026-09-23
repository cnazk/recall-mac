import RecallCore
import SwiftUI

/// The pinned group, always visible above the results.
///
/// It does not scroll away with a search, because a pin the user has to go looking for
/// has not earned its place. Slots 1–9 carry their shortcut in the corner.
struct PinnedRailView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Pinned", systemImage: "pin.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isInMemoryMode {
                    // Standing notice, not a one-off alert: the consequence lasts as long
                    // as the mode does.
                    Label("Cleared when Recall quits", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("In-Memory Mode keeps nothing on disk, including pins.")
                }
            }
            .padding(.horizontal, 14)

            ScrollView(.horizontal, showsIndicators: false) {
                // A container so neighbouring chips merge and separate as one material
                // rather than as a row of unrelated pills.
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                    ForEach(Array(model.pins.enumerated()), id: \.element.id) { index, item in
                        PinChip(item: item, slot: index + 1, settings: model.settings)
                            .onTapGesture {
                                Task { await model.paste(item) }
                            }
                            .contextMenu {
                                Button("Paste") { Task { await model.paste(item) } }
                                Button("Unpin") { Task { await model.togglePin(item) } }
                                if index > 0 {
                                    Button("Move Left") { Task { await move(from: index, to: index - 1) } }
                                }
                                if index < model.pins.count - 1 {
                                    Button("Move Right") { Task { await move(from: index, to: index + 1) } }
                                }
                            }
                            .draggable(item.id.uuidString)
                            .dropDestination(for: String.self) { received, _ in
                                guard let dropped = received.first,
                                      let sourceID = UUID(uuidString: dropped),
                                      let from = model.pins.firstIndex(where: { $0.id == sourceID })
                                else { return false }
                                Task { await move(from: from, to: index) }
                                return true
                            }
                    }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .padding(.top, 6)
    }

    private func move(from: Int, to: Int) async {
        var order = model.pins.map(\.id)
        guard order.indices.contains(from), order.indices.contains(to) else { return }
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        await model.reorderPins(order)
    }
}

private struct PinChip: View {
    let item: ClipItem
    let slot: Int
    let settings: RecallSettings

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.kind.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(item.railTitle)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)

            if slot <= 9 {
                Text("⌘\(slot)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Interactive glass: these are the one thing in the panel you hit directly
        // without reading first, and the material responds to the pointer.
        .glassSurface(Capsule(), settings: settings, isInteractive: true)
        .overlay(alignment: .topTrailing) {
            if item.sensitivity == .secret {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .offset(x: 3, y: -3)
                    .help("Kept deliberately — this looks like a credential.")
            }
        }
    }
}

public extension ClipItem {
    /// A short label for a chip or list. Secrets are never shown in the clear, pinned or
    /// not.
    var railTitle: String {
        if sensitivity == .secret { return String(localized: "Sensitive value") }
        if let summary, !summary.isEmpty { return summary }
        switch payload {
        case .text(let text), .richText(_, let text):
            return text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        case .url(let url):
            return link?.title ?? url.host ?? url.absoluteString
        case .color(let color):
            return color.raw
        case .image:
            return String(localized: "Image")
        case .files(let refs):
            return refs.count == 1 ? refs[0].url.lastPathComponent : String(localized: "\(refs.count) files")
        }
    }
}

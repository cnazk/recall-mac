import RecallCore
import SwiftUI

/// The scratchpad's contents: the history list, stripped to what a side-by-side session
/// needs — no sidebar, no detail pane, no tabs.
public struct ScratchpadView: View {
    @Bindable private var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(8)
            // Its title bar is hidden, so the search strip is the handle.
            .contentShape(.rect)
            .gesture(WindowDragGesture())

            Divider()

            List(model.items, selection: $model.selection) { item in
                ItemRowView(item: item, isThinking: model.isEnriching(item), density: model.settings.rowDensity)
                    .tag(item.id)
                    .itemDragProvider(item, model: model)
                    .onTapGesture(count: 2) {
                        Task { await model.paste(item) }
                    }
                    .contextMenu {
                        Button("Paste") { Task { await model.paste(item) } }
                        Button("Paste as Plain Text") { Task { await model.paste(item, style: .plainText) } }
                        if item.sensitivity != .secret {
                            Button("Quick Look") {
                                Task { await QuickLookPresenter.shared.toggle(item, using: model) }
                            }
                        }
                        Divider()
                        Button(item.isPinned ? "Unpin" : "Pin") { Task { await model.togglePin(item) } }
                    }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        // The same single glass surface as the panel: this window also floats over the
        // documents being worked in.
        // Continuous, to match the layer mask on the hosting view — macOS rounds
        // windows with a squircle, and a circular arc against one reads as a crease.
        .glassSurface(settings: model.settings)
        .frame(minWidth: 260, minHeight: 300)
        .task { await model.reload() }
    }
}

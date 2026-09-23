import RecallOTP
import SwiftUI

/// The Codes tab: the two-factor accounts, their current codes, and the ring draining
/// towards the next rotation.
public struct CodesView: View {
    @Bindable private var model: OTPModel
    @FocusState private var searchFocused: Bool
    @State private var showsManualEntry = false
    /// The account whose code was just copied, so the row can say so before the panel
    /// goes away.
    @State private var copiedAccountID: UUID?

    public init(model: OTPModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let uri = model.pendingImportURI {
                importPrompt(uri: uri)
                Divider()
            }

            // Anything that went wrong, said out loud. This used to be written to
            // `model.failure` and rendered only when the helper was entirely
            // unreachable — so a failed import set a string nobody ever saw, and the
            // button looked dead.
            if model.isHelperAvailable, let failure = model.failure {
                failureBanner(failure)
                Divider()
            }

            if !model.isHelperAvailable {
                unavailable
            } else if model.accounts.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task {
            await model.refresh()
            searchFocused = true
        }
        .sheet(isPresented: $showsManualEntry) {
            ManualAccountSheet(model: model)
        }
        .background(slotShortcuts)
    }

    /// ⌘1–9 copies the code for the nth account on screen, the same shortcut shape the
    /// history panel uses for pinned clips.
    private var slotShortcuts: some View {
        ForEach(1...9, id: \.self) { slot in
            Button("Copy code \(slot)") {
                let accounts = model.visibleAccounts
                guard slot <= accounts.count else { return }
                Task {
                    await model.pasteCode(for: accounts[slot - 1])
                    model.dismissPanel?()
                }
            }
            .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .command)
            .hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.rotation").foregroundStyle(.secondary)
            TextField("Search accounts", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.return) {
                    guard let first = model.visibleAccounts.first else { return .ignored }
                    Task {
                        await model.pasteCode(for: first)
                        model.dismissPanel?()
                    }
                    return .handled
                }
                // The same order as the history tab: the query first, then the panel.
                .onKeyPress(.escape) {
                    if model.searchText.isEmpty {
                        model.dismissPanel?()
                    } else {
                        model.searchText = ""
                    }
                    return .handled
                }

            Menu {
                Button("Scan QR Code on Screen…") {
                    Task { await model.importFromScreen() }
                }
                Button("Paste Setup Link") {
                    if let string = NSPasteboard.general.string(forType: .string) {
                        Task { await model.importURI(string) }
                    }
                }
                Button("Enter Manually…") { showsManualEntry = true }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
    }

    /// True when a live, unexpired code is already on screen for this account.
    private func isRevealed(_ account: OTPAccountSummary) -> Bool {
        guard let live = model.codes[account.id] else { return false }
        return !live.hasExpired
    }

    private func failureBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss") { model.clearFailure() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.orange.opacity(0.12))
    }

    private func importPrompt(uri: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "qrcode").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Two-factor setup link copied")
                    .font(.callout.weight(.medium))
                Text("Recall did not save it to history. Add it to your codes?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Not Now") { model.pendingImportURI = nil }
            Button("Add") { Task { await model.importURI(uri) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
    }

    private var list: some View {
        List(model.visibleAccounts) { account in
            CodeRow(
                account: account,
                live: model.codes[account.id],
                wasCopied: copiedAccountID == account.id
            )
                .contentShape(Rectangle())
                // First click reveals — which is what the authentication is for. Once a
                // code is on screen it has already been paid for, so the next click does
                // the thing you actually wanted: copies it and gets out of the way.
                .onTapGesture {
                    Task {
                        guard isRevealed(account) else {
                            await model.requestCode(for: account)
                            return
                        }
                        await model.pasteCode(for: account)

                        // Long enough to register as confirmation, short enough not to
                        // feel like waiting. Without the pause the panel is gone before
                        // the row has finished turning green.
                        withAnimation(.easeOut(duration: 0.15)) { copiedAccountID = account.id }
                        try? await Task.sleep(for: .milliseconds(450))
                        copiedAccountID = nil
                        model.dismissPanel?()
                    }
                }
                .contextMenu {
                    Button("Copy Code") {
                        Task {
                            await model.pasteCode(for: account)
                            withAnimation(.easeOut(duration: 0.15)) { copiedAccountID = account.id }
                            try? await Task.sleep(for: .milliseconds(450))
                            copiedAccountID = nil
                            model.dismissPanel?()
                        }
                    }
                    Divider()
                    Button("Remove…", role: .destructive) {
                        Task { await model.remove(account) }
                    }
                }
        }
        .listStyle(.inset)
        // Without this the list paints its own opaque backing and the glass stops at the
        // search bar — the Codes tab was a white slab below the header while the history
        // tab beside it was translucent.
        .scrollContentBackground(.hidden)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No two-factor accounts", systemImage: "lock.rotation")
        } description: {
            Text("Add one by scanning a setup QR code on screen, or by copying its setup link.")
        } actions: {
            Button("Scan QR Code on Screen…") {
                Task { await model.importFromScreen() }
            }
            Button("Enter Manually…") { showsManualEntry = true }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Two-factor helper unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(model.failure ?? String(localized: "The helper that holds your two-factor secrets could not be reached."))
                .font(.caption)
            Button("Try Again") {
                Task { await model.refresh() }
            }
            .controlSize(.small)
        }
    }
}

/// One account: label, code, and the ring.
private struct CodeRow: View {
    let account: OTPAccountSummary
    let live: OTPModel.LiveCode?
    /// True for the moment just after this code was copied.
    var wasCopied = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.issuer.isEmpty ? account.account : account.issuer)
                    .font(.callout.weight(.medium))
                if !account.issuer.isEmpty {
                    Text(account.account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let live {
                // The clock lives here, around the two things that actually move.
                //
                // It used to be one `Timer.publish` driving a `now` on the whole view,
                // which invalidated the entire Codes tab — search field, list and all —
                // once a second. A `TimelineView` redraws only what it wraps.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // An expired code is not a code. It used to hang on screen until the
                    // account was unlocked again — a number that looks usable, is not,
                    // and has no business still being displayed.
                    if remaining(live, at: context.date) > 0 {
                        HStack(spacing: 10) {
                            Text(formatted(live.code))
                                .font(.title3.monospacedDigit())
                                // Green says copied; amber says this will rotate in under
                                // five seconds and pasting it is likely to fail. Copied
                                // wins, because it is the thing that just happened.
                                .foregroundStyle(codeColour(live, at: context.date))
                                .scaleEffect(wasCopied ? 1.06 : 1)
                                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: wasCopied)
                            DrainRing(fraction: live.fraction(at: context.date))
                                .frame(width: 18, height: 18)
                        }
                        .transition(.opacity)
                    } else {
                        locked
                    }
                }
            } else {
                locked
            }
        }
        .padding(.vertical, 4)
    }

    private var locked: some View {
        Text("Click to show")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func codeColour(_ live: OTPModel.LiveCode, at date: Date) -> Color {
        if wasCopied { return .green }
        return remaining(live, at: date) <= 5 ? .orange : .primary
    }

    private func remaining(_ live: OTPModel.LiveCode, at date: Date) -> Int {
        max(0, live.secondsRemaining - Int(date.timeIntervalSince(live.fetchedAt)))
    }

    /// Codes read more easily split in half, the way authenticator apps show them.
    private func formatted(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }
}

private struct DrainRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(fraction < 0.2 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: fraction)
        }
    }
}

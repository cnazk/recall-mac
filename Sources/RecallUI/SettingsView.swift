import RecallOTP
import RecallCore
import RecallSecurity
import SwiftUI

/// The preferences window (⌘,).
public struct SettingsView: View {
    @Bindable private var controller: SettingsController
    @State private var newName = ""
    @State private var newText = ""
    @State private var newTag = ""

    /// Supplies the current shortcodes for the read-only list.
    private let snippetProvider: (() -> [(code: String, title: String)])?
    private let otp: OTPModel?
    private let usageProvider: (() async -> (count: Int, bytes: Int64)?)?
    @State private var usage: (count: Int, bytes: Int64)?
    @State private var loginItemState = LoginItem.state
    @State private var authenticationPolicy: OTPAuthenticationPolicy = .default
    /// Remembered separately so switching away from "after a while" and back does not
    /// forget the length that was chosen.
    @State private var graceMinutes = 5
    @State private var exportedURIs: [String] = []

    public init(
        controller: SettingsController,
        otp: OTPModel? = nil,
        usageProvider: (() async -> (count: Int, bytes: Int64)?)? = nil,
        snippetProvider: (() -> [(code: String, title: String)])? = nil
    ) {
        self.controller = controller
        self.otp = otp
        self.usageProvider = usageProvider
        self.snippetProvider = snippetProvider
    }

    @State private var tab: SettingsTab = .general

    public var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            privacy.tabItem { Label("Privacy", systemImage: "lock") }.tag(SettingsTab.privacy)
            intelligence.tabItem { Label("Intelligence", systemImage: "sparkles") }.tag(SettingsTab.intelligence)
            collections.tabItem { Label("Collections", systemImage: "folder") }.tag(SettingsTab.collections)
            snippets.tabItem { Label("Snippets", systemImage: "text.badge.plus") }.tag(SettingsTab.snippets)
            if otp != nil {
                twoFactor.tabItem { Label("Two-Factor", systemImage: "lock.rotation") }.tag(SettingsTab.twoFactor)
            }
        }
        // Wide enough for six tabs. Narrower, and AppKit gives up and collapses them
        // into a "Navigation Tab Bar" overflow menu behind a chevron, which is a worse
        // way to present six items than any of the alternatives.
        .frame(width: 640)
        .scenePadding()
        // Something asked for a particular page — the ✨ in the panel, for one. Handled
        // both on appear and on change, so it works whether Settings was already open or
        // is opening because of the request.
        .onAppear { honourRequestedTab() }
        .onChange(of: SettingsNavigator.shared.requestedTab) { _, _ in honourRequestedTab() }
    }

    private func honourRequestedTab() {
        guard let requested = SettingsNavigator.shared.consumeRequest() else { return }
        tab = requested
    }

    // MARK: - General

    private var general: some View {
        Form {
            Section {
                Toggle("Open Recall at login", isOn: Binding(
                    get: { loginItemState.isOn },
                    set: { loginItemState = LoginItem.setEnabled($0) }
                ))
                .disabled(loginItemState == .unavailable)

                switch loginItemState {
                case .awaitingApproval:
                    HStack(spacing: 6) {
                        Text("Waiting for approval in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open") { LoginItem.openSystemSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                case .unavailable:
                    Text("Move Recall to your Applications folder to start it at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                default:
                    Text("Recall only records while it is running, so it needs to come back after a restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Keep history", selection: binding(\.storageMode)) {
                    Text("On disk, encrypted").tag(StorageMode.persistent)
                    Text("In memory only").tag(StorageMode.inMemory)
                }
                if controller.isInMemoryMode {
                    Label(
                        "Nothing is written to disk. Your history — including pinned items — is cleared when Recall quits.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Picker("Remember", selection: binding(\.historyLimit)) {
                    Text("200 items").tag(200)
                    Text("1,000 items").tag(1_000)
                    Text("5,000 items").tag(5_000)
                    Text("20,000 items").tag(20_000)
                }
                .disabled(controller.isInMemoryMode)

                Picker("Delete items after", selection: retentionBinding) {
                    Text("A day").tag(TimeInterval(60 * 60 * 24))
                    Text("A week").tag(TimeInterval(60 * 60 * 24 * 7))
                    Text("A month").tag(TimeInterval(60 * 60 * 24 * 30))
                    Text("Never").tag(TimeInterval(0))
                }
                .disabled(controller.isInMemoryMode)

                Text("Pinned items are never deleted automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Row height", selection: binding(\.rowDensity)) {
                    Text("Comfortable").tag(RowDensity.comfortable)
                    Text("Compact").tag(RowDensity.compact)
                }
                Toggle("Show the icon of the app each item came from", isOn: binding(\.showsSourceIcons))
            }

            Section {
                Toggle("Liquid Glass", isOn: binding(\.liquidGlassEnabled))

                if controller.settings.liquidGlassEnabled {
                    // A slider rather than named steps: this is a matter of taste against
                    // whatever wallpaper you happen to have, and the right answer is
                    // wherever it stops looking wrong to you.
                    let intensity = Binding<Double>(
                        get: { controller.settings.glassIntensity.value },
                        set: { newValue in
                            controller.update { $0.glassIntensity = GlassIntensity(newValue) }
                        }
                    )
                    Slider(value: intensity, in: 0...1) {
                        Text("Intensity")
                    } minimumValueLabel: {
                        Text("Subtle").font(.caption).foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("Strong").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(controller.settings.liquidGlassEnabled
                    ? "How much of what is behind shows through the panel, the scratchpad and the pinned items. Turn it off for a plain background — easier to read against a busy desktop."
                    : "The panel, the scratchpad and the pinned items use a plain material instead.")
                    .font(.caption)
            }

            Section {
                Toggle("Paste several items in order", isOn: binding(\.pasteStackEnabled))
            } footer: {
                Text("⌃⌥⌘C queues the last thing you copied; ⌃⌥⌘V pastes the queue in the order you added it, one item per press. A small readout shows what is next. The queue clears itself after ten idle minutes, and ⌘V is never touched.")
                    .font(.caption)
            }

            Section("Opening the panel") {
                Picker("Show Recall with", selection: binding(\.activation)) {
                    Text("Keyboard shortcut only").tag(ActivationStyle.hotkeyOnly)
                    Text("Shortcut or screen edge").tag(ActivationStyle.hotkeyAndScreenEdge)
                }
                if controller.settings.activation == .hotkeyAndScreenEdge {
                    Picker("Screen edge", selection: binding(\.screenEdge)) {
                        Text("Left").tag(ScreenEdge.left)
                        Text("Right").tag(ScreenEdge.right)
                    }
                    Picker("Open after", selection: binding(\.edgeTriggerDwell)) {
                        Text("Immediately").tag(TimeInterval(0.05))
                        Text("A moment").tag(TimeInterval(0.12))
                        Text("A pause").tag(TimeInterval(0.35))
                    }
                    Text("The panel will not open while you are dragging something, or near a hot corner.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("History size") {
                if let usage {
                    LabeledContent("Stored", value: "\(usage.count.formatted()) items")
                    LabeledContent(
                        "On disk",
                        value: usage.bytes == 0
                            ? "Nothing — In-Memory Mode"
                            : ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
                    )
                } else {
                    Text("Measuring…").font(.caption).foregroundStyle(.secondary)
                }
            }

            if controller.needsRestart {
                Label("Quit and reopen Recall to apply the storage change.", systemImage: "arrow.clockwise")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .task {
            usage = await usageProvider?()
            // The user may have revoked it in System Settings since we last looked.
            loginItemState = LoginItem.state
        }
    }

    // MARK: - Privacy

    private var privacy: some View {
        Form {
            Section {
                LabeledContent("Delete detected secrets after") {
                    Picker("", selection: binding(\.secretTimeToLive)) {
                        Text("30 seconds").tag(TimeInterval(30))
                        Text("1 minute").tag(TimeInterval(60))
                        Text("5 minutes").tag(TimeInterval(300))
                    }
                    .labelsHidden()
                }
                Text("2FA codes, card numbers and API keys are detected as they are copied and removed automatically — unless you pin them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What counts as sensitive") {
                Text("Turn a rule off if it keeps catching something that is not a secret. Anything still switched on is detected as it is copied and removed automatically, unless you pin it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                DisclosureGroup("Service credentials (\(enabledCount(in: SecretRule.providerRules)) of \(SecretRule.providerRules.count) on)") {
                    ForEach(SecretRule.providerRules, id: \.identifier) { rule in
                        ruleToggle(rule)
                    }
                }

                ForEach(SecretRule.builtIn.filter { rule in
                    !SecretRule.providerRules.contains { $0.identifier == rule.identifier }
                }, id: \.identifier) { rule in
                    ruleToggle(rule)
                }
            }

            Section("Never captured from") {
                Text("Password managers, keychains and authenticator apps are always excluded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(controller.settings.userExcludedBundleIDs.sorted(), id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).font(.callout.monospaced())
                        Spacer()
                        Button("Remove") {
                            controller.update { $0.userExcludedBundleIDs.remove(bundleID) }
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            Section("Links") {
                Toggle("Fetch titles and icons for copied links", isOn: binding(\.enrichLinks))
                Text("The only time Recall uses the network. Everything else, including all AI, happens on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Intelligence

    private var intelligence: some View {
        Form {
            Section {
                Toggle("Clean up messy text as it is copied", isOn: binding(\.normalizeWhitespace))
                Toggle("Read text in copied images", isOn: binding(\.ocrImages))
                Toggle("Search by meaning as well as words", isOn: binding(\.semanticSearchEnabled))
                Toggle("Summarize long clippings", isOn: binding(\.summarizeLongText))
                Toggle("Sort clippings into collections", isOn: binding(\.autoTaggingEnabled))
            } footer: {
                Text("All processing happens on device. Nothing is ever sent to a server.")
                    .font(.caption)
            }

            Section {
                Button("Reset All Settings", role: .destructive) {
                    controller.resetToDefaults()
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Collections

    private var collections: some View {
        Form {
            Section {
                ForEach(controller.settings.collections) { collection in
                    HStack {
                        Label(collection.name, systemImage: collection.systemImage)
                        Spacer()
                        Text(collection.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Toggle("Show", isOn: enabledBinding(for: collection))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        Button {
                            controller.update { $0.collections.removeAll { $0.id == collection.id } }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Collections are saved searches. Clearing history does not remove them.")
                    .font(.caption)
            }

            Section("New collection") {
                TextField("Name", text: $newName)
                TextField("Matching text (optional)", text: $newText)
                TextField("Tag (optional)", text: $newTag)
                Button("Add Collection") {
                    addCollection()
                }
                .disabled(!canAddCollection)
            }
        }
        .formStyle(.grouped)
    }

    private var canAddCollection: Bool {
        !newName.trimmingCharacters(in: .whitespaces).isEmpty
            && !(newText.isEmpty && newTag.isEmpty)
    }

    private func addCollection() {
        let collection = SmartCollection(
            name: newName.trimmingCharacters(in: .whitespaces),
            systemImage: "folder",
            tags: newTag.isEmpty ? [] : [newTag.lowercased()],
            textContains: newText.isEmpty ? nil : newText
        )
        // A collection with no conditions would match everything and look like a bug.
        guard collection.isWellFormed else { return }

        controller.update { $0.collections.append(collection) }
        newName = ""
        newText = ""
        newTag = ""
    }

    private func enabledBinding(for collection: SmartCollection) -> Binding<Bool> {
        Binding(
            get: { collection.isEnabled },
            set: { isEnabled in
                controller.update { settings in
                    guard let index = settings.collections.firstIndex(where: { $0.id == collection.id }) else { return }
                    settings.collections[index].isEnabled = isEnabled
                }
            }
        )
    }

    // MARK: - Snippets

    private var snippets: some View {
        Form {
            Section {
                Toggle("Expand shortcodes as I type", isOn: binding(\.snippetExpansionEnabled))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type a shortcode such as :sig anywhere and Recall replaces it with the item.")
                    Text("This needs Accessibility permission, because it is the only way to see typing outside Recall. Recall listens — it can never change or block a keystroke — and keeps only the last few characters, discarded the moment you press Return or move the cursor.")
                }
                .font(.caption)
            }

            Section("Shortcodes") {
                if snippetItems.isEmpty {
                    Text("None yet. Right-click an item in the history panel and choose “Add Shortcode…”.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snippetItems, id: \.code) { entry in
                        HStack {
                            Text(entry.code).font(.callout.monospaced())
                            Spacer()
                            Text(entry.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Shortcodes live on the items themselves, so this is display-only here; editing
    /// happens in the panel, next to the item it belongs to.
    private var snippetItems: [(code: String, title: String)] {
        (snippetProvider?() ?? []).sorted { $0.code < $1.code }
    }

    /// One rule's switch, with the plain-language summary under it.
    @ViewBuilder
    private func ruleToggle(_ rule: SecretRule) -> some View {
        Toggle(isOn: Binding(
            get: { !controller.settings.disabledSecretRules.contains(rule.identifier) },
            set: { isOn in
                controller.update { settings in
                    if isOn {
                        settings.disabledSecretRules.remove(rule.identifier)
                    } else {
                        settings.disabledSecretRules.insert(rule.identifier)
                    }
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.displayName)
                Text(rule.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func enabledCount(in rules: [SecretRule]) -> Int {
        rules.count { !controller.settings.disabledSecretRules.contains($0.identifier) }
    }

    // MARK: - Two-factor

    /// The three choices, separate from the policy itself so that picking "after a while"
    /// does not have to invent a length before the length picker appears.
    private enum AuthenticationChoice: Hashable {
        case always, afterGrace, never

        init(_ policy: OTPAuthenticationPolicy) {
            switch policy {
            case .always: self = .always
            case .afterGrace: self = .afterGrace
            case .never: self = .never
            }
        }
    }

    private func apply(_ choice: AuthenticationChoice, otp: OTPModel) {
        switch choice {
        case .always: set(.always, otp: otp)
        case .never: set(.never, otp: otp)
        case .afterGrace: set(.afterGrace(minutes: graceMinutes), otp: otp)
        }
    }

    private func set(_ policy: OTPAuthenticationPolicy, otp: OTPModel) {
        authenticationPolicy = policy
        Task { await otp.setAuthenticationPolicy(policy) }
    }

    @ViewBuilder
    private var twoFactor: some View {
        if let otp {
            Form {
                Section {
                    Picker("Ask for Touch ID", selection: Binding(
                        get: { AuthenticationChoice(authenticationPolicy) },
                        set: { apply($0, otp: otp) }
                    )) {
                        Text("Every time").tag(AuthenticationChoice.always)
                        Text("After a while").tag(AuthenticationChoice.afterGrace)
                        Text("Never").tag(AuthenticationChoice.never)
                    }

                    if case .afterGrace = authenticationPolicy {
                        Picker("Ask again after", selection: Binding(
                            get: { graceMinutes },
                            set: { minutes in
                                graceMinutes = minutes
                                set(.afterGrace(minutes: minutes), otp: otp)
                            }
                        )) {
                            ForEach(OTPAuthenticationPolicy.graceOptions, id: \.self) { minutes in
                                Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                            }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(authenticationPolicy.summary)
                        Text("Your two-factor secrets are held by a separate, sandboxed helper — Recall itself never sees them, only the six digits you ask for.")
                    }
                    .font(.caption)
                }

                Section("Accounts") {
                    if otp.accounts.isEmpty {
                        Text("None yet. Press ⌘⇧A and scan a setup QR code on screen.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(otp.accounts) { account in
                            Text(account.label).font(.callout)
                        }
                    }
                }

                Section {
                    Button("Export Setup Links…") {
                        Task { exportedURIs = await otp.exportURIs() }
                    }
                    .disabled(otp.accounts.isEmpty)

                    if !exportedURIs.isEmpty {
                        // Shown once, never stored: copying them is the user's choice.
                        ForEach(exportedURIs, id: \.self) { uri in
                            Text(uri)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                    }
                } footer: {
                    Text("Export asks for Touch ID every time. An authenticator that holds your secrets hostage is a worse authenticator.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)
            .task {
                authenticationPolicy = await otp.authenticationPolicy()
                if case .afterGrace(let minutes) = authenticationPolicy { graceMinutes = minutes }
                await otp.refresh()
            }
        }
    }

    // MARK: - Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<RecallSettings, Value>) -> Binding<Value> {
        Binding(
            get: { controller.settings[keyPath: keyPath] },
            set: { newValue in controller.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// `0` stands in for "never" so the picker can use a non-optional tag.
    private var retentionBinding: Binding<TimeInterval> {
        Binding(
            get: { controller.settings.retention ?? 0 },
            set: { newValue in
                controller.update { $0.retention = newValue == 0 ? nil : newValue }
            }
        )
    }
}

private extension SmartCollection {
    /// A one-line description of what the collection matches, for the settings list.
    var summary: String {
        var parts: [String] = []
        if pinnedOnly { parts.append("pinned") }
        if !tags.isEmpty { parts.append(tags.sorted().map { "#\($0)" }.joined(separator: " ")) }
        if !kinds.isEmpty { parts.append(kinds.map(\.rawValue).sorted().joined(separator: ", ")) }
        if let textContains, !textContains.isEmpty { parts.append("“\(textContains)”") }
        if let sourceApp, !sourceApp.isEmpty { parts.append("from \(sourceApp)") }
        return parts.joined(separator: " · ")
    }
}

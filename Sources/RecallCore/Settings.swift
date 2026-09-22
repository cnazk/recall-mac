import Foundation

/// Where history lives for this run of the app.
public enum StorageMode: String, Codable, Sendable, CaseIterable {
    /// Encrypted SQLite file under Application Support.
    case persistent
    /// Nothing touches the disk; quitting the app discards the whole history.
    case inMemory
}

/// How the history panel is summoned.
public enum ActivationStyle: String, Codable, Sendable, CaseIterable {
    case hotkeyOnly
    case hotkeyAndScreenEdge
}

public enum ScreenEdge: String, Codable, Sendable, CaseIterable {
    case left
    case right
}

/// How much of what is behind shows through Recall's floating windows.
///
/// Liquid Glass has no intensity dial of its own — it is one material. This is a scrim
/// drawn between the glass and the content: more scrim, less show-through. So 0 is the
/// quiet end and 1 is the material left to do its thing.
///
/// A clamped value rather than a bare `Double`, so nothing downstream has to wonder
/// whether it was handed 1.4 or -0.2 by a settings file from somewhere else.
public struct GlassIntensity: Codable, Sendable, Equatable, Hashable {
    /// Between 0 and 1 inclusive, always.
    public let value: Double

    /// The most the content is ever dimmed, at intensity 0. Past this the panel stops
    /// looking like glass at all, which is what the off switch is for.
    public static let maximumScrim = 0.5

    /// Where the material changes from `regular` to `clear`.
    ///
    /// The scrim alone could only ever take the panel from dim to *plain* glass — at the
    /// top of the range it simply ran out, and "strongest" looked no clearer than
    /// three-quarters. The upper half switches material instead, so the bar keeps going
    /// somewhere: dim → plain glass → genuinely clear.
    public static let clearThreshold = 0.5

    /// Scrim used at the bottom of the clear half, chosen so the two materials meet
    /// without a visible step at the crossover.
    static let clearMatchingScrim = 0.18

    public static let `default` = GlassIntensity(0.6)

    public init(_ value: Double) {
        self.value = value.isFinite ? min(max(value, 0), 1) : 0.6
    }

    /// Whether this intensity uses the clear material rather than the regular one.
    public var usesClearMaterial: Bool {
        value >= Self.clearThreshold
    }

    /// Opacity of the scrim behind the content.
    ///
    /// Each half of the bar fades its own scrim out towards the top, so the whole range
    /// reads as one continuous move from opaque towards invisible.
    public var scrim: Double {
        if usesClearMaterial {
            let position = (value - Self.clearThreshold) / (1 - Self.clearThreshold)
            return (1 - position) * Self.clearMatchingScrim
        }
        let position = value / Self.clearThreshold
        return (1 - position) * Self.maximumScrim + position * Self.clearMatchingScrim
    }

    /// Encoded as a plain number, so the settings file stays readable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self.init(number)
            return
        }
        // The three named levels this replaced. Decoded so an existing choice carries
        // over instead of silently resetting to the default.
        let named = try container.decode(String.self)
        switch named {
        case "subtle": self.init(0)
        case "medium": self.init(0.5)
        case "strong": self.init(1)
        default: self.init(Self.default.value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// How tightly history rows are packed.
public enum RowDensity: String, Codable, Sendable, CaseIterable {
    case comfortable
    case compact

    /// Vertical padding per row.
    public var verticalPadding: Double {
        switch self {
        case .comfortable: 3
        case .compact: 1
        }
    }

    /// Lines of preview text shown.
    public var previewLineLimit: Int {
        switch self {
        case .comfortable: 2
        case .compact: 1
        }
    }
}

/// User-facing configuration. Everything here is local; none of it is ever uploaded.
public struct RecallSettings: Codable, Sendable, Equatable {
    public var storageMode: StorageMode
    public var historyLimit: Int
    /// Items older than this are pruned. `nil` keeps history forever.
    public var retention: TimeInterval?
    /// How long a detected secret survives before it is deleted.
    public var secretTimeToLive: TimeInterval
    public var normalizeWhitespace: Bool
    public var enrichLinks: Bool
    public var ocrImages: Bool
    public var semanticSearchEnabled: Bool
    public var summarizeLongText: Bool
    public var autoTaggingEnabled: Bool
    public var activation: ActivationStyle
    public var screenEdge: ScreenEdge
    /// Bundle identifiers we refuse to capture from, on top of the built-in list.
    public var userExcludedBundleIDs: Set<String>
    /// Long text is summarised only past this length.
    public var summaryThreshold: Int
    /// Saved views shown in the panel sidebar.
    public var collections: [SmartCollection]
    public var rowDensity: RowDensity
    /// Show the icon of the app a clip came from.
    public var showsSourceIcons: Bool
    /// Seen the first-run explanation of the permissions Recall may ask for.
    public var hasCompletedOnboarding: Bool
    /// Dwell time at the screen edge before the panel slides out, in seconds.
    public var edgeTriggerDwell: TimeInterval
    /// Queue several clips with ⌃⌥⌘C and paste them in order with ⌃⌥⌘V.
    public var pasteStackEnabled: Bool
    /// Identifiers of secret rules the user has switched off. Stored as the disabled set
    /// rather than the enabled one, so a rule added in a later version is on by default —
    /// a detector that silently stops covering new formats is worse than useless.
    public var disabledSecretRules: Set<String>
    /// Expand typed shortcodes such as `:sig`. Off until the user asks for it, because it
    /// is the one feature that needs an event tap.
    public var snippetExpansionEnabled: Bool
    /// Draw the floating windows with Liquid Glass. Off falls back to a plain material,
    /// which is what someone who finds the translucency distracting — or hard to read
    /// against a busy desktop — actually wants.
    public var liquidGlassEnabled: Bool
    public var glassIntensity: GlassIntensity

    public static let `default` = RecallSettings(
        storageMode: .persistent,
        historyLimit: 5_000,
        retention: 60 * 60 * 24 * 30,
        secretTimeToLive: 60,
        normalizeWhitespace: true,
        enrichLinks: true,
        ocrImages: true,
        semanticSearchEnabled: true,
        summarizeLongText: true,
        autoTaggingEnabled: true,
        activation: .hotkeyAndScreenEdge,
        screenEdge: .right,
        userExcludedBundleIDs: [],
        summaryThreshold: 600,
        collections: SmartCollection.builtIn,
        snippetExpansionEnabled: false,
        pasteStackEnabled: false,
        disabledSecretRules: [],
        rowDensity: .comfortable,
        showsSourceIcons: true,
        hasCompletedOnboarding: false,
        edgeTriggerDwell: 0.12,
        liquidGlassEnabled: true,
        glassIntensity: .default
    )

    public init(
        storageMode: StorageMode,
        historyLimit: Int,
        retention: TimeInterval?,
        secretTimeToLive: TimeInterval,
        normalizeWhitespace: Bool,
        enrichLinks: Bool,
        ocrImages: Bool,
        semanticSearchEnabled: Bool,
        summarizeLongText: Bool,
        autoTaggingEnabled: Bool,
        activation: ActivationStyle,
        screenEdge: ScreenEdge,
        userExcludedBundleIDs: Set<String>,
        summaryThreshold: Int,
        collections: [SmartCollection] = SmartCollection.builtIn,
        snippetExpansionEnabled: Bool = false,
        pasteStackEnabled: Bool = false,
        disabledSecretRules: Set<String> = [],
        rowDensity: RowDensity = .comfortable,
        showsSourceIcons: Bool = true,
        hasCompletedOnboarding: Bool = false,
        edgeTriggerDwell: TimeInterval = 0.12,
        liquidGlassEnabled: Bool = true,
        glassIntensity: GlassIntensity = .default
    ) {
        self.storageMode = storageMode
        self.historyLimit = historyLimit
        self.retention = retention
        self.secretTimeToLive = secretTimeToLive
        self.normalizeWhitespace = normalizeWhitespace
        self.enrichLinks = enrichLinks
        self.ocrImages = ocrImages
        self.semanticSearchEnabled = semanticSearchEnabled
        self.summarizeLongText = summarizeLongText
        self.autoTaggingEnabled = autoTaggingEnabled
        self.activation = activation
        self.screenEdge = screenEdge
        self.userExcludedBundleIDs = userExcludedBundleIDs
        self.summaryThreshold = summaryThreshold
        self.collections = collections
        self.snippetExpansionEnabled = snippetExpansionEnabled
        self.pasteStackEnabled = pasteStackEnabled
        self.disabledSecretRules = disabledSecretRules
        self.rowDensity = rowDensity
        self.showsSourceIcons = showsSourceIcons
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.edgeTriggerDwell = edgeTriggerDwell
        self.liquidGlassEnabled = liquidGlassEnabled
        self.glassIntensity = glassIntensity
    }
}

public extension RecallSettings {
    /// Decoding is hand-written, and every field is decoded leniently.
    ///
    /// Two ways a settings blob goes stale, and both have to be survivable. A blob saved
    /// *before* a field existed is missing it. A blob saved by a *newer* build can carry
    /// an enum case this one has never heard of — and that throws, which would take every
    /// other preference down with it. `try?` covers both: one unreadable field falls back
    /// to its default and the rest of the file is kept.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = RecallSettings.default

        self.init(
            storageMode: (try? container.decodeIfPresent(StorageMode.self, forKey: .storageMode)) ?? fallback.storageMode,
            historyLimit: (try? container.decodeIfPresent(Int.self, forKey: .historyLimit)) ?? fallback.historyLimit,
            retention: (try? container.decodeIfPresent(TimeInterval.self, forKey: .retention)) ?? nil,
            secretTimeToLive: (try? container.decodeIfPresent(TimeInterval.self, forKey: .secretTimeToLive)) ?? fallback.secretTimeToLive,
            normalizeWhitespace: (try? container.decodeIfPresent(Bool.self, forKey: .normalizeWhitespace)) ?? fallback.normalizeWhitespace,
            enrichLinks: (try? container.decodeIfPresent(Bool.self, forKey: .enrichLinks)) ?? fallback.enrichLinks,
            ocrImages: (try? container.decodeIfPresent(Bool.self, forKey: .ocrImages)) ?? fallback.ocrImages,
            semanticSearchEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .semanticSearchEnabled)) ?? fallback.semanticSearchEnabled,
            summarizeLongText: (try? container.decodeIfPresent(Bool.self, forKey: .summarizeLongText)) ?? fallback.summarizeLongText,
            autoTaggingEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .autoTaggingEnabled)) ?? fallback.autoTaggingEnabled,
            activation: (try? container.decodeIfPresent(ActivationStyle.self, forKey: .activation)) ?? fallback.activation,
            screenEdge: (try? container.decodeIfPresent(ScreenEdge.self, forKey: .screenEdge)) ?? fallback.screenEdge,
            userExcludedBundleIDs: (try? container.decodeIfPresent(Set<String>.self, forKey: .userExcludedBundleIDs)) ?? [],
            summaryThreshold: (try? container.decodeIfPresent(Int.self, forKey: .summaryThreshold)) ?? fallback.summaryThreshold,
            collections: (try? container.decodeIfPresent([SmartCollection].self, forKey: .collections)) ?? fallback.collections,
            snippetExpansionEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .snippetExpansionEnabled)) ?? false,
            pasteStackEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .pasteStackEnabled)) ?? false,
            disabledSecretRules: (try? container.decodeIfPresent(Set<String>.self, forKey: .disabledSecretRules)) ?? [],
            rowDensity: (try? container.decodeIfPresent(RowDensity.self, forKey: .rowDensity)) ?? fallback.rowDensity,
            showsSourceIcons: (try? container.decodeIfPresent(Bool.self, forKey: .showsSourceIcons)) ?? true,
            hasCompletedOnboarding: (try? container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)) ?? false,
            edgeTriggerDwell: (try? container.decodeIfPresent(TimeInterval.self, forKey: .edgeTriggerDwell)) ?? fallback.edgeTriggerDwell,
            liquidGlassEnabled: (try? container.decodeIfPresent(Bool.self, forKey: .liquidGlassEnabled)) ?? fallback.liquidGlassEnabled,
            glassIntensity: (try? container.decodeIfPresent(GlassIntensity.self, forKey: .glassIntensity)) ?? fallback.glassIntensity
        )
    }
}

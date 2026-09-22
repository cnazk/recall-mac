import Foundation
import Testing
@testable import RecallCore

@Suite("Liquid Glass settings")
struct GlassSettingsTests {
    @Test("Glass is on by default, and not at either extreme")
    func defaults() {
        #expect(RecallSettings.default.liquidGlassEnabled)
        let intensity = RecallSettings.default.glassIntensity
        #expect(intensity.value > 0 && intensity.value < 1)
    }

    @Test("The bar runs from most-dimmed to not dimmed at all")
    func scrimOrdering() {
        #expect(GlassIntensity(1).scrim == 0)
        #expect(GlassIntensity(0).scrim == GlassIntensity.maximumScrim)
        #expect(GlassIntensity(0).scrim < 1, "a scrim that opaque stops being a scrim")
    }

    /// Nothing anywhere on the bar should make the panel *more* opaque than the notch to
    /// its left — the whole thing has to read as one continuous move towards clearer.
    @Test("Dimming never increases as the bar moves right")
    func scrimDecreasesMonotonically() {
        var previous = Double.infinity
        for step in 0...100 {
            let scrim = GlassIntensity(Double(step) / 100).scrim
            #expect(scrim <= previous + 1e-9, "dimming went back up at \(step)%")
            previous = scrim
        }
    }

    @Test("The top half uses the clear material, which a scrim alone cannot reach")
    func topHalfGoesClear() {
        #expect(!GlassIntensity(0).usesClearMaterial)
        #expect(!GlassIntensity(0.49).usesClearMaterial)
        #expect(GlassIntensity(0.5).usesClearMaterial)
        #expect(GlassIntensity(1).usesClearMaterial)
    }

    @Test("The two materials meet without a visible step at the crossover")
    func crossoverIsContinuous() {
        let below = GlassIntensity(GlassIntensity.clearThreshold - 0.001).scrim
        let above = GlassIntensity(GlassIntensity.clearThreshold).scrim
        #expect(abs(below - above) < 0.01, "a jump of \(abs(below - above)) would show")
    }

    @Test("Anything off the end of the bar is clamped, not honoured")
    func clampsOutOfRange() {
        #expect(GlassIntensity(-3).value == 0)
        #expect(GlassIntensity(42).value == 1)
        #expect(GlassIntensity(0.4).value == 0.4)
    }

    @Test("Nonsense from a settings file lands on the default rather than NaN")
    func rejectsNonFinite() {
        #expect(GlassIntensity(.nan) == .default)
        #expect(GlassIntensity(.infinity) == .default)
    }

    @Test("A value chosen on the bar survives a round trip")
    func roundTripsAnyValue() throws {
        for value in [0.0, 0.13, 0.5, 0.87, 1.0] {
            var settings = RecallSettings.default
            settings.glassIntensity = GlassIntensity(value)
            let data = try JSONEncoder().encode(settings)
            let restored = try JSONDecoder().decode(RecallSettings.self, from: data)
            #expect(restored.glassIntensity.value == value)
        }
    }

    /// The bar replaced three named steps. An existing choice should carry over rather
    /// than silently resetting.
    @Test("The named levels this replaced still decode", arguments: [
        ("subtle", 0.0), ("medium", 0.5), ("strong", 1.0),
    ])
    func decodesRetiredNames(name: String, expected: Double) throws {
        let json = #"{"glassIntensity":"\#(name)"}"#
        let settings = try JSONDecoder().decode(RecallSettings.self, from: Data(json.utf8))
        #expect(settings.glassIntensity.value == expected)
    }

    /// Settings saved before these fields existed must still load, or one addition costs
    /// the user every other preference they have set.
    @Test("An older settings blob still decodes, with glass on")
    func decodesOlderBlob() throws {
        let json = #"{"storageMode":"inMemory","historyLimit":42,"rowDensity":"compact"}"#
        let settings = try JSONDecoder().decode(RecallSettings.self, from: Data(json.utf8))

        #expect(settings.historyLimit == 42)
        #expect(settings.rowDensity == .compact)
        #expect(settings.liquidGlassEnabled)
        #expect(settings.glassIntensity == .default)
    }


    @Test("An unreadable intensity falls back rather than failing")
    func unknownIntensityFallsBack() throws {
        let json = #"{"glassIntensity":"iridescent"}"#
        let settings = try JSONDecoder().decode(RecallSettings.self, from: Data(json.utf8))
        #expect(settings.glassIntensity == .default)
    }

    /// One unreadable field must not take the rest of the file with it.
    @Test("A corrupt value elsewhere does not discard everything else")
    func oneBadFieldDoesNotDiscardTheRest() throws {
        let json = #"{"historyLimit":99,"storageMode":"telepathy","rowDensity":"compact"}"#
        let settings = try JSONDecoder().decode(RecallSettings.self, from: Data(json.utf8))

        #expect(settings.historyLimit == 99)
        #expect(settings.rowDensity == .compact)
        #expect(settings.storageMode == RecallSettings.default.storageMode)
    }

    @Test("Keeping history forever still decodes as forever, not as the default")
    func retentionNilIsPreserved() throws {
        let json = #"{"retention":null}"#
        let settings = try JSONDecoder().decode(RecallSettings.self, from: Data(json.utf8))
        #expect(settings.retention == nil)
    }
}

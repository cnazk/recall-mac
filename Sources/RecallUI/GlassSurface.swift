import RecallCore
import SwiftUI

/// The material Recall's floating windows are made of.
///
/// One modifier rather than a `glassEffect` call per view, so the panel, the scratchpad,
/// the pinned chips and the paste-stack readout cannot drift apart — and so the whole lot
/// answers to one setting.
///
/// Liquid Glass has no intensity of its own; it is one material. The levels come from a
/// scrim drawn *between* the glass and the content, which is what `background` before
/// `glassEffect` produces. More scrim, less show-through.
struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let isEnabled: Bool
    let intensity: GlassIntensity
    /// Interactive glass responds to the pointer. Right for something you click straight
    /// at, like a pinned chip; wrong for a whole window.
    var isInteractive = false

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .background(scrim, in: shape)
                .glassEffect(glass, in: shape)
        } else {
            // Not "no background" — a window that paints nothing is a hole. This is the
            // ordinary vibrant material every other Mac utility window uses.
            content.background(.regularMaterial, in: shape)
        }
    }

    /// The top half of the bar uses the clear material, which is a good deal more
    /// transparent than the regular one — a scrim alone runs out long before "strongest"
    /// looks like anything of the sort.
    private var glass: Glass {
        let base: Glass = intensity.usesClearMaterial ? .clear : .regular
        return isInteractive ? base.interactive() : base
    }

    private var scrim: some ShapeStyle {
        Color(nsColor: .windowBackgroundColor).opacity(intensity.scrim)
    }
}

extension View {
    /// Draws this view as one of Recall's floating surfaces.
    func glassSurface(
        _ shape: some Shape,
        settings: RecallSettings,
        isInteractive: Bool = false
    ) -> some View {
        modifier(GlassSurface(
            shape: shape,
            isEnabled: settings.liquidGlassEnabled,
            intensity: settings.glassIntensity,
            isInteractive: isInteractive
        ))
    }

    /// The panel's own shape, which every full-window surface shares.
    func glassSurface(settings: RecallSettings, isInteractive: Bool = false) -> some View {
        glassSurface(
            RoundedRectangle(cornerRadius: PanelController.cornerRadius, style: .continuous),
            settings: settings,
            isInteractive: isInteractive
        )
    }
}

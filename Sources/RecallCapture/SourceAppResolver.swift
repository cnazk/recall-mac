import AppKit
import Foundation
import RecallCore

/// Resolves which app a clip came from.
///
/// This has to be asked at capture time: by the time the panel is open, the frontmost
/// app is Recall itself.
public enum SourceAppResolver {
    public static func current() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceApp(
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            processIdentifier: app.processIdentifier
        )
    }

    /// The source app's icon, for the history row. Looked up lazily by the UI.
    public static func icon(for source: SourceApp?) -> NSImage? {
        guard let bundleID = source?.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

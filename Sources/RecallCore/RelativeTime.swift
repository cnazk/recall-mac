import Foundation

/// How long ago a clip was copied, as a short, *stable* label.
///
/// SwiftUI's `Text(date, style: .relative)` is a live timer: it rewrites itself every
/// second, and because "4 seconds ago" and "10 seconds ago" are different widths, every
/// row in the list reflows once a second. The seconds were never worth reading anyway —
/// nobody picks a clip by which second it was copied in.
///
/// So the label changes at most once a minute, and only ever gets shorter units as time
/// passes: `now`, `3m`, `5h`, `2d`, then a date.
public enum RelativeTime {
    public static func label(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)

        // A clip captured a moment "ahead" of now — a clock adjustment, or a stored date
        // from a machine that disagrees — reads as current rather than as nonsense.
        guard seconds >= 60 else { return String(localized: "now", comment: "A clip copied under a minute ago") }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes)m", comment: "Minutes ago, abbreviated as short as possible") }

        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours)h", comment: "Hours ago, abbreviated as short as possible") }

        let days = hours / 24
        if days < 7 { return String(localized: "\(days)d", comment: "Days ago, abbreviated as short as possible") }

        return dateLabel(for: date, now: now, calendar: calendar)
    }

    /// Older than a week: a date, with the year only when it is not this one.
    private static func dateLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "dMMM" : "dMMMyyyy")
        return formatter.string(from: date)
    }

    /// The full date, for the tooltip — the detail the short label drops.
    public static func exact(for date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

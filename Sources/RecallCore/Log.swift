import OSLog

/// Subsystem-wide loggers. Nothing logged here may contain clipboard content —
/// log categories, kinds and counts only.
public enum Log {
    public static let subsystem = "com.recall.app"

    public static let capture = Logger(subsystem: subsystem, category: "capture")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let security = Logger(subsystem: subsystem, category: "security")
    public static let intelligence = Logger(subsystem: subsystem, category: "intelligence")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let paste = Logger(subsystem: subsystem, category: "paste")
}

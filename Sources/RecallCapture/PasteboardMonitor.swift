import AppKit
import Foundation
import RecallCore

/// Watches `NSPasteboard.general` and emits a snapshot whenever its `changeCount` moves.
///
/// macOS has no change notification for the pasteboard, so polling is the only option;
/// 0.2s is the interval every clipboard manager converges on — fast enough to feel
/// instant, cheap enough to be invisible in Activity Monitor.
public final class PasteboardMonitor: @unchecked Sendable {
    public typealias Handler = @Sendable (PasteboardSnapshot) -> Void

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private let reader: PasteboardReader
    private var timer: DispatchSourceTimer?
    /// The main queue, and it has to be.
    ///
    /// This polled on a background queue until it was found to be the cause of crashes
    /// all over the app — including inside SwiftUI, with no Recall code on the stack.
    /// Reading the pasteboard means `NSPasteboard.readObjects`, `NSBitmapImageRep` and
    /// `NSWorkspace.frontmostApplication`, none of which may be touched off the main
    /// thread; doing it anyway corrupts state that something unrelated trips over later.
    ///
    /// Polling `changeCount` here costs nothing, and the work that follows a change is a
    /// few milliseconds. Everything after the snapshot is plain data and goes back off
    /// the main thread immediately.
    private let queue = DispatchQueue.main
    private var lastChangeCount: Int
    /// True while the user has capture paused. Held on ``queue`` with the timer.
    private var isPaused = false
    /// Guards the self-write state, which is touched by the writer and the poller on
    /// different threads.
    private let selfWriteLock = NSLock()
    /// True between the start and end of a write Recall is making itself.
    private var isSelfWriting = false
    /// Every change up to here was ours.
    private var suppressedThrough = -1
    private let handler: Handler

    public init(
        pasteboard: NSPasteboard = .general,
        interval: TimeInterval = 0.2,
        reader: PasteboardReader = PasteboardReader(),
        handler: @escaping Handler
    ) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.reader = reader
        self.lastChangeCount = pasteboard.changeCount
        self.handler = handler
    }

    public func start() {
        queue.async { [self] in
            guard timer == nil, !isPaused else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            source.setEventHandler { [weak self] in self?.poll() }
            timer = source
            source.resume()
            Log.capture.info("Pasteboard monitor started")
        }
    }

    public func stop() {
        queue.async { [self] in
            cancelTimer()
        }
    }

    /// Stops recording until ``resume()``.
    ///
    /// The timer is torn down rather than short-circuited in `poll`, so a paused Recall
    /// is not reading the pasteboard at all — "paused" should mean the app is not
    /// looking, not that it looks and discards.
    public func pause() {
        queue.async { [self] in
            isPaused = true
            cancelTimer()
            Log.capture.info("Capture paused")
        }
    }

    /// Starts recording again, from here.
    ///
    /// The change count is re-baselined first. Without that, whatever was copied *during*
    /// the pause is a change the monitor has not seen, so the first poll after resuming
    /// would sweep it into history — which would make pausing before copying a password
    /// worse than useless.
    public func resume() {
        queue.async { [self] in
            isPaused = false
            lastChangeCount = pasteboard.changeCount
            Log.capture.info("Capture resumed")
        }
        start()
    }

    private func cancelTimer() {
        dispatchPrecondition(condition: .onQueue(queue))
        timer?.cancel()
        timer = nil
    }

    /// Called immediately before Recall writes to the pasteboard.
    ///
    /// Predicting the resulting change count does not work: a rich-text write bumps it
    /// twice — once for `clearContents`, once for `declareTypes` — and reading the count
    /// asynchronously can read it after the write has already happened. So the writer
    /// brackets its work instead, and the poller ignores anything inside the brackets.
    public func beginSelfWrite() {
        selfWriteLock.lock()
        isSelfWriting = true
        selfWriteLock.unlock()
    }

    /// Called once Recall has finished writing.
    public func endSelfWrite() {
        let count = pasteboard.changeCount
        selfWriteLock.lock()
        isSelfWriting = false
        suppressedThrough = max(suppressedThrough, count)
        selfWriteLock.unlock()
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        selfWriteLock.lock()
        let isOurs = isSelfWriting || changeCount <= suppressedThrough
        selfWriteLock.unlock()

        // Recall must never re-capture what Recall just pasted.
        if isOurs { return }

        let snapshot = reader.snapshot(of: pasteboard, changeCount: changeCount)
        handler(snapshot)
    }
}

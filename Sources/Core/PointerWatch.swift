import Foundation

/// Whether the pointer's movements are reaching the page. When they stop,
/// YouTube's controls no longer come up on hover, and its cursor, hidden
/// while a video plays, stays hidden. WebKit answers a hover move only after
/// the page next draws, and sends nothing more until it has, so a page that
/// stops drawing stops hearing the pointer (see `HoverGate`). Drift sees
/// every move over its window; the page says, at most once a second, that it
/// is hearing them too. When the two disagree the page is asked to draw, and
/// if they go on disagreeing, the tab's log gets a description of everything
/// that decides where a move goes, for the debugging archive.
enum PointerWatch {

    /// The pointer has been moving over the page at least this long...
    static let moving: TimeInterval = 2
    /// ...and the page has heard nothing for at least this long.
    static let silent: TimeInterval = 2.5
    /// Said once, not said again for this long.
    static let quiet: TimeInterval = 30
    /// A gap this long between moves ends one run of movement.
    static let pause: TimeInterval = 0.5
    /// Moving this long with the page hearing nothing, and the page is asked
    /// to draw: WebKit holds every move until the page has drawn since the
    /// last one. A page that hears the pointer says so every second, so this
    /// is past what a healthy one ever takes.
    static let nudge: TimeInterval = 1.5

    static func shouldReport(now: Date, movingSince: Date, pageHeard: Date, lastReport: Date) -> Bool {
        now.timeIntervalSince(movingSince) >= moving
            && now.timeIntervalSince(pageHeard) >= silent
            && now.timeIntervalSince(lastReport) >= quiet
    }

    /// One tab's side of it.
    struct Track {
        private(set) var movingSince = Date.distantPast
        private(set) var lastMove = Date.distantPast
        private(set) var pageHeard = Date.distantPast
        private(set) var lastReport = Date.distantPast

        mutating func pageHeardMove(at now: Date = Date()) { pageHeard = now }

        /// A move Drift saw over the page. True when it is time to report.
        mutating func driftSawMove(at now: Date = Date()) -> Bool {
            if now.timeIntervalSince(lastMove) > PointerWatch.pause { movingSince = now }
            lastMove = now
            guard PointerWatch.shouldReport(now: now, movingSince: movingSince, pageHeard: pageHeard, lastReport: lastReport) else { return false }
            lastReport = now
            return true
        }

        private(set) var lastNudge = Date.distantPast
        /// When the page was last asked to draw and has not yet; see `nudge`.
        var drawAsked: Date?

        /// After `driftSawMove`: true when the page should be asked to draw,
        /// at most once a `nudge`, and not while it is still being asked.
        mutating func shouldNudge(at now: Date = Date()) -> Bool {
            guard drawAsked == nil,
                  now.timeIntervalSince(movingSince) >= PointerWatch.nudge,
                  now.timeIntervalSince(pageHeard) >= PointerWatch.nudge,
                  now.timeIntervalSince(lastNudge) >= PointerWatch.nudge else { return false }
            lastNudge = now
            return true
        }
    }

    /// Runs in every frame, in Drift's own world, so a player inside an
    /// iframe counts. Only real moves count.
    static let script = """
    (function () {
      if (globalThis.__driftPointer) return;
      globalThis.__driftPointer = true;
      var last = 0;
      addEventListener('mousemove', function (event) {
        if (!event.isTrusted) return;
        var now = Date.now();
        if (now - last < 1000) return;
        last = now;
        try { webkit.messageHandlers.driftPointer.postMessage(1); } catch (_) {}
      }, { capture: true, passive: true });
    })();
    """
}

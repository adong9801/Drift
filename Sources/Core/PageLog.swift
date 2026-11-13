import Foundation

/// What went wrong on a page lately: script errors, failed loads, a crashed
/// web process. Kept per tab, and read only when a debugging archive is made,
/// so "the page went black" comes with what the page said at the time.
struct PageLog: Equatable {

    struct Entry: Equatable {
        let time: Date
        let level: String
        let text: String
    }

    static let capacity = 150
    /// A single script error can be a screenful; the archive wants the gist.
    static let lineLimit = 600

    private(set) var entries: [Entry] = []

    mutating func add(_ level: String, _ text: String, at time: Date = Date()) {
        let trimmed = text.count > Self.lineLimit ? String(text.prefix(Self.lineLimit)) + "…" : text
        entries.append(Entry(time: time, level: level, text: trimmed))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func render() -> String {
        guard !entries.isEmpty else { return "nothing logged" }
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.SSS"
        return entries.map { "\(clock.string(from: $0.time)) \($0.level.padding(toLength: 7, withPad: " ", startingAt: 0)) \($0.text)" }
            .joined(separator: "\n")
    }

    // MARK: - Hearing from the page

    /// Runs in the page's own world, since only there can console calls and
    /// error events be seen. It hands each one to Drift's world as a string on
    /// a DOM event: primitives cross worlds, objects and message handlers do
    /// not, so nothing of Drift's is exposed to the page.
    static let captureScript = """
    (function () {
      if (window.__driftLogHooked) return;
      window.__driftLogHooked = true;
      function tell(level, parts) {
        try {
          var text = parts.map(function (p) {
            if (p instanceof Error) return p.name + ': ' + p.message + (p.stack ? '\\n' + p.stack : '');
            if (typeof p === 'string') return p;
            try { return JSON.stringify(p); } catch (e) { return String(p); }
          }).join(' ');
          document.dispatchEvent(new CustomEvent('__driftLog', { detail: JSON.stringify({ level: level, text: text }) }));
        } catch (e) {}
      }
      ['error', 'warn'].forEach(function (level) {
        var original = console[level];
        console[level] = function () {
          tell(level, Array.prototype.slice.call(arguments));
          return original.apply(console, arguments);
        };
      });
      window.addEventListener('error', function (event) {
        var where = event.filename ? ' (' + event.filename + ':' + event.lineno + ')' : '';
        tell('uncaught', [event.message + where]);
      }, true);
      window.addEventListener('unhandledrejection', function (event) {
        tell('promise', [event.reason instanceof Error ? event.reason : String(event.reason)]);
      });
    })();
    """

    /// Drift's side of the hand-off, in Drift's world.
    static let relayScript = """
    document.addEventListener('__driftLog', function (event) {
      try {
        var body = JSON.parse(event.detail);
        body.frame = window === window.top ? 'top' : location.host;
        webkit.messageHandlers.driftLog.postMessage(body);
      } catch (e) {}
    });
    """
}

import Foundation

/// When a tab that is not on screen gives its web process back.
///
/// A sleeping tab keeps its row, icon, address and preview. Its page, and the
/// few hundred megabytes behind it, go; choosing the tab brings the page back
/// at the scroll position and with the back-forward history it had.
enum TabSleep {

    private static let enabledKey = "drift.sleepTabs.v1"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Out of sight this long, and a tab is put to sleep.
    static var idleLimit: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: "drift.sleepMinutes.v1") as? Int ?? 10
        return TimeInterval(max(1, min(60, minutes))) * 60
    }
    /// Under memory pressure from the system, this is long enough.
    static let pressureLimit: TimeInterval = 2 * 60

    /// What would be lost by sleeping the page, as far as can be told.
    struct Activity: Equatable {
        var playing = false
        /// Someone has changed a form or editable region, other than a search input.
        var edited = false
        var capturing = false
        /// An unresponsive or navigating page cannot safely be discarded.
        var unknown = false
    }

    static func shouldSleep(
        idleFor idle: TimeInterval,
        limit: TimeInterval,
        isVisible: Bool,
        isLoading: Bool,
        activity: Activity
    ) -> Bool {
        guard !isVisible, !isLoading, idle >= limit else { return false }
        // Music in the background and a half-written email are both reasons to
        // leave a tab alone for as long as it takes.
        return !activity.playing && !activity.edited && !activity.capturing && !activity.unknown
    }

    /// Runs in every page, in Drift's own script world. Notes typing into the
    /// places people lose work from: forms and editable regions. Explicit
    /// search inputs do not count; other fields conservatively keep the tab.
    static let tracker = """
    (function () {
      if (globalThis.__driftTracked) return;
      globalThis.__driftTracked = true;
      var frame = Math.random().toString(36).slice(2);
      function report(gone) {
        var playing = Array.prototype.some.call(document.querySelectorAll('video, audio'), function (m) {
          return !m.paused && !m.ended;
        });
        try { webkit.messageHandlers.driftActivity.postMessage({frame: frame, playing: playing, edited: !!globalThis.__driftEdited, gone: !!gone}); } catch (_) {}
      }
      addEventListener('input', function (event) {
        if (!event.isTrusted) return;
        var target = event.target;
        if (target && (target.tagName === 'TEXTAREA' || target.tagName === 'SELECT' || target.isContentEditable || (target.tagName === 'INPUT' && target.type !== 'search'))) {
          globalThis.__driftEdited = true;
          report(false);
        }
      }, true);
      addEventListener('change', function (event) {
        if (event.isTrusted && event.target && event.target.matches('input:not([type="search"]), textarea, select')) {
          globalThis.__driftEdited = true;
          report(false);
        }
      }, true);
      ['playing', 'pause', 'ended', 'emptied'].forEach(function (name) {
        addEventListener(name, function () { report(false); }, true);
      });
      addEventListener('pagehide', function () { report(true); });
      addEventListener('pageshow', function () { report(false); });
    })();
    """

    static let query = """
    (function () {
      var media = document.querySelectorAll('video, audio');
      var playing = false;
      for (var i = 0; i < media.length; i++) {
        var m = media[i];
        if (!m.paused && !m.ended && m.readyState > 2) { playing = true; break; }
      }
      return { playing: playing, edited: !!globalThis.__driftEdited, tracked: !!globalThis.__driftTracked };
    })()
    """
}

import Foundation

/// Notes in the tab's log what became of a drag over the page, for the
/// debugging archive: what the page was offered, which element was under the
/// pointer, and whether the page took it. A drop that does "nothing at all"
/// is otherwise invisible: the drag may never have reached the page, reached
/// it carrying something the page does not want, or landed on an element
/// that is not the page's drop area.
///
/// Runs in Drift's own world, in every frame; a page's own handlers have run
/// by the time each event is looked at, since that is done once the event
/// has been dispatched. Says a few lines per drag, not one per pointer move.
enum DragWatch {

    static let script = """
    (function () {
      if (globalThis.__driftDragWatch) return;
      globalThis.__driftDragWatch = true;
      var active = false, overSaid = false, lastAccepted = null;
      function describe(el) {
        if (!el || !el.tagName) return el === document ? 'the document' : String(el);
        var s = el.tagName.toLowerCase();
        if (el.id) s += '#' + el.id;
        var c = typeof el.className === 'string' ? el.className.trim().split(/\\s+/).filter(Boolean).slice(0, 3).join('.') : '';
        if (c) s += '.' + c;
        var label = el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('data-testid'));
        if (label) s += ' [' + String(label).slice(0, 40) + ']';
        return s;
      }
      function types(e) {
        try { return Array.prototype.join.call(e.dataTransfer.types, ', ') || 'nothing'; } catch (_) { return '?'; }
      }
      function say(text) {
        try { webkit.messageHandlers.driftLog.postMessage({ level: 'drag', text: text, frame: window === window.top ? 'top' : location.host }); } catch (_) {}
      }
      // After the page's own handlers: the event has finished dispatching.
      function afterwards(e, body) { setTimeout(function () { body(e.defaultPrevented); }, 0); }

      window.addEventListener('dragenter', function (e) {
        if (active) return;
        active = true; overSaid = false; lastAccepted = null;
        // Read now: once the event is over, the types are gone.
        var carrying = types(e);
        afterwards(e, function (taken) {
          say('drag came over the page carrying ' + carrying + ', over ' + describe(e.target) + '; the page ' + (taken ? 'took notice' : 'did not take notice'));
        });
      }, true);
      window.addEventListener('dragover', function (e) {
        afterwards(e, function (taken) {
          if (overSaid && taken === lastAccepted) return;
          overSaid = true; lastAccepted = taken;
          say('dragging over ' + describe(e.target) + ': the page ' + (taken ? 'will take a drop here' : 'will not take a drop here (it did not cancel dragover)'));
        });
      }, true);
      window.addEventListener('dragleave', function (e) {
        if (e.relatedTarget !== null) return;
        // Left the page, or only crossed into a frame; said once.
        if (active) say('drag left the page');
        active = false;
      }, true);
      window.addEventListener('drop', function (e) {
        var files = 0;
        try { files = e.dataTransfer.files.length; } catch (_) {}
        var carrying = types(e);
        afterwards(e, function (taken) {
          say('dropped on ' + describe(e.target) + ' with ' + files + ' file(s), carrying ' + carrying + '; the page ' + (taken ? 'handled it' : 'did not handle it'));
        });
        active = false;
      }, true);
      window.addEventListener('dragend', function () { active = false; }, true);
    })();
    """
}

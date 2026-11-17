import Foundation

/// Full-screen video inside the browser window, the way Arc and Chrome do it,
/// instead of WebKit's own, which lifts the page into a second window on a
/// Space of its own.
///
/// The page's `requestFullscreen` is replaced before any of its scripts run.
/// The stand-in pins the element over the whole viewport, reports it as the
/// fullscreen element, and fires `fullscreenchange`, which is all a player
/// such as YouTube's looks at to switch to its full-screen controls. Drift is
/// told, and clears its own chrome away round the page.
enum PageFullscreen {

    /// Runs in the page's world, in every frame. A frame's request climbs to
    /// the top by `postMessage`, each parent pinning the iframe in turn, so a
    /// player embedded in another site fills the window too.
    static let script = """
    (function () {
      if (window.__driftFullscreen) return;
      window.__driftFullscreen = true;
      var current = null;
      var sheet = null;
      // The host is a black, viewport-filling box at the document root. The
      // element the page asked to show full screen is MOVED into it (see enter),
      // which lifts it clear of every ancestor transform, clip and stacking
      // context the site wraps it in. A site like X virtualises its timeline
      // with transforms and re-renders it constantly; a merely z-indexed overlay
      // left in place gets trapped in those contexts and the page's own chrome
      // paints back over it within a frame or two. Re-parenting is immune to all
      // of that. The element is put back exactly where it was on exit.
      var css = '[data-drift-fs-host]{position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;'
        + 'max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;border:0!important;'
        + 'z-index:2147483647!important;background:#000!important;display:block!important;overflow:hidden!important}'
        + '[data-drift-fs-host] > [data-drift-fullscreen]{position:absolute!important;inset:0!important;top:0!important;left:0!important;'
        + 'width:100%!important;height:100%!important;max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;'
        + 'margin:0!important;padding:0!important;transform:none!important;border-radius:0!important;border:0!important;background:#000!important;z-index:auto!important}'
        // An <iframe> cannot be moved — that reloads it and kills an embedded
        // player — so it is pinned in place with position:fixed instead, and the
        // ancestor transforms/clips that would otherwise trap the pin are
        // stripped (see tagAncestors). This rule only applies when NOT in the host.
        + '[data-drift-fullscreen]{position:fixed!important;inset:0!important;top:0!important;left:0!important;'
        + 'width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;'
        + 'margin:0!important;padding:0!important;transform:none!important;border-radius:0!important;border:0!important;'
        + 'z-index:2147483647!important;background:#000!important}'
        // Pinned-in-place video: fix it to the viewport, not to whatever inner
        // box the player positions it in. The site (YouTube) sizes and offsets
        // the <video> for a portrait clip inside its own container; a
        // viewport-fixed override ignores that and centres it in the window.
        + '[data-drift-fullscreen] video{position:fixed!important;inset:0!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;'
        + 'max-width:none!important;max-height:none!important;margin:0!important;transform:none!important;object-fit:contain!important}'
        // Re-parented video: it now lives in the host at the root, so fill the
        // host box directly. (Overrides the rule above; placed after it.)
        + '[data-drift-fs-host] video{position:absolute!important;inset:0!important;left:0!important;top:0!important;width:100%!important;height:100%!important;'
        + 'max-width:none!important;max-height:none!important;margin:0!important;transform:none!important;object-fit:contain!important}'
        + '[data-drift-fs-up]{transform:none!important;-webkit-transform:none!important;perspective:none!important;-webkit-perspective:none!important;'
        + 'filter:none!important;-webkit-filter:none!important;backdrop-filter:none!important;-webkit-backdrop-filter:none!important;'
        + 'will-change:auto!important;contain:none!important;clip-path:none!important}'
        + 'html[data-drift-fullscreen-root],html[data-drift-fullscreen-root]>body{overflow:hidden!important}';

      function tell(kind) {
        if (window !== window.top) {
          try { window.parent.postMessage({ __driftFullscreen: kind }, '*'); } catch (e) {}
        } else {
          document.dispatchEvent(new CustomEvent('__driftFullscreen', { detail: kind }));
        }
      }
      function fire(target) {
        ['fullscreenchange', 'webkitfullscreenchange'].forEach(function (name) {
          try { target.dispatchEvent(new Event(name, { bubbles: true })); } catch (e) {}
        });
      }
      var host = null;      // our black, root-level full-screen box
      var home = null;      // { parent, next } the moved element is restored to
      function ensureHost() {
        if (!host || !host.isConnected) {
          host = document.createElement('div');
          host.setAttribute('data-drift-fs-host', '');
          document.documentElement.appendChild(host);
        }
        return host;
      }
      function sendHome(el) {
        if (home && home.parent) {
          try { home.parent.insertBefore(el, home.next); }
          catch (e) { try { home.parent.appendChild(el); } catch (e2) {} }
        }
        home = null;
      }
      // An <iframe> is pinned in place (moving it reloads it); its trapping
      // ancestors have their transform/clip stripped so the pin reaches the
      // viewport. Restored by clearAncestors on exit.
      function tagAncestors(element) {
        clearAncestors();
        for (var up = element.parentElement; up && up !== document.documentElement; up = up.parentElement) {
          up.setAttribute('data-drift-fs-up', '');
        }
      }
      function clearAncestors() {
        var tagged = document.querySelectorAll('[data-drift-fs-up]');
        for (var i = 0; i < tagged.length; i++) tagged[i].removeAttribute('data-drift-fs-up');
      }
      // Pinning in place is what most players (YouTube) want, and moving a
      // player's own element out of its tree can break it — YouTube's goes
      // black. Re-parenting is only needed when an ancestor would trap the pin:
      // a transform/filter/perspective makes that ancestor the containing block
      // and a stacking context, so a virtualised, re-rendering feed like X's
      // keeps pulling the pinned element back behind its chrome. Detect exactly
      // that case and lift out only then; otherwise pin in place as before.
      function needsReparent(element) {
        for (var up = element.parentElement; up && up !== document.documentElement; up = up.parentElement) {
          try {
            var cs = getComputedStyle(up);
            if (cs.transform !== 'none' || cs.perspective !== 'none' || cs.filter !== 'none'
                || (cs.willChange && /transform|perspective|filter/.test(cs.willChange))
                || (cs.contain && /strict|content|paint|layout/.test(cs.contain))) return true;
          } catch (e) {}
        }
        return false;
      }
      function enter(element) {
        if (!(element instanceof Element) || !element.isConnected) return Promise.reject(new TypeError('not in the document'));
        if (current === element) return Promise.resolve();
        if (current) { current.removeAttribute('data-drift-fullscreen'); sendHome(current); clearAncestors(); }
        if (!sheet) { sheet = document.createElement('style'); sheet.textContent = css; }
        if (!sheet.isConnected) document.documentElement.appendChild(sheet);
        current = element;
        element.setAttribute('data-drift-fullscreen', '');
        if (element.tagName !== 'IFRAME' && needsReparent(element)) {
          home = { parent: element.parentNode, next: element.nextSibling };
          ensureHost().appendChild(element);             // lift a trapped player (X) to the root
        } else {
          tagAncestors(element);                         // pin in place (YouTube, iframes, most)
        }
        document.documentElement.setAttribute('data-drift-fullscreen-root', '');
        tell('enter');
        fire(element);
        // Players lay themselves out again on resize; give them the nudge.
        setTimeout(function () { try { window.dispatchEvent(new Event('resize')); } catch (e) {} }, 50);
        return Promise.resolve();
      }
      function exit() {
        if (!current) return Promise.resolve();
        var was = current;
        current = null;
        was.removeAttribute('data-drift-fullscreen');
        sendHome(was);                                   // put a moved element back
        clearAncestors();                                // un-strip a pinned iframe's ancestors
        if (host && host.isConnected) host.remove();
        host = null;
        document.documentElement.removeAttribute('data-drift-fullscreen-root');
        if (sheet) sheet.remove();
        tell('exit');
        fire(was.isConnected ? was : document);
        setTimeout(function () { try { window.dispatchEvent(new Event('resize')); } catch (e) {} }, 50);
        return Promise.resolve();
      }

      ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen'].forEach(function (name) {
        Element.prototype[name] = function () { return enter(this); };
      });
      ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen'].forEach(function (name) {
        Document.prototype[name] = function () { return exit(); };
      });
      if (window.HTMLVideoElement) {
        HTMLVideoElement.prototype.webkitEnterFullscreen = function () { enter(this); };
        HTMLVideoElement.prototype.webkitEnterFullScreen = HTMLVideoElement.prototype.webkitEnterFullscreen;
        HTMLVideoElement.prototype.webkitExitFullscreen = function () { exit(); };
        HTMLVideoElement.prototype.webkitExitFullScreen = HTMLVideoElement.prototype.webkitExitFullscreen;
        try { Object.defineProperty(HTMLVideoElement.prototype, 'webkitSupportsFullscreen', { get: function () { return true; }, configurable: true }); } catch (e) {}
        try { Object.defineProperty(HTMLVideoElement.prototype, 'webkitDisplayingFullscreen', { get: function () { return this === current; }, configurable: true }); } catch (e) {}
      }
      function define(name, get) {
        try { Object.defineProperty(Document.prototype, name, { get: get, configurable: true }); } catch (e) {}
      }
      define('fullscreenElement', function () { return current; });
      define('webkitFullscreenElement', function () { return current; });
      define('webkitCurrentFullScreenElement', function () { return current; });
      define('fullscreenEnabled', function () { return true; });
      define('webkitFullscreenEnabled', function () { return true; });
      define('webkitIsFullScreen', function () { return current !== null; });
      define('fullscreen', function () { return current !== null; });

      // A frame below asking, and Drift asking from outside.
      window.addEventListener('message', function (event) {
        var kind = event.data && event.data.__driftFullscreen;
        if (!kind) return;
        var frames = document.querySelectorAll('iframe');
        for (var i = 0; i < frames.length; i++) {
          if (frames[i].contentWindow !== event.source) continue;
          if (kind === 'enter') enter(frames[i]); else exit();
          return;
        }
      });
      document.addEventListener('__driftFullscreenExit', function () {
        if (current && current.tagName === 'IFRAME') {
          try { current.contentWindow.postMessage({ __driftFullscreenExit: true }, '*'); } catch (e) {}
        }
        exit();
      });
      window.addEventListener('message', function (event) {
        if (event.data && event.data.__driftFullscreenExit) exit();
      });
    })();
    """

    /// Drift's side, in Drift's world, top frame only: passes the page's word on.
    static let relayScript = """
    document.addEventListener('__driftFullscreen', function (event) {
      try { webkit.messageHandlers.driftFullscreen.postMessage(event.detail); } catch (e) {}
    });
    """

    /// Sent into Drift's world to end it: Escape, a tab switch, or the window
    /// leaving full screen. The page's world hears it as a DOM event.
    static let exitScript = "document.dispatchEvent(new CustomEvent('__driftFullscreenExit'))"
}

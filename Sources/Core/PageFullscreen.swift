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
      var css = '[data-drift-fullscreen]{position:fixed!important;inset:0!important;top:0!important;left:0!important;'
        + 'width:100vw!important;height:100vh!important;max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;'
        + 'margin:0!important;padding:0!important;transform:none!important;border-radius:0!important;border:0!important;'
        + 'z-index:2147483647!important;background:#000!important;object-fit:contain}'
        // The video inside is placed and sized by the site's script for the
        // player as it was, and YouTube's arithmetic puts it half off screen
        // once the player is stretched. Pinned to the viewport itself, it
        // fills the screen whatever the script says; the player's controls
        // stay where they are, laid over it.
        + '[data-drift-fullscreen] video{position:fixed!important;inset:0!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;'
        + 'max-width:none!important;max-height:none!important;margin:0!important;transform:none!important;object-fit:contain!important}'
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
      function enter(element) {
        if (!(element instanceof Element) || !element.isConnected) return Promise.reject(new TypeError('not in the document'));
        if (current === element) return Promise.resolve();
        if (current) current.removeAttribute('data-drift-fullscreen');
        if (!sheet) { sheet = document.createElement('style'); sheet.textContent = css; }
        if (!sheet.isConnected) document.documentElement.appendChild(sheet);
        current = element;
        element.setAttribute('data-drift-fullscreen', '');
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

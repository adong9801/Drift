import Foundation

/// The Chrome Web Store, working in Drift. The store greys out its "Add to
/// Chrome" button in any browser it does not take for Chrome. This turns that
/// button into "Add to Drift", or "Remove from Drift" for an extension already
/// installed, and hands the click to Drift, which installs from the store as a
/// pasted store link does: after asking, with what the extension may do.
enum WebStore {

    static let host = "chromewebstore.google.com"

    /// Runs in Drift's own world on the store's pages, out of the store's
    /// reach. The store is a single-page app that redraws its button as it
    /// pleases, so the button is found again whenever the page changes, by
    /// what it is: a disabled button that names Chrome. ("Install Chrome",
    /// the store's advert for Chrome, is never disabled.)
    static let script = """
    (function () {
      if (location.hostname !== '\(host)' || window !== window.top) return;
      var states = {};
      var asking = {};
      function itemID() {
        var match = location.pathname.match(/\\/([a-p]{32})(?:\\/|$)/);
        return match ? match[1] : null;
      }
      // The heading, once the page has drawn it. Until then nothing is
      // asked: an extension installed from a file is known only by name.
      function itemName() {
        var heading = document.querySelector('main h1, h1');
        return heading ? heading.textContent.trim() : '';
      }
      function label(state) {
        return state === 'installed' ? 'Remove from Drift' : state === 'working' ? 'Just a moment\\u2026' : 'Add to Drift';
      }
      function buttons() {
        return Array.prototype.filter.call(document.querySelectorAll('button'), function (button) {
          return button.hasAttribute('data-drift-store') || (button.disabled && /Chrome/.test(button.textContent || ''));
        });
      }
      function setLabel(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        for (var node = walker.nextNode(); node; node = walker.nextNode()) {
          if (node.nodeValue.trim()) { if (node.nodeValue !== text) node.nodeValue = text; return; }
        }
      }
      // "Switch to Chrome to install extensions and themes", which is no
      // longer true: the strip it sits in goes. Found by its words, so only
      // in English; elsewhere it stays, and is merely wrong.
      function hideAdvice() {
        var main = document.querySelector('main');
        if (!main) return;
        var walker = document.createTreeWalker(main, NodeFilter.SHOW_TEXT);
        for (var node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!/^\\s*Switch to Chrome to install/.test(node.nodeValue)) continue;
          var strip = node.parentElement;
          while (strip.parentElement && strip.parentElement !== main && strip.parentElement.getBoundingClientRect().height <= 80) strip = strip.parentElement;
          strip.style.setProperty('display', 'none', 'important');
          return;
        }
      }
      function ask(message) {
        try { return webkit.messageHandlers.driftStore.postMessage(message); }
        catch (e) { return Promise.reject(e); }
      }
      function refresh() {
        hideAdvice();
        var id = itemID();
        var found = buttons();
        if (!id || !found.length) return;
        var name = itemName();
        if (!states[id] && !asking[id] && name) {
          asking[id] = true;
          ask({ kind: 'state', id: id, name: name })
            .then(function (state) { states[id] = state; refresh(); }, function () {})
            .finally(function () { asking[id] = false; });
        }
        var state = states[id] || 'not installed';
        found.forEach(function (button) {
          button.setAttribute('data-drift-store', '');
          button.disabled = state === 'working';
          button.removeAttribute('aria-disabled');
          setLabel(button, label(state));
        });
      }
      document.addEventListener('click', function (event) {
        var button = event.target.closest && event.target.closest('button[data-drift-store]');
        var id = itemID();
        if (!button || !id) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        var before = states[id] || 'not installed';
        if (before === 'working') return;
        states[id] = 'working';
        refresh();
        ask({ kind: before === 'installed' ? 'remove' : 'install', id: id, name: itemName(), page: location.href })
          .then(function (state) { states[id] = state; }, function () { states[id] = before; })
          .finally(refresh);
      }, true);
      var pending = false;
      new MutationObserver(function () {
        if (pending) return;
        pending = true;
        setTimeout(function () { pending = false; refresh(); }, 150);
      }).observe(document, { childList: true, subtree: true });
      refresh();
    })();
    """
}

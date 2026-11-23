import AppKit
import WebKit

/// The History page, as Chrome has it: every page visited, newest first, a
/// card a day, searchable, with pages to tick and remove, and a way to clear
/// a stretch of time. Command-Y opens it.
///
/// It is a page in a tab, at drift://history, so it goes back and forward,
/// sleeps, and comes back at launch like any other. Drift serves the page,
/// with no script in it; what makes it work runs in Drift's own world (see
/// `Tab.ownWorld`), where it talks to `HistoryBridge`. Websites cannot see
/// that bridge, and it answers nothing but this page in a tab of its own.
enum HistoryPage {

    static let scheme = "drift"
    static let host = "history"
    static let url = URL(string: "drift://history/")!

    static func isPage(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == scheme && url?.host?.lowercased() == host
    }

    /// The tab's icon.
    static let icon: NSImage? = {
        let image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "History")
        image?.isTemplate = true
        return image
    }()

    /// Lines handed to the page at a time; more come as it is scrolled.
    static let pageSize = 150

    /// Goes up with every change to history, so a page shown again can tell
    /// whether what it lists is out of date.
    @MainActor static var version = 0

    // MARK: - Answers

    /// What the page asks for, answered from the one history every window
    /// reads. Private windows read it too, and change nothing.
    @MainActor
    static func answer(_ body: [String: Any], store: BrowserStore? = nil) -> [String: Any]? {
        let store = store ?? .shared
        switch body["op"] as? String {
        case "query":
            let text = body["text"] as? String ?? ""
            let limit = min(500, max(1, body["limit"] as? Int ?? pageSize))
            var cursor: (stamp: Int64, url: String)?
            if let after = body["after"] as? [String: Any], let time = after["time"] as? Double, let url = after["url"] as? String {
                cursor = (Int64(time), url)
            }
            let found = store.history.visits(matching: text, after: cursor, limit: limit + 1)
            let rows: [[String: Any]] = found.prefix(limit).map { visit in
                // Icons are kept under the host as the page had it, "www." and all.
                ["url": visit.url, "title": visit.title, "time": Double(visit.stamp), "host": History.host(of: visit.url),
                 "iconHost": URL(string: visit.url)?.host ?? ""]
            }
            return ["rows": rows, "more": found.count > limit, "version": version]
        case "version":
            return ["version": version]
        case "remove":
            let items = (body["items"] as? [[String: Any]] ?? []).compactMap { item -> (url: String, time: Date)? in
                guard let url = item["url"] as? String, let time = item["time"] as? Double else { return nil }
                return (url, Date(timeIntervalSince1970: time / 1000))
            }
            store.removeVisits(items)
            return ["version": version]
        case "clear":
            let spans: [String: TimeInterval] = ["hour": 3600, "day": 86_400, "week": 7 * 86_400, "month": 28 * 86_400]
            let range = body["range"] as? String ?? ""
            guard range == "all" || spans[range] != nil else { return nil }
            store.clearHistory(since: spans[range].map { Date().addingTimeInterval(-$0) })
            return ["version": version]
        default:
            return nil
        }
    }

    // MARK: - The page

    /// Not even the page's own script may run, and nothing may be loaded
    /// from anywhere but here. No site may put it in a frame.
    static let policy = "default-src 'none'; img-src 'self' drift:; style-src 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <meta name="color-scheme" content="light dark">
    <title>History</title>
    <style>
    :root {
      color-scheme: light dark;
      --bg: #f3f2f0; --card: #ffffff; --raised: #ffffff;
      --text: #373530; --muted: #787774; --faint: #9b9a97;
      --line: rgba(0, 0, 0, 0.09); --hover: rgba(0, 0, 0, 0.045);
      --accent: #0a7aff; --chosen: rgba(10, 122, 255, 0.10); --on-accent: #ffffff;
      --shadow: 0 1px 2px rgba(0, 0, 0, 0.05), 0 1px 4px rgba(0, 0, 0, 0.04);
    }
    @supports (color: AccentColor) { :root { --accent: AccentColor; } }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1b1b1b; --card: #262626; --raised: #303030;
        --text: #ebebeb; --muted: #9e9e9e; --faint: #737373;
        --line: rgba(255, 255, 255, 0.10); --hover: rgba(255, 255, 255, 0.06);
        --chosen: rgba(10, 132, 255, 0.22); --shadow: none;
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--bg); color: var(--text); }
    body { font: 13px/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
    button { font: inherit; color: inherit; cursor: default; }
    [hidden] { display: none !important; }

    header { position: sticky; top: 0; z-index: 5; height: 60px; display: flex; align-items: center; gap: 16px;
      padding: 0 20px; background: var(--bg); border-bottom: 1px solid transparent; }
    header.scrolled { border-bottom-color: var(--line); }
    header .normal, header .selection { display: flex; align-items: center; gap: 16px; width: 100%; height: 100%; }
    header .selection { display: none; }
    header.selecting { background: var(--accent); color: var(--on-accent); border-bottom-color: transparent; }
    header.selecting .normal { display: none; }
    header.selecting .selection { display: flex; }
    .title { flex: none; width: 216px; font-size: 18px; font-weight: 600; letter-spacing: -0.01em; }
    .search { flex: 1; max-width: 720px; height: 36px; display: flex; align-items: center; gap: 8px; padding: 0 14px;
      border-radius: 18px; background: var(--card); box-shadow: inset 0 0 0 1px var(--line); }
    .search:focus-within { box-shadow: inset 0 0 0 2px var(--accent); }
    .search svg { flex: none; width: 15px; height: 15px; fill: none; stroke: var(--muted); stroke-width: 1.8; stroke-linecap: round; }
    .search input { flex: 1; min-width: 0; height: 100%; border: 0; outline: 0; background: transparent; color: inherit; font: inherit; font-size: 14px; }
    .search input::-webkit-search-cancel-button { opacity: 0.6; }
    .spacer { flex: 1; }
    .count { font-size: 15px; font-weight: 600; }
    .bar-button { height: 32px; padding: 0 14px; border: 0; border-radius: 16px; background: transparent; font-weight: 600; }
    .bar-button:hover { background: rgba(255, 255, 255, 0.16); }
    .quiet { height: 32px; padding: 0 14px; border: 0; border-radius: 16px; background: transparent; color: var(--accent); font-weight: 500; white-space: nowrap; }
    .quiet:hover { background: var(--hover); }
    #clear-top { display: none; }

    #layout { display: flex; align-items: flex-start; }
    nav { position: sticky; top: 60px; flex: none; width: 236px; padding: 4px 12px 20px 12px; }
    nav button { display: flex; align-items: center; gap: 12px; width: 100%; height: 36px; padding: 0 16px; margin-bottom: 2px;
      border: 0; border-radius: 18px; background: transparent; text-align: left; }
    nav button:hover { background: var(--hover); }
    nav button.active { background: var(--chosen); color: var(--accent); font-weight: 600; }
    nav svg { flex: none; width: 16px; height: 16px; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
    main { flex: 1; min-width: 0; padding: 4px 20px 48px 0; }
    #list { max-width: 960px; margin: 0 auto; }

    .day { margin: 0 0 16px; padding: 6px 0 8px; border-radius: 12px; background: var(--card); box-shadow: var(--shadow), inset 0 0 0 1px var(--line); }
    .day h2 { margin: 0; padding: 12px 20px 8px; font-size: 13px; font-weight: 600; }
    .row { display: flex; align-items: center; height: 40px; padding: 0 6px 0 10px; }
    .row:hover { background: var(--hover); }
    .row.chosen { background: var(--chosen); }
    .row input { flex: none; width: 15px; height: 15px; margin: 0 14px 0 10px; accent-color: var(--accent); }
    .time { flex: none; width: 74px; color: var(--muted); font-variant-numeric: tabular-nums; white-space: nowrap; }
    .page { flex: 1; min-width: 0; display: flex; align-items: center; height: 100%; color: inherit; text-decoration: none; }
    .page:focus-visible { outline: 2px solid var(--accent); outline-offset: -2px; border-radius: 6px; }
    .icon { flex: none; width: 16px; height: 16px; margin-right: 14px; border-radius: 3px; object-fit: contain; }
    .letter { display: inline-flex; align-items: center; justify-content: center; background: var(--line); color: var(--muted); font-size: 10px; font-weight: 700; }
    .name { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .host { flex: 0 1 auto; max-width: 40%; margin-left: 10px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--muted); }
    .more { flex: none; width: 32px; height: 32px; margin-left: 8px; display: inline-flex; align-items: center; justify-content: center;
      border: 0; border-radius: 16px; background: transparent; color: var(--muted); }
    .more:hover, .more.open { background: var(--hover); color: var(--text); }
    .more svg { width: 16px; height: 16px; fill: currentColor; }
    .empty { padding: 96px 20px; text-align: center; color: var(--muted); font-size: 15px; }

    #menu { position: absolute; z-index: 10; min-width: 208px; padding: 6px 0; border-radius: 10px; background: var(--raised);
      box-shadow: 0 6px 24px rgba(0, 0, 0, 0.18), 0 0 0 1px var(--line); }
    #menu button { display: block; width: 100%; padding: 8px 16px; border: 0; background: transparent; text-align: left; }
    #menu button:hover, #menu button:focus-visible { background: var(--hover); outline: 0; }

    dialog { width: 420px; max-width: calc(100vw - 32px); padding: 22px 24px 18px; border: 0; border-radius: 14px;
      background: var(--raised); color: var(--text); box-shadow: 0 12px 48px rgba(0, 0, 0, 0.3), 0 0 0 1px var(--line); }
    dialog::backdrop { background: rgba(0, 0, 0, 0.32); }
    dialog h3 { margin: 0 0 8px; font-size: 16px; font-weight: 600; }
    dialog p { margin: 0 0 18px; color: var(--muted); }
    dialog label { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin: 0 0 20px; }
    dialog select { font: inherit; min-width: 180px; }
    .buttons { display: flex; justify-content: flex-end; gap: 8px; }
    .plain, .filled { height: 32px; padding: 0 18px; border-radius: 16px; font-weight: 500; }
    .plain { border: 1px solid var(--line); background: transparent; color: var(--accent); }
    .plain:hover { background: var(--hover); }
    .filled { border: 0; background: var(--accent); color: var(--on-accent); }
    .filled:hover { filter: brightness(1.08); }

    @media (max-width: 900px) {
      nav { display: none; }
      main { padding-left: 20px; }
      .title { width: auto; }
      #clear-top { display: inline-flex; align-items: center; }
    }
    </style>
    </head>
    <body>
    <header id="bar">
      <div class="normal">
        <div class="title">History</div>
        <label class="search">
          <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="5"/><path d="M11 11l3.5 3.5"/></svg>
          <input id="search" type="search" placeholder="Search history" aria-label="Search history" autocomplete="off" spellcheck="false" autofocus>
        </label>
        <div class="spacer"></div>
        <button id="clear-top" class="quiet">Clear browsing data</button>
      </div>
      <div class="selection">
        <span id="count" class="count"></span>
        <div class="spacer"></div>
        <button id="selection-cancel" class="bar-button">Cancel</button>
        <button id="selection-delete" class="bar-button">Delete</button>
      </div>
    </header>
    <div id="layout">
      <nav>
        <button id="nav-history" class="active">
          <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.2"/><path d="M8 4.6V8l2.4 1.5"/></svg>History
        </button>
        <button id="clear-side">
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5"/></svg>Clear browsing data
        </button>
      </nav>
      <main><div id="list"></div></main>
    </div>
    <div id="menu" role="menu" hidden>
      <button data-act="site" role="menuitem">More from this site</button>
      <button data-act="remove" role="menuitem">Remove from history</button>
    </div>
    <dialog id="confirm">
      <h3>Remove selected items?</h3>
      <p>They will be taken out of your history and will no longer be suggested as you type.</p>
      <div class="buttons"><button class="plain" id="confirm-no">Cancel</button><button class="filled" id="confirm-yes">Remove</button></div>
    </dialog>
    <dialog id="clear">
      <h3>Clear browsing data</h3>
      <p>Takes the pages you visited in that time out of your history and out of the suggestions as you type. Cookies, site data and logins stay.</p>
      <label>Time range
        <select id="range">
          <option value="hour">Last hour</option>
          <option value="day">Last 24 hours</option>
          <option value="week">Last 7 days</option>
          <option value="month">Last 4 weeks</option>
          <option value="all">All time</option>
        </select>
      </label>
      <div class="buttons"><button class="plain" id="clear-no">Cancel</button><button class="filled" id="clear-yes">Clear data</button></div>
    </dialog>
    </body>
    </html>
    """#

    /// What runs the page, in Drift's world. In every page's main frame,
    /// where it stops at once anywhere but drift://history.
    static let script = #"""
    (function () {
      if (location.protocol !== 'drift:' || location.host !== 'history') return;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.driftHistory;
      var list = document.getElementById('list');
      if (!bridge || !list || list.dataset.ready) return;
      list.dataset.ready = '1';

      function $(id) { return document.getElementById(id); }
      function ask(message) { return Promise.resolve(bridge.postMessage(message)); }
      var header = $('bar'), search = $('search'), menu = $('menu');
      var pageSize = 150;
      var state = { query: '', cursor: null, more: true, loading: false, generation: 0, day: null, card: null, version: -1 };
      var chosen = new Map();
      var anchor = null;
      var menuRow = null;

      // MARK: Days and times, in the Mac's own language and time zone.

      function dayKey(date) { return date.getFullYear() + '-' + date.getMonth() + '-' + date.getDate(); }
      function dayTitle(date) {
        var now = new Date();
        var yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
        var text = date.toLocaleDateString(undefined, { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
        if (dayKey(date) === dayKey(now)) return 'Today - ' + text;
        if (dayKey(date) === dayKey(yesterday)) return 'Yesterday - ' + text;
        return text;
      }
      function timeText(date) { return date.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' }); }

      // MARK: The list

      var dots = '<svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="3.2" r="1.4"/><circle cx="8" cy="8" r="1.4"/><circle cx="8" cy="12.8" r="1.4"/></svg>';

      function line(visit) {
        var row = document.createElement('div');
        row.className = 'row';
        row.dataset.url = visit.url;
        row.dataset.time = String(visit.time);
        row.dataset.host = visit.host || '';

        var box = document.createElement('input');
        box.type = 'checkbox';
        box.setAttribute('aria-label', 'Select');

        var when = document.createElement('span');
        when.className = 'time';
        when.textContent = timeText(new Date(visit.time));

        var page = document.createElement('a');
        page.className = 'page';
        page.href = visit.url;
        page.rel = 'noreferrer';
        page.title = visit.url;

        var icon = document.createElement('img');
        icon.className = 'icon';
        icon.alt = '';
        icon.addEventListener('error', function () {
          var letter = document.createElement('span');
          letter.className = 'icon letter';
          letter.textContent = (visit.host || '?').charAt(0).toUpperCase();
          icon.replaceWith(letter);
        });
        icon.src = 'drift://history/icon/' + encodeURIComponent(visit.iconHost || visit.host || '-');

        var name = document.createElement('span');
        name.className = 'name';
        name.textContent = visit.title || visit.url;
        var host = document.createElement('span');
        host.className = 'host';
        host.textContent = visit.host || '';
        page.append(icon, name, host);

        var more = document.createElement('button');
        more.className = 'more';
        more.title = 'More actions';
        more.setAttribute('aria-haspopup', 'menu');
        more.innerHTML = dots;

        row.append(box, when, page, more);
        return row;
      }

      function add(visit) {
        var date = new Date(visit.time);
        var key = dayKey(date);
        if (key !== state.day || !state.card || !state.card.isConnected) {
          state.card = document.createElement('section');
          state.card.className = 'day';
          var title = document.createElement('h2');
          title.textContent = dayTitle(date);
          state.card.append(title);
          list.append(state.card);
          state.day = key;
        }
        state.card.append(line(visit));
      }

      function showEmpty() {
        var old = list.querySelector('.empty');
        if (list.querySelector('.row') || state.more) { if (old) old.remove(); return; }
        if (old) return;
        var none = document.createElement('div');
        none.className = 'empty';
        none.textContent = state.query ? 'No search results found' : 'Your browsing history appears here';
        list.append(none);
      }

      function reset() {
        state.generation++;
        state.cursor = null;
        state.more = true;
        state.loading = false;
        state.day = null;
        state.card = null;
        chosen.clear();
        anchor = null;
        closeMenu();
        list.textContent = '';
        selectionChanged();
      }

      function load() {
        if (state.loading || !state.more) return;
        state.loading = true;
        var generation = state.generation;
        ask({ op: 'query', text: state.query, after: state.cursor, limit: pageSize }).then(function (answer) {
          if (generation !== state.generation) return;
          state.loading = false;
          var rows = (answer && answer.rows) || [];
          rows.forEach(add);
          if (rows.length) state.cursor = { time: rows[rows.length - 1].time, url: rows[rows.length - 1].url };
          state.more = !!(answer && answer.more);
          if (answer) state.version = answer.version;
          showEmpty();
          moreIfNear();
        }, function () {
          if (generation === state.generation) state.loading = false;
        });
      }

      function moreIfNear() {
        var root = document.documentElement;
        if (state.more && root.scrollHeight - (window.scrollY + window.innerHeight) < 900) load();
      }

      function startOver() { reset(); load(); }

      // MARK: Ticking and removing

      function keyOf(row) { return row.dataset.url + '\n' + row.dataset.time; }
      function rows() { return Array.prototype.slice.call(list.querySelectorAll('.row')); }
      function choose(row, on) {
        row.classList.toggle('chosen', on);
        row.querySelector('input').checked = on;
        if (on) chosen.set(keyOf(row), row); else chosen.delete(keyOf(row));
      }
      function selectionChanged() {
        header.classList.toggle('selecting', chosen.size > 0);
        $('count').textContent = chosen.size === 1 ? '1 selected' : chosen.size + ' selected';
      }
      function clearSelection() {
        chosen.forEach(function (row) { choose(row, false); });
        chosen.clear();
        anchor = null;
        selectionChanged();
      }

      function removeRows(gone) {
        if (!gone.length) return Promise.resolve();
        var items = gone.map(function (row) { return { url: row.dataset.url, time: Number(row.dataset.time) }; });
        return ask({ op: 'remove', items: items }).then(function (answer) {
          if (answer) state.version = answer.version;
          gone.forEach(function (row) {
            chosen.delete(keyOf(row));
            var card = row.parentNode;
            row.remove();
            if (card && !card.querySelector('.row')) {
              card.remove();
              if (card === state.card) { state.card = null; state.day = null; }
            }
          });
          selectionChanged();
          showEmpty();
          moreIfNear();
        });
      }

      list.addEventListener('click', function (event) {
        var box = event.target.closest('input[type=checkbox]');
        if (box) {
          var row = box.closest('.row');
          var on = box.checked;
          var all = rows();
          var from = anchor && anchor.isConnected ? all.indexOf(anchor) : -1;
          if (event.shiftKey && from >= 0) {
            var to = all.indexOf(row);
            for (var i = Math.min(from, to); i <= Math.max(from, to); i++) choose(all[i], on);
          } else {
            choose(row, on);
          }
          anchor = row;
          selectionChanged();
          return;
        }
        var more = event.target.closest('.more');
        if (more) {
          event.preventDefault();
          if (menuRow === more.closest('.row')) closeMenu(); else openMenu(more);
        }
      });

      // Shift-clicking a run of boxes would otherwise select the text between.
      list.addEventListener('mousedown', function (event) {
        if (event.shiftKey && event.target.closest('input[type=checkbox]')) event.preventDefault();
      });

      // MARK: The row's menu

      function openMenu(button) {
        closeMenu();
        menuRow = button.closest('.row');
        button.classList.add('open');
        menu.hidden = false;
        var place = button.getBoundingClientRect();
        var top = place.bottom + window.scrollY + 4;
        if (place.bottom + menu.offsetHeight + 8 > window.innerHeight) top = place.top + window.scrollY - menu.offsetHeight - 4;
        menu.style.top = Math.max(window.scrollY + 4, top) + 'px';
        menu.style.left = Math.max(8, place.right + window.scrollX - menu.offsetWidth) + 'px';
        menu.querySelector('button').focus({ preventScroll: true });
      }
      function closeMenu() {
        if (menuRow) { var open = menuRow.querySelector('.more.open'); if (open) open.classList.remove('open'); }
        menuRow = null;
        menu.hidden = true;
      }
      menu.addEventListener('click', function (event) {
        var item = event.target.closest('button');
        var row = menuRow;
        closeMenu();
        if (!item || !row) return;
        if (item.dataset.act === 'site') {
          search.value = row.dataset.host;
          runSearch();
          window.scrollTo(0, 0);
        } else if (item.dataset.act === 'remove') {
          removeRows([row]);
        }
      });
      document.addEventListener('mousedown', function (event) {
        if (!menu.hidden && !menu.contains(event.target) && !event.target.closest('.more')) closeMenu();
      });
      window.addEventListener('resize', closeMenu);

      // MARK: Searching

      var typing = null;
      function runSearch() {
        clearTimeout(typing);
        var text = search.value.trim();
        if (text === state.query) return;
        state.query = text;
        try { history.replaceState(null, '', text ? 'drift://history/?q=' + encodeURIComponent(text) : 'drift://history/'); } catch (e) {}
        startOver();
      }
      search.addEventListener('input', function () {
        clearTimeout(typing);
        typing = setTimeout(runSearch, 150);
      });
      search.addEventListener('keydown', function (event) {
        if (event.key === 'Enter') runSearch();
      });

      // MARK: Dialogs

      function open(dialog) { closeMenu(); if (!dialog.open) dialog.showModal(); }
      $('selection-cancel').addEventListener('click', clearSelection);
      $('selection-delete').addEventListener('click', function () { open($('confirm')); });
      $('confirm-no').addEventListener('click', function () { $('confirm').close(); });
      $('confirm-yes').addEventListener('click', function () {
        $('confirm').close();
        var gone = [];
        chosen.forEach(function (row) { gone.push(row); });
        removeRows(gone).then(function () { anchor = null; });
      });
      function openClear() { open($('clear')); $('range').focus(); }
      $('clear-side').addEventListener('click', openClear);
      $('clear-top').addEventListener('click', openClear);
      $('clear-no').addEventListener('click', function () { $('clear').close(); });
      $('clear-yes').addEventListener('click', function () {
        $('clear').close();
        ask({ op: 'clear', range: $('range').value }).then(startOver);
      });
      $('nav-history').addEventListener('click', function () {
        if (search.value) { search.value = ''; runSearch(); }
        window.scrollTo(0, 0);
      });

      document.addEventListener('keydown', function (event) {
        if (event.key !== 'Escape' || document.querySelector('dialog[open]')) return;
        if (!menu.hidden) { closeMenu(); event.preventDefault(); }
        else if (chosen.size) { clearSelection(); event.preventDefault(); }
      });

      window.addEventListener('scroll', function () {
        header.classList.toggle('scrolled', window.scrollY > 0);
        moreIfNear();
      }, { passive: true });
      window.addEventListener('resize', moreIfNear);

      // Shown again after other browsing: brought up to date, unless
      // something on it is in hand.
      function refreshIfStale() {
        if (document.visibilityState !== 'visible' || chosen.size || document.querySelector('dialog[open]')) return;
        ask({ op: 'version' }).then(function (answer) {
          if (answer && answer.version !== state.version && !chosen.size) startOver();
        });
      }
      document.addEventListener('visibilitychange', refreshIfStale);
      window.addEventListener('pageshow', function (event) { if (event.persisted) refreshIfStale(); });

      search.value = new URLSearchParams(location.search).get('q') || '';
      state.query = search.value.trim();
      load();
      if (document.visibilityState === 'visible') search.focus({ preventScroll: true });
    })();
    """#
}

/// Serves drift://history: the page, and the site icons Drift has kept.
/// Only to the History page itself. A site that framed it could trick a
/// click; one that could load the icons would learn, from which exist,
/// where the user had been.
@MainActor
final class HistorySchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = HistorySchemeHandler()

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let request = task.request
        guard let url = request.url, HistoryPage.isPage(url), HistoryPage.isPage(request.mainDocumentURL) else {
            return task.didFailWithError(URLError(.noPermissionsToReadFile))
        }
        var status = 200
        var type = "text/html; charset=utf-8"
        var data = Data()
        let path = url.path
        if path.isEmpty || path == "/" {
            data = Data(HistoryPage.html.utf8)
        } else if path.hasPrefix("/icon/"), case let host = String(path.dropFirst(6)), Self.isHost(host),
                  let stored = FaviconCache.shared.storedData(host: host) {
            type = "image/png"
            data = stored
        } else {
            status = 404
            type = "text/plain"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": type,
            "Content-Length": String(data.count),
            "Content-Security-Policy": HistoryPage.policy,
            "X-Frame-Options": "DENY",
            "Cache-Control": "no-store",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// A host name and nothing else, so no path can reach past the icons.
    static func isHost(_ text: String) -> Bool {
        !text.isEmpty && !text.hasPrefix(".") && !text.contains("..")
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

/// The History page's line to Drift. In Drift's world, so websites cannot
/// see it, and answering only the History page's own top frame.
@MainActor
final class HistoryBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = HistoryBridge()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == HistoryPage.scheme, origin.host == HistoryPage.host,
              HistoryPage.isPage(message.webView?.url),
              let body = message.body as? [String: Any], let answer = HistoryPage.answer(body)
        else { return replyHandler(nil, "not the History page") }
        replyHandler(answer, nil)
    }
}

/// The History menu's latest pages, kept up to date: the menu bar only
/// redraws for something it watches.
@MainActor
final class HistoryMenu: ObservableObject {
    static let shared = HistoryMenu()
    @Published private(set) var recent: [HistoryEntry] = []

    private init() { recent = BrowserStore.shared.history.recent(limit: 15) }

    func refresh(from history: History) {
        let latest = history.recent(limit: 15)
        if latest != recent { recent = latest }
    }
}

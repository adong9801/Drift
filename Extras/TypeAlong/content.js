// Type Along, in the page: shows what comes next in grey where you are
// typing, and moves on as you type it. It only watches your keys; whatever
// you type still goes to the page as normal.
//
// One copy runs in every frame. They share their place through
// storage.local, so typing in one frame (Google Docs takes keys in a hidden
// iframe of its own) moves the grey text drawn in another.
(() => {
  if (window.__typeAlong) return;
  window.__typeAlong = true;

  const api = globalThis.browser ?? globalThis.chrome;
  const me = Math.random().toString(36).slice(2);
  const isTop = window === window.top;
  const isDocs = location.hostname === 'docs.google.com' && location.pathname.startsWith('/document/');
  // A parent frame looks for this before reaching into a child document.
  document.documentElement?.setAttribute('data-type-along', '');

  let state = { text: '', pos: 0, wrong: 0, active: false, strict: true, rev: 0 };
  let finishedAt = 0;

  api.storage.local.get('typeAlong').then((stored) => {
    if (stored.typeAlong) state = { ...state, ...stored.typeAlong };
    renderSoon();
  });
  api.storage.onChanged.addListener((changes, area) => {
    if (area !== 'local' || !changes.typeAlong) return;
    const next = changes.typeAlong.newValue;
    // Our own write coming back, possibly behind keys typed since.
    if (!next || next.writer === me) return;
    state = { ...state, ...next };
    renderSoon();
  });

  function save() {
    state = { ...state, writer: me, rev: (state.rev || 0) + 1 };
    api.storage.local.set({ typeAlong: state });
  }

  // MARK: - Keys

  // Smart quotes, dashes and hard spaces in the pasted text are typed with
  // the plain keys.
  function plain(c) {
    return c
      .replace(/[‘’‚′]/g, "'")
      .replace(/[“”„″]/g, '"')
      .replace(/[‒–—−]/g, '-')
      .replace(/[   ]/g, ' ');
  }

  function typed(c) {
    if (state.pos >= state.text.length) return;
    if (state.wrong > 0) {
      state.wrong += 1;
    } else if (plain(c) === plain(state.text[state.pos])) {
      state.pos += 1;
    } else if (state.strict !== false) {
      state.wrong += 1;
    } else {
      state.pos += 1;
    }
    if (state.pos >= state.text.length) {
      state.active = false;
      finishedAt = Date.now();
    }
    save();
  }

  function deleted(kind) {
    if (state.wrong > 0) {
      state.wrong = kind === 'char' ? state.wrong - 1 : 0;
    } else if (kind === 'char') {
      state.pos = Math.max(0, state.pos - 1);
    } else {
      // Back to the start of the word, or of the line.
      let p = state.pos;
      const stop = kind === 'line' ? /\n/ : /[\s]/;
      while (p > 0 && stop.test(state.text[p - 1])) p -= 1;
      while (p > 0 && !stop.test(state.text[p - 1])) p -= 1;
      state.pos = p;
    }
    save();
  }

  function editableOf(el) {
    if (!el || el.nodeType !== 1) return null;
    if (el.tagName === 'TEXTAREA') return el;
    if (el.tagName === 'INPUT') return /^(text|search|email|url|tel|)$/i.test(el.type) ? el : null;
    if (el.isContentEditable) {
      let root = el;
      while (root.parentElement && root.parentElement.isContentEditable) root = root.parentElement;
      return root;
    }
    if (el.ownerDocument.designMode === 'on') return el.ownerDocument.body;
    return null;
  }

  function onKey(event) {
    if (!state.active || !state.text || event.metaKey || event.ctrlKey) return;
    if (event.isComposing || event.keyCode === 229) return;
    if (!editableOf(event.target)) return;
    // A frame watched from here that has since got a copy of its own: that
    // copy counts the key, and counting it twice would skip a character.
    const from = event.target.ownerDocument;
    if (from !== document && from.documentElement.hasAttribute('data-type-along')) return;
    if (event.key === 'Backspace') {
      deleted(event.altKey ? 'word' : 'char');
    } else if (event.key === 'Enter') {
      typed('\n');
    } else if (event.key === 'Tab' && state.text[state.pos] === '\t') {
      typed('\t');
    } else if (event.key.length === 1) {
      typed(event.key);
    } else {
      return;
    }
    // After the page has put the character in and moved its caret.
    setTimeout(renderSoon, 0);
    setTimeout(renderSoon, 60);
  }

  // MARK: - Documents watched

  const views = new Map();

  function watch(doc) {
    if (views.has(doc)) return;
    views.set(doc, { doc, ghost: null, pill: null });
    doc.addEventListener('keydown', onKey, true);
    doc.addEventListener('selectionchange', renderSoon);
    doc.addEventListener('focusin', renderSoon, true);
    doc.addEventListener('focusout', () => setTimeout(renderSoon, 0), true);
    doc.addEventListener('scroll', renderSoon, true);
    doc.defaultView?.addEventListener('resize', renderSoon);
  }

  // Same-origin frames this copy was not injected into, such as the editor
  // frame of a rich text box or Google Docs' hidden typing frame.
  function watchChildFrames() {
    for (const frame of document.querySelectorAll('iframe')) {
      let doc = null;
      try { doc = frame.contentDocument; } catch (_) { continue; }
      if (!doc || !doc.documentElement || doc.documentElement.hasAttribute('data-type-along')) continue;
      watch(doc);
    }
  }

  watch(document);
  watchChildFrames();
  new MutationObserver(() => watchChildFrames()).observe(document, { childList: true, subtree: true });

  // MARK: - Where the caret is

  const MIRRORED = [
    'direction', 'boxSizing', 'width', 'height', 'overflowX', 'overflowY',
    'borderTopWidth', 'borderRightWidth', 'borderBottomWidth', 'borderLeftWidth', 'borderStyle',
    'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft',
    'fontStyle', 'fontVariant', 'fontWeight', 'fontStretch', 'fontSize', 'lineHeight', 'fontFamily',
    'textAlign', 'textTransform', 'textIndent', 'letterSpacing', 'wordSpacing', 'tabSize',
  ];

  function lineHeightOf(style) {
    const line = parseFloat(style.lineHeight);
    return Number.isFinite(line) ? line : parseFloat(style.fontSize) * 1.25;
  }

  // An <input> or <textarea> has no caret box to ask for, so a hidden copy
  // of it, styled the same, is laid out up to the caret and measured.
  function fieldCaret(field) {
    const doc = field.ownerDocument;
    const style = doc.defaultView.getComputedStyle(field);
    const copy = doc.createElement('div');
    for (const name of MIRRORED) copy.style[name] = style[name];
    copy.style.position = 'absolute';
    copy.style.visibility = 'hidden';
    copy.style.top = '0';
    copy.style.left = '-9999px';
    copy.style.whiteSpace = field.tagName === 'INPUT' ? 'pre' : 'pre-wrap';
    copy.style.overflowWrap = 'break-word';
    const at = field.selectionEnd ?? field.value.length;
    copy.textContent = field.value.slice(0, at);
    const mark = doc.createElement('span');
    mark.textContent = field.value.slice(at) || '.';
    copy.appendChild(mark);
    doc.documentElement.appendChild(copy);
    const left = mark.offsetLeft + parseFloat(style.borderLeftWidth);
    const top = mark.offsetTop + parseFloat(style.borderTopWidth);
    copy.remove();
    const box = field.getBoundingClientRect();
    return {
      x: box.left + left - field.scrollLeft,
      y: box.top + top - field.scrollTop,
      height: lineHeightOf(style),
      right: box.right - parseFloat(style.paddingRight) - parseFloat(style.borderRightWidth),
      style,
    };
  }

  function editableCaret(root) {
    const doc = root.ownerDocument;
    const selection = doc.getSelection();
    if (!selection || !selection.rangeCount) return null;
    const range = selection.getRangeAt(0).cloneRange();
    range.collapse(false);
    const node = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
    if (!node || !root.contains(node)) return null;
    const style = doc.defaultView.getComputedStyle(node);
    let rect = range.getClientRects()[0];
    if (!rect || (!rect.width && !rect.height)) {
      // An empty line has no text to measure: its block's corner will do.
      const block = node.getBoundingClientRect();
      rect = {
        left: block.left + parseFloat(style.paddingLeft),
        top: block.top + parseFloat(style.paddingTop),
        height: lineHeightOf(style),
      };
    }
    const rootBox = root.getBoundingClientRect();
    const rootStyle = doc.defaultView.getComputedStyle(root);
    return {
      x: rect.left,
      y: rect.top,
      height: rect.height || lineHeightOf(style),
      right: rootBox.right - parseFloat(rootStyle.paddingRight),
      style,
    };
  }

  // Google Docs draws its text and its caret itself. The caret is an
  // element of its own, and the text beside it is Arial unless set otherwise.
  function docsCaret(doc) {
    const caret = doc.querySelector('.kix-cursor-caret');
    if (!caret) return null;
    const box = caret.getBoundingClientRect();
    if (!box.height || box.bottom < 0 || box.top > doc.defaultView.innerHeight) return null;
    const page = caret.closest('.kix-appview-editor') || doc.body;
    return {
      x: box.right + 1,
      y: box.top,
      height: box.height,
      right: page.getBoundingClientRect().right - 72,
      style: { fontFamily: 'Arial, sans-serif', fontSize: `${Math.round(box.height * 0.74)}px`, fontWeight: '400', fontStyle: 'normal', letterSpacing: 'normal', color: '#000' },
    };
  }

  function caretIn(doc) {
    if (isDocs && doc === document && isTop) return docsCaret(doc);
    const field = editableOf(doc.activeElement);
    if (!field) return null;
    return field.tagName === 'INPUT' || field.tagName === 'TEXTAREA' ? fieldCaret(field) : editableCaret(field);
  }

  // MARK: - Drawing

  let pending = false;
  function renderSoon() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      for (const view of views.values()) render(view);
    });
  }

  // While Docs is in front, its caret moves without telling anyone.
  if (isDocs && isTop) setInterval(() => { if (state.active) renderSoon(); }, 150);

  function ghostFor(view) {
    if (!view.ghost || !view.ghost.isConnected) {
      // On the <html> element, outside <body>: in a rich text box the body
      // is the text being edited, and nothing of ours belongs in it.
      view.ghost = view.doc.createElement('type-along-ghost');
      view.doc.documentElement.appendChild(view.ghost);
    }
    return view.ghost;
  }

  function hideGhost(view) {
    if (view.ghost) view.ghost.style.setProperty('display', 'none', 'important');
  }

  function render(view) {
    if (isTop && view.doc === document) renderPill();
    // Docs' hidden typing frame has nowhere to show anything.
    if (isDocs && view.doc !== document) return hideGhost(view);
    if (!state.active || !state.text || state.pos >= state.text.length) return hideGhost(view);
    const caret = caretIn(view.doc);
    if (!caret) return hideGhost(view);

    const ghost = ghostFor(view);
    const rest = state.text.slice(state.pos);
    const line = rest.split('\n')[0];
    ghost.textContent = '';
    if (state.wrong > 0) {
      const mark = view.doc.createElement('span');
      mark.textContent = `⌫ ${state.wrong}`;
      mark.style.cssText = 'color:#fff;background:#e5484d;border-radius:3px;padding:0 3px;margin-right:4px;font-size:0.8em;';
      ghost.appendChild(mark);
    }
    const next = view.doc.createElement('span');
    next.textContent = line.length ? line.slice(0, 160) : '↵';
    ghost.appendChild(next);

    const style = caret.style;
    const css = {
      all: 'initial',
      display: 'block',
      position: 'fixed',
      left: `${caret.x}px`,
      top: `${caret.y}px`,
      height: `${caret.height}px`,
      'line-height': `${caret.height}px`,
      'max-width': `${Math.max(40, caret.right - caret.x)}px`,
      overflow: 'hidden',
      'white-space': 'pre',
      'font-family': style.fontFamily,
      'font-size': style.fontSize,
      'font-weight': style.fontWeight,
      'font-style': style.fontStyle,
      'letter-spacing': style.letterSpacing,
      color: style.color || '#000',
      opacity: state.wrong > 0 ? '0.55' : '0.38',
      'pointer-events': 'none',
      'z-index': '2147483647',
    };
    ghost.removeAttribute('style');
    for (const [name, value] of Object.entries(css)) ghost.style.setProperty(name, value, 'important');
  }

  // MARK: - The progress pill

  let pill = null;
  function renderPill() {
    const showing = state.text && (state.active || state.pos > 0) && (state.pos < state.text.length || Date.now() - finishedAt < 4000);
    if (!showing) {
      if (pill) pill.host.style.setProperty('display', 'none', 'important');
      return;
    }
    if (!pill || !pill.host.isConnected) {
      const host = document.createElement('type-along-pill');
      const root = host.attachShadow({ mode: 'closed' });
      root.innerHTML = `
        <style>
          :host { all: initial; position: fixed; right: 16px; bottom: 16px; z-index: 2147483647; }
          div { display: flex; align-items: center; gap: 8px; padding: 6px 8px 6px 12px; border-radius: 999px;
                background: rgba(28, 28, 30, 0.88); color: #fff; font: 12px/1.2 -apple-system, system-ui, sans-serif;
                box-shadow: 0 4px 16px rgba(0, 0, 0, 0.25); -webkit-backdrop-filter: blur(12px); }
          span { font-variant-numeric: tabular-nums; }
          button { all: unset; cursor: pointer; padding: 2px 8px; border-radius: 999px; background: rgba(255, 255, 255, 0.14); }
          button:hover { background: rgba(255, 255, 255, 0.24); }
        </style>
        <div><span></span><button data-act="pause"></button><button data-act="stop">✕</button></div>`;
      root.addEventListener('click', (event) => {
        const act = event.target.closest && event.target.closest('button')?.dataset.act;
        if (act === 'pause') state.active = !state.active;
        else if (act === 'stop') state = { ...state, text: '', pos: 0, wrong: 0, active: false };
        else return;
        save();
        renderSoon();
      });
      document.documentElement.appendChild(host);
      pill = { host, label: root.querySelector('span'), pause: root.querySelector('[data-act=pause]') };
    }
    pill.host.style.removeProperty('display');
    const done = state.pos >= state.text.length;
    const percent = Math.floor((state.pos / state.text.length) * 100);
    pill.label.textContent = done ? 'Type Along · done' : `Type Along · ${percent}%${state.active ? '' : ' · paused'}`;
    pill.host.setAttribute('role', 'status');
    pill.host.setAttribute('aria-label', `${pill.label.textContent}, ${state.pos} of ${state.text.length}`);
    pill.pause.style.display = done ? 'none' : '';
    pill.pause.textContent = state.active ? 'Pause' : 'Resume';
  }
})();

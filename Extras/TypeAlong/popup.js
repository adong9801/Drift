// The popup: where the text goes in, and the controls for a run through it.
// Everything lives in storage.local under "typeAlong", which the content
// script in every page watches.
const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

let state = { text: '', pos: 0, wrong: 0, active: false, strict: true, rev: 0 };

function save(changes) {
  state = { ...state, ...changes, writer: 'popup', rev: (state.rev || 0) + 1 };
  return api.storage.local.set({ typeAlong: state }).then(show);
}

function show() {
  const started = state.text.length > 0;
  const running = started && state.active;
  $('progress').textContent = started
    ? `${state.pos.toLocaleString()} of ${state.text.length.toLocaleString()}${state.pos >= state.text.length ? ' · done' : ''}`
    : '';
  $('start').textContent = started ? 'Start with This Text' : 'Start';
  $('pause').hidden = !started || state.pos >= state.text.length;
  $('pause').textContent = running ? 'Pause' : 'Resume';
  $('restart').hidden = !started;
  $('stop').hidden = !started;
  $('strict').checked = state.strict !== false;
}

$('start').addEventListener('click', async () => {
  // Windows line endings and non-breaking spaces are typed as Return and Space.
  const text = $('text').value.replace(/\r\n?/g, '\n').replace(/ /g, ' ');
  if (!text.trim()) { $('text').focus(); return; }
  await save({ text, pos: 0, wrong: 0, active: true, strict: $('strict').checked });
  window.close();
});

$('pause').addEventListener('click', () => save({ active: !state.active }));
$('restart').addEventListener('click', () => save({ pos: 0, wrong: 0, active: true }));
$('stop').addEventListener('click', () => {
  $('text').value = '';
  save({ text: '', pos: 0, wrong: 0, active: false });
});
$('strict').addEventListener('change', () => save({ strict: $('strict').checked }));

// Kept up to date while it is open, as typing moves on in the page.
api.storage.onChanged.addListener((changes, area) => {
  if (area !== 'local' || !changes.typeAlong?.newValue) return;
  state = { ...state, ...changes.typeAlong.newValue };
  show();
});

api.storage.local.get('typeAlong').then((stored) => {
  if (stored.typeAlong) state = { ...state, ...stored.typeAlong };
  $('text').value = state.text;
  show();
  if (!state.text) $('text').focus();
});

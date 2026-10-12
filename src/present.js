/* Quire — the presentation window.
 * A mirror of the main window's composer for a projector or second monitor.
 * Everything it shows arrives over the `present` event from app.js
 * (presentPush); it sends three things back — `present-hello` on load (so the
 * main window starts feeding it), `present-caret` when the text is clicked
 * (the main window moves its caret there), and `present-size` for +/−. */
'use strict';

const T = window.__TAURI__;
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/* Same live styling as the composer's backdrop (app.js paintBackdrop): the
   markers stay in the text, so what's on the wall is what's in the file —
   and so a click can map straight back to a character offset. */
const live = s => esc(s)
  .replace(/\*\*([^*\n]+)\*\*/g, '<b>**$1**</b>')
  .replace(/__([^_\n]+)__/g, '<i>__$1__</i>')
  .replace(/`([^`\n]+)`/g, '<code>`$1`</code>')
  .replace(/@[a-zA-Z][a-zA-Z0-9_-]*/g, '<span class="tag">$&</span>');

let last = null;
const send = (name, payload) => T.event.emitTo('main', name, payload).catch(() => {});

function applyTheme(t) {
  const r = document.documentElement;
  r.dataset.theme = t.theme; r.dataset.size = t.size; r.dataset.font = t.font; r.dataset.tags = t.tags; r.dataset.scale = t.scale || 'm';
  if (t.accent) { r.style.setProperty('--accent', t.accent); r.style.setProperty('--accent-ink', t.accent); r.style.setProperty('--on-accent', '#FFFFFF'); r.style.setProperty('--accent-soft', t.accent + '26'); }
  else ['--accent', '--accent-ink', '--on-accent', '--accent-soft'].forEach(p => r.style.removeProperty(p));
}

function show(p) {
  applyTheme(p.theme);
  const stage = $('#stage'), idle = $('#idle');
  if (p.kind === 'idle') {
    stage.hidden = true; idle.hidden = false;
    $('#i-date').textContent = p.date;
    $('#i-words').textContent = p.stats.wordsToday;
    $('#i-entries').textContent = p.stats.entries;
    $('#i-drafts').textContent = p.stats.drafts;
    last = p; return;
  }
  idle.hidden = true; stage.hidden = false;
  $('#p-date').textContent = p.date;
  $('#p-star').hidden = !p.starred;
  const h = $('#p-title'); h.textContent = p.title; h.hidden = !p.title.trim();
  $('#p-tags').textContent = p.tags.join('  ');
  $('#p-words').textContent = `${p.words} ${p.words === 1 ? 'word' : 'words'}`;
  const textChanged = !last || last.body !== p.body || last.kind !== p.kind;
  const caretChanged = !last || last.caret !== p.caret;
  if (textChanged || caretChanged) renderBody(p);
  last = p;
  if (textChanged || caretChanged) keepVisible(caretChanged);
}

function renderBody(p) {
  const el = $('#p-body'), text = p.body;
  if (!text) { el.innerHTML = (p.caret != null ? '<span class="p-caret" id="p-caret"></span>' : '') + '<span class="placeholder">Begin writing</span>'; return; }
  const at = p.kind === 'write' && p.caret != null ? Math.max(0, Math.min(text.length, p.caret)) : null;
  // The caret is an empty span, so the body's text content stays byte-equal
  // to the draft and clicks map back to offsets (see caretFromPoint).
  el.innerHTML = at == null ? live(text) : live(text.slice(0, at)) + '<span class="p-caret" id="p-caret"></span>' + live(text.slice(at));
  if (text.endsWith('\n')) el.insertAdjacentHTML('beforeend', '<span class="zwsp" aria-hidden="true">​</span>');
}

/* Scroll only once the caret leaves a comfortable band, then put it a little
   above centre — the reader's eye rests there — rather than pinning the newest
   line to the bottom. A wheel-scroll by hand holds until the next keystroke. */
function keepVisible(moved) {
  const c = $('#p-caret'), sc = $('#p-scroll');
  if (!c || !sc) return;
  if (moved) { c.classList.add('still'); setTimeout(() => c.classList.remove('still'), 500); }
  const r = c.getBoundingClientRect(), sr = sc.getBoundingClientRect();
  const margin = Math.min(sr.height * 0.2, r.height * 2);
  if (r.top >= sr.top + margin && r.bottom <= sr.bottom - margin) return;
  sc.scrollTo({ top: sc.scrollTop + (r.top - sr.top) - sr.height * 0.45, behavior: 'smooth' });
}

/* Mouse: a click on the text moves the main window's caret to that character.
   The offset is the length of every text node before the hit, plus the hit's
   own offset — the styling only wraps text, never changes it. */
function caretFromPoint(x, y) {
  let node, offset;
  if (document.caretPositionFromPoint) { const p = document.caretPositionFromPoint(x, y); if (!p) return null; node = p.offsetNode; offset = p.offset; }
  else if (document.caretRangeFromPoint) { const r = document.caretRangeFromPoint(x, y); if (!r) return null; node = r.startContainer; offset = r.startOffset; }
  else return null;
  const body = $('#p-body');
  if (!node || !body.contains(node)) return null;
  // Everything from the start of the body to the hit, as text, is the offset
  // — the one zero-width space standing in for a trailing newline aside.
  const pre = document.createRange();
  pre.setStart(body, 0); pre.setEnd(node, offset);
  return pre.toString().replace(/\u200B/g, '').length;
}
$('#p-body').addEventListener('click', ev => {
  if (!last || last.kind !== 'write') return;
  const off = caretFromPoint(ev.clientX, ev.clientY);
  if (off == null) return;
  send('present-caret', { offset: Math.min(off, last.body.length) });
});

/* Keys: F full screen, +/− text size (saved by the main window), H hints, Esc out. */
const win = T.window.getCurrentWindow();
const hintsKey = 'quire.present.hints';
function applyHints() { const off = localStorage.getItem(hintsKey) === 'off'; $('#hints').hidden = off; document.body.classList.toggle('no-hints', off); }
document.addEventListener('keydown', async ev => {
  const k = ev.key;
  if (k === 'f' || k === 'F' || k === 'F11') { ev.preventDefault(); await win.setFullscreen(!(await win.isFullscreen())); return; }
  if (k === '+' || k === '=') { ev.preventDefault(); send('present-size', { delta: 1 }); return; }
  if (k === '-' || k === '_') { ev.preventDefault(); send('present-size', { delta: -1 }); return; }
  if (k === 'h' || k === 'H') { ev.preventDefault(); localStorage.setItem(hintsKey, $('#hints').hidden ? 'on' : 'off'); applyHints(); return; }
  if (k === 'Escape') { ev.preventDefault(); if (await win.isFullscreen()) await win.setFullscreen(false); else await win.close(); }
});
applyHints();

T.event.listen('present', ev => show(ev.payload));
window.addEventListener('pagehide', () => send('present-bye', null));
send('present-hello', null);

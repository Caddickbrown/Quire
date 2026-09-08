/*
  wander — the front end.

  The same journal the macOS app opens: entries are plain markdown in the jnl
  layout, and the Rust side (src-tauri/src/journal.rs) does every read and write.
  This file is the interface — the index, the page, the two panels — and the
  live markdown styling in the editor.
*/

const invoke = window.__TAURI__.core.invoke;
const dialog = window.__TAURI__.dialog;
const appWindow = window.__TAURI__.window.getCurrentWindow();

const $ = (id) => document.getElementById(id);
const PAGES = ['journal', 'inbox', 'starred'];

const state = {
  base: '',
  entries: [],
  page: 'journal',
  query: '',
  selection: null,
  title: '',
  body: '',
  saveState: '',
  sheetDate: null,
  calendarMonth: null,
  pendingDelete: null,
  // Bumped whenever the entry list changes. Anything derived from every entry
  // — the visible set, the streak — is cached against it, because with a big
  // journal those walks are done several times per render.
  revision: 0,
};

const touch = () => { state.revision += 1; };

let THEMES = [];
let theme = null;

const settings = Object.assign({
  theme: 'almanac',
  type: 17.5,
  lead: 0.42,
  measure: 760,
  focus: false,
  paper: 'auto',
  columns: { index: true, stats: true, options: false },
}, JSON.parse(localStorage.getItem('wander.settings') || '{}'));

function persistSettings() {
  localStorage.setItem('wander.settings', JSON.stringify(settings));
}

// ---------------------------------------------------------------- utilities

const idOf = (entry) => `${entry.source}#${entry.ts}`;

/// The entry as it sits in the file. The Rust side no longer sends this — it is
/// the header line plus the body a second time, and it doubled the JSON the
/// front end had to parse — so it is rebuilt here, where it is actually wanted.
function rawOf(entry) {
  let raw = `[${entry.ts}]`;
  if (entry.suffix) raw += ` ${entry.suffix}`;
  if (entry.body) raw += `\n${entry.body}`;
  return raw;
}

/// Folded to lower case once and kept on the entry: search used to fold the
/// whole journal on every keystroke in the find box.
function haystack(entry) {
  if (entry.folded === undefined) entry.folded = rawOf(entry).toLowerCase();
  return entry.folded;
}

const current = () => state.entries.find((e) => idOf(e) === state.selection) || null;

const words = (text) => (text.trim() ? text.trim().split(/\s+/).length : 0);
const paragraphs = (text) => text.split(/\n\s*\n/).filter((p) => p.trim()).length;
const readingMinutes = (text) => (words(text) ? Math.max(1, Math.round(words(text) / 220)) : 0);

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June',
                'July', 'August', 'September', 'October', 'November', 'December'];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const SHORT_MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const pad = (n) => String(n).padStart(2, '0');

function parseStamp(ts) {
  // "YYYY-MM-DD HH:MM:SS" as local time, without Date's string-parsing quirks.
  const [date, time] = ts.split(' ');
  const [y, m, d] = date.split('-').map(Number);
  const [hh, mm, ss] = (time || '00:00:00').split(':').map(Number);
  return new Date(y, m - 1, d, hh, mm, ss);
}

const stampOf = (date) =>
  `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
  `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;

const dayOf = (date) => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
const longDay = (date) => `${DAYS[date.getDay()]}, ${date.getDate()} ${MONTHS[date.getMonth()]} ${date.getFullYear()}`;
const shortDay = (date) => `${date.getDate()} ${SHORT_MONTHS[date.getMonth()]}`;
const clock = (date) => `${pad(date.getHours())}:${pad(date.getMinutes())}`;

const PROMPTS = [
  'Write the sentence you would rather not. It is usually the one carrying the entry.',
  'Detail before conclusion: what was on the table, what the light was doing, who spoke first.',
  'A journal is not a defence. Nobody is going to cross-examine the draft.',
  'If the day resists summary, put down three things in the order they happened and stop.',
  'The dull entries are the ones worth having in five years. Keep them.',
  'Name the thing you are avoiding, then leave it. Naming is enough for today.',
  'Write it as you would tell it to one person, and not as you would post it.',
  'What changed today that you would not have predicted on Monday?',
  'End mid-thought if you must. Tomorrow’s entry can pick up the sentence.',
  'Tag it @later and let the future reader do the sorting.',
  'One page is a good day’s work. Half a page still counts.',
  'Describe the room. The feeling tends to follow the furniture.',
];

// ------------------------------------------------------------------- filing

let visibleCache = { key: null, list: [] };

function visibleEntries() {
  const query = state.query.trim().toLowerCase();
  const key = `${state.revision}\u0000${state.page}\u0000${query}`;
  if (visibleCache.key === key) return visibleCache.list;

  const found = query
    ? state.entries.filter((e) => haystack(e).includes(query))
    : state.entries;
  const list = state.page === 'inbox' ? found.filter((e) => e.unfiled)
    : state.page === 'starred' ? found.filter((e) => e.starred)
    : found.filter((e) => !e.unfiled);
  visibleCache = { key, list };
  return list;
}

/// Sections for the index: the inbox is one undated run, because inbox.md is;
/// the other pages are set by month.
function sections() {
  const list = visibleEntries();
  if (state.page === 'inbox') {
    return list.length ? [{ title: 'Inbox', entries: list, inbox: true }] : [];
  }
  const order = [];
  const buckets = new Map();
  for (const entry of list) {
    const key = entry.date.slice(0, 7);
    if (!buckets.has(key)) { order.push(key); buckets.set(key, []); }
    buckets.get(key).push(entry);
  }
  return order.map((key) => {
    const [y, m] = key.split('-').map(Number);
    return { title: `${MONTHS[m - 1]} ${y}`, entries: buckets.get(key), inbox: false };
  });
}

let streakCache = { revision: -1, value: 0 };

function streak() {
  if (streakCache.revision === state.revision) return streakCache.value;
  streakCache = { revision: state.revision, value: countStreak() };
  return streakCache.value;
}

function countStreak() {
  const days = new Set(state.entries.map((e) => e.date));
  if (!days.size) return 0;
  let cursor = new Date();
  if (!days.has(dayOf(cursor))) {
    cursor.setDate(cursor.getDate() - 1);
    if (!days.has(dayOf(cursor))) return 0;
  }
  let count = 0;
  while (days.has(dayOf(cursor))) {
    count += 1;
    cursor.setDate(cursor.getDate() - 1);
  }
  return count;
}

// -------------------------------------------------------- markdown styling

const escapeHtml = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

const mark = (s) => `<span class="mark">${s}</span>`;

function inlineStyle(text) {
  let out = escapeHtml(text);
  out = out.replace(/`([^`\n]+)`/g,
    (_, code) => `<span class="code">${mark('`')}${code}${mark('`')}</span>`);
  out = out.replace(/\*\*(.+?)\*\*/g,
    (_, body) => `${mark('**')}<span class="strong">${body}</span>${mark('**')}`);
  out = out.replace(/\*([^*\n]+?)\*/g,
    (_, body) => `${mark('*')}<span class="em">${body}</span>${mark('*')}`);
  out = out.replace(/\[([^\]\n]*)\]\(([^)\s]+)\)/g,
    (_, label, url) => `${mark('[')}<span class="link">${label}</span>${mark(']')}` +
                       `${mark('(')}<span class="url">${url}</span>${mark(')')}`);
  out = out.replace(/@[a-zA-Z][a-zA-Z0-9_-]*/g, (tag) => `<span class="tag">${tag}</span>`);
  return out;
}

/// One source line as one styled block. Structure shows; the markers recede.
function renderLine(line) {
  if (!line) return '<span class="ln"><br></span>';

  let match = line.match(/^(#{1,6})\s+(.*)$/);
  if (match) {
    const level = Math.min(match[1].length, 3);
    return `<span class="ln h${level}">${mark(match[1])} ${inlineStyle(match[2])}</span>`;
  }
  match = line.match(/^(\s*>\s?)(.*)$/);
  if (match) {
    return `<span class="ln quote">${mark(match[1])}${inlineStyle(match[2])}</span>`;
  }
  match = line.match(/^(\s*(?:[-*+]|\d{1,3}\.)\s)(.*)$/);
  if (match) {
    return `<span class="ln bullet">${mark(match[1])}${inlineStyle(match[2])}</span>`;
  }
  if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
    return `<span class="ln hr">${escapeHtml(line)}</span>`;
  }
  return `<span class="ln">${inlineStyle(line)}</span>`;
}

// -------------------------------------------------- the contenteditable page

const prose = $('prose');

/// The text as the DOM currently holds it, plus where the caret sits in it.
function readProse() {
  const selection = window.getSelection();
  let text = '';
  let caret = null;
  const lines = Array.from(prose.children);

  lines.forEach((line, index) => {
    if (index) text += '\n';
    if (selection && selection.anchorNode === prose && selection.anchorOffset === index) {
      caret = text.length;
    }
    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
    let node;
    let sawText = false;
    while ((node = walker.nextNode())) {
      sawText = true;
      if (selection && selection.anchorNode === node) {
        caret = text.length + selection.anchorOffset;
      }
      text += node.nodeValue;
    }
    if (!sawText && selection && line.contains(selection.anchorNode)) caret = text.length;
  });

  // Typing into an empty editor can leave a bare text node behind.
  if (!lines.length) {
    text = prose.textContent;
    caret = selection && selection.anchorNode ? selection.anchorOffset : text.length;
  }
  return { text, caret };
}

/// The lines as the DOM currently has them, so a keystroke can be matched
/// against them and only its own line rebuilt.
let renderedLines = [];

function renderProse(text, caret) {
  const lines = text.split('\n');

  // Typing touches one line, and the styling here is line by line, so replacing
  // that one block beats re-parsing the whole entry's HTML on every keystroke.
  // Anything wider — a paste, a return, a delete across a newline — falls
  // through to the full rebuild below.
  if (lines.length === renderedLines.length && prose.children.length === lines.length) {
    let changed = -1;
    let count = 0;
    for (let index = 0; index < lines.length && count < 2; index += 1) {
      if (lines[index] !== renderedLines[index]) { changed = index; count += 1; }
    }
    if (count < 2) {
      if (count === 1) {
        const holder = document.createElement('div');
        holder.innerHTML = renderLine(lines[changed]);
        prose.replaceChild(holder.firstChild, prose.children[changed]);
      }
      renderedLines = lines;
      if (caret !== null && caret !== undefined) placeCaret(caret);
      markLiveLine();
      return;
    }
  }

  prose.innerHTML = lines.map(renderLine).join('');
  renderedLines = lines;
  if (caret !== null && caret !== undefined) placeCaret(caret);
  markLiveLine();
}

function placeCaret(offset) {
  let remaining = offset;
  const lines = Array.from(prose.children);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const length = line.textContent.length;
    if (remaining <= length) {
      const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
      let node;
      let seen = 0;
      while ((node = walker.nextNode())) {
        if (seen + node.nodeValue.length >= remaining) {
          const range = document.createRange();
          range.setStart(node, remaining - seen);
          range.collapse(true);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          return;
        }
        seen += node.nodeValue.length;
      }
      // Empty line: put the caret in the block itself.
      const range = document.createRange();
      range.setStart(line, 0);
      range.collapse(true);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      return;
    }
    remaining -= length + 1;   // the newline between blocks
  }
}

/// Focus mode lights only the line the caret is on. Finding it by walking up
/// from the caret touches two nodes; asking every line whether it contains the
/// caret touched all of them, on every keystroke.
let liveLine = null;

function markLiveLine() {
  if (!settings.focus) {
    if (liveLine) { liveLine.classList.remove('live'); liveLine = null; }
    return;
  }
  const anchor = window.getSelection() ? window.getSelection().anchorNode : null;
  let line = anchor && (anchor.nodeType === 1 ? anchor : anchor.parentElement);
  while (line && line !== prose && line.parentElement !== prose) line = line.parentElement;
  if (line === prose) line = null;

  if (line === liveLine) return;
  if (liveLine) liveLine.classList.remove('live');
  liveLine = line;
  if (liveLine) liveLine.classList.add('live');
}

const undoStack = [];
let undoTimer = null;

function snapshot(text, caret) {
  clearTimeout(undoTimer);
  undoTimer = setTimeout(() => {
    const last = undoStack[undoStack.length - 1];
    if (!last || last.text !== text) undoStack.push({ text, caret });
    if (undoStack.length > 200) undoStack.shift();
  }, 400);
}

prose.addEventListener('input', () => {
  const { text, caret } = readProse();
  state.body = text;
  snapshot(text, caret);
  renderProse(text, caret);
  edited();
  renderCounts();
});

prose.addEventListener('keydown', (event) => {
  const meta = event.metaKey || event.ctrlKey;
  if (meta && event.key.toLowerCase() === 'z') {
    event.preventDefault();
    const previous = undoStack.pop();
    if (previous) {
      state.body = previous.text;
      renderProse(previous.text, previous.caret);
      edited();
      renderCounts();
    }
    return;
  }
  if (meta && (event.key === 'b' || event.key === 'i')) {
    event.preventDefault();
    wrapSelection(event.key === 'b' ? '**' : '*');
  }
});

document.addEventListener('selectionchange', () => {
  if (document.activeElement === prose) markLiveLine();
});

function wrapSelection(marker) {
  const { text, caret } = readProse();
  const selection = window.getSelection();
  const chosen = selection && !selection.isCollapsed ? selection.toString() : '';
  if (!chosen) {
    const next = text.slice(0, caret) + marker + marker + text.slice(caret);
    state.body = next;
    renderProse(next, caret + marker.length);
  } else {
    const start = text.indexOf(chosen);
    if (start < 0) return;
    const wrapped = chosen.startsWith(marker) && chosen.endsWith(marker);
    const replacement = wrapped
      ? chosen.slice(marker.length, -marker.length)
      : marker + chosen + marker;
    const next = text.slice(0, start) + replacement + text.slice(start + chosen.length);
    state.body = next;
    renderProse(next, start + replacement.length);
  }
  edited();
  renderCounts();
}

// ------------------------------------------------------------------- saving

let saveTimer = null;

/// Clean when the buffer matches what is on disk, or what was last written
/// from it — the Rust side trims what it stores, so comparing only against the
/// stored entry would leave a buffer with a trailing newline dirty for ever,
/// saving on a loop.
function dirty(entry) {
  if (state.title === entry.title && state.body === entry.body) return false;
  const written = entry.written;
  return !written || state.title !== written.title || state.body !== written.body;
}

function edited() {
  const entry = current();
  if (!entry) return;
  if (!dirty(entry)) {
    clearTimeout(saveTimer);
    if (state.saveState === 'Writing…') setSaveState('');
    return;
  }
  setSaveState('Writing…');
  clearTimeout(saveTimer);
  saveTimer = setTimeout(save, 700);
}

function setSaveState(text) {
  state.saveState = text;
  $('save-state').textContent = text;
}

async function save() {
  clearTimeout(saveTimer);
  const entry = current();
  if (!entry || !dirty(entry)) return;
  const written = { title: state.title, body: state.body };
  try {
    const saved = await invoke('save', {
      ts: entry.ts,
      source: entry.source,
      title: written.title,
      body: written.body,
      starred: entry.starred,
    });
    absorb(entry, saved, written);
    setSaveState(saved ? `Saved ${clock(new Date())}` : '');
  } catch (error) {
    setSaveState(`Not saved — ${error}`);
  }
}

/// Fold what the disk now holds back into the list, without rereading the
/// folder. Saving used to call `refresh`, which parsed every file in the
/// journal and rebuilt the index from it — once every 700ms while you typed,
/// and it took the caret and the undo stack with it each time.
function absorb(entry, saved, written) {
  // By id, not by identity: a reload may have swapped the objects out while
  // the write was in flight.
  const id = idOf(entry);
  const index = state.entries.findIndex((e) => idOf(e) === id);

  // Emptied: the Rust side has taken it off disk, so it leaves the list too.
  if (!saved) {
    if (index >= 0) state.entries.splice(index, 1);
    touch();
    // Only move on if the entry that went was the one still open — a save that
    // lands after you have clicked elsewhere must not drag you back.
    if (!current()) ensureSelection();
    render();
    return;
  }

  // Saving never moves an entry, so its id — and its place in the list — hold.
  if (written) saved.written = written;
  if (index >= 0) state.entries[index] = saved;
  else state.entries.unshift(saved);
  touch();
  render();
}

async function refresh(selectId) {
  const journal = await invoke('load');
  state.base = journal.base;
  state.entries = journal.entries;
  touch();
  if (selectId !== undefined && selectId !== null) state.selection = selectId;
  if (!current()) {
    const first = visibleEntries()[0];
    state.selection = first ? idOf(first) : null;
  }
  loadDraft();
  render();
}

function loadDraft() {
  const entry = current();
  state.title = entry ? entry.title : '';
  state.body = entry ? entry.body : '';
  $('title').value = state.title;
  renderProse(state.body, null);
  undoStack.length = 0;
}

function selectEntry(id) {
  if (state.selection === id) return;
  save();
  state.selection = id;
  loadDraft();
  setSaveState('');
  render();
}

// ------------------------------------------------------------------ actions

async function newEntry(draft) {
  await save();
  const entry = await invoke('create', { draft });
  state.page = draft ? 'inbox' : 'journal';
  // A blank entry isn't on disk until it has text; hold it in the list.
  state.entries.unshift(entry);
  touch();
  state.selection = idOf(entry);
  loadDraft();
  render();
  prose.focus();
}

async function toggleStar() {
  await save();
  // `save` may have replaced the entry object, so ask for it again.
  const entry = current();
  if (!entry) return;
  const saved = await invoke('save', {
    ts: entry.ts, source: entry.source,
    title: entry.title, body: entry.body, starred: !entry.starred,
  });
  absorb(entry, saved, null);
}

async function toggleFiling() {
  const entry = current();
  if (!entry) return;
  await save();
  const moved = await invoke('relocate', {
    ts: entry.ts, source: entry.source, newTs: null, toInbox: !entry.unfiled,
  });
  state.page = moved.unfiled ? 'inbox' : 'journal';
  await refresh(idOf(moved));
}

async function removeEntry(entry) {
  await invoke('remove', { ts: entry.ts, source: entry.source });
  state.selection = null;
  await refresh(null);
}

async function moveEntry(date) {
  const entry = current();
  if (!entry) return;
  const moved = await invoke('relocate', {
    ts: entry.ts, source: entry.source, newTs: stampOf(date), toInbox: null,
  });
  await refresh(idOf(moved));
}

// ---------------------------------------------------------------- rendering

function render() {
  renderMasthead();
  renderList();
  renderEditor();
  renderPanels();
  applySettings();
}

function renderMasthead() {
  const nav = $('pages');
  const ordered = [state.page, ...PAGES.filter((p) => p !== state.page)];
  nav.innerHTML = '';
  // Only the inbox carries a count: it is a queue, and the number is the thing
  // waiting to be dealt with. Counted once, not once per button.
  const count = state.entries.reduce((n, e) => n + (e.unfiled ? 1 : 0), 0);
  for (const page of ordered) {
    const button = document.createElement('button');
    button.className = `quiet${page === state.page ? ' on' : ''}`;
    button.textContent = page === 'inbox' && count
      ? `Inbox ${count}`
      : page.charAt(0).toUpperCase() + page.slice(1);
    button.onclick = () => { state.page = page; ensureSelection(); render(); };
    nav.appendChild(button);
  }

  const entry = current();
  const number = entry
    ? state.entries.length - state.entries.findIndex((e) => idOf(e) === state.selection)
    : null;
  const parts = [];
  if (number) parts.push(`No. ${String(number).padStart(3, '0')}`);
  parts.push(longDay(new Date()));
  const run = streak();
  if (run > 1) parts.push(`${run}-day streak`);
  $('running-head').textContent = parts.join(' · ');

  document.querySelectorAll('[data-column]').forEach((button) => {
    const open = settings.columns[button.dataset.column];
    if (button.classList.contains('quiet')) button.classList.toggle('on', open);
    else button.textContent = open ? 'Open' : 'Closed';
  });
}

/// The index is windowed. A journal of any age is thousands of rows, and
/// building every one of them — which is what this did — cost a third of a
/// second of frozen interface every time anything at all changed. Rows are
/// built a screenful at a time and appended as the list is scrolled.
const LIST_BATCH = 60;
const LIST_LOOKAHEAD = 400;
let listItems = [];
let listShown = 0;
let listKey = null;
let rowHeight = 56;

/// Stands in for the rows not built yet, so the scrollbar still measures the
/// whole journal rather than the handful of rows currently in the document.
const spacer = document.createElement('div');
spacer.className = 'list-rest';

function renderList() {
  const list = $('list');
  // Most re-renders are a word count or a title changing, not the list itself.
  // Only a different page or a different search starts again from the top.
  const key = `${state.page}\u0000${state.query}`;
  const keep = key === listKey;
  listKey = key;
  const wasScrolled = keep ? list.scrollTop : 0;

  list.innerHTML = '';
  listItems = [];
  listShown = 0;
  const grouped = sections();

  if (!grouped.length) {
    const note = document.createElement('p');
    note.className = 'marginalia';
    note.style.padding = '22px 14px';
    note.textContent = state.query
      ? 'No entry matches that.'
      : state.page === 'inbox'
        ? 'The inbox is empty — start a draft when something isn’t ready to be dated.'
        : state.page === 'starred'
          ? 'Nothing starred. Star an entry to keep it where you can find it again.'
          : 'Nothing filed yet. The first entry is the hardest to place; it needn’t be good.';
    list.appendChild(note);
    return;
  }

  for (const section of grouped) {
    listItems.push({ section });
    for (const entry of section.entries) listItems.push({ entry });
  }
  spacer.style.height = '0px';
  list.appendChild(spacer);
  // Back to where the list was, which means building the rows up to there.
  growTo(Math.max(wasScrolled + list.clientHeight, LIST_LOOKAHEAD));
  list.scrollTop = wasScrolled;
  growList();
}

/// Rows enough to cover what is on screen, and a little beyond it.
function growList() {
  const list = $('list');
  growTo(list.scrollTop + list.clientHeight + LIST_LOOKAHEAD);
}

function growTo(bottom) {
  const list = $('list');
  // How far the rows built so far reach. Taken from the list's own scroll
  // height rather than the spacer's offsetTop, which is measured against
  // whichever ancestor happens to be positioned.
  const built = () => list.scrollHeight - spacer.offsetHeight;
  while (listShown < listItems.length && built() < bottom) {
    const end = Math.min(listItems.length, listShown + LIST_BATCH);
    const batch = document.createDocumentFragment();
    for (let index = listShown; index < end; index += 1) {
      const item = listItems[index];
      batch.appendChild(item.section ? sectionNode(item.section) : rowNode(item.entry));
    }
    list.insertBefore(batch, spacer);
    listShown = end;
    // Measured rather than guessed, so the scrollbar is about the right size.
    const first = list.querySelector('.row');
    if (first && first.offsetHeight) rowHeight = first.offsetHeight;
    spacer.style.height = `${(listItems.length - listShown) * rowHeight}px`;
  }
}

$('list').addEventListener('scroll', () => {
  if (listShown < listItems.length) growList();
});

function sectionNode(section) {
  const head = document.createElement('div');
  head.className = `month${section.inbox ? ' inbox' : ''}`;
  head.innerHTML = `<span class="smallcaps">${section.title}</span>` +
                   `<span class="smallcaps">${section.entries.length}</span>`;
  return head;
}

function rowNode(entry) {
  const row = document.createElement('button');
  row.className = `row${idOf(entry) === state.selection ? ' on' : ''}`;
  const title = entry.title || firstLine(entry.body);
  const date = parseStamp(entry.ts);
  const meta = `${entry.unfiled ? 'Draft · ' : ''}${shortDay(date)} · ${entry.words} ` +
               `${entry.words === 1 ? 'word' : 'words'}`;
  row.innerHTML =
    `<div class="row-title${title ? '' : ' untitled'}">${escapeHtml(title || 'Untitled')}` +
    `${entry.starred ? '<span class="star"> ✱</span>' : ''}</div>` +
    `<div class="row-meta"><span class="smallcaps">${escapeHtml(meta)}</span>` +
    `<span class="spacer"></span>` +
    `${entry.unfiled ? '<span class="smallcaps file">File</span>' : ''}</div>`;
  row.onclick = (event) => {
    if (event.target.classList.contains('file')) {
      selectEntry(idOf(entry));
      toggleFiling();
      return;
    }
    selectEntry(idOf(entry));
  };
  row.oncontextmenu = (event) => {
    event.preventDefault();
    selectEntry(idOf(entry));
    state.pendingDelete = entry;
    $('confirm-note').textContent =
      `“${entry.title || firstLine(entry.body) || 'Untitled'}” will be removed from ` +
      `${entry.source.split('/').pop()} on disk.`;
    $('confirm').hidden = false;
  };
  return row;
}

const firstLine = (body) =>
  (body.split('\n').find((line) => line.trim()) || '').replace(/^[#>\-*_`\s]+/, '');

function renderEditor() {
  const entry = current();
  $('blank').hidden = !!entry;
  document.querySelector('.page').hidden = !entry;
  if (!entry) return;

  const date = parseStamp(entry.ts);
  const parts = [longDay(date), clock(date)];
  if (entry.tags.length) parts.push(entry.tags.slice(0, 4).join(' '));
  $('dateline').textContent = parts.join(' · ').toUpperCase();

  $('star-toggle').textContent = entry.starred ? '✱ Starred' : 'Star';
  $('star-toggle').classList.toggle('on', entry.starred);
  $('file-toggle').hidden = !entry.unfiled;
  renderCounts();
}

function renderCounts() {
  const count = words(state.body);
  const parts = [`${count} ${count === 1 ? 'word' : 'words'}`, `${state.body.length} characters`];
  const minutes = readingMinutes(state.body);
  if (minutes) parts.push(`${minutes} min read`);
  $('counts').textContent = parts.join(' · ').toUpperCase();
}

function renderPanels() {
  const entry = current();
  $('s-words').textContent = words(state.body);
  $('s-chars').textContent = state.body.length;
  $('s-paras').textContent = paragraphs(state.body);
  $('s-read').textContent = `${readingMinutes(state.body)} min`;

  const number = entry
    ? state.entries.length - state.entries.findIndex((e) => idOf(e) === state.selection)
    : null;
  $('s-number').textContent = number ? `No. ${String(number).padStart(3, '0')}` : '—';
  $('s-written').textContent = entry
    ? `${shortDay(parseStamp(entry.ts))} · ${clock(parseStamp(entry.ts))}` : '—';
  $('s-tags').textContent = entry && entry.tags.length ? entry.tags.slice(0, 3).join(' ') : '—';
  $('s-status').textContent = entry ? (entry.unfiled ? 'In the inbox' : 'Filed') : '—';
  $('s-file').textContent = entry ? entry.source.split('/').pop() : '—';
  $('a-file').hidden = !entry || !entry.unfiled;

  $('s-entries').textContent = state.entries.length;
  $('s-total').textContent = state.entries.reduce((sum, e) => sum + e.words, 0).toLocaleString();
  const prefix = dayOf(new Date()).slice(0, 7);
  $('s-month').textContent = state.entries.filter((e) => e.date.startsWith(prefix)).length;
  const run = streak();
  $('s-streak').textContent = `${run} ${run === 1 ? 'day' : 'days'}`;

  $('o-type').textContent = settings.type.toFixed(1);
  $('o-lead').textContent = (1 + settings.lead).toFixed(2);
  $('o-measure').textContent = settings.measure;
  $('o-focus').textContent = settings.focus ? 'On' : 'Off';
  $('o-paper').textContent = settings.paper.charAt(0).toUpperCase() + settings.paper.slice(1);
  $('o-path').textContent = state.base;

  const day = Math.floor((Date.now() - new Date(new Date().getFullYear(), 0, 0)) / 86400000);
  $('prompt').textContent = PROMPTS[day % PROMPTS.length];
}

/// The theme table is the same file the Mac and iOS apps read.
async function loadThemes() {
  try {
    const response = await fetch('./themes.json');
    THEMES = (await response.json()).themes;
  } catch (error) {
    THEMES = [];
  }
  theme = THEMES.find((t) => t.id === settings.theme) || THEMES[0] || null;
}

const isDark = () => {
  if (settings.paper === 'dark') return true;
  if (settings.paper === 'light') return false;
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
};

/// Paint the theme: its palette as custom properties, its faces, and the
/// structural switches as data attributes the stylesheet keys off.
function applyTheme() {
  if (!theme) return;
  const root = document.documentElement;
  const palette = isDark() ? theme.dark : theme.light;
  for (const [key, value] of Object.entries(palette)) {
    root.style.setProperty(`--${key.replace(/[A-Z]/g, (c) => '-' + c.toLowerCase())}`, value);
  }
  const stack = (face, fallback) => `'${face.families.join("', '")}', ${fallback}`;
  root.style.setProperty('--prose', stack(theme.type.prose, 'Georgia, serif'));
  root.style.setProperty('--display', stack(theme.type.display, 'Georgia, serif'));
  root.style.setProperty('--label', stack(theme.type.label, 'system-ui, sans-serif'));
  root.style.setProperty('--label-size', `${theme.type.label.size || 10.5}px`);
  root.style.setProperty('--label-tracking', `${(theme.type.label.tracking || 1.15) / 10}em`);
  root.style.setProperty('--display-scale', theme.type.display.scale || 1);
  root.style.setProperty('--corner', `${theme.chrome.corner || 0}px`);
  root.style.setProperty('--border', `${theme.chrome.border || 1}px`);
  root.style.setProperty('--masthead-rule', `${theme.chrome.mastheadRule || 0}px`);
  root.dataset.masthead = theme.chrome.mastheadStyle || 'rule';
  root.dataset.rows = theme.chrome.rowStyle || 'rule';
  root.dataset.stats = theme.chrome.statsStyle || 'rows';
  root.dataset.pageCard = String(!!theme.chrome.pageCard);
  root.dataset.ornament = theme.chrome.ornament || 'none';
  $('o-theme').textContent = theme.name;
}

function applySettings() {
  const root = document.documentElement;
  root.style.setProperty('--type', `${settings.type}px`);
  root.style.setProperty('--lead', (1 + settings.lead).toFixed(2));
  root.style.setProperty('--measure', `${settings.measure}px`);
  root.dataset.theme = settings.paper;
  root.dataset.system = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  applyTheme();
  prose.classList.toggle('focus', settings.focus);

  for (const [name, open] of Object.entries(settings.columns)) {
    $(`col-${name}`).classList.toggle('closed', !open);
  }
  persistSettings();
}

function ensureSelection() {
  if (current() && visibleEntries().some((e) => idOf(e) === state.selection)) return;
  const first = visibleEntries()[0];
  state.selection = first ? idOf(first) : null;
  loadDraft();
}

// ------------------------------------------------------------- the calendar

function openSheet() {
  const entry = current();
  if (!entry) return;
  state.sheetDate = parseStamp(entry.ts);
  state.calendarMonth = new Date(state.sheetDate);
  $('sheet-title').textContent = entry.title || firstLine(entry.body) || 'Untitled';
  $('dest-label').textContent = entry.unfiled ? 'Stays in' : 'Moves to';
  $('sheet-note').textContent = entry.unfiled
    ? 'This one is still in the inbox, which isn’t dated — retiming it rewrites it in place '
      + 'rather than filing it under a day.'
    : 'The date is the filename. Changing it rewrites both day files, so jnl and the Mac app '
      + 'see the entry under its new date.';
  renderCalendar();
  $('scrim').hidden = false;
}

function renderCalendar() {
  const month = state.calendarMonth;
  $('cal-month').textContent = `${MONTHS[month.getMonth()]} ${month.getFullYear()}`;
  $('time').value = clock(state.sheetDate);

  const weekdays = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
  $('cal-weekdays').innerHTML = weekdays
    .map((day) => `<span class="smallcaps">${day}</span>`).join('');

  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const lead = (first.getDay() + 6) % 7;             // weeks start on Monday
  const start = new Date(first);
  start.setDate(start.getDate() - lead);
  const marked = new Set(state.entries.map((e) => e.date));

  const grid = $('cal-grid');
  grid.innerHTML = '';
  for (let index = 0; index < 42; index += 1) {
    const day = new Date(start);
    day.setDate(day.getDate() + index);
    const cell = document.createElement('button');
    const classes = ['day'];
    if (day.getMonth() !== month.getMonth()) classes.push('out');
    if (dayOf(day) === dayOf(new Date())) classes.push('today');
    if (dayOf(day) === dayOf(state.sheetDate)) classes.push('on');
    if (marked.has(dayOf(day))) classes.push('marked');
    cell.className = classes.join(' ');
    cell.innerHTML = `<span>${day.getDate()}</span><span class="dot"></span>`;
    cell.onclick = () => {
      const chosen = new Date(day);
      chosen.setHours(state.sheetDate.getHours(), state.sheetDate.getMinutes(), 0, 0);
      state.sheetDate = chosen;
      state.calendarMonth = new Date(chosen);
      renderCalendar();
    };
    grid.appendChild(cell);
  }

  const entry = current();
  const date = dayOf(state.sheetDate).split('-');
  $('dest').textContent = entry && entry.unfiled
    ? 'inbox.md'
    : `journal/${date[0]}/${date[1]}/${date[2]}.md`;
}

function nudgeTime(minutes) {
  const next = new Date(state.sheetDate);
  next.setMinutes(next.getMinutes() + minutes);
  state.sheetDate = next;
  renderCalendar();
}

/// Accepts "9", "930", "9:30", "09:30"; anything else snaps back.
function commitTime() {
  const digits = $('time').value.replace(/\D/g, '');
  let hour = null;
  let minute = 0;
  if (digits.length <= 2) hour = Number(digits);
  else if (digits.length === 3) { hour = Number(digits[0]); minute = Number(digits.slice(1)); }
  else if (digits.length === 4) { hour = Number(digits.slice(0, 2)); minute = Number(digits.slice(2)); }
  if (hour !== null && hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59) {
    const next = new Date(state.sheetDate);
    next.setHours(hour, minute, 0, 0);
    state.sheetDate = next;
  }
  renderCalendar();
}

// -------------------------------------------------------------------- wiring

$('title').addEventListener('input', (event) => {
  state.title = event.target.value;
  edited();
});
$('query').addEventListener('input', (event) => {
  state.query = event.target.value;
  $('clear-query').hidden = !state.query;
  ensureSelection();
  render();
});
$('clear-query').onclick = () => {
  state.query = '';
  $('query').value = '';
  $('clear-query').hidden = true;
  ensureSelection();
  render();
};

$('new-entry').onclick = () => newEntry(false);
$('blank-new').onclick = () => newEntry(false);
$('new-draft').onclick = () => newEntry(true);
$('star-toggle').onclick = toggleStar;
$('file-toggle').onclick = toggleFiling;
$('a-file').onclick = toggleFiling;
$('s-status').onclick = toggleFiling;
$('dateline').onclick = openSheet;
$('s-written').onclick = openSheet;
$('a-copy').onclick = async () => {
  const entry = current();
  if (entry) await navigator.clipboard.writeText(rawOf(entry));
};

document.querySelectorAll('[data-column]').forEach((button) => {
  button.onclick = () => {
    const name = button.dataset.column;
    settings.columns[name] = !settings.columns[name];
    applySettings();
    renderMasthead();
  };
});

document.querySelectorAll('[data-step]').forEach((button) => {
  button.onclick = () => {
    const step = button.dataset.step;
    if (step === 'type-') settings.type = Math.max(13, settings.type - 0.5);
    if (step === 'type+') settings.type = Math.min(28, settings.type + 0.5);
    if (step === 'lead-') settings.lead = Math.max(0.10, settings.lead - 0.06);
    if (step === 'lead+') settings.lead = Math.min(1.20, settings.lead + 0.06);
    if (step === 'measure-') settings.measure = Math.max(520, settings.measure - 40);
    if (step === 'measure+') settings.measure = Math.min(1100, settings.measure + 40);
    applySettings();
    renderPanels();
  };
});

$('o-focus').onclick = () => { settings.focus = !settings.focus; applySettings(); renderPanels(); };
$('o-paper').onclick = () => {
  const order = ['auto', 'light', 'dark'];
  settings.paper = order[(order.indexOf(settings.paper) + 1) % order.length];
  applySettings();
  renderPanels();
};
$('o-folder').onclick = async () => {
  const chosen = await dialog.open({ directory: true, title: 'Choose a journal folder' });
  if (!chosen) return;
  const journal = await invoke('set_folder', { path: chosen });
  state.base = journal.base;
  state.entries = journal.entries;
  touch();
  state.selection = null;
  ensureSelection();
  render();
};

function renderThemes() {
  const grid = $('theme-grid');
  grid.innerHTML = '';
  $('themes-count').textContent = `${THEMES.length} looks · one journal`;

  for (const entry of THEMES) {
    const palette = isDark() ? entry.dark : entry.light;
    const card = document.createElement('button');
    card.className = `theme-card${entry.id === settings.theme ? ' on' : ''}`;
    const display = `'${entry.type.display.families.join("', '")}', Georgia, serif`;
    const label = `'${entry.type.label.families.join("', '")}', system-ui, sans-serif`;
    const prose = `'${entry.type.prose.families.join("', '")}', Georgia, serif`;
    const upper = entry.type.display.uppercase ? 'uppercase' : 'none';
    const filled = entry.chrome.filledButtons;

    card.innerHTML =
      `<div class="theme-preview" style="background:${palette.paper}">
         <div class="pv-mast">
           <span style="font-family:${display};font-size:13px;color:${palette.ink};text-transform:${upper}">wander</span>
           <span class="pv-meta" style="font-family:${label};color:${palette.accent}">journal</span>
         </div>
         ${entry.chrome.mastheadRule ? `<div class="pv-rule" style="background:${palette.ink};height:${Math.min(entry.chrome.mastheadRule, 3)}px"></div>` : '<div style="height:4px"></div>'}
         <div class="pv-title" style="font-family:${display};font-size:${Math.min(21, 15 * (entry.type.display.scale || 1))}px;color:${palette.ink};text-transform:${upper}">The long way round</div>
         <div class="pv-meta" style="font-family:${label};color:${palette.muted}">8 sep · 122 words</div>
         <div class="pv-body" style="font-family:${prose};color:${palette.prose};line-height:${entry.chrome.lineHeight}">Left before seven and took the long way round the reservoir, which adds twenty minutes.</div>
         <div class="pv-dots" style="margin-top:auto">
           <span class="pv-chip" style="font-family:${label};border-radius:${entry.chrome.corner}px;${filled ? `background:${palette.accent};color:${palette.paper}` : `color:${palette.accent};box-shadow:inset 0 0 0 1px ${palette.rule}`}">new entry</span>
           <i style="background:${palette.tint}"></i><i style="background:${palette.green}"></i>
         </div>
       </div>
       <div class="theme-caption">
         <div class="row"><span class="scheme-dot ${entry.scheme || 'both'}" title="Best in ${entry.scheme || 'either'}"></span>
           ${entry.name}${entry.id === settings.theme ? ' <span class="smallcaps" style="color:var(--accent)">In use</span>' : ''}</div>
         <p>${entry.note}</p>
       </div>`;

    card.onclick = () => {
      settings.theme = entry.id;
      theme = entry;
      // Type size and leading belong to the look.
      settings.type = entry.type.prose.size || 17.5;
      settings.lead = (entry.chrome.lineHeight || 1.42) - 1;
      applySettings();
      renderPanels();
      $('themes').hidden = true;
    };
    grid.appendChild(card);
  }
}

$('o-theme').onclick = () => { renderThemes(); $('themes').hidden = false; };
$('themes-done').onclick = () => { $('themes').hidden = true; };

$('cal-prev').onclick = () => {
  state.calendarMonth.setMonth(state.calendarMonth.getMonth() - 1);
  renderCalendar();
};
$('cal-next').onclick = () => {
  state.calendarMonth.setMonth(state.calendarMonth.getMonth() + 1);
  renderCalendar();
};
$('cal-today').onclick = () => {
  const now = new Date();
  now.setHours(state.sheetDate.getHours(), state.sheetDate.getMinutes(), 0, 0);
  state.sheetDate = now;
  state.calendarMonth = new Date(now);
  renderCalendar();
};
$('time-down').onclick = () => nudgeTime(-5);
$('time-up').onclick = () => nudgeTime(5);
$('time').addEventListener('change', commitTime);
$('time').addEventListener('blur', commitTime);

$('sheet-cancel').onclick = () => { $('scrim').hidden = true; };
$('sheet-move').onclick = async () => {
  $('scrim').hidden = true;
  await moveEntry(state.sheetDate);
};
$('confirm-cancel').onclick = () => { $('confirm').hidden = true; state.pendingDelete = null; };
$('confirm-delete').onclick = async () => {
  $('confirm').hidden = true;
  if (state.pendingDelete) await removeEntry(state.pendingDelete);
  state.pendingDelete = null;
};

document.addEventListener('keydown', (event) => {
  const meta = event.metaKey || event.ctrlKey;
  if (!meta) {
    if (event.key === 'Escape') {
      for (const id of ['scrim', 'themes', 'confirm']) $(id).hidden = true;
    }
    return;
  }
  const key = event.key.toLowerCase();
  const shortcuts = {
    n: () => newEntry(event.shiftKey),
    s: () => save(),
    f: () => { $('query').focus(); $('query').select(); },
    d: () => (event.shiftKey ? openSheet() : toggleStar()),
    j: () => toggleFiling(),
    1: () => { state.page = 'journal'; ensureSelection(); render(); },
    2: () => { state.page = 'inbox'; ensureSelection(); render(); },
    3: () => { state.page = 'starred'; ensureSelection(); render(); },
    t: () => { renderThemes(); $('themes').hidden = false; },
    '\\': () => {
      const name = event.shiftKey ? 'stats' : event.altKey ? 'options' : 'index';
      settings.columns[name] = !settings.columns[name];
      applySettings();
      renderMasthead();
    },
  };
  if (shortcuts[key]) {
    event.preventDefault();
    shortcuts[key]();
  }
});

// On Linux and Windows the window has no bar of its own: the masthead is the
// drag region (see data-tauri-drag-region in index.html) and carries the
// controls. macOS keeps its title bar, and hides them.
document.querySelectorAll('[data-window]').forEach((button) => {
  button.onclick = () => {
    const action = button.dataset.window;
    if (action === 'minimise') appWindow.minimize();
    if (action === 'maximise') appWindow.toggleMaximize();
    if (action === 'close') appWindow.close();
  };
});

invoke('undecorated').then((custom) => {
  if (custom) document.documentElement.dataset.chrome = 'custom';
}).catch(() => {});

window.matchMedia('(prefers-color-scheme: dark)')
  .addEventListener('change', () => applySettings());

window.addEventListener('beforeunload', () => { save(); });

loadThemes().then(() => {
  applySettings();
  refresh();
});

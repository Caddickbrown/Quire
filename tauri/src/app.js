/*
  wander — the front end.

  The same journal the macOS app opens: entries are plain markdown in the jnl
  layout, and the Rust side (src-tauri/src/journal.rs) does every read and write.
  This file is the interface — the index, the page, the two panels — and the
  live markdown styling in the editor.
*/

const invoke = window.__TAURI__.core.invoke;
const dialog = window.__TAURI__.dialog;

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
};

const settings = Object.assign({
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

const matches = (entry, query) => {
  const q = query.trim().toLowerCase();
  return !q || entry.raw.toLowerCase().includes(q);
};

function visibleEntries() {
  const found = state.entries.filter((e) => matches(e, state.query));
  if (state.page === 'inbox') return found.filter((e) => e.unfiled);
  if (state.page === 'starred') return found.filter((e) => e.starred);
  return found.filter((e) => !e.unfiled);
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

function streak() {
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

function renderProse(text, caret) {
  prose.innerHTML = text.split('\n').map(renderLine).join('');
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

/// Focus mode lights only the line the caret is on.
function markLiveLine() {
  if (!settings.focus) return;
  const selection = window.getSelection();
  Array.from(prose.children).forEach((line) => {
    line.classList.toggle('live', !!selection && line.contains(selection.anchorNode));
  });
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

function edited() {
  const entry = current();
  if (!entry) return;
  if (state.title === entry.title && state.body === entry.body) {
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
  if (!entry) return;
  if (state.title === entry.title && state.body === entry.body) return;
  try {
    const saved = await invoke('save', {
      ts: entry.ts,
      source: entry.source,
      title: state.title,
      body: state.body,
      starred: entry.starred,
    });
    await refresh(saved ? idOf(saved) : null);
    setSaveState(saved ? `Saved ${clock(new Date())}` : '');
  } catch (error) {
    setSaveState(`Not saved — ${error}`);
  }
}

async function refresh(selectId) {
  const journal = await invoke('load');
  state.base = journal.base;
  state.entries = journal.entries;
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
  state.selection = idOf(entry);
  loadDraft();
  render();
  prose.focus();
}

async function toggleStar() {
  const entry = current();
  if (!entry) return;
  await save();
  const saved = await invoke('save', {
    ts: entry.ts, source: entry.source,
    title: entry.title, body: entry.body, starred: !entry.starred,
  });
  await refresh(saved ? idOf(saved) : null);
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
  for (const page of ordered) {
    const button = document.createElement('button');
    button.className = `quiet${page === state.page ? ' on' : ''}`;
    // Only the inbox carries a count: it is a queue, and the number is the
    // thing waiting to be dealt with.
    const count = state.entries.filter((e) => e.unfiled).length;
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

function renderList() {
  const list = $('list');
  list.innerHTML = '';
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
    const head = document.createElement('div');
    head.className = `month${section.inbox ? ' inbox' : ''}`;
    head.innerHTML = `<span class="smallcaps">${section.title}</span>` +
                     `<span class="smallcaps">${section.entries.length}</span>`;
    list.appendChild(head);

    for (const entry of section.entries) {
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
      list.appendChild(row);
    }
  }
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

function applySettings() {
  const root = document.documentElement;
  root.style.setProperty('--type', `${settings.type}px`);
  root.style.setProperty('--lead', (1 + settings.lead).toFixed(2));
  root.style.setProperty('--measure', `${settings.measure}px`);
  root.dataset.theme = settings.paper;
  root.dataset.system = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
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
  if (entry) await navigator.clipboard.writeText(entry.raw);
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
  state.selection = null;
  ensureSelection();
  render();
};

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
    if (event.key === 'Escape' && !$('scrim').hidden) $('scrim').hidden = true;
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

window.matchMedia('(prefers-color-scheme: dark)')
  .addEventListener('change', () => applySettings());

window.addEventListener('beforeunload', () => { save(); });

refresh();

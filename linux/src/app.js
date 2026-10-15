/* Quire 0.6 — front end.
 * Disk access goes through the Rust commands (jnl format, atomic writes).
 * This file owns the UI: views, the editor and its macros, search grammar,
 * calendar, media, stats, settings, reminders, lock, backups and imports. */
'use strict';

const T = window.__TAURI__;
const invoke = (cmd, args) => T.core.invoke(cmd, args);
const fileSrc = p => T.core.convertFileSrc(p);
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const DEFAULT_UI = {
  theme: 'almanac', accent: 'theme', size: 'm', font: 'serif', autoDark: false,
  focusDims: true, typewriter: true, prompts: true, autoPromote: false, chime: true,
  goalOn: true, goal: 250, timerMins: 15,
  reminderOn: false, reminderTime: '21:00',
  lockOn: false, pinHash: '',
  sortNewest: true, grouped: true, welcomed: false, showCal: false, showTags: false,
  dateFormat: 'weekday', weekStart: 'mon', weekNumbers: false, highlightTags: true,
  assetSort: 'newest', assetGroup: 'none', ignoredTagGroups: [],
};
const ACCENTS = { theme: null, blue: '#1C7ED6', indigo: '#5C5CD6', purple: '#945CD6', pink: '#E0568C', red: '#E04A4A', orange: '#F08C38', teal: '#24AAA8', green: '#34A86C' };
const THEMES = [
  ['almanac', 'Almanac', '#F7F1E4', '#1F1A14', '#8E2F1C', 500],
  ['broadsheet', 'Broadsheet', '#FBFAF7', '#111111', '#111111', 650],
  ['linen', 'Linen', '#F3F4F1', '#1B1F23', '#1F5F8B', 500],
  ['cinema', 'Cinema', '#16130F', '#EDE6D8', '#E08A6B', 400],
  ['night', 'Night', '#121416', '#E6E6E3', '#7FB685', 400],
  ['marathon', 'Marathon', '#0B0C0C', '#ECEFE9', '#C8FF00', 800],
  ['marathon-day', 'Marathon Day', '#E6E8E3', '#0B0C0C', '#C8FF00', 800],
];
const DARK_THEMES = ['cinema', 'night', 'marathon'];
// Each light theme's dark partner when "go dark with the system" is on.
const DARK_PARTNER = { 'marathon-day': 'marathon' };
const TABS = [
  { id: 'today', label: 'Today', key: '1' },
  { id: 'inbox', label: 'Inbox', key: '2' },
  { id: 'journal', label: 'Journal', key: '3' },
  { id: 'starred', label: 'Starred', key: '4' },
  { id: 'lookback', label: 'Look back', key: '5' },
];

const S = {
  folder: '', isSample: false, splitTags: [], splitSource: 'none', backupDir: null, templates: [], searches: [], hasTransfer: false,
  entries: [], ui: { ...DEFAULT_UI },
  view: 'today', sel: null, mode: 'read', draft: null, focus: false, locked: false,
  query: '', tag: null, day: null, showAllTags: false, journal: 'all', jview: 'list',
  calMonth: null, year: new Date().getFullYear(), promptReroll: 0,
  timer: { left: null, running: false, handle: null },
  assets: null, assetUrls: new Map(), tagReview: null, tagPicks: {}, backups: null, sizes: null, statsExtra: null, tplEdit: null,
  narrow: false, showList: true, tagPick: null, lightbox: null, printDay: null, jnlDir: null, customChrome: false, chromeAvail: false,
  folderMissing: false, conflicts: [], stale: false, menuAsset: null,
  backupInterval: 'off', backupKeep: 10, lastBackup: null, backupRunning: false,
  dataSaver: false, dataSaved: 0, mediaTools: { ffmpeg: true, heif: true }, compress: null, compressReport: null,
};

/* ---------- helpers ---------- */
const pad = n => String(n).padStart(2, '0');
const nowTs = (d = new Date()) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
const today = () => nowTs().slice(0, 10);
const dateObj = iso => new Date(iso.slice(0, 10) + 'T12:00:00');
const isoOf = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const fmtDay = iso => dateObj(iso).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
const fmtLong = iso => dateObj(iso).toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
const fmtDayYear = iso => dateObj(iso).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' });
const fmtMonth = (y, m) => new Date(y, m, 1).toLocaleDateString('en-GB', { month: 'long', year: 'numeric' });
const words = s => (s.trim().match(/\S+/g) || []).length;
const short = n => n >= 10000 ? Math.round(n / 1000) + 'k' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n);
const bytes = n => n >= 1 << 30 ? (n / (1 << 30)).toFixed(2) + ' GB' : n >= 1 << 20 ? (n / (1 << 20)).toFixed(1) + ' MB' : n >= 1024 ? Math.round(n / 1024) + ' KB' : n + ' B';
/** Decimal units (1 KB = 1000 bytes), as Nook reports Data Saver figures. */
const decBytes = n => { n = Math.max(0, +n || 0); const f = (v, u) => `${v >= 100 ? Math.round(v) : v.toFixed(1).replace(/\.0$/, '')} ${u}`; return n >= 1e9 ? f(n / 1e9, 'GB') : n >= 1e6 ? f(n / 1e6, 'MB') : n >= 1e3 ? f(n / 1e3, 'KB') : `${n} bytes`; };
const plural = (n, one, many = one + 's') => `${n} ${n === 1 ? one : many}`;
const key = e => e ? `${e.file}\u0000${e.raw.trimEnd()}` : '';
const sameEntry = (a, b) => a && b && key(a) === key(b);
// jnl's header shape. HDR_LINE is the make_raw guard: body lines like this get a leading "\".
const HDR_LINE = /^\[[0-9]{4}[-–][0-9]{2}[-–][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]/;
const unguard = s => String(s || '').replace(/^\\(\[[0-9]{4}[-–][0-9]{2}[-–][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\])/gm, '$1');
const firstLine = s => { const l = unguard(s).split('\n').find(l => l.trim() && !/^[-*_\s]+$/.test(l)) || ''; return l.replace(/^#+\s*/, '').replace(/^\s*([-*+]\s+(\[[ xX]\]\s*)?|\d+[.)]\s+|>\s?)/, '').replace(/!\[[^\]]*\]\([^)]*\)/g, '[image]').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1').replace(/(\*\*|__|`)/g, '').trim().slice(0, 90); };
const dayFile = date => `journal/${date.slice(0, 4)}/${date.slice(5, 7)}/${date.slice(8, 10)}.md`;
const mediaRe = /!?\[([^\]]*)\]\(([^)\s]+)\)/g;
const mediaKind = p => { const x = (p.split('.').pop() || '').toLowerCase(); return /^(jpe?g|png|gif|webp|heic|heif|bmp|svg|avif)$/.test(x) ? 'image' : /^(mp4|mov|m4v|webm|mkv)$/.test(x) ? 'video' : /^(m4a|mp3|wav|aac|ogg|opus|flac|caf)$/.test(x) ? 'audio' : 'file'; };
/** Local links in an entry that resolve to a file under the journal root. */
const mediaOf = e => [...(e.body || '').matchAll(mediaRe)].map(m => m[2]).filter(p => resolveRel(e.file, p));

/** A link `p` in entry file `file` → root-relative path, as the back end resolves it:
 *  `../` or `./` → from the file's folder; `assets/…` → from the journal root;
 *  anything else → from the file's folder. Schemes, `#…`, `/…` and links that
 *  climb above the root resolve to nothing (null). */
function resolveRel(file, p) {
  p = String(p || '').trim();
  if (!p || /^[a-z][a-z0-9+.-]*:/i.test(p) || p.startsWith('#') || p.startsWith('/')) return null;
  try { p = decodeURIComponent(p); } catch { /* keep it as written */ }
  const parts = p.startsWith('assets/') ? [] : String(file || '').split('/').slice(0, -1);
  for (const seg of p.split('/')) {
    if (seg === '..') { if (!parts.length) return null; parts.pop(); }
    else if (seg && seg !== '.') parts.push(seg);
  }
  return parts.length ? parts.join('/') : null;
}

/** Mirror of make_raw in journal.rs — must stay byte-identical (see api.md, "format rules"). */
function makeRaw(ts, title, starred, body) {
  let suffix = String(title || '').split(/\s+/).filter(Boolean).join(' ');
  if (starred) suffix = suffix ? suffix + ' *' : '*';
  body = String(body || '').trim().split('\n').map(l => HDR_LINE.test(l) ? '\\' + l : l).join('\n');
  if (suffix && body) return `[${ts}] ${suffix}\n${body}`;
  if (suffix) return `[${ts}] ${suffix}`;
  return `[${ts}]\n${body}`;
}

/* dates in the user's chosen format (Settings › Display) */
const WD = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const MO = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
function fmtDate(iso, fmt = S.ui.dateFormat) {
  const d = dateObj(iso), y = d.getFullYear();
  if (fmt === 'iso') return iso.slice(0, 10);
  if (fmt === 'medium') return `${d.getDate()} ${MO[d.getMonth()].slice(0, 3)} ${y}`;
  if (fmt === 'long') return `${WD[d.getDay()]}, ${d.getDate()} ${MO[d.getMonth()]} ${y}`;
  return `${WD[d.getDay()].slice(0, 3)}, ${d.getDate()} ${MO[d.getMonth()].slice(0, 3)}${y !== new Date().getFullYear() ? ' ' + y : ''}`;
}
function isoWeek(d) {
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7));
  return Math.ceil(((t - Date.UTC(t.getUTCFullYear(), 0, 1)) / 864e5 + 1) / 7);
}
/** Prompt of the day: the same one all day, ↻ steps through the deck. */
function promptText() {
  const P = window.QUIRE_PROMPTS || ['Begin writing'];
  const day = Math.floor((Date.now() - new Date().getTimezoneOffset() * 6e4) / 864e5);
  return P[(((day + S.promptReroll) % P.length) + P.length) % P.length];
}
/** Consecutive written days (drafts count) ending yesterday. */
function streakToYesterday() {
  const days = new Set(S.entries.map(e => e.date));
  const t = new Date(); t.setDate(t.getDate() - 1);
  let n = 0; while (days.has(isoOf(t))) { n++; t.setDate(t.getDate() - 1); }
  return n;
}

function toast(msg, kind = '') {
  const t = $('#toast');
  t.textContent = msg; t.classList.toggle('error', kind === 'error'); t.classList.add('show');
  clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('show'), kind === 'error' ? 4200 : 2600);
}
function fail(err) { console.error(err); toast(String(err?.message || err), 'error'); }

/** A moment worth marking: filing, reaching the word goal. Marathon shows a
 *  //BANNER in the signal colour with registration ticks (after the game's
 *  run-complete card); every other theme just toasts. */
function stamp(code, msg) {
  if (!String(document.documentElement.dataset.theme || '').startsWith('marathon')) { toast(msg); return; }
  let b = $('#stamp');
  if (!b) { b = document.createElement('div'); b.id = 'stamp'; b.setAttribute('role', 'status'); b.setAttribute('aria-live', 'polite'); document.body.appendChild(b); }
  b.innerHTML = `<i class="tk tl"></i><i class="tk tr"></i><i class="tk bl"></i><i class="tk br"></i><span class="st-code">//${esc(code)}</span><span class="st-msg">${esc(msg)}</span>`;
  b.classList.remove('show'); void b.offsetWidth; b.classList.add('show');
  clearTimeout(stamp.h); stamp.h = setTimeout(() => b.classList.remove('show'), 2200);
}
function checkGoal() {
  if (!S.ui.goalOn || !S.ui.goal) return;
  const day = today();
  if (S.goalStamped === day || todaysWords() < S.ui.goal) return;
  S.goalStamped = day;
  stamp('GOAL_COMPLETE', `${S.ui.goal} words today`);
}

/* ---------- data ---------- */
async function load(reselect) {
  const snap = await invoke('load');
  Object.assign(S, {
    folder: snap.folder, isSample: snap.is_sample, splitTags: snap.split_tags || [], splitSource: snap.split_tags_source, backupDir: snap.backup_dir,
    templates: snap.templates || [], searches: snap.searches || [], hasTransfer: snap.has_transfer, entries: snap.entries || [], jnlDir: snap.jnl_dir || null,
    folderMissing: !!snap.folder_missing, conflicts: snap.conflicts || [],
    backupInterval: snap.backup_interval || 'off', backupKeep: snap.backup_keep || 10, lastBackup: snap.last_backup || null, backupRunning: !!snap.backup_running,
    dataSaver: !!snap.data_saver, dataSaved: snap.data_saved || 0, mediaTools: snap.media_tools || { ffmpeg: false, heif: false },
  });
  S.ui = { ...DEFAULT_UI, ...(snap.ui && typeof snap.ui === 'object' ? snap.ui : {}) };
  if (!Array.isArray(S.ui.ignoredTagGroups)) S.ui.ignoredTagGroups = [];
  S.statsExtra = null; S.sizes = null;
  if (reselect) S.sel = S.entries.find(e => sameEntry(e, reselect)) || S.entries.find(e => e.ts === reselect.ts && e.file === reselect.file) || null;
  else if (S.sel) S.sel = S.entries.find(e => sameEntry(e, S.sel)) || null;
  // The composer's reference must follow the reload too, or its index/raw go stale.
  if (S.draft?.ref) { const r = S.draft.ref; S.draft.ref = S.entries.find(e => sameEntry(e, r)) || S.entries.find(e => e.file === r.file && e.ts === r.ts) || r; }
  S.assets = null;
  if (snap.migration) toast(`inbox.md folded into inbox/: ${plural(snap.migration.moved, 'draft')} moved${snap.migration.skipped ? `, ${snap.migration.skipped} already there` : ''}. The original is in ${snap.migration.backup}`);
  if (snap.migration_error) fail(snap.migration_error);
  applyUi();
}
const saveUi = () => invoke('save_ui', { ui: S.ui }).catch(fail);
const inbox = () => S.entries.filter(e => e.source === 'inbox').sort((a, b) => b.ts.localeCompare(a.ts));
const filed = () => S.entries.filter(e => e.source !== 'inbox');
const byNewest = arr => [...arr].sort((a, b) => b.ts.localeCompare(a.ts));
const sorted = arr => S.ui.sortNewest ? byNewest(arr) : [...arr].sort((a, b) => a.ts.localeCompare(b.ts));

function applyUi() {
  const r = document.documentElement;
  let theme = S.ui.theme;
  if (S.ui.autoDark && window.matchMedia('(prefers-color-scheme: dark)').matches && !DARK_THEMES.includes(theme)) theme = DARK_PARTNER[theme] || 'cinema';
  r.dataset.theme = theme; r.dataset.size = S.ui.size; r.dataset.font = S.ui.font; r.dataset.tags = S.ui.highlightTags ? 'on' : 'off';
  const acc = ACCENTS[S.ui.accent];
  if (acc) { r.style.setProperty('--accent', acc); r.style.setProperty('--accent-ink', acc); r.style.setProperty('--on-accent', '#FFFFFF'); r.style.setProperty('--accent-soft', acc + '26'); }
  else ['--accent', '--accent-ink', '--on-accent', '--accent-soft'].forEach(p => r.style.removeProperty(p));
}

/* ---------- search grammar (Nook's SearchQuery) ----------
   words · "exact phrase" · tag:x or @x · before:YYYY[-MM[-DD]] · after:… · has:image|video|audio|media · is:starred */
function parseQuery(q) {
  const out = { terms: [], phrases: [], tags: [], before: null, after: null, has: [], starred: false };
  const re = /"([^"]+)"|(\S+)/g;
  let m;
  while ((m = re.exec(q))) {
    if (m[1]) { out.phrases.push(m[1].toLowerCase()); continue; }
    const t = m[2], l = t.toLowerCase();
    if (l.startsWith('tag:')) { const t = l.slice(4).replace(/^@/, ''); if (t) out.tags.push('@' + t); }
    else if (l.startsWith('@') && l.length > 1) out.tags.push(l);
    else if (l.startsWith('before:') && /^\d{4}(-\d{2}){0,2}$/.test(l.slice(7))) out.before = l.slice(7);
    else if (l.startsWith('after:') && /^\d{4}(-\d{2}){0,2}$/.test(l.slice(6))) out.after = l.slice(6);
    else if (l.startsWith('has:')) { const h = l.slice(4); if (/^(image|video|audio|media)$/.test(h)) out.has.push(h); }
    else if (l === 'is:starred') out.starred = true;
    else out.terms.push(l);
  }
  return out;
}
function matchesQuery(e, q) {
  if (q.starred && !e.starred) return false;
  if (q.before && !(e.date < q.before)) return false;
  if (q.after && !(e.date > q.after || e.date.startsWith(q.after))) return false;
  if (q.tags.length) { const tl = e.tags.map(t => t.toLowerCase()); if (!q.tags.every(t => tl.includes(t))) return false; }
  if (q.has.length) { const kinds = mediaOf(e).map(p => mediaKind(resolveRel(e.file, p))); if (!q.has.every(h => h === 'media' ? kinds.some(k => k !== 'file') : kinds.includes(h))) return false; }
  if (q.terms.length || q.phrases.length) {
    const hay = (e.title + '\n' + e.body).toLowerCase();
    if (!q.terms.every(t => hay.includes(t))) return false;
    if (!q.phrases.every(p => hay.includes(p))) return false;
  }
  return true;
}
function journalList() {
  let list = filed();
  if (S.journal === 'main') list = list.filter(e => e.source === 'journal');
  else if (S.journal !== 'all') list = list.filter(e => e.split === S.journal);
  const q = S.query.trim();
  // A day picked on the calendar, or a search, also shows inbox drafts, so a draft-only day isn't empty and a search finds everything.
  if ((S.day || q) && S.journal === 'all') list = [...list, ...inbox().filter(e => !S.day || e.date === S.day)];
  if (S.tag) list = list.filter(e => e.tags.includes(S.tag));
  if (S.day) list = list.filter(e => e.date === S.day);
  if (q) { const pq = parseQuery(q); list = list.filter(e => matchesQuery(e, pq)); }
  return sorted(list);
}
function countTags(list) {
  const m = new Map();
  list.forEach(e => e.tags.forEach(t => m.set(t, (m.get(t) || 0) + 1)));
  return [...m.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

/* ---------- shell ---------- */
function renderTabs() {
  const inboxN = inbox().length;
  $('#tabs').innerHTML = TABS.map(t => {
    let extra = '';
    if (t.id === 'inbox' && inboxN) extra = `<span class="badge">${inboxN}</span>`;
    return `<button class="tab" data-action="view" data-view="${t.id}" ${S.view === t.id ? 'aria-current="page"' : ''} title="Ctrl+${t.key}">${t.label}${extra}</button>`;
  }).join('');
  // Marathon's counter strip (hidden in other themes): filed entries, drafts, words.
  const c = $('#counters');
  if (c) {
    const f = filed(), words = f.reduce((n, e) => n + (e.words || 0), 0);
    const n = v => v.toLocaleString('en-GB');
    c.innerHTML = `<span class="ctr c-entries" title="Filed entries"><svg viewBox="0 0 16 16" aria-hidden="true"><rect x="2" y="2" width="12" height="12"/><rect x="5" y="5" width="6" height="6"/></svg>${n(f.length)}</span>`
      + `<span class="ctr c-drafts" title="Drafts in the inbox"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M2 3h12M2 6.5h12M2 10h12M2 13.5h8"/></svg>${n(inboxN)}</span>`
      + `<span class="ctr c-words" title="Words filed"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5l5.6 3.2v6.6L8 14.5l-5.6-3.2V4.7z"/><path d="M8 5v6M5.5 6.5L8 5l2.5 1.5"/></svg>${n(words)}</span>`;
  }
}

/** The unreachable-folder banner sits above every view. */
function renderMissing() {
  const mb = $('#missing');
  if (mb) {
    mb.hidden = !S.folderMissing;
    const name = (S.folder || '').split('/').filter(Boolean).pop() || S.folder;
    mb.innerHTML = S.folderMissing ? `<span>Quire can’t reach “${esc(name)}”. Nothing is being saved until you find the folder again.</span><span class="spacer"></span><button class="btn primary" data-action="locate-folder">Locate folder…</button><button class="btn" data-action="use-sample">Use sample</button>` : '';
  }
  const nb = $('#topbar [data-action="new"]'); if (nb) nb.disabled = S.folderMissing;
}

function render() {
  S.narrow = window.innerWidth < 860;
  S.stale = false;
  renderTabs();
  renderMissing();
  $('#cog').toggleAttribute('aria-current', S.view === 'settings');
  if (S.view === 'settings') $('#cog').setAttribute('aria-current', 'page');
  const app = $('#app');
  app.classList.toggle('focus', S.focus);
  app.classList.toggle('narrow', S.narrow);
  app.classList.toggle('show-list', S.narrow && (S.showList || (!S.sel && S.mode !== 'write')));
  app.classList.toggle('locked', S.locked);
  const body = $('#body');
  if (S.locked) body.innerHTML = renderLock();
  else if (S.view === 'lookback') body.innerHTML = renderLookBack();
  else if (S.view === 'settings') {
    // Keep the reader's place: actions in Settings re-render the whole page.
    const prev = $('.settings main'), top = prev ? prev.scrollTop : null;
    body.innerHTML = renderSettings();
    const m = $('.settings main'); if (m && top != null) m.scrollTop = top;
  }
  else body.innerHTML = renderList() + renderPane();
  afterRender();
}

function rowHtml(e, opts = {}) {
  const sel = S.mode === 'write' && S.draft ? (S.draft.ref && sameEntry(S.draft.ref, e)) : sameEntry(S.sel, e);
  const t = e.title || firstLine(e.body);
  const when = opts.day ? `${fmtDay(e.date)} · ${e.time}` : e.time;
  const kinds = [...new Set(mediaOf(e).map(mediaKind))];
  const badges = kinds.map(k => `<span class="mbadge" title="${k}">${icon[k] || icon.file}</span>`).join('');
  const right = [
    e.source === 'split' ? `@${esc(e.split)}` : '',
    e.tags.slice(0, 2).map(t => `<span class="rtag">${esc(t)}</span>`).join(''),
    badges,
    e.starred ? '<span class="star">★</span>' : '',
    opts.writing && sel ? '<span class="star">writing</span>' : '',
  ].filter(Boolean).join(' ');
  return `<button class="row ${sel ? 'sel' : ''}" data-action="open" data-file="${esc(e.file)}" data-index="${e.index}" data-ctx="entry">
    <span class="meta"><span class="mono">${when}</span><span class="meta-r">${right}</span></span>
    <span class="t ${t ? '' : 'untitled'}">${esc(t || 'Untitled')}</span>
    ${opts.excerpt && e.title && e.body ? `<span class="ex">${esc(firstLine(e.body))}</span>` : ''}
  </button>`;
}

function groupByDay(list, opts) {
  if (!S.ui.grouped) return `<div class="rows">${list.map(e => rowHtml(e, { ...opts, day: true })).join('')}</div>`;
  let out = '', cur = null;
  for (const e of list) {
    if (e.date !== cur) {
      if (cur !== null) out += '</div>';
      cur = e.date;
      const label = e.date === today() ? `Today · ${fmtDate(e.date)}` : fmtDate(e.date);
      out += `<div class="group-label"><button class="daylink" data-action="day" data-day="${e.date}" title="Show just this day">${label}</button></div><div class="rows">`;
    }
    out += rowHtml(e, opts);
  }
  return out + (cur !== null ? '</div>' : '');
}

function searchBox(id, ph) {
  return `<div class="search"><input id="${id}" data-input="${id === 'search' ? 'query' : 'gosearch'}" value="${id === 'search' ? esc(S.query) : ''}" placeholder="${esc(ph)}" autocomplete="off" spellcheck="false"></div>`;
}

function renderList() {
  let head = '', listHtml = '';
  if (S.view === 'today') {
    const drafts = inbox();
    const todays = sorted(filed().filter(e => e.date === today()));
    head = searchBox('gosearch', 'Search everything · Ctrl+Shift+F');
    listHtml += `<div class="group-label"><span>Inbox · ${drafts.length} draft${drafts.length === 1 ? '' : 's'}</span></div><div class="rows">${drafts.map(e => rowHtml(e, { day: true, writing: true })).join('') || '<div class="empty-note">Inbox is empty.</div>'}</div>`;
    listHtml += `<div class="group-label"><span>Today · ${fmtDate(today())}</span></div><div class="rows">${todays.map(e => rowHtml(e, { excerpt: true })).join('') || '<div class="empty-note">Nothing filed today yet.</div>'}</div>`;
  } else if (S.view === 'inbox') {
    const drafts = S.ui.sortNewest ? inbox() : inbox().reverse();
    head = `<div class="list-tools"><span class="group-label" style="padding:0">Inbox · ${drafts.length}</span><span style="display:flex;gap:12px">${sortBtn()}${drafts.length && S.mode !== 'write' ? '<button class="btn ghost" data-action="file-all">File all</button>' : ''}</span></div>`;
    listHtml = S.ui.grouped ? (groupByDay(drafts, { writing: true, excerpt: true }) || '<div class="empty-note">Inbox zero. Ctrl+N to start a draft.</div>') : `<div class="rows">${drafts.map(e => rowHtml(e, { day: true, writing: true, excerpt: true })).join('') || '<div class="empty-note">Inbox zero. Ctrl+N to start a draft.</div>'}</div>`;
  } else if (S.view === 'starred') {
    const list = sorted(S.entries.filter(e => e.starred));
    head = `<div class="list-tools"><span class="group-label" style="padding:0">Starred · ${list.length}</span><span style="display:flex;gap:12px">${sortBtn()}<button class="btn ghost" data-action="random">Random</button></span></div>`;
    listHtml = groupByDay(list, { excerpt: true }) || '<div class="empty-note">Nothing starred yet. Star an entry from its toolbar.</div>';
  } else if (S.view === 'journal') {
    const splits = [...new Set(S.entries.filter(e => e.split).map(e => e.split))];
    const tagCounts = countTags(filed());
    const shown = S.showAllTags ? tagCounts : tagCounts.slice(0, 8);
    head = `<div class="list-tools">
        <select class="picker" data-input="journal" aria-label="Journal">
          <option value="all" ${S.journal === 'all' ? 'selected' : ''}>All journals</option>
          <option value="main" ${S.journal === 'main' ? 'selected' : ''}>Main journal</option>
          ${splits.map(s => `<option value="${esc(s)}" ${S.journal === s ? 'selected' : ''}>@${esc(s)} (split)</option>`).join('')}
        </select>
        <div class="seg" role="group" aria-label="View">
          <button data-action="jview" data-v="list" aria-pressed="${S.jview === 'list'}">List</button>
          <button data-action="jview" data-v="stream" aria-pressed="${S.jview === 'stream'}">Stream</button>
          <button data-action="jview" data-v="media" aria-pressed="${S.jview === 'media'}">Media</button>
        </div>
      </div>
      <div class="search-row">${searchBox('search', 'Search · "phrase" · tag: · before: · after: · has: · is:starred')}${S.query.trim() && !S.searches.some(s => s.query === S.query.trim()) ? '<button class="btn ghost" data-action="pin-search" title="Save this search">Pin</button>' : ''}</div>
      ${S.searches.length ? `<div class="saved">${S.searches.map((s, i) => `<button class="chip ${S.query.trim() === s.query ? 'on' : ''}" data-action="saved" data-i="${i}" title="${esc(s.query)} · right-click to remove" data-ctx="saved">${esc(s.name)}</button>`).join('')}</div>` : ''}
      <div class="group-label"><button class="daylink" data-action="toggle-ui" data-k="showCal">${S.ui.showCal ? '▾' : '▸'} Calendar</button><span style="display:flex;gap:12px;letter-spacing:0;text-transform:none;font-weight:500"><button class="daylink" data-action="day" data-day="${today()}">Today</button><button class="daylink" data-action="day" data-day="${isoOf(new Date(Date.now() - 864e5))}">Yesterday</button></span></div>
      ${S.ui.showCal ? renderCalendar() : ''}
      ${tagCounts.length ? `<div class="group-label"><button class="daylink" data-action="toggle-ui" data-k="showTags">${S.ui.showTags ? '▾' : '▸'} Tags · ${tagCounts.length}</button>${S.ui.showTags ? '<button class="btn ghost" style="min-height:22px;padding:0;font-size:12px" data-action="random-tag">Random</button>' : ''}</div>${S.ui.showTags ? `<div class="chips">
        ${shown.map(([t, n]) => `<button class="chip" data-action="tag" data-tag="${esc(t)}" aria-pressed="${S.tag === t}">${esc(t)}<small>${n}</small></button>`).join('')}
        ${tagCounts.length > 8 ? `<button class="chip more" data-action="alltags">${S.showAllTags ? 'Fewer' : `+${tagCounts.length - 8} more`}</button>` : ''}
      </div>` : ''}` : ''}`;
    const list = journalList();
    const label = [S.day && fmtDate(S.day), S.tag, S.query.trim() && `“${S.query.trim()}”`].filter(Boolean).join(' · ');
    head += `<div class="group-label"><span><span style="text-transform:none;letter-spacing:0">${label ? esc(label) + ' · ' : ''}</span>${list.length} entr${list.length === 1 ? 'y' : 'ies'}</span><span style="display:flex;gap:12px">${sortBtn()}${label ? '<button class="btn ghost" style="min-height:22px;padding:0;font-size:12px" data-action="clearfilter">Clear</button>' : ''}</span></div>`;
    listHtml = groupByDay(list.slice(0, 500), { excerpt: true }) || '<div class="empty-note">No entries match.</div>';
  }
  return `<section class="list-pane" aria-label="Entries">${head}${listHtml}</section>`;
}
const sortBtn = () => `<button class="btn ghost" style="min-height:22px;padding:0;font-size:12px" data-action="sort" title="Sort">${S.ui.sortNewest ? 'Newest first' : 'Oldest first'}</button>`;

/* ---------- calendar ---------- */
function renderCalendar() {
  const now = new Date();
  const [y, m] = S.calMonth || [now.getFullYear(), now.getMonth()];
  const start = { mon: 1, sun: 0, sat: 6 }[S.ui.weekStart] ?? 1;
  const first = new Date(y, m, 1), off = (first.getDay() - start + 7) % 7, days = new Date(y, m + 1, 0).getDate();
  const filedDays = new Set(filed().map(e => e.date)), draftDays = new Set(inbox().map(e => e.date));
  const media = new Set(filed().filter(e => mediaOf(e).length).map(e => e.date));
  const cells = Array(off).fill('<span></span>');
  for (let d = 1; d <= days; d++) {
    const iso = `${y}-${pad(m + 1)}-${pad(d)}`;
    const cls = [filedDays.has(iso) ? 'has' : draftDays.has(iso) ? 'draft' : '', iso === today() ? 'today' : '', S.day === iso ? 'on' : '', media.has(iso) ? 'media' : ''].filter(Boolean).join(' ');
    cells.push(`<button class="cal-d ${cls}" data-action="day" data-day="${iso}" ${!filedDays.has(iso) && !draftDays.has(iso) ? 'disabled' : ''}>${d}</button>`);
  }
  while (cells.length % 7) cells.push('<span></span>');
  const wk = !!S.ui.weekNumbers;
  const head = (wk ? '<span class="cal-wk" aria-hidden="true"></span>' : '') + Array.from({ length: 7 }, (_, i) => `<span>${'SMTWTFS'[(start + i) % 7]}</span>`).join('');
  let grid = '';
  for (let r = 0; r < cells.length; r += 7) {
    if (wk) { const n = isoWeek(new Date(y, m, 1 - off + r + 3)); grid += `<span class="cal-wk" title="Week ${n}">${n}</span>`; }
    grid += cells.slice(r, r + 7).join('');
  }
  return `<div class="cal">
    <div class="cal-h"><button class="btn ghost" data-action="cal" data-d="-1" aria-label="Previous month">‹</button><button class="btn ghost" data-action="cal" data-d="0" style="color:var(--ink)">${fmtMonth(y, m)}</button><button class="btn ghost" data-action="cal" data-d="1" aria-label="Next month">›</button></div>
    <div class="cal-g${wk ? ' wk' : ''}">${head}${grid}</div></div>`;
}

/* ---------- entry pane ---------- */
function renderPane() {
  if (S.view === 'journal' && S.jview === 'stream' && S.mode !== 'write') return renderStream();
  if (S.view === 'journal' && S.jview === 'media' && S.mode !== 'write') return renderMedia();
  if (S.mode === 'write' && S.draft) return renderWrite();
  if (S.sel) return renderRead(S.sel);
  if (S.printDay) return renderDayPage(S.printDay);
  if (S.view === 'journal') { const d = S.day || journalList()[0]?.date; if (d) return renderDayPage(d); }
  return renderHome();
}

const icon = {
  trash: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="square"><path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6"/></svg>`,
  star: on => `<svg width="17" height="17" viewBox="0 0 24 24" fill="${on ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><path d="M12 4l2.4 5 5.4.6-4 3.7 1.1 5.3L12 16l-4.9 2.6 1.1-5.3-4-3.7 5.4-.6z"/></svg>`,
  pen: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M4 20l4-1 11-11-3-3L5 16z"/><path d="M14 6l3 3"/></svg>`,
  clock: `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="13" r="7"/><path d="M12 9v4l2 2M10 3h4"/></svg>`,
  more: `<svg width="18" height="18" viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="2"/><circle cx="12" cy="12" r="2"/><circle cx="19" cy="12" r="2"/></svg>`,
  image: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 16l5-5 4 4 3-3 6 6"/></svg>`,
  video: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="6" width="13" height="12" rx="2"/><path d="M16 10l5-3v10l-5-3z"/></svg>`,
  audio: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>`,
  file: `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M14 3H6v18h12V7z"/><path d="M14 3v4h4"/></svg>`,
  lock: `<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/></svg>`,
};

function dateButton(ts) {
  return `<button class="btn" data-action="retime" aria-label="Change date and time">${fmtDayYear(ts)} · ${ts.slice(11, 16)} <span style="color:var(--muted);display:flex">${icon.pen}</span></button>`;
}
const moreBtn = (ctx) => `<button class="btn" data-action="menu" data-menu="${ctx}" aria-label="More" aria-haspopup="menu">${icon.more}</button>`;

function renderRead(e) {
  const isDraft = e.source === 'inbox';
  return `<section class="entry-pane" aria-label="Entry">
    <div class="toolbar">
      ${S.narrow ? '<button class="btn" data-action="show-list">‹ List</button>' : ''}
      ${dateButton(e.ts)}
      ${isDraft ? '<span class="pill">Draft</span>' : e.source === 'split' ? `<span class="pill">@${esc(e.split)} journal</span>` : ''}
      <span class="spacer"></span>
      <button class="btn ${e.starred ? 'star-on' : ''}" data-action="star" aria-label="${e.starred ? 'Unstar' : 'Star'}" title="Star">${icon.star(e.starred)}</button>
      ${moreBtn('read')}
      <button class="btn" data-action="edit" title="Edit (↵)">${icon.pen} Edit</button>
      ${isDraft ? `<button class="btn primary" data-action="file" title="Ctrl+J">File to ${fmtDay(e.date)} <span class="k">Ctrl+J</span></button>` : ''}
    </div>
    <div class="page"><article class="sheet print-sheet">
      <span class="print-only mono" style="font-size:12px;color:var(--muted)">${fmtLong(e.date)} · ${e.time}</span>
      ${e.title ? `<h1>${esc(e.title)}</h1><div class="rule"></div>` : ''}
      <div class="prose" data-file="${esc(e.file)}" data-index="${e.index}">${renderProse(e.body, e.file)}</div>
    </article></div>
    <div class="statusbar"><span class="mono">${e.words} words · ${isDraft ? 'draft' : 'filed'}</span><span class="spacer"></span><span class="mono">${esc(e.file)}</span></div>
  </section>`;
}

/** Markdown-ish rendering: paragraphs, headings, bold/italic/code, links,
 *  @tags, task checkboxes (clickable), and media from assets/. */
function renderProse(body, file) {
  if (!body.trim()) return '<p style="color:var(--muted);font-style:italic">(no text)</p>';
  body = unguard(body); // "\[2026-…]" is stored escaped so jnl doesn't split there; show it as written

  let taskIx = 0;
  const taskRe = /^\s*[-*+]\s+\[[ xX]\]\s/;
  const isListBlock = lines => lines.every(l => taskRe.test(l) || /^\s*[-*+]\s+/.test(l) || /^\s*\d+[.)]\s+/.test(l));
  // Code spans and link URLs are lifted out before the emphasis/tag passes so their contents are left alone.
  const inline = s => {
    const keep = [];
    const hold = html => { keep.push(html); return `\u0000${keep.length - 1}\u0000`; };
    const out = esc(s)
      .replace(/`([^`]+)`/g, (x, c) => hold(`<code>${c}</code>`))
      .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g, (x, t, u) => hold(`<a href="${u}" data-action="open-url">`) + t + hold('</a>'))
      .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
      .replace(/__([^_]+)__/g, '<i>$1</i>')
      .replace(/(^|[\s(])_([^_]+)_(?=[\s).,!?]|$)/g, '$1<i>$2</i>')
      .replace(/(^|[\s(])\*([^*\s][^*]*)\*(?=[\s).,!?]|$)/g, '$1<i>$2</i>')
      .replace(/@[a-zA-Z][a-zA-Z0-9_-]*/g, m => `<button class="tag taglink" data-action="tag-jump" data-tag="${m}">${m}</button>`);
    return out.replace(/\u0000(\d+)\u0000/g, (x, i) => keep[+i]);
  };
  const media = (alt, p) => {
    if (/^https?:/i.test(p)) return `<a href="${esc(p)}" data-action="open-url">${esc(alt || p)}</a>`;
    const rel = resolveRel(file, p);
    if (!rel) return `<span class="imgref">${esc(alt || p)}</span>`;
    const kind = mediaKind(rel), name = rel.split('/').pop();
    const url = S.assetUrls.get(rel);
    if (kind === 'image') return url ? `<span class="figure"><img class="media" src="${url}" alt="${esc(alt)}" data-action="lightbox" data-rel="${esc(rel)}"><span class="caption mono">${esc(alt || name)}</span></span>` : `<span class="imgref" data-asset="${esc(rel)}">[image · ${esc(name)}]</span>`;
    if (kind === 'video') return url ? `<video class="media" controls src="${url}"></video>` : `<span class="imgref" data-asset="${esc(rel)}">[video · ${esc(name)}]</span>`;
    if (kind === 'audio') return url ? `<audio controls src="${url}"></audio>` : `<span class="imgref" data-asset="${esc(rel)}">[audio · ${esc(name)}]</span>`;
    return `<button class="imgref" data-action="open-asset" data-rel="${esc(rel)}">${icon.file} ${esc(alt || name)}</button>`;
  };
  // Inline markup plus media embeds and local-file links; used by paragraphs and list items alike.
  const richText = text => {
    const re = /!\[([^\]]*)\]\(([^)\s]+)\)/g;
    let last = 0, out = '', m;
    while ((m = re.exec(text))) { out += inline(text.slice(last, m.index)).replace(/\n/g, '<br>'); out += media(m[1], m[2]); last = m.index + m[0].length; }
    out += inline(text.slice(last)).replace(/\n/g, '<br>');
    return out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (x, a, p) => /^https?:/i.test(p) ? x : media(a, p));
  };
  return body.split(/\n\s*\n/).map(block => {
    const lines = block.split('\n');
    const isList = isListBlock(lines);
    // Keep the checkbox numbering in step with toggleTask(), which counts every task-shaped line in the body.
    if (!isList) taskIx += lines.filter(l => taskRe.test(l)).length;
    if (/^#{1,6}\s/.test(block)) {
      const [h, ...rest] = lines;
      return `<h3>${inline(h.replace(/^#+\s*/, ''))}</h3>${rest.length ? `<p>${richText(rest.join('\n'))}</p>` : ''}`;
    }
    if (isList) {
      const ordered = /^\s*\d+[.)]\s+/.test(lines[0]);
      const items = lines.map(l => {
        const task = l.match(/^\s*[-*+]\s+\[([ xX])\]\s(.*)$/);
        if (task) { const ix = taskIx++; return `<li class="task"><label><input type="checkbox" data-action="task" data-ix="${ix}" ${task[1] !== ' ' ? 'checked' : ''}> <span>${richText(task[2])}</span></label></li>`; }
        return `<li>${richText(l.replace(/^\s*([-*+]|\d+[.)])\s+/, ''))}</li>`;
      }).join('');
      return ordered ? `<ol>${items}</ol>` : `<ul>${items}</ul>`;
    }
    if (/^>\s?/.test(block)) return `<blockquote>${richText(lines.map(l => l.replace(/^>\s?/, '')).join('\n'))}</blockquote>`;
    return `<p>${richText(block)}</p>`;
  }).join('');
}

function renderHome() {
  const md = today().slice(5);
  const otd = byNewest(filed().filter(e => e.date.slice(5) === md && e.date < today()));
  const drafts = inbox();
  const prompt = promptText();
  const todayN = filed().filter(e => e.date === today()).length;
  const wroteToday = S.entries.some(e => e.date === today()); // today's inbox drafts count as written
  const remind = S.ui.reminderOn && !wroteToday && /^\d{2}:\d{2}/.test(S.ui.reminderTime || '') && nowTs().slice(11, 16) >= S.ui.reminderTime;
  return `<section class="home"><div class="inner">
    <span class="eyebrow">${fmtLong(today())}</span>
    <h1>${S.view === 'inbox' ? 'Inbox' : S.view === 'journal' ? 'Journal' : S.view === 'starred' ? 'Starred' : 'Today'}</h1>
    ${S.view === 'today' ? `<p class="lead">${todayN ? `${todayN} entr${todayN === 1 ? 'y' : 'ies'} filed today` : (remind ? 'Nothing written yet today, and it’s past your reminder' : 'Nothing filed yet today')}${S.ui.goalOn ? `, <span style="color:var(--accent)">${todaysWords()} of ${S.ui.goal}</span> words` : ''}.</p>` : ''}
    ${S.view === 'today' && S.ui.goalOn ? `<div class="mstrip" aria-hidden="true"><span>Today’s words</span><span class="mono">${todaysWords()}/${S.ui.goal}</span><i style="width:${Math.min(100, Math.round(todaysWords() / Math.max(1, S.ui.goal) * 100))}%"></i></div>` : ''}
    <button class="card" data-action="new" ${S.folderMissing ? 'disabled' : ''}><span class="title">Begin a new entry</span><span class="sub">${S.ui.prompts ? esc(prompt) : 'Ctrl+N'}</span></button>
    ${drafts.length && S.view !== 'inbox' ? `<button class="card" data-action="view" data-view="inbox"><span class="title">${drafts.length} draft${drafts.length === 1 ? '' : 's'} in the inbox</span><span class="sub">Oldest from ${fmtDay(drafts[drafts.length - 1].date)} · Ctrl+2</span></button>` : ''}
    ${S.hasTransfer && S.view === 'today' ? '<button class="card" data-action="file-transfer"><span class="title">transfer.md has entries to file</span><span class="sub">jnl’s batch import: file them straight into their days</span></button>' : ''}
    <span class="eyebrow" style="margin-top:10px">On this day</span>
    ${otd.length ? otd.slice(0, 3).map(e => `<button class="card" data-action="open" data-file="${esc(e.file)}" data-index="${e.index}"><span class="sub mono">${fmtDayYear(e.date)} · ${today().slice(0, 4) - e.date.slice(0, 4)} year${today().slice(0, 4) - e.date.slice(0, 4) === 1 ? '' : 's'} ago</span><span class="title">${esc(e.title || firstLine(e.body))}</span></button>`).join('') : '<div class="empty-note">Nothing written on this day in earlier years.</div>'}
    ${S.isSample ? '<div class="banner">You’re looking at the sample journal. Settings › Folder points Quire at a copy of your real one.</div>' : ''}
  </div></section>`;
}

function renderStream() {
  const q = S.query.trim() ? parseQuery(S.query.trim()) : null;
  // journalList() already carries drafts for a day or a search; otherwise add them here.
  const drafts = S.journal === 'all' && !S.day && !q ? inbox().filter(e => !S.tag || e.tags.includes(S.tag)) : [];
  const list = sorted([...journalList(), ...drafts]).slice(0, 300);
  let out = '', cur = null;
  for (const e of list) {
    if (e.date !== cur) { cur = e.date; out += `<div class="day">${fmtDate(e.date)}</div>`; }
    out += `<button class="item" data-action="open" data-file="${esc(e.file)}" data-index="${e.index}">
      <span class="m">${e.time}${e.source === 'inbox' ? ' · draft' : ''}${e.starred ? ' · ★' : ''}${e.split ? ' · @' + esc(e.split) : ''}</span>
      ${e.title ? `<span class="t">${esc(e.title)}</span>` : ''}
      <span class="b">${esc((b => b.length > 900 ? b.slice(0, 900) + '…' : b)(unguard(e.body))).replace(/@[a-zA-Z][a-zA-Z0-9_-]*/g, '<span class="tag">$&</span>')}</span></button>`;
  }
  return `<section class="stream" aria-label="Stream"><div class="inner">${out || '<div class="empty-note">No entries match.</div>'}</div></section>`;
}

function renderMedia() {
  if (!S.assets) { loadAssets(); return '<section class="stream"><div class="inner"><div class="empty-note">Reading assets/…</div></div></section>'; }
  const owners = assetOwners();
  const first = a => owners.get(a.rel)?.[0] || null;
  const name = a => a.rel.split('/').pop();
  const byName = (a, b) => name(a).localeCompare(name(b));
  // Dated by the earliest entry that links the file; unlinked files go last, by name.
  const dated = dir => (a, b) => { const x = first(a)?.ts, y = first(b)?.ts; return x && y ? dir * x.localeCompare(y) || byName(a, b) : x ? -1 : y ? 1 : byName(a, b); };
  const sorts = { newest: dated(-1), oldest: dated(1), largest: (a, b) => (b.bytes || 0) - (a.bytes || 0) || byName(a, b), kind: (a, b) => a.kind.localeCompare(b.kind) || dated(-1)(a, b), name: byName };
  const list = [...S.assets].sort(sorts[S.ui.assetSort] || sorts.newest);
  if (!list.length) return '<section class="stream"><div class="inner"><div class="empty-note">No media yet. Attach a photo from the composer’s ⋯ menu.</div></div></section>';
  const total = list.reduce((a, x) => a + (x.bytes || 0), 0);
  const tile = a => {
    const url = S.assetUrls.get(a.rel), o = first(a);
    const inner = a.kind === 'image' && url ? `<img src="${url}" alt="" loading="lazy">` : `<span class="tile-k">${icon[a.kind] || icon.file}<small>${esc(name(a))}</small></span>`;
    return `<div class="mtile ${a.referenced ? '' : 'orphan'}" data-ctx="asset" data-rel="${esc(a.rel)}">
      <button class="mtile-main" data-action="${a.kind === 'image' ? 'lightbox' : 'open-asset'}" data-rel="${esc(a.rel)}" ${o ? `data-file="${esc(o.file)}" data-index="${o.index}"` : ''} aria-label="${esc(name(a))}">${inner}<span class="tile-d">${o ? fmtDay(o.date) : a.referenced ? 'unlinked' : 'orphan'}</span></button>
      <button class="mtile-more" data-action="asset-menu" data-rel="${esc(a.rel)}" aria-label="More for ${esc(name(a))}" aria-haspopup="menu">${icon.more}</button></div>`;
  };
  const g = S.ui.assetGroup;
  let body = '';
  if (g === 'day' || g === 'month' || g === 'year') {
    const groups = new Map();
    for (const a of list) {
      const d = first(a)?.date, k = !d ? '' : g === 'day' ? d : g === 'month' ? d.slice(0, 7) : d.slice(0, 4);
      if (!groups.has(k)) groups.set(k, []);
      groups.get(k).push(a);
    }
    for (const [k, arr] of groups) {
      const label = !k ? 'Not linked to an entry' : g === 'day' ? fmtDate(k) : g === 'month' ? fmtMonth(+k.slice(0, 4), +k.slice(5, 7) - 1) : k;
      body += `<div class="group-label gallery-h"><span>${esc(label)}</span><span>${arr.length}</span></div><div class="gallery">${arr.map(tile).join('')}</div>`;
    }
  } else body = `<div class="gallery">${list.map(tile).join('')}</div>`;
  const opt = (k, v, l) => `<option value="${v}" ${S.ui[k] === v ? 'selected' : ''}>${l}</option>`;
  return `<section class="stream" aria-label="Media"><div class="inner wide">
    <div class="gallery-tools"><span class="group-label" style="padding:0">${plural(list.length, 'file')} · ${bytes(total)}</span><span class="spacer"></span>
      <label class="gl">Sort <select class="picker" data-input="asset-sort" aria-label="Sort media">${opt('assetSort', 'newest', 'Newest')}${opt('assetSort', 'oldest', 'Oldest')}${opt('assetSort', 'largest', 'Largest')}${opt('assetSort', 'kind', 'Kind')}${opt('assetSort', 'name', 'Name')}</select></label>
      <label class="gl">Group <select class="picker" data-input="asset-group" aria-label="Group media">${opt('assetGroup', 'none', 'None')}${opt('assetGroup', 'day', 'Day')}${opt('assetGroup', 'month', 'Month')}${opt('assetGroup', 'year', 'Year')}</select></label>
      ${list.some(a => !a.referenced) ? '<button class="btn ghost" data-action="clear-orphans">Clear orphans</button>' : ''}</div>
    ${body}</div></section>`;
}
/** rel → entries (oldest first) whose links resolve to it. */
function assetOwners() {
  const m = new Map();
  for (const e of S.entries) for (const p of mediaOf(e)) {
    const r = resolveRel(e.file, p);
    if (!m.has(r)) m.set(r, []);
    const l = m.get(r); if (!l.includes(e)) l.push(e);
  }
  for (const l of m.values()) l.sort((a, b) => a.ts.localeCompare(b.ts));
  return m;
}
async function loadAssets() {
  try {
    S.assets = await invoke('assets');
    await Promise.all(S.assets.filter(a => !S.assetUrls.get(a.rel)).map(async a => { try { S.assetUrls.set(a.rel, fileSrc(await invoke('asset_path', { rel: a.rel }))); } catch { S.assetUrls.set(a.rel, null); } }));
    if (S.view === 'journal' && S.jview === 'media' && S.mode !== 'write') render();
  } catch (e) { S.assets = []; fail(e); }
}
/** Swap every unresolved [data-asset] placeholder on screen (entry, day page, anywhere) for its media; URLs are cached. */
async function resolveVisibleMedia() {
  const want = [...new Set($$('#body [data-asset]').map(el => el.dataset.asset))].filter(r => !S.assetUrls.has(r));
  if (!want.length) return;
  await Promise.all(want.map(async rel => { try { S.assetUrls.set(rel, fileSrc(await invoke('asset_path', { rel }))); } catch { S.assetUrls.set(rel, null); } }));
  if (!want.some(r => S.assetUrls.get(r))) return;
  // Re-render just the prose blocks that had placeholders, so nothing else (inputs, scroll) is disturbed.
  for (const pr of $$('#body .prose[data-file]')) {
    if (!pr.querySelector('[data-asset]')) continue;
    const e = S.entries.find(x => x.file === pr.dataset.file && x.index === +pr.dataset.index);
    if (e) pr.innerHTML = renderProse(e.body, e.file);
  }
}

/* ---------- the composer ---------- */
function renderWrite() {
  const d = S.draft;
  const isDraft = !d.ref || d.ref.source === 'inbox';
  const empty = !d.body.trim() && !d.title.trim();
  return `<section class="entry-pane" aria-label="Composer">
    <div class="toolbar">
      ${S.narrow ? '<button class="btn" data-action="show-list">‹ List</button>' : ''}
      ${dateButton(d.ts)}
      <span class="pill">${isDraft ? (guardCount(d) ? 'Not saved' : d.ref ? 'Draft · saved' : 'New draft') : 'Editing filed entry'}</span>
      <span class="spacer"></span>
      <button class="btn" data-action="focus" title="Focus (Ctrl+Alt+F)">Focus</button>
      <button class="btn ${d.starred ? 'star-on' : ''}" data-action="star" aria-label="Star">${icon.star(d.starred)}</button>
      ${moreBtn('write')}
      ${isDraft
        ? `<button class="btn primary" data-action="file" ${empty ? 'disabled' : ''}>File to ${fmtDay(d.ts)} <span class="k">Ctrl+J</span></button>`
        : `<button class="btn" data-action="cancel-edit">Cancel <span class="k">Esc</span></button><button class="btn primary" data-action="save-edit">Save <span class="k">Ctrl+S</span></button>`}
    </div>
    <div id="guard">${guardHtml()}</div>
    <div class="page" id="page"><article class="sheet">
      <input class="title-input" id="title" placeholder="Title (optional)" value="${esc(d.title)}" autocomplete="off" ${S.folderMissing ? 'readonly' : ''}>
      <div class="rule"></div>
      <div class="editor" id="editor"><div class="backdrop" id="backdrop" aria-hidden="true"></div><textarea id="bodyta" spellcheck="true" aria-label="Entry text" ${S.folderMissing ? 'readonly' : ''}>${esc(d.body)}</textarea></div>
      ${S.ui.prompts && !d.body.trim() ? '<button class="prompt-again" data-action="prompt">↻ Another prompt</button>' : ''}
    </article></div>
    <div class="statusbar">
      <span class="mono" id="wc">${words(d.body)} words</span>
      <span class="focus-hint">Esc to leave focus</span>
      <span class="spacer"></span>
      <span id="goal">${S.ui.goalOn ? goalHtml() : ''}</span>
      ${timerHtml()}
      <span class="mono" id="savefile">${d.ref ? esc(d.ref.file) : 'saves to the inbox'}</span>
    </div>
  </section>`;
}

function todaysWords() {
  let n = S.entries.filter(e => e.date === today() && !(S.draft?.ref && sameEntry(e, S.draft.ref))).reduce((a, e) => a + e.words, 0);
  if (S.draft && S.draft.ts.slice(0, 10) === today()) n += words(S.draft.body);
  return n;
}
function goalHtml() {
  const n = todaysWords(), g = Math.max(1, S.ui.goal), pct = Math.min(1, n / g), c = 2 * Math.PI * 9;
  return `<span class="goal"><svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="var(--line)" stroke-width="3"/><circle cx="12" cy="12" r="9" fill="none" stroke="var(--accent)" stroke-width="3" stroke-linecap="round" stroke-dasharray="${(c * pct).toFixed(1)} ${c.toFixed(1)}" transform="rotate(-90 12 12)"/></svg><span><b>${n}</b> of ${g} today</span></span>`;
}
function timerHtml() {
  const t = S.timer;
  const left = t.left ?? S.ui.timerMins * 60;
  const cls = t.left === 0 ? 'done' : t.running ? 'running' : '';
  const label = t.left === 0 ? 'Time' : `${pad(Math.floor(left / 60))}:${pad(left % 60)}`;
  return `<button class="timer ${cls}" data-action="timer" id="timerbtn" title="Writing timer (click to start/pause, double-click to reset)">${icon.clock}<span class="mono">${label}</span></button>`;
}

function paintBackdrop() {
  const ta = $('#bodyta'), bd = $('#backdrop');
  if (!ta || !bd) return;
  const text = ta.value;
  const caret = ta.selectionStart ?? text.length;
  const dim = S.focus && S.ui.focusDims;
  const live = s => esc(s).replace(/\*\*([^*\n]+)\*\*/g, '<b>**$1**</b>').replace(/__([^_\n]+)__/g, '<i>__$1__</i>').replace(/`([^`\n]+)`/g, '<code>`$1`</code>').replace(/@[a-zA-Z][a-zA-Z0-9_-]*/g, '<span class="tag">$&</span>');
  if (!text) {
    const p = S.ui.prompts ? promptText() : 'Begin writing';
    bd.innerHTML = `<span id="caretmark"></span><span class="placeholder">${esc(p)}</span>`;
  } else {
    const parts = text.split(/(\n\s*\n)/);
    let pos = 0, html = '';
    for (const part of parts) {
      const start = pos, end = pos + part.length;
      const isSep = /^\n\s*\n$/.test(part);
      const here = caret >= start && caret <= end;
      let inner = here ? live(text.slice(start, caret)) + '<span id="caretmark"></span>' + live(text.slice(caret, end)) : live(part);
      html += isSep ? inner : `<span class="para ${dim && !here ? 'dim' : ''}">${inner}</span>`;
      pos = end;
    }
    bd.innerHTML = html + (text.endsWith('\n') ? '​' : '');
  }
  ta.style.height = bd.offsetHeight + 'px';
}
function typewriter() {
  if (!(S.focus && S.ui.typewriter)) return;
  const m = $('#caretmark'), page = $('#page');
  if (!m || !page) return;
  const r = m.getBoundingClientRect(), pr = page.getBoundingClientRect();
  page.scrollTop += (r.top - pr.top) - page.clientHeight * 0.45;
}

/* editor macros: list continuation (Nook's ListContinuation), wrap selection, insert at caret */
function listContinuation(line) {
  let m;
  if ((m = line.match(/^(\s*)([-*+] \[[ xX]\] )(.*)$/))) return m[3].trim() ? { cont: m[1] + m[2].slice(0, 2) + '[ ] ' } : { end: m[1].length + m[2].length };
  if ((m = line.match(/^(\s*)(\d+)([.)] )(.*)$/))) return m[4].trim() ? { cont: m[1] + (parseInt(m[2], 10) + 1) + m[3] } : { end: m[1].length + m[2].length + m[3].length };
  if ((m = line.match(/^(\s*)([-*+] )(.*)$/))) return m[3].trim() ? { cont: m[1] + m[2] } : { end: m[1].length + m[2].length };
  return null;
}
function editorEnter(ta) {
  const pos = ta.selectionStart;
  if (pos !== ta.selectionEnd) return false;
  const before = ta.value.slice(0, pos), lineStart = before.lastIndexOf('\n') + 1;
  const line = before.slice(lineStart);
  const after = ta.value.slice(pos);
  if (after && after[0] !== '\n') return false;
  const r = listContinuation(line);
  if (!r) return false;
  if (r.cont !== undefined) ta.setRangeText('\n' + r.cont, pos, pos, 'end');
  else ta.setRangeText('', lineStart, lineStart + r.end, 'end');
  ta.dispatchEvent(new Event('input'));
  return true;
}
function wrapSelection(ta, open, close = open) {
  const a = ta.selectionStart, b = ta.selectionEnd, sel = ta.value.slice(a, b);
  if (sel.startsWith(open) && sel.endsWith(close) && sel.length >= open.length + close.length) { ta.setRangeText(sel.slice(open.length, sel.length - close.length), a, b, 'select'); }
  else { ta.setRangeText(open + sel + close, a, b, 'select'); ta.setSelectionRange(a + open.length, b + open.length); }
  ta.dispatchEvent(new Event('input'));
}
function insertAtCaret(text) {
  const ta = $('#bodyta'); if (!ta) return;
  const a = ta.selectionStart, b = ta.selectionEnd;
  const needsNl = a > 0 && ta.value[a - 1] !== '\n' ? '\n\n' : '';
  ta.setRangeText(needsNl + text, a, b, 'end');
  ta.focus(); ta.dispatchEvent(new Event('input'));
}
const fillTemplate = s => { const d = new Date(); return s.replace(/\{\{date\}\}/g, isoOf(d)).replace(/\{\{time\}\}/g, nowTs(d).slice(11, 16)).replace(/\{\{weekday\}\}/g, d.toLocaleDateString('en-GB', { weekday: 'long' })); };

/* tag autocomplete */
function tagAutocomplete(ta) {
  const pos = ta.selectionStart, before = ta.value.slice(0, pos);
  const m = before.match(/(^|\s)(@[a-zA-Z][a-zA-Z0-9_-]*)$/);
  const box = $('#tagpick');
  if (!m) { if (box) box.remove(); S.tagPick = null; return; }
  const typed = m[2].toLowerCase();
  const opts = countTags(S.entries).map(x => x[0]).filter(t => t.toLowerCase().startsWith(typed) && t.toLowerCase() !== typed).slice(0, 6);
  if (!opts.length) { if (box) box.remove(); S.tagPick = null; return; }
  S.tagPick = { start: pos - m[2].length, end: pos, opts, ix: 0 };
  const el = box || Object.assign(document.createElement('div'), { id: 'tagpick', className: 'tagpick' });
  if (!box) el.addEventListener('mousedown', ev => ev.preventDefault()); // keep the textarea focused so blur doesn't close the picker before the click lands
  el.innerHTML = opts.map((t, i) => `<button data-action="tag-accept" data-i="${i}" class="${i === 0 ? 'on' : ''}">${esc(t)}</button>`).join('');
  const cm = $('#caretmark'), ed = $('#editor');
  if (!box) ed.appendChild(el);
  if (cm) { const r = cm.getBoundingClientRect(), er = ed.getBoundingClientRect(); el.style.left = Math.min(r.left - er.left, er.width - 220) + 'px'; el.style.top = (r.bottom - er.top + 6) + 'px'; }
}
function acceptTag(i) {
  const ta = $('#bodyta'), p = S.tagPick; if (!ta || !p) return;
  ta.setRangeText(p.opts[i] + ' ', p.start, p.end, 'end');
  $('#tagpick')?.remove(); S.tagPick = null;
  ta.focus(); ta.dispatchEvent(new Event('input'));
}

let saveChain = Promise.resolve();
let saveTimer = null;
const isDraftRef = d => !!d && (!d.ref || d.ref.source === 'inbox');
const isDirtyEdit = d => !!d?.ref && d.ref.source !== 'inbox' && makeRaw(d.ts, d.title, d.starred, d.body) !== d.ref.raw.trimEnd();
/** Header-shaped lines in a draft's body: while there are any (and the user hasn't said "Keep as one"), nothing autosaves. */
const guardCount = d => isDraftRef(d) && !d.keepOne ? d.body.split('\n').filter(l => HDR_LINE.test(l)).length : 0;
function guardHtml() {
  const n = guardCount(S.draft);
  if (!n) return '';
  return `<div class="guard-banner" role="alert"><span>This looks like ${plural(n, 'entry', 'entries')} — nothing is saved until you choose.</span><span class="spacer"></span><button class="btn primary" data-action="guard-import">Import</button><button class="btn" data-action="guard-keep">Keep as one</button></div>`;
}
function scheduleSave() {
  clearTimeout(saveTimer);
  const d = S.draft;
  if (!isDraftRef(d) || guardCount(d) || S.folderMissing) return;
  saveTimer = setTimeout(() => {
    saveChain = saveChain.then(saveDraftNow).then(checkGoal).catch(e => {
      // Drop the reference so the next save re-creates the draft instead of failing on a stale index/raw forever.
      // An unreachable folder changed nothing on disk, so the reference is still good there.
      if (S.draft === d && !/unavailable/i.test(String(e))) d.ref = null;
      fail(e);
    });
  }, 700);
}

/** Drafts autosave to their day's file under inbox/. Filed entries save on Ctrl+S, or when you leave them. */
async function saveDraftNow() {
  const d = S.draft;
  if (!isDraftRef(d) || guardCount(d)) return;
  if (!d.title.trim() && !d.body.trim()) return;
  const raw = makeRaw(d.ts, d.title, d.starred, d.body);
  if (d.ref && d.ref.raw.trimEnd() === raw) return;
  S.ignoreWatch = Date.now() + 1500;
  const r = !d.ref
    ? await invoke('create_draft', { ts: d.ts, title: d.title, starred: d.starred, body: d.body })
    : await invoke('update_entry', { file: d.ref.file, index: d.ref.index, expectedRaw: d.ref.raw, ts: d.ts, title: d.title, starred: d.starred, body: d.body });
  // The back end says exactly where it wrote and what; load() swaps this for the full entry.
  if (S.draft === d) d.ref = { ...(d.ref || {}), file: r.file, index: r.index, raw: r.raw, ts: d.ts, source: 'inbox' };
  await load();
  refreshChrome();
  // The list beside the composer shows the draft once it exists on disk.
  const lp = $('.list-pane'); if (lp && !S.narrow) { const top = lp.scrollTop; const tmp = document.createElement('div'); tmp.innerHTML = renderList(); const nl = tmp.firstElementChild; lp.replaceWith(nl); nl.scrollTop = top; }
  const st = $('#savefile'); if (st && d.ref) st.textContent = d.ref.file;
}
/** Is everything in the composer on disk? */
const draftSaved = d => !d || (isDraftRef(d) ? (!d.title.trim() && !d.body.trim()) || (!!d.ref && d.ref.raw.trimEnd() === makeRaw(d.ts, d.title, d.starred, d.body)) : !isDirtyEdit(d));
/** Write out whatever the composer holds. true = on disk, false = a save failed, 'stay' = the user chose to keep writing. */
async function flushDraft(d) {
  clearTimeout(saveTimer);
  try {
    if (isDraftRef(d)) {
      await saveChain.catch(() => {});
      const n = guardCount(d);
      if (n) {
        if (!(await askConfirm(`This draft looks like ${plural(n, 'entry', 'entries')} and hasn’t been saved yet. Save it as one entry?`, 'Save as one'))) return 'stay';
        d.keepOne = true;
      }
      await saveDraftNow();
    } else if (isDirtyEdit(d)) {
      await saveEditCore(d);
      toast('Saved');
    }
    return draftSaved(d);
  } catch (e) { console.error(e); return false; }
}
function refreshChrome() {
  const wc = $('#wc'); if (wc && S.draft) wc.textContent = `${words(S.draft.body)} words`;
  const g = $('#goal'); if (g && S.ui.goalOn) g.innerHTML = goalHtml();
  const pill = $('.toolbar .pill');
  if (pill && S.draft && isDraftRef(S.draft)) pill.textContent = guardCount(S.draft) ? 'Not saved' : S.draft.ref ? 'Draft · saved' : 'New draft';
  const fileBtn = $('[data-action="file"]');
  if (fileBtn && S.draft) fileBtn.disabled = !S.draft.body.trim() && !S.draft.title.trim();
  const gb = $('#guard'); if (gb && S.draft) { const h = guardHtml(); if (gb.innerHTML !== h) gb.innerHTML = h; }
  renderTabs();
}
/** An empty new draft's time floats with the clock until you type or retime it. */
function refreshDateButton() {
  const d = S.draft, b = $('[data-action="retime"]'); if (!d) return;
  if (b) b.outerHTML = dateButton(d.ts);
  const fb = $('.toolbar [data-action="file"]'); if (fb && isDraftRef(d)) fb.innerHTML = `File to ${fmtDay(d.ts)} <span class="k">Ctrl+J</span>`;
}
function restampIfFloating(typed) {
  const d = S.draft;
  if (!d || !d.floating) return;
  if (d.ref || d.retimed) { d.floating = false; return; }
  if (typed || (!d.title.trim() && !d.body.trim())) { d.ts = nowTs(); refreshDateButton(); }
  if (typed) d.floating = false;
}

function startDraft(body = '', title = '') {
  if (S.folderMissing) { toast('Quire can’t reach your journal folder, so nothing would be saved'); return; }
  S.draft = { ref: null, ts: nowTs(), title, body, starred: false, floating: !body.trim() && !title.trim(), retimed: false, keepOne: false };
  S.mode = 'write'; S.sel = null; S.showList = false;
  if (!['today', 'inbox'].includes(S.view)) S.view = 'inbox';
  render();
  const ta = $('#bodyta'); if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); paintBackdrop(); }
}
function editEntry(e) {
  if (S.folderMissing) { toast('Quire can’t reach your journal folder, so nothing would be saved'); S.sel = e; S.mode = 'read'; render(); return; }
  S.draft = { ref: e, ts: e.ts, title: e.title, body: e.body, starred: e.starred, floating: false, retimed: false, keepOne: false };
  S.mode = 'write'; S.showList = false;
  render();
  const ta = $('#bodyta'); if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); paintBackdrop(); }
}
/** Leave the composer without losing anything: drafts and edited filed entries are saved first.
 *  Returns false when the composer should stay open (a failed save the user didn't discard, or "keep writing"). */
async function leaveWrite() {
  clearTimeout(saveTimer);
  const d = S.draft;
  if (d) {
    const ok = await flushDraft(d);
    if (ok === 'stay') return false;
    if (!ok && !(await askConfirm('Couldn’t save — discard changes?', 'Discard'))) return false;
  }
  const ref = d?.ref;
  S.mode = 'read'; S.draft = null; S.focus = false;
  if (ref) S.sel = S.entries.find(e => sameEntry(e, ref)) || null;
  render();
  return true;
}
/** Esc / Cancel on a filed entry: an explicit cancel, but ask before throwing edits away. */
async function cancelEdit() {
  const d = S.draft;
  if (isDirtyEdit(d) && !(await askConfirm('Discard your changes to this entry?', 'Discard'))) return;
  S.mode = 'read'; S.draft = null; S.focus = false; render();
}
/** Same entry after a reload (indexes shift when files change). */
const reresolve = e => e && (S.entries.find(x => sameEntry(x, e)) || S.entries.find(x => x.file === e.file && x.ts === e.ts) || null);
async function fileCurrent() {
  let target;
  if (S.mode === 'write' && S.draft) {
    if (!isDraftRef(S.draft)) return;
    if (guardCount(S.draft)) { toast('Choose Import or Keep as one first'); return; }
    if (S.ui.autoPromote && !S.draft.title.trim()) promoteFirstLine(false);
    clearTimeout(saveTimer); await saveChain; await saveDraftNow();
    if (!draftSaved(S.draft)) throw new Error('Couldn’t save the draft, so it wasn’t filed');
    target = S.draft.ref;
  } else target = S.sel;
  if (!target || target.source !== 'inbox') return;
  const dest = await invoke('file_draft', { file: target.file, index: target.index, expectedRaw: target.raw });
  S.mode = 'read'; S.draft = null; S.focus = false;
  await load();
  S.sel = S.entries.find(e => e.file === dest && e.ts === target.ts) || null;
  if (S.view === 'inbox') S.sel = inbox()[0] || S.sel;
  stamp('ENTRY_FILED', `Filed to ${dest}`);
  render();
}
function promoteFirstLine(rerender = true) {
  const d = S.draft; if (!d) return;
  const lines = d.body.split('\n');
  const ix = lines.findIndex(l => l.trim());
  if (ix < 0) return;
  d.title = lines[ix].replace(/^#+\s*/, '').trim();
  d.body = lines.slice(ix + 1).join('\n').replace(/^\s*\n/, '');
  if (rerender) { render(); $('#bodyta')?.focus(); }
  scheduleSave();
}
/** Save a filed entry being edited; the composer stays as it is. */
async function saveEditCore(d) {
  S.ignoreWatch = Date.now() + 1500;
  const r = await invoke('update_entry', { file: d.ref.file, index: d.ref.index, expectedRaw: d.ref.raw, ts: d.ts, title: d.title, starred: d.starred, body: d.body });
  await load(r);
  if (S.draft === d) d.ref = S.entries.find(e => sameEntry(e, r)) || { ...d.ref, ...r };
  return r;
}
async function saveEdit() {
  const d = S.draft; if (!d?.ref) return;
  await saveEditCore(d);
  S.mode = 'read'; S.draft = null; S.focus = false; toast('Saved'); render();
}
/** "Import" on the embedded-header banner: each [header] becomes its own inbox draft; text above the first stays here. */
async function guardImport() {
  const d = S.draft; if (!d) return;
  clearTimeout(saveTimer); await saveChain.catch(() => {});
  const lines = d.body.split('\n');
  const i = lines.findIndex(l => HDR_LINE.test(l));
  if (i < 0) return;
  S.ignoreWatch = Date.now() + 1500;
  const n = await invoke('import_text', { text: lines.slice(i).join('\n'), nowTs: nowTs() });
  // Imported first, then the old draft goes: import only appends, so the draft's index and raw still hold.
  if (d.ref && d.ref.source === 'inbox') {
    try { await invoke('delete_entry', { file: d.ref.file, index: d.ref.index, expectedRaw: d.ref.raw }); }
    catch (e) { fail(e); }
  }
  if (S.draft === d) { d.ref = null; d.body = lines.slice(0, i).join('\n').replace(/\s+$/, ''); d.keepOne = false; }
  await load();
  toast(`Imported ${plural(n, 'entry', 'entries')}`);
  render();
  const ta = $('#bodyta'); if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); paintBackdrop(); }
  scheduleSave();
}
async function toggleStar() {
  if (S.mode === 'write' && S.draft) {
    S.draft.starred = !S.draft.starred;
    const b = $('[data-action="star"]'); b.classList.toggle('star-on', S.draft.starred); b.innerHTML = icon.star(S.draft.starred);
    if (isDraftRef(S.draft)) scheduleSave();
    return;
  }
  const e = S.sel; if (!e) return;
  S.ignoreWatch = Date.now() + 1500;
  const r = await invoke('update_entry', { file: e.file, index: e.index, expectedRaw: e.raw, ts: e.ts, title: e.title, starred: !e.starred, body: e.body });
  await load(r);
  render();
}
async function toggleTask(e, ix, checked) {
  let n = 0;
  const body = e.body.split('\n').map(l => { const m = l.match(/^(\s*[-*+]\s+\[)([ xX])(\]\s.*)$/); if (!m) return l; const mine = n++ === ix; return mine ? m[1] + (checked ? 'x' : ' ') + m[3] : l; }).join('\n');
  S.ignoreWatch = Date.now() + 1500;
  const had = sameEntry(S.sel, e);
  const r = await invoke('update_entry', { file: e.file, index: e.index, expectedRaw: e.raw, ts: e.ts, title: e.title, starred: e.starred, body });
  await load(had ? r : undefined); // a tick on the day page shouldn't open the entry
  render();
}
function toggleFocus() {
  if (S.mode !== 'write') { if (S.sel) editEntry(S.sel); else startDraft(); }
  S.focus = !S.focus;
  $('#app').classList.toggle('focus', S.focus);
  paintBackdrop(); typewriter(); $('#bodyta')?.focus();
}

/* ---------- menus ---------- */
function openMenu(anchor, ctx) {
  const items = [];
  const d = S.draft, e = S.sel;
  if (ctx === 'write') {
    items.push(['Promote first line to title', 'promote', !d.body.trim()]);
    if (S.templates.length) { items.push(['Insert template', null]); S.templates.forEach(t => items.push([`   ${t.name}`, 'tpl:' + t.name])); items.push(['', null]); }
    items.push(['Attach photo, audio or file…', 'attach']);
    items.push(['Import as separate entries…', 'import-text']);
    items.push(['Copy text', 'copy']);
    items.push(['Print…', 'print']);
    if (!d.ref || d.ref.source === 'inbox') items.push(['Discard draft', 'discard', false, true]);
  } else if (ctx === 'read') {
    items.push(['Copy text', 'copy']);
    items.push(['Print entry…', 'print']);
    items.push(['Print this day…', 'print-day']);
    items.push(['', null]);
    items.push(['Change date & time', 'retime']);
    items.push(['Open file in your editor', 'open-file']);
    items.push(['Show file', 'reveal']);
    items.push(['', null]);
    if (e?.source !== 'inbox') items.push(['Return to inbox', 'unfile']);
    items.push(['Delete', 'delete', false, true]);
  }
  showMenu(anchor.getBoundingClientRect(), items);
}
/** items: [label, action, disabled, danger]; no action = heading; no label = rule. */
function showMenu(r, items) {
  const layer = $('#popover');
  layer.innerHTML = `<div class="menu" role="menu" style="left:${Math.max(8, Math.min(r.left, innerWidth - 280))}px;top:${Math.max(8, Math.min(r.bottom + 6, innerHeight - 36 * items.length - 20))}px">${items.map(([l, a, dis, danger]) => a ? `<button role="menuitem" data-menu-item="${a}" ${dis ? 'disabled' : ''} class="${danger ? 'danger' : ''}">${esc(l)}</button>` : l ? `<span class="menu-h">${esc(l)}</span>` : '<span class="menu-rule"></span>').join('')}</div>`;
  layer.classList.add('open');
  layer.querySelector('[role="menuitem"]:not([disabled])')?.focus();
}
function openAssetMenu(r, rel) {
  S.menuAsset = rel;
  const n = (assetOwners().get(rel) || []).length;
  showMenu(r, [['View', 'asset-view'], ['Show file', 'asset-reveal'], [n > 1 ? `Go to entry (${n})…` : 'Go to entry', 'asset-goto', !n], ['', null], ['Delete…', 'asset-delete', false, true]]);
}
/** Open an entry in the Journal, leaving the composer and any popover first. */
async function openInJournal(ref) {
  closePopover();
  if (S.mode === 'write' && !(await leaveWrite())) return;
  const e = reresolve(ref); if (!e) return;
  S.view = 'journal'; S.jview = 'list'; S.sel = e; S.mode = 'read'; S.showList = false; render();
}
async function assetAction(a, rel) {
  const name = rel.split('/').pop();
  const asset = (S.assets || []).find(x => x.rel === rel);
  const kind = asset?.kind || mediaKind(rel);
  const owners = assetOwners().get(rel) || [];
  if (a === 'asset-view') {
    if (kind === 'image') { let url = S.assetUrls.get(rel); if (!url) { url = fileSrc(await invoke('asset_path', { rel })); S.assetUrls.set(rel, url); } openLightbox(rel, url, owners[0] || null); }
    else await invoke('plugin:opener|open_path', { path: await invoke('asset_path', { rel }) });
  } else if (a === 'asset-reveal') {
    await invoke('plugin:opener|reveal_item_in_dir', { path: await invoke('asset_path', { rel }) });
  } else if (a === 'asset-goto') {
    if (owners.length === 1) return openInJournal(owners[0]);
    if (!owners.length) return toast('No entry links this file');
    const layer = $('#popover');
    layer.innerHTML = `<div class="popover centered" role="dialog" aria-label="Entries using ${esc(name)}"><h3>Used by ${owners.length} entries</h3>
      <div class="pick-list">${byNewest(owners).map(e => `<button class="row" data-action="open-journal" data-file="${esc(e.file)}" data-index="${e.index}"><span class="meta"><span class="mono">${fmtDay(e.date)} · ${e.time}</span>${e.source === 'inbox' ? '<span>draft</span>' : ''}</span><span class="t">${esc(e.title || firstLine(e.body) || 'Untitled')}</span></button>`).join('')}</div>
      <div class="row2"><span></span><button class="btn" id="ask-no">Close</button></div></div>`;
    layer.classList.add('open');
    $('#ask-no').onclick = closePopover; askConfirm.cancel = closePopover;
    layer.querySelector('.pick-list .row')?.focus();
  } else if (a === 'asset-delete') {
    const n = owners.length;
    const msg = n ? `${plural(n, 'entry', 'entries')} link${n === 1 ? 's' : ''} this file, and those links will break. This can’t be undone.` : `<b>${esc(name)}</b> isn’t linked by any entry. This can’t be undone.`;
    if (!(await askConfirm(msg, 'Delete', { what: 'File', whereLabel: n ? 'Linked by' : 'Unlinked', item: { name, meta: n ? plural(n, 'entry', 'entries') : 'assets/' } }))) return;
    await invoke('delete_asset', { rel });
    S.assets = null; S.assetUrls.delete(rel); S.sizes = null; S.statsExtra = null;
    toast(`Deleted ${name}`); render();
  }
}
async function menuAction(a) {
  closePopover();
  const d = S.draft, e = S.sel;
  if (a.startsWith('asset-')) { if (S.menuAsset) await assetAction(a, S.menuAsset); return; }
  if (a === 'promote') { promoteFirstLine(); return; }
  if (a.startsWith('tpl:')) { const t = S.templates.find(x => x.name === a.slice(4)); if (t) insertAtCaret(fillTemplate(t.body)); return; }
  if (a === 'attach') {
    const p = await invoke('plugin:dialog|open', { options: { multiple: false, title: 'Attach a file' } });
    if (!p) return;
    const link = await invoke('attach_file', { src: p, ts: d.ts, entryFile: d.ref ? d.ref.file : 'inbox' });
    if (S.draft === d) { insertAtCaret(link); toast('Attached'); } else { await navigator.clipboard.writeText(link).catch(() => {}); toast('Attached — the link is on the clipboard'); }
    return;
  }
  if (a === 'import-text') { openImportText(); return; }
  if (a === 'copy') { const src = S.mode === 'write' ? d : e; await navigator.clipboard.writeText([src.title, src.body].filter(Boolean).join('\n\n')); toast('Copied'); return; }
  if (a === 'print') { window.print(); return; }
  if (a === 'print-day') { S.printDay = e.date; S.sel = null; render(); setTimeout(() => { window.print(); S.printDay = null; S.sel = e; render(); }, 150); return; }
  if (a === 'open-file') { await invoke('plugin:opener|open_path', { path: S.folder + '/' + e.file }); return; }
  if (a === 'reveal') { await invoke('plugin:opener|reveal_item_in_dir', { path: S.folder + '/' + e.file }); return; }
  if (a === 'discard') {
    if (!(await askConfirm('Discard this draft? It will be removed from the inbox.', 'Discard'))) return;
    clearTimeout(saveTimer); await saveChain;
    if (d.ref && d.ref.source === 'inbox') await invoke('delete_entry', { file: d.ref.file, index: d.ref.index, expectedRaw: d.ref.raw });
    S.mode = 'read'; S.draft = null; S.focus = false; await load(); S.sel = null; toast('Discarded'); render(); return;
  }
  if (a === 'retime') { const b = $('[data-action="retime"]'); if (b) openRetime(b); return; }
  if (a === 'unfile') { await doUnfile(); return; }
  if (a === 'delete') { await doDelete(); return; }
}
async function doDelete() {
  const e = S.sel; if (!e) return;
  if (!(await askConfirm(`This removes it from ${esc(e.file)}.`, 'Delete', { what: 'Entry', whereLabel: 'File', item: { name: e.title || firstLine(e.body) || 'Untitled', meta: `${fmtDay(e.date)} · ${e.time}` } }))) return;
  await invoke('delete_entry', { file: e.file, index: e.index, expectedRaw: e.raw });
  S.sel = null; await load(); toast('Deleted'); render();
}
async function doUnfile() {
  const e = S.sel; if (!e) return;
  const r = await invoke('unfile_entry', { file: e.file, index: e.index, expectedRaw: e.raw });
  await load(r); toast('Back in the inbox'); render();
}

/* ---------- popovers ---------- */
function openRetime(anchor) {
  const cur = S.mode === 'write' && S.draft ? S.draft.ts : S.sel?.ts;
  if (!cur) return;
  const r = anchor.getBoundingClientRect();
  const isFiled = (S.mode === 'write' ? S.draft.ref : S.sel)?.source === 'journal';
  $('#popover').innerHTML = `<div class="popover" style="left:${Math.min(r.left, innerWidth - 320)}px;top:${r.bottom + 8}px" role="dialog" aria-label="Date and time">
    <h3>Date &amp; time</h3>
    <div class="row2"><label>Date<input type="date" id="rt-date" value="${cur.slice(0, 10)}"></label><label>Time<input type="time" id="rt-time" step="1" value="${cur.slice(11)}"></label></div>
    <div class="quick"><button class="btn" data-rt="now">Now</button><button class="btn" data-rt="yesterday">Yesterday</button></div>
    ${isFiled ? '<div class="note">Changing the date moves the entry to that day’s file, in time order.</div>' : ''}
    <div class="row2"><button class="btn" data-rt="cancel">Cancel</button><button class="btn primary" data-rt="save">Save</button></div>
  </div>`;
  $('#popover').classList.add('open');
  $('#rt-date').focus();
}
async function retimeSave() {
  const d = $('#rt-date').value, t = $('#rt-time').value;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d) || !/^\d{2}:\d{2}/.test(t)) return toast('Pick a date and time');
  const ts = `${d} ${t.length === 5 ? t + ':00' : t.slice(0, 8)}`;
  closePopover();
  if (S.mode === 'write' && S.draft) {
    S.draft.ts = ts; S.draft.retimed = true; S.draft.floating = false;
    if (S.draft.ref && S.draft.ref.source === 'inbox') { clearTimeout(saveTimer); await saveChain; await saveDraftNow(); }
    render(); return;
  }
  const e = S.sel; if (!e) return;
  S.ignoreWatch = Date.now() + 1500;
  const r = await invoke('update_entry', { file: e.file, index: e.index, expectedRaw: e.raw, ts, title: e.title, starred: e.starred, body: e.body });
  await load(r);
  toast(r.file !== e.file ? `Moved to ${r.file}` : 'Time updated');
  render();
}
const DANGER_TITLES = { Delete: 'Permanent deletion', Discard: 'Changes will be lost', Remove: 'Removal pending', Restore: 'Folder will be overwritten' };
/** opts.item: { name, meta } — the thing being destroyed, shown as a highlighted row. */
function askConfirm(html, okLabel, opts = {}) {
  const danger = opts.danger ?? (okLabel in DANGER_TITLES);
  return new Promise(resolve => {
    const layer = $('#popover');
    const head = danger ? `<div class="dz-head"><span class="dz-title">${esc(opts.title || DANGER_TITLES[okLabel] || okLabel)}</span><span class="dz-cols"><span>${esc(opts.what || 'Target')}</span><span>${esc(opts.whereLabel || 'Location')}</span></span></div>` : '';
    const item = danger && opts.item ? `<div class="dz-item"><span class="dz-ico" aria-hidden="true">${icon.trash || '×'}</span><span class="dz-name">${esc(opts.item.name)}</span><span class="dz-meta mono">${esc(opts.item.meta || '')}</span></div>` : '';
    const micro = danger ? `<div class="dz-micro" aria-hidden="true">[WRITE PENDING] [NO UNDO]<br>FILE IO ${'· '.repeat(3)}AWAITING CONFIRMATION…</div>` : '';
    layer.innerHTML = `<div class="popover centered ${danger ? 'danger-panel' : ''}" role="alertdialog" aria-label="${danger ? 'Confirm ' + esc(okLabel.toLowerCase()) : 'Confirm'}">${head}${item}<div class="dz-body" style="font-size:14px;line-height:1.5">${html}</div>
      <div class="row2"><button class="btn" id="ask-no">Cancel</button><button class="btn primary ${danger ? 'danger' : ''}" id="ask-yes">${esc(okLabel)}</button></div>${micro}</div>`;
    layer.classList.add('open');
    const done = v => { closePopover(); resolve(v); };
    $('#ask-yes').onclick = () => done(true); $('#ask-no').onclick = () => done(false);
    askConfirm.cancel = () => done(false);
    // Destructive choices start on Cancel, so a stray Enter can't delete.
    (danger ? $('#ask-no') : $('#ask-yes')).focus();
  });
}
function askText(title, placeholder, value = '') {
  return new Promise(resolve => {
    const layer = $('#popover');
    layer.innerHTML = `<div class="popover centered" role="dialog"><h3>${esc(title)}</h3><input id="ask-in" placeholder="${esc(placeholder)}" value="${esc(value)}">
      <div class="row2"><button class="btn" id="ask-no">Cancel</button><button class="btn primary" id="ask-yes">OK</button></div></div>`;
    layer.classList.add('open');
    const done = v => { closePopover(); resolve(v); };
    $('#ask-yes').onclick = () => done($('#ask-in').value.trim()); $('#ask-no').onclick = () => done(null);
    $('#ask-in').onkeydown = ev => { if (ev.key === 'Enter') { ev.preventDefault(); ev.stopPropagation(); done($('#ask-in').value.trim()); } };
    askConfirm.cancel = () => done(null);
    $('#ask-in').focus();
  });
}
function openImportText() {
  const layer = $('#popover');
  layer.innerHTML = `<div class="popover centered wide" role="dialog"><h3>Import as separate entries</h3>
    <div class="note">Paste text with <span class="mono">[YYYY-MM-DD HH:MM:SS]</span> headers and each becomes an inbox draft. Headerless text becomes one draft dated now.</div>
    <textarea id="imp-text" rows="10" placeholder="Paste here…"></textarea>
    <div class="row2"><button class="btn" id="ask-no">Cancel</button><button class="btn primary" id="ask-yes">Import</button></div></div>`;
  layer.classList.add('open');
  $('#ask-no').onclick = closePopover;
  askConfirm.cancel = closePopover;
  $('#ask-yes').onclick = async () => { const t = $('#imp-text').value; closePopover(); try { const n = await invoke('import_text', { text: t, nowTs: nowTs() }); await load(); toast(`${plural(n, 'draft')} added to the inbox`); if (S.mode === 'write') refreshChrome(); else render(); } catch (e) { fail(e); } };
  $('#imp-text').focus();
}
function closePopover() { const l = $('#popover'); l.classList.remove('open'); l.innerHTML = ''; }

/* ---------- lightbox ---------- */
function openLightbox(rel, url, owner) {
  const layer = $('#popover');
  layer.innerHTML = `<div class="lightbox" role="dialog" aria-label="Image"><img src="${url}" alt=""><div class="lb-bar"><span class="mono">${esc(rel.split('/').pop())}</span><span class="spacer"></span>${owner ? `<button class="btn" data-action="open-journal" data-file="${esc(owner.file)}" data-index="${owner.index}">Open entry</button>` : ''}<button class="btn" data-action="open-asset" data-rel="${esc(rel)}">Open in app</button><button class="btn" id="ask-no">Close</button></div></div>`;
  layer.classList.add('open');
  $('#ask-no').onclick = closePopover; askConfirm.cancel = closePopover;
}

/* ---------- a day on one page (jnl log) ---------- */
function renderDayPage(date) {
  const es = sorted([...filed().filter(e => e.date === date), ...inbox().filter(e => e.date === date)]).sort((a, b) => a.ts.localeCompare(b.ts));
  const wordsN = es.reduce((a, e) => a + e.words, 0);
  const prevD = [...new Set(filed().map(e => e.date))].filter(d => d < date).sort().pop();
  const nextD = [...new Set(filed().map(e => e.date))].filter(d => d > date).sort()[0];
  return `<section class="entry-pane" aria-label="Day">
    <div class="toolbar">
      ${S.narrow ? '<button class="btn" data-action="show-list">‹ List</button>' : ''}
      <button class="btn ghost" data-action="day-jump" data-day="${prevD || date}" ${prevD ? '' : 'disabled'} title="Earlier day">‹</button>
      <span style="font-size:14px;font-weight:600">${date === today() ? 'Today · ' : ''}${fmtDate(date)}</span>
      <button class="btn ghost" data-action="day-jump" data-day="${nextD || date}" ${nextD ? '' : 'disabled'} title="Later day">›</button>
      <span class="spacer"></span>
      <button class="btn" data-action="print-day-btn" data-day="${date}">Print day</button>
      <button class="btn primary" data-action="new" ${S.folderMissing ? 'disabled' : ''}>New entry</button>
    </div>
    <div class="page"><article class="sheet print-sheet day-page">
      ${es.length ? es.map(e => `<section class="day-entry">
        <div class="day-meta mono"><button class="daylink mono" data-action="open" data-file="${esc(e.file)}" data-index="${e.index}">${e.time}</button>${e.source === 'inbox' ? ' · draft' : ''}${e.starred ? ' · ★' : ''}</div>
        ${e.title ? `<h2>${esc(e.title)}</h2>` : ''}
        <div class="prose" data-file="${esc(e.file)}" data-index="${e.index}">${renderProse(e.body, e.file)}</div></section>`).join('') : '<p class="empty-note">Nothing written this day.</p>'}
    </article></div>
    <div class="statusbar"><span class="mono">${es.length} entr${es.length === 1 ? 'y' : 'ies'} · ${wordsN} words</span><span class="spacer"></span><span class="mono">${esc(dayFile(date))}</span></div>
  </section>`;
}

/* ---------- drop and paste attachments ---------- */
async function attachPaths(paths) {
  if (S.mode !== 'write' || !S.draft) { toast('Open a draft first, then drop files onto it'); return; }
  const d = S.draft;
  for (const p of paths) {
    const link = await invoke('attach_file', { src: p, ts: d.ts, entryFile: d.ref ? d.ref.file : 'inbox' });
    if (S.draft !== d) { toast('Attached, but the draft was closed first'); return; }
    insertAtCaret(link);
  }
  toast(paths.length === 1 ? 'Attached' : `Attached ${paths.length}`);
}
/* ---------- window chrome ----------
   As in Wander: on Linux and Windows the window has no bar of its own, so the
   top bar is the drag region and carries the controls. Close goes through
   onCloseRequested so the last edit reaches the disk first. */
const appWindow = T.window.getCurrentWindow();
function setChrome(custom) {
  S.customChrome = !!custom;
  if (custom) document.documentElement.dataset.chrome = 'custom'; else delete document.documentElement.dataset.chrome;
}
async function syncMaximised() { try { document.documentElement.dataset.maximised = String(await appWindow.isMaximized()); } catch {} }
document.querySelectorAll('[data-window]').forEach(b => b.addEventListener('click', () => {
  const a = b.dataset.window;
  if (a === 'minimise') appWindow.minimize();
  if (a === 'maximise') appWindow.toggleMaximize();
  if (a === 'close') appWindow.close();
}));
// Our own drag region rather than Tauri's data-tauri-drag-region: that one
// starts the move on the first mousedown, which hands the pointer to the window
// manager and swallows the second click, so double-click-to-maximise never
// fires on Linux. Here the move starts only once the pointer travels 4px, and a
// double-click toggles maximise. Only the bare bar counts, not its buttons.
let dragFrom = null;
document.addEventListener('mousedown', ev => {
  if (!S.customChrome || ev.button !== 0 || !ev.target.closest('[data-drag]') || ev.target.closest('button, a, input, select, textarea')) return;
  if (ev.detail === 2) { dragFrom = null; appWindow.toggleMaximize(); return; }
  dragFrom = { x: ev.screenX, y: ev.screenY };
});
document.addEventListener('mousemove', ev => {
  if (!dragFrom || !(ev.buttons & 1)) { dragFrom = null; return; }
  if (Math.abs(ev.screenX - dragFrom.x) + Math.abs(ev.screenY - dragFrom.y) > 4) { dragFrom = null; appWindow.startDragging(); }
});
document.addEventListener('mouseup', () => { dragFrom = null; });
invoke('undecorated').then(c => { S.chromeAvail = true; setChrome(c); syncMaximised(); }).catch(() => {});
appWindow.onResized(() => syncMaximised());
appWindow.onCloseRequested(async ev => {
  ev.preventDefault();
  // Never lose the last edit: save drafts and edited filed entries; if that fails, ask before closing.
  let ok = true;
  if (S.mode === 'write' && S.draft) {
    ok = await flushDraft(S.draft);
    if (ok === 'stay') return;
    if (!ok) ok = await askConfirm('Couldn’t save — discard changes?', 'Discard');
  }
  if (ok) await appWindow.destroy();
});

T.event.listen('tauri://drag-drop', ev => { const paths = ev.payload?.paths || []; if (paths.length) attachPaths(paths).catch(fail); });
// WebKitGTK fires no paste event at all when the clipboard holds only an
// image. So Ctrl+V in the body also starts a short timer: if no paste event
// has arrived by then, ask the back end for the clipboard image.
let pasteSeen = false;
document.addEventListener('keydown', ev => {
  if (!(ev.ctrlKey && !ev.shiftKey && !ev.altKey && ev.key.toLowerCase() === 'v')) return;
  if (S.mode !== 'write' || document.activeElement?.id !== 'bodyta' || S.folderMissing) return;
  pasteSeen = false;
  const d = S.draft;
  setTimeout(async () => {
    if (pasteSeen || !d) return;
    try {
      const link = await invoke('paste_image', { ts: d.ts, entryFile: d.ref ? d.ref.file : 'inbox' });
      if (!link) return;
      if (S.draft === d && S.mode === 'write') { insertAtCaret(link); toast('Image attached'); }
      else { navigator.clipboard?.writeText(link).catch(() => {}); toast('Image saved; link copied'); }
    } catch (e) { fail(e); }
  }, 150);
}, true);
document.addEventListener('paste', async ev => {
  if (S.mode !== 'write' || document.activeElement?.id !== 'bodyta') return;
  pasteSeen = true;
  const item = [...(ev.clipboardData?.items || [])].find(i => i.type.startsWith('image/'));
  const blob0 = item && item.getAsFile();
  const hasText = [...(ev.clipboardData?.types || [])].some(t => t.startsWith('text/'));
  if (!blob0) {
    // WebKitGTK often won't give the page clipboard images: ask the back end.
    if (hasText) return;
    ev.preventDefault();
    const d = S.draft; if (!d) return;
    try {
      const link = await invoke('paste_image', { ts: d.ts, entryFile: d.ref ? d.ref.file : 'inbox' });
      if (!link) return;
      if (S.draft === d && S.mode === 'write') { insertAtCaret(link); toast('Image attached'); }
      else { navigator.clipboard?.writeText(link).catch(() => {}); toast('Image saved; link copied'); }
    } catch (e) { fail(e); }
    return;
  }
  ev.preventDefault();
  const d = S.draft; // the draft the paste landed in, before anything async
  const blob = blob0; if (!d) return;
  const MIME_EXT = { 'image/jpeg': 'jpg', 'image/jpg': 'jpg', 'image/svg+xml': 'svg', 'image/png': 'png', 'image/gif': 'gif', 'image/webp': 'webp', 'image/heic': 'heic', 'image/heif': 'heif', 'image/avif': 'avif', 'image/bmp': 'bmp', 'image/tiff': 'tiff' };
  const ext = MIME_EXT[blob.type] || (blob.type.split('/')[1] || '').replace(/[^a-z0-9]/gi, '') || 'png';
  try {
    const b64 = await new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(r.result); r.onerror = () => rej(r.error); r.readAsDataURL(blob); });
    const link = await invoke('attach_bytes', { name: `pasted.${ext}`, bytesB64: b64, ts: d.ts, entryFile: d.ref ? d.ref.file : 'inbox' });
    if (S.draft === d && S.mode === 'write') { insertAtCaret(link); toast('Image attached'); }
    else { await navigator.clipboard.writeText(link).catch(() => {}); toast('Image attached — the link is on the clipboard'); }
  } catch (e) { fail(e); }
});

/* ---------- lock ---------- */
function renderLock() {
  return `<div class="lockveil"><div class="lockbox"><span style="color:var(--accent)">${icon.lock}</span><h1>Quire is locked</h1>
    <input id="pin" type="password" inputmode="numeric" placeholder="PIN" autocomplete="off" aria-label="PIN"><button class="btn primary" data-action="unlock">Unlock</button><div class="note" id="pin-note"></div></div></div>`;
}
async function tryUnlock() {
  const ok = await invoke('pin_check', { pin: $('#pin')?.value || '' });
  if (ok) { S.locked = false; render(); } else { $('#pin-note').textContent = 'Wrong PIN'; $('#pin').value = ''; $('#pin').focus(); }
}
async function lockNow() { if (!S.ui.pinHash) return toast('Set a PIN in Settings › Privacy first'); if (S.mode === 'write' && !(await leaveWrite())) return; S.locked = true; render(); $('#pin')?.focus(); }

/* ---------- Look back ---------- */
function renderLookBack() {
  const all = filed();
  const days = new Map();
  all.forEach(e => days.set(e.date, (days.get(e.date) || 0) + e.words));
  const dates = [...days.keys()].sort();
  const has = d => days.has(d);
  let cur = 0; const t = new Date(); if (!has(isoOf(t))) t.setDate(t.getDate() - 1);
  while (has(isoOf(t))) { cur++; t.setDate(t.getDate() - 1); }
  let longest = 0, run = 0, prev = null;
  // Math.round: local-noon dates are 23 or 25 hours apart across a DST change.
  for (const d of dates) { const dt = dateObj(d); run = prev && Math.round((dt - prev) / 864e5) === 1 ? run + 1 : 1; longest = Math.max(longest, run); prev = dt; }
  const Y = S.year;
  const yearEntries = all.filter(e => e.date.startsWith(String(Y)));
  const yWords = yearEntries.reduce((a, e) => a + e.words, 0);
  const yDays = new Set(yearEntries.map(e => e.date)).size;
  const years = [...new Set(dates.map(d => +d.slice(0, 4)))].sort((a, b) => b - a);
  if (!years.includes(new Date().getFullYear())) years.unshift(new Date().getFullYear());
  const vals = [...days.entries()].filter(([d]) => d.startsWith(String(Y))).map(([, w]) => w).sort((a, b) => a - b);
  const q = p => vals.length ? vals[Math.floor(p * (vals.length - 1))] : 0;
  const cuts = [q(.25), q(.5), q(.75)];
  const lv = w => !w ? 0 : w <= cuts[0] ? 1 : w <= cuts[1] ? 2 : w <= cuts[2] ? 3 : 4;
  const shades = ['var(--heat0)', 'color-mix(in srgb, var(--accent) 22%, var(--card))', 'color-mix(in srgb, var(--accent) 45%, var(--card))', 'color-mix(in srgb, var(--accent) 72%, var(--card))', 'var(--accent)'];
  const jan1 = new Date(Y, 0, 1), off = (jan1.getDay() + 6) % 7;
  let cells = '<span class="blank"></span>'.repeat(off);
  const end = new Date(Y, 11, 31), tdy = today();
  for (let d = new Date(jan1); d <= end; d.setDate(d.getDate() + 1)) {
    const k = isoOf(d);
    if (k > tdy) { cells += '<span class="future"></span>'; continue; }
    const w = days.get(k) || 0;
    cells += `<button class="heatcell" data-action="day-jump" data-day="${k}" title="${fmtDayYear(k)}: ${w} words" style="background:${shades[lv(w)]}" ${w ? '' : 'disabled'}></button>`;
  }
  const mw = Array(12).fill(0); yearEntries.forEach(e => mw[+e.date.slice(5, 7) - 1] += e.words);
  const mmax = Math.max(1, ...mw), lastM = Y === new Date().getFullYear() ? new Date().getMonth() : 11;
  const bars = mw.map((w, i) => `<div class="b ${i === lastM ? 'hi' : ''}" title="${w} words"><span>${w ? short(w) : ''}</span><i style="height:${Math.round(w / mmax * 110)}px"></i><span>${'JFMAMJJASOND'[i]}</span></div>`).join('');
  const wd = Array(7).fill(0); all.forEach(e => wd[(dateObj(e.date).getDay() + 6) % 7]++);
  const wmax = Math.max(1, ...wd);
  const wbars = wd.map((n, i) => `<div class="b ${n === wmax ? 'hi' : ''}"><span>${n || ''}</span><i style="height:${Math.round(n / wmax * 110)}px"></i><span>${'MTWTFSS'[i]}</span></div>`).join('');
  const hours = Array(24).fill(0); all.forEach(e => hours[+e.time.slice(0, 2)]++);
  const hmax = Math.max(1, ...hours);
  const hbars = hours.map((n, i) => `<div class="b ${n === hmax ? 'hi' : ''}" title="${n} at ${pad(i)}:00"><i style="height:${Math.round(n / hmax * 70)}px"></i><span>${i % 6 === 0 ? pad(i) : ''}</span></div>`).join('');
  const tags = countTags(yearEntries).slice(0, 6), tmax = Math.max(1, ...tags.map(x => x[1]));
  const md = today().slice(5);
  const otd = byNewest(all.filter(e => e.date.slice(5) === md && e.date < today()));
  // Year in review
  let yLongest = 0, yRun = 0, yPrev = null;
  for (const d of [...new Set(yearEntries.map(e => e.date))].sort()) { const dt = dateObj(d); yRun = yPrev && Math.round((dt - yPrev) / 864e5) === 1 ? yRun + 1 : 1; yLongest = Math.max(yLongest, yRun); yPrev = dt; }
  const longestEntry = yearEntries.reduce((a, e) => !a || e.words > a.words ? e : a, null);
  const firstE = [...yearEntries].sort((a, b) => a.ts.localeCompare(b.ts))[0], lastE = byNewest(yearEntries)[0];
  const starredN = yearEntries.filter(e => e.starred).length, mediaN = yearEntries.filter(e => mediaOf(e).length).length;
  const bestMonth = mw.indexOf(Math.max(...mw));
  const link = e => e ? `<button class="daylink" data-action="open-journal" data-file="${esc(e.file)}" data-index="${e.index}">${esc(e.title || firstLine(e.body) || 'Untitled')}</button>` : '—';
  if (!S.sizes && !S.folderMissing) invoke('sizes_cmd').then(s => { S.sizes = s; if (S.view === 'lookback') { const el = $('#sizes'); if (el) el.innerHTML = sizesHtml(); } }).catch(() => {});
  if (!S.statsExtra && !S.folderMissing) invoke('stats_extra').then(s => { S.statsExtra = s; if (S.view === 'lookback') { const el = $('#stats-extra'); if (el) el.innerHTML = statsExtraHtml(); } }).catch(() => {});
  return `<div class="lookback">
    <div class="col">
      <div style="display:flex;justify-content:space-between;align-items:center"><h1>${Y === new Date().getFullYear() ? `${Y} so far` : Y}</h1>
        <select class="picker" data-input="year" aria-label="Year">${years.map(y => `<option ${y === Y ? 'selected' : ''}>${y}</option>`).join('')}</select></div>
      <div class="tiles">
        <div class="tile"><span class="v acc">${cur}</span><span class="l">day streak${cur === longest && cur > 1 ? ' · a record' : ''}</span></div>
        ${cur !== longest ? `<div class="tile"><span class="v">${longest}</span><span class="l">longest streak</span></div>` : ''}
        <div class="tile sep"><span class="v">${yDays}</span><span class="l">days written in ${Y}</span></div>
        <div class="tile"><span class="v">${short(yWords)}</span><span class="l">words in ${Y}</span></div>
        <div class="tile"><span class="v">${yDays ? Math.round(yWords / yDays) : 0}</span><span class="l">words a day</span></div>
      </div>
      <div class="panel"><h2>Words per day</h2><div class="heat">${cells}</div><div class="heat-months">${Array.from({ length: 12 }, (_, i) => `<span style="left:${Math.round((new Date(Y, i, 1) - jan1) / 864e5 + off) / 7 * 14}px">${'JFMAMJJASOND'[i]}</span>`).join('')}</div><span class="legend">less ${shades.map(s => `<i style="background:${s}"></i>`).join('')} more</span></div>
      <div class="two">
        <div class="panel"><h2>Words per month</h2><div class="bars" style="grid-template-columns:repeat(12,minmax(0,1fr))">${bars}</div></div>
        <div class="panel"><h2>Entries by weekday</h2><div class="bars" style="grid-template-columns:repeat(7,minmax(0,1fr))">${wbars}</div></div>
      </div>
      <div class="panel"><h2>Entries by hour</h2><div class="bars small" style="grid-template-columns:repeat(24,minmax(0,1fr));height:95px">${hbars}</div></div>
      <div class="panel"><h2>Top tags in ${Y}</h2>${tags.map(([tg, n]) => `<div class="tagbar"><button class="chip" data-action="tag-jump" data-tag="${esc(tg)}">${esc(tg)}</button><div class="track"><div class="fill" style="width:${Math.round(n / tmax * 100)}%"></div></div><span class="n">${n}</span></div>`).join('') || '<div class="empty-note">No tags this year.</div>'}</div>
      <div class="panel review"><h2>${Y} in review</h2>
        <div class="kv"><span>Entries</span><b>${yearEntries.length}</b><span>Days written</span><b>${yDays}</b><span>Words</span><b>${yWords.toLocaleString('en-GB')}</b><span>Longest streak</span><b>${yLongest} day${yLongest === 1 ? '' : 's'}</b>
        <span>Best month</span><b>${mw[bestMonth] ? new Date(Y, bestMonth, 1).toLocaleDateString('en-GB', { month: 'long' }) + ' · ' + short(mw[bestMonth]) + ' words' : '—'}</b>
        <span>Longest entry</span><b>${longestEntry ? `${link(longestEntry)} · ${longestEntry.words} words` : '—'}</b>
        <span>First entry</span><b>${firstE ? fmtDayYear(firstE.date) + ' · ' : ''}${link(firstE)}</b><span>Latest entry</span><b>${lastE ? fmtDayYear(lastE.date) + ' · ' : ''}${link(lastE)}</b>
        <span>Starred</span><b>${starredN}</b><span>With media</span><b>${mediaN}</b></div></div>
    </div>
    <div class="col">
      <span class="eyebrow" style="padding-top:12px">On this day</span>
      ${otd.length ? otd.slice(0, 4).map(e => `<button class="card" data-action="open-journal" data-file="${esc(e.file)}" data-index="${e.index}"><span class="sub mono">${fmtDayYear(e.date)}</span><span class="title">${esc(e.title || firstLine(e.body))}</span>${e.title ? `<span class="sub">${esc(firstLine(e.body))}</span>` : ''}</button>`).join('') : '<div class="empty-note">Nothing on this day in earlier years.</div>'}
      <button class="daylink" data-action="random" style="font-family:var(--writing);font-size:19px;color:var(--ink)">A random entry <span style="color:var(--accent)">→</span> <span class="k mono" style="font-size:11px;color:var(--muted)">Ctrl+R</span></button>
      <div class="panel"><h2>All time</h2>
        <div class="sub" style="font-size:13px;color:var(--muted);line-height:1.6">${all.length} entries over ${days.size} days · ${short(all.reduce((a, e) => a + e.words, 0))} words · since ${dates[0] ? fmtDayYear(dates[0]) : '—'}</div></div>
      <div class="panel review"><h2>Library</h2><div id="stats-extra">${statsExtraHtml()}</div></div>
      <div class="panel"><h2>Storage</h2><div id="sizes">${sizesHtml()}</div></div>
    </div>
  </div>`;
}
function statsExtraHtml() {
  const x = S.statsExtra; if (!x) return '<div class="empty-note">Counting…</div>';
  const ld = x.longest_day || {}, loc = x.sizes_by_location || {};
  const locs = [['Inbox', loc.inbox], ['Journal', loc.journal], ['Split journals', loc.splits], ['Media', loc.media]].filter(r => r[1] != null);
  const mx = Math.max(1, ...locs.map(r => r[1] || 0));
  return `<div class="kv">
      <span>Drafts</span><b>${x.drafts ?? 0}</b>
      <span>Tags</span><b>${x.tags ?? 0}</b>
      <span>Split journals</span><b>${x.splits ?? 0}</b>
      <span>Words per entry</span><b>${(+x.avg_words_per_entry || 0).toLocaleString('en-GB', { maximumFractionDigits: 1 })} <small style="color:var(--muted)">average</small></b>
      <span>Longest day</span><b>${ld.date ? `<button class="daylink" data-action="day-jump" data-day="${esc(ld.date)}">${esc(fmtDate(ld.date))}</button> · ${(ld.words || 0).toLocaleString('en-GB')} words` : '—'}</b>
    </div>
    ${locs.length ? `<div class="loc-sizes">${locs.map(([l, b]) => `<div class="tagbar"><span style="font-size:13px">${l}</span><div class="track"><div class="fill" style="width:${Math.round((b || 0) / mx * 100)}%"></div></div><span class="n">${bytes(b || 0)}</span></div>`).join('')}</div>` : ''}`;
}
function sizesHtml() {
  const s = S.sizes; if (!s) return '<div class="empty-note">Measuring…</div>';
  const rows = [['Text', s.text], ['Images', s.image], ['Video', s.video], ['Audio', s.audio], ['Other files', s.other]].filter(x => x[1]);
  const mx = Math.max(1, ...rows.map(x => x[1]));
  return rows.map(([l, b]) => `<div class="tagbar"><span style="font-size:13px">${l}</span><div class="track"><div class="fill" style="width:${Math.round(b / mx * 100)}%"></div></div><span class="n">${bytes(b)}</span></div>`).join('');
}

/* ---------- Settings ---------- */
function renderSettings() {
  const sw = (k, label, note) => `<div class="srow"><div class="lbl"><span>${label}</span>${note ? `<span class="note">${note}</span>` : ''}</div><button class="switch" role="switch" aria-checked="${!!S.ui[k]}" aria-label="${label}" data-action="toggle" data-k="${k}"></button></div>`;
  const seg = (k, label, opts, note) => `<div class="srow"><div class="lbl"><span>${label}</span>${note ? `<span class="note">${note}</span>` : ''}</div><div class="seg">${opts.map(([v, l]) => `<button data-action="set" data-k="${k}" data-v="${v}" aria-pressed="${S.ui[k] == v}">${l}</button>`).join('')}</div></div>`;
  const theme = ([id, name, bg, ink, acc, w]) => `<button class="theme-card" data-action="set" data-k="theme" data-v="${id}" aria-pressed="${S.ui.theme === id}"><div class="pv${id.startsWith('marathon') ? ' pv-marathon' : ''}" style="background:${bg};color:${ink}"><b style="font-weight:${w}">Aa</b><i style="background:${acc}"></i><small>The rain stopped around six…</small></div><span class="nm">${name}${S.ui.theme === id ? ' ✓' : ''}</span></button>`;
  const tpl = S.tplEdit !== null ? S.templates.find(t => t.name === S.tplEdit) : null;
  const splitNote = { env: 'Currently from the JNL_SPLIT_TAGS environment variable.', 'jnl config': 'Currently from jnl’s config file (JNL_SPLIT_TAGS).' }[S.splitSource] || '';
  return `<div class="settings">
    <nav aria-label="Settings sections"><h1>Settings</h1>
      <a href="#s-folder">Folder</a><a href="#s-templates">Templates</a><a href="#s-appearance">Appearance</a><a href="#s-display">Display</a><a href="#s-writing">Writing</a><a href="#s-reminder">Reminder</a><a href="#s-privacy">Privacy</a><a href="#s-backup">Backup</a><a href="#s-media">Media</a><a href="#s-maint">Maintenance</a><a href="#s-keys">Keyboard</a><a href="#s-about">About</a></nav>
    <main>
      <section id="s-folder"><h2>Folder</h2>
        ${S.isSample ? '<div class="banner">Quire is using its sample journal. Point it at a <b>copy</b> of your JNL_DIR to try it on real entries — it writes jnl-format files, but it’s a prototype.</div>' : ''}
        <div class="srow"><div class="lbl"><span>Journal folder</span><span class="path">${esc(S.folder)}</span></div>
          <button class="btn" data-action="pick-folder">Choose…</button><button class="btn ghost" data-action="open-folder">Show</button>${S.isSample ? '' : '<button class="btn ghost" data-action="use-sample">Use sample</button>'}</div>
        ${S.jnlDir && S.jnlDir !== S.folder ? `<div class="srow"><div class="lbl"><span>jnl’s folder</span><span class="note">JNL_DIR is set to <span class="path">${esc(S.jnlDir)}</span>. Point Quire at a copy of it first; use it directly once you trust it.</span></div><button class="btn ghost" data-action="use-jnl-dir">Use it</button></div>` : ''}
        <div class="srow"><div class="lbl"><span>Or paste a path</span><span class="note">~ is expanded</span></div><input id="pathin" class="picker" style="width:280px;padding:0 10px" placeholder="/home/you/notes"><button class="btn" data-action="set-path">Use</button></div>
        <div class="srow"><div class="lbl"><span>Split tags</span><span class="note">Filing a draft with one of these @tags writes it to <span class="mono">&lt;tag&gt;.md</span> instead of the day, as jnl’s JNL_SPLIT_TAGS does. ${splitNote}</span></div><input id="splitin" class="picker" style="width:220px;padding:0 10px" value="${esc(S.splitTags.join(' '))}" placeholder="work private"><button class="btn" data-action="set-split">Save</button></div>
      </section>
      <section id="s-templates"><h2>Templates</h2>
        <div class="note" style="margin-bottom:8px">Markdown files in <span class="mono">.quire/templates/</span>, inserted from the composer’s ⋯ menu. <span class="mono">{{date}}</span>, <span class="mono">{{time}}</span> and <span class="mono">{{weekday}}</span> fill in on insert.</div>
        <div class="tpl"><div class="tpl-list">${S.templates.map(t => `<button class="row ${S.tplEdit === t.name ? 'sel' : ''}" data-action="tpl-edit" data-name="${esc(t.name)}"><span class="t">${esc(t.name)}</span><span class="ex">${esc(firstLine(t.body))}</span></button>`).join('') || '<div class="empty-note">No templates yet.</div>'}<button class="btn ghost" data-action="tpl-new">+ New template</button></div>
        ${tpl ? `<div class="tpl-edit"><div style="display:flex;gap:10px;align-items:center"><input id="tpl-name" class="picker" style="flex-grow:1;padding:0 10px" value="${esc(tpl.name)}"><button class="btn ghost danger" data-action="tpl-delete">Delete</button></div><textarea id="tpl-body" rows="12">${esc(tpl.body)}</textarea><div style="display:flex;gap:14px"><button class="btn primary" data-action="tpl-save">Save template</button><button class="btn" data-action="tpl-close">Close</button></div></div>` : ''}</div>
      </section>
      <section id="s-appearance"><h2>Appearance</h2>
        <div class="themes">${THEMES.map(theme).join('')}</div>
        <div class="srow"><div class="lbl"><span>Accent</span><span class="note">The theme’s own, or one of Nook’s eight</span></div><div class="swatches">
          ${Object.entries(ACCENTS).map(([k, c]) => `<button class="swatch" data-action="set" data-k="accent" data-v="${k}" aria-pressed="${S.ui.accent === k}" aria-label="${k}" title="${k}" style="background:${c || 'conic-gradient(#8E2F1C 0 33%, #111 0 66%, #E08A6B 0)'}"></button>`).join('')}</div></div>
        ${seg('font', 'Writing font', [['serif', 'Serif'], ['sans', 'Sans'], ['system', 'System'], ['mono', 'Mono']])}
        ${seg('size', 'Text size', [['s', 'S'], ['m', 'M'], ['l', 'L'], ['xl', 'XL']])}
        ${sw('autoDark', 'Go dark when the system is dark', 'Cinema for most themes; Marathon Day switches to Marathon')}
        ${sw('grouped', 'Group lists by date')}
        ${S.chromeAvail ? `<div class="srow"><div class="lbl"><span>Use the system title bar</span><span class="note">Off: Quire draws its own minimise, maximise and close in the top bar, which doubles as the drag handle. On: your desktop's bar and buttons.</span></div><button class="switch" role="switch" aria-checked="${!S.customChrome}" aria-label="Use the system title bar" data-action="system-titlebar"></button></div>` : ''}
      </section>
      <section id="s-display"><h2>Display</h2>
        ${seg('dateFormat', 'Date format', [['weekday', 'Weekday'], ['medium', 'Medium'], ['long', 'Long'], ['iso', 'ISO']], `List headings and day pages. Today reads “${esc(fmtDate(today()))}”`)}
        ${seg('weekStart', 'Calendar starts on', [['mon', 'Monday'], ['sun', 'Sunday'], ['sat', 'Saturday']])}
        ${sw('weekNumbers', 'Show week numbers', 'ISO week numbers down the side of the calendar')}
        ${sw('highlightTags', 'Highlight @tags', 'In the accent colour, while reading and writing')}
      </section>
      <section id="s-writing"><h2>Writing</h2>
        ${sw('focusDims', 'Focus dims other paragraphs')}
        ${sw('typewriter', 'Typewriter scrolling in Focus', 'Keeps the line you’re writing mid-screen')}
        ${sw('prompts', 'Prompts in an empty composer', 'Nook’s prompt deck; ↻ for another')}
        ${sw('autoPromote', 'Use the first line as the title when filing', 'For drafts without a title')}
        ${sw('goalOn', 'Daily word goal', 'Counts everything dated today')}
        ${seg('goal', 'Goal', [[100, '100'], [250, '250'], [500, '500'], [750, '750'], [1000, '1000']])}
        ${seg('timerMins', 'Timer', [[5, '5 min'], [10, '10'], [15, '15'], [25, '25'], [45, '45']])}
        ${sw('chime', 'Chime when the timer ends')}
      </section>
      <section id="s-reminder"><h2>Reminder</h2>
        ${sw('reminderOn', 'Daily reminder', 'A system notification while Quire is running, and a line on Today afterwards if nothing’s written')}
        <div class="srow"><div class="lbl"><span>Time</span></div><input type="time" id="remind-time" class="picker" value="${esc(S.ui.reminderTime)}" data-input="reminderTime"></div>
      </section>
      <section id="s-privacy"><h2>Privacy</h2>
        ${sw('lockOn', 'Lock on launch', 'Asks for the PIN when Quire opens. Ctrl+L locks now.')}
        <div class="srow"><div class="lbl"><span>PIN</span><span class="note">${S.ui.pinHash ? 'A PIN is set.' : 'No PIN yet.'} This keeps a glance away, not an attacker: the files stay plain markdown.</span></div><button class="btn" data-action="set-pin">${S.ui.pinHash ? 'Change PIN' : 'Set PIN'}</button>${S.ui.pinHash ? '<button class="btn ghost" data-action="clear-pin">Remove</button>' : ''}</div>
      </section>
      ${backupSectionHtml()}
      ${mediaSectionHtml()}
      <section id="s-maint"><h2>Maintenance</h2>
        <div class="srow"><div class="lbl"><span>Clean up</span><span class="note">Normalises … and straight quotes, reorders days by time, removes exact duplicates, and moves entries matching a split tag into their file. jnl’s <span class="mono">cleanup</span>, plus Nook’s dedupe.</span></div><button class="btn" data-action="cleanup">Clean up</button></div>
        <div class="srow"><div class="lbl"><span>Sort inbox by date</span></div><button class="btn" data-action="sort-inbox">Sort</button></div>
        <div class="srow"><div class="lbl"><span>Merge ex-split journals into journal</span><span class="note">Root <span class="mono">&lt;name&gt;.md</span> journals that are no longer split tags: their entries go back into their days, and emptied files are removed</span></div><button class="btn" data-action="merge-ex-split">Merge…</button></div>
        ${S.conflicts.length ? `<div class="srow"><div class="lbl"><span>Sync conflicts · ${S.conflicts.length}</span><span class="note">Copies a sync tool left beside a journal file. Merge adds the entries the main file is missing, sorts it, then deletes the copy.</span></div></div>
        <div class="conflicts">${S.conflicts.map(c => `<div class="srow"><div class="lbl"><span class="path">${esc(c)}</span></div><button class="btn" data-action="merge-conflict" data-rel="${esc(c)}">Merge</button></div>`).join('')}</div>` : ''}
        <div class="srow"><div class="lbl"><span>Clear orphan media</span><span class="note">Deletes files in assets/ that no entry links to</span></div><button class="btn" data-action="clear-orphans">Check…</button></div>
        <div class="srow"><div class="lbl"><span>Export</span><span class="note">Every filed entry, in order, as one markdown file</span></div><button class="btn" data-action="export">Export…</button></div>
        <div class="srow"><div class="lbl"><span>Import a markdown folder</span><span class="note">Dated .md/.txt files (Obsidian daily notes work); files already in jnl format keep their entries</span></div><button class="btn" data-action="import-md">Choose folder…</button></div>
        <div class="srow"><div class="lbl"><span>Import from Day One</span><span class="note">An unzipped JSON export; photos beside it come across into assets/</span></div><button class="btn" data-action="import-dayone">Choose…</button></div>
        <div class="srow"><div class="lbl"><span>File transfer.md</span><span class="note">jnl’s batch file: entries in it are filed straight into their days</span></div><button class="btn" data-action="file-transfer" ${S.hasTransfer ? '' : 'disabled'}>${S.hasTransfer ? 'File now' : 'Empty'}</button></div>
        <div class="srow"><div class="lbl"><span>Tag review</span><span class="note">Finds tags that differ only by case or one letter and merges the ones you choose</span></div><button class="btn" data-action="tag-review">Review…</button></div>
        <div id="tag-review">${tagReviewHtml()}</div>
      </section>
      <section id="s-keys"><h2>Keyboard</h2><div class="keys">
        <span><kbd>Ctrl</kbd> <kbd>N</kbd></span><span>New entry</span>
        <span><kbd>Ctrl</kbd> <kbd>J</kbd></span><span>File the draft to its day</span>
        <span><kbd>Ctrl</kbd> <kbd>S</kbd></span><span>Save</span>
        <span><kbd>Ctrl</kbd> <kbd>↵</kbd></span><span>Save &amp; start a new draft</span>
        <span><kbd>Ctrl</kbd> <kbd>B</kbd> / <kbd>I</kbd> / <kbd>\`</kbd></span><span>Bold · italic · code around the selection</span>
        <span><kbd>↵</kbd> in a list</span><span>Continues “- ”, “1. ” and “- [ ]” lists; ↵ on an empty item ends it</span>
        <span><kbd>↹</kbd> in a list</span><span>Indents the item (<kbd>Shift</kbd> <kbd>↹</kbd> outdents); a multi-line selection indents every line. Elsewhere ↹ moves focus</span>
        <span><kbd>@</kbd></span><span>Tag autocomplete; ↹ or ↵ accepts</span>
        <span><kbd>Ctrl</kbd> <kbd>Alt</kbd> <kbd>F</kbd></span><span>Focus</span>
        <span><kbd>Ctrl</kbd> <kbd>Shift</kbd> <kbd>F</kbd></span><span>Search the journal</span>
        <span><kbd>Ctrl</kbd> <kbd>T</kbd></span><span>Date &amp; time</span>
        <span><kbd>Ctrl</kbd> <kbd>R</kbd></span><span>Random entry</span>
        <span><kbd>Ctrl</kbd> <kbd>P</kbd></span><span>Print the open entry</span>
        <span><kbd>Ctrl</kbd> <kbd>L</kbd></span><span>Lock</span>
        <span><kbd>Ctrl</kbd> <kbd>1</kbd>–<kbd>5</kbd></span><span>Today · Inbox · Journal · Starred · Look back</span>
        <span><kbd>Ctrl</kbd> <kbd>,</kbd></span><span>Settings</span>
        <span><kbd>↑</kbd> <kbd>↓</kbd> <kbd>↵</kbd></span><span>Move through a list · open / edit</span>
        <span><kbd>Esc</kbd></span><span>Leave focus · stop editing · clear selection</span>
        <span><kbd>Ctrl</kbd> <kbd>[</kbd></span><span>Back: like Esc while writing · otherwise back to the list</span>
      </div></section>
      <section id="s-about"><h2>About</h2>
        <p style="font-size:14px;line-height:1.6;color:var(--muted);max-width:640px">Quire 0.7 reads and writes the jnl format: <span class="mono">journal/YYYY/MM/DD.md</span>, split journals and, for drafts, <span class="mono">inbox/YYYY/MM/DD.md</span> (an <span class="mono">inbox.md</span> left by jnl or Nook is folded in on open, the original kept under <span class="mono">.quire/migration/</span>), with atomic writes like jnl. Quire’s own extras live in <span class="mono">.quire/</span> (templates, saved searches) and <span class="mono">assets/</span> (media); jnl ignores both. Not here: voice recording and transcription, iCloud sync, widgets, the phone and desk mode. Themes beyond Nook’s and Quire’s own need Wander’s source.</p>
        <p style="font-size:13px;color:var(--muted)"><button class="btn ghost" data-action="welcome">Show the welcome note again</button></p>
      </section>
    </main></div>`;
}
function backupListHtml() {
  if (!S.backupDir) return '';
  if (S.backups === null) return '<div class="empty-note">Reading backups…</div>';
  if (!S.backups.length) return '<div class="empty-note">No backups in that folder yet.</div>';
  return `<div class="group-label"><span>Backups</span></div><div class="rows">${S.backups.slice(0, 8).map(b => `<div class="srow" style="padding:6px 0"><span class="mono" style="font-size:13px">${esc(b)}</span><span class="spacer"></span><button class="btn ghost" data-action="restore" data-name="${esc(b)}">Restore…</button></div>`).join('')}</div>`;
}
function backupSectionHtml() {
  if (S.backups === null && S.backupDir) invoke('backups').then(b => { S.backups = b; const el = $('#backup-list'); if (el) el.innerHTML = backupListHtml(); }).catch(() => { S.backups = []; });
  const last = S.backupRunning ? 'Backing up…' : S.lastBackup ? `${fmtDate(S.lastBackup.slice(0, 10))} ${S.lastBackup.slice(11, 16)}` : 'Never';
  const iv = [['off', 'Off'], ['daily', 'Daily'], ['weekly', 'Weekly'], ['change', 'On every change']];
  const note = { off: 'Only when you press Back up now', daily: 'When Quire opens or comes back to the front, if a day has passed', weekly: 'When Quire opens or comes back to the front, if a week has passed', change: '30 seconds after your last change, at most once every five minutes' }[S.backupInterval] || '';
  return `<section id="s-backup"><h2>Backup</h2>
    <div class="srow"><div class="lbl"><span>Backup folder</span><span class="path">${esc(S.backupDir || 'Not set')}</span></div><button class="btn" data-action="pick-backup">Choose…</button>${S.backupDir ? `<button class="btn primary" data-action="backup-now" ${S.backupRunning ? 'disabled' : ''}>Back up now</button>` : ''}</div>
    <div class="srow"><div class="lbl"><span>Automatic</span><span class="note">${note}</span></div><div class="seg" role="group" aria-label="Automatic backup">${iv.map(([v, l]) => `<button data-action="backup-interval" data-v="${v}" aria-pressed="${S.backupInterval === v}">${l}</button>`).join('')}</div></div>
    <div class="srow"><div class="lbl"><span>Keep last ${S.backupKeep}</span><span class="note">Older Quire backups are pruned; Nook’s are never touched</span></div><div class="stepper" role="group" aria-label="Backups to keep"><button class="btn" data-action="backup-keep" data-d="-1" aria-label="Keep fewer" ${S.backupKeep <= 1 ? 'disabled' : ''}>−</button><span class="mono" aria-live="polite">${S.backupKeep}</span><button class="btn" data-action="backup-keep" data-d="1" aria-label="Keep more" ${S.backupKeep >= 50 ? 'disabled' : ''}>+</button></div></div>
    <div class="srow"><div class="lbl"><span>Last backup</span></div><span class="mono status-v">${esc(last)}</span></div>
    <div id="backup-list">${backupListHtml()}</div>
  </section>`;
}
const DATA_SAVER_NOTE = 'Compresses attached media to save space — photos (longest edge 2048 px), videos (720p H.264) and voice memos (low-bitrate audio). The original format is kept so links stay valid; videos re-encode in the background after attaching. Existing media isn’t touched until you run Compress existing media below. HEIC photos always become JPEG so every app can show them.';
function mediaSectionHtml() {
  const t = S.mediaTools || {}, c = S.compress, rep = S.compressReport;
  const tools = [!t.ffmpeg && 'Install ffmpeg to compress video and audio', !t.heif && 'Install libheif-examples (heif-convert) to convert HEIC'].filter(Boolean);
  const issues = rep ? [...(rep.skippedMissingTools || []), ...(rep.errors || [])] : [];
  return `<section id="s-media"><h2>Media</h2>
    <div class="srow"><div class="lbl"><span>Data Saver</span><span class="note">${esc(DATA_SAVER_NOTE)}</span></div><button class="switch" role="switch" aria-checked="${!!S.dataSaver}" aria-label="Data Saver" data-action="data-saver"></button></div>
    <div class="srow"><div class="lbl"><span>Data saved</span><span class="note">By Data Saver, on every device that shares this folder</span></div><span class="mono status-v" id="data-saved">${decBytes(S.dataSaved)}</span></div>
    ${tools.map(n => `<div class="tool-note">${esc(n)}</div>`).join('')}
    <div class="srow"><div class="lbl"><span>Compress existing media</span><span class="note">Converts HEIC photos to JPEG and compresses photos, videos and voice memos already in assets/. Files that were already compressed are skipped.</span></div><button class="btn" data-action="compress" id="compress-btn" ${c ? 'disabled' : ''}>${c ? `Compressing ${c.done || 0}/${c.total || 0}` : 'Compress existing media'}</button></div>
    ${issues.length ? `<ul class="issue-list">${issues.map(m => `<li>${esc(m)}</li>`).join('')}</ul>` : ''}
  </section>`;
}
/** Swap one settings section in place, so inputs elsewhere on the page keep their text and focus. */
function patchSection(id) {
  const el = document.getElementById(id); if (!el) return;
  el.outerHTML = id === 's-backup' ? backupSectionHtml() : id === 's-media' ? mediaSectionHtml() : el.outerHTML;
}
function compressSummary(r) {
  const parts = [];
  if (r.heicConverted) parts.push(`Converted ${plural(r.heicConverted, 'HEIC photo')} to JPEG.`);
  if (r.images || r.videos || r.audio) parts.push(`Compressed ${plural(r.images, 'photo')}, ${plural(r.videos, 'video')}, ${r.audio} audio — saved ${decBytes(r.savedBytes)}.`);
  return parts.join(' ') || 'No new media to compress.';
}

const tagGroupId = grp => grp.tags.map(t => t[0]).sort().join('|');
const visibleTagGroups = () => { const ign = new Set(S.ui.ignoredTagGroups || []); return (S.tagReview || []).filter(g => !ign.has(tagGroupId(g))); };
const tagPick = grp => { const id = tagGroupId(grp); return S.tagPicks[id] || (S.tagPicks[id] = { on: false, to: grp.suggested || grp.tags[0]?.[0] }); };
const chosenTagGroups = () => visibleTagGroups().filter(g => tagPick(g).on);
function tagReviewHtml() {
  if (!S.tagReview) return '';
  const gs = visibleTagGroups();
  if (!gs.length) return '<div class="empty-note">No near-duplicate tags found.</div>';
  const n = chosenTagGroups().length;
  return `<div class="tag-review">${gs.map(grp => {
    const id = esc(tagGroupId(grp)), p = tagPick(grp);
    return `<div class="srow tag-group"><input type="checkbox" class="tg-check" data-input="merge-on" data-id="${id}" ${p.on ? 'checked' : ''} aria-label="Merge ${esc(grp.tags.map(t => t[0]).join(', '))}">
      <div class="lbl"><span>${grp.tags.map(([t, c]) => `<span class="tag">${esc(t)}</span> <small style="color:var(--muted)">${c}</small>`).join('  ·  ')}</span><span class="note">Merge into <select class="picker" data-input="merge-to" data-id="${id}">${grp.tags.map(([t]) => `<option ${t === p.to ? 'selected' : ''}>${esc(t)}</option>`).join('')}</select></span></div>
      <button class="btn ghost" data-action="tag-ignore" data-id="${id}">Not a match — ignore</button></div>`;
  }).join('')}
    <div class="srow"><div class="lbl"><span class="note">Tick the groups to merge, then apply them together.</span></div><button class="btn primary" data-action="tags-apply" id="tags-apply" ${n ? '' : 'disabled'}>Apply (${n})</button></div></div>`;
}

/* ---------- after render ---------- */
function afterRender() {
  // A re-render drops the tag picker element; drop its state too, or Enter would insert at stale offsets.
  S.tagPick = null; $('#tagpick')?.remove();
  const ta = $('#bodyta'), ti = $('#title');
  if (ta && S.draft) {
    paintBackdrop();
    ta.addEventListener('input', () => {
      restampIfFloating(true);
      S.draft.body = ta.value; paintBackdrop(); typewriter(); refreshChrome(); scheduleSave(); tagAutocomplete(ta);
      const again = $('[data-action="prompt"]'); if (again && ta.value.trim()) again.remove();
    });
    ['keyup', 'click', 'select'].forEach(ev => ta.addEventListener(ev, () => { paintBackdrop(); typewriter(); }));
    ta.addEventListener('blur', () => { $('#tagpick')?.remove(); S.tagPick = null; });
    ta.addEventListener('keydown', ev => {
      if (ev.isComposing || ev.keyCode === 229) return; // an IME is composing: its keys aren't ours
      if (S.tagPick && !ev.ctrlKey) {
        if (ev.key === 'Tab' || ev.key === 'Enter') { ev.preventDefault(); acceptTag(S.tagPick.ix); return; }
        if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') { ev.preventDefault(); S.tagPick.ix = (S.tagPick.ix + (ev.key === 'ArrowDown' ? 1 : -1) + S.tagPick.opts.length) % S.tagPick.opts.length; $$('#tagpick button').forEach((b, i) => b.classList.toggle('on', i === S.tagPick.ix)); return; }
        if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); $('#tagpick')?.remove(); S.tagPick = null; return; }
      }
      if (ev.key === 'Enter' && !ev.shiftKey && !ev.ctrlKey && editorEnter(ta)) ev.preventDefault();
      if (ev.key === 'Tab' && !ev.ctrlKey && !ev.altKey && !ev.metaKey) {
        // Tab indents (Shift outdents) a list item, or every line of a multi-line selection.
        // Anywhere else it's left alone, so Tab still moves focus out of the editor.
        const v = ta.value, a = ta.selectionStart, b = ta.selectionEnd;
        const ls = v.lastIndexOf('\n', a - 1) + 1;
        const le0 = v.indexOf('\n', a), line = v.slice(ls, le0 < 0 ? v.length : le0);
        const multi = v.slice(a, b).includes('\n');
        if (!multi && !/^\s*([-*+]\s|\d+[.)]\s)/.test(line)) return;
        ev.preventDefault();
        if (multi) {
          const end = b > a && v[b - 1] === '\n' ? b - 1 : b; // a selection ending at a line start doesn't take that line
          const le = v.indexOf('\n', end), stop = le < 0 ? v.length : le;
          const out = v.slice(ls, stop).split('\n').map(l => ev.shiftKey ? l.replace(/^( {1,2}|\t)/, '') : l ? '  ' + l : l).join('\n');
          ta.setRangeText(out, ls, stop, 'select');
        } else if (ev.shiftKey) {
          const n = line.startsWith('  ') ? 2 : line.startsWith(' ') || line.startsWith('\t') ? 1 : 0;
          if (n) { ta.setRangeText('', ls, ls + n, 'preserve'); ta.setSelectionRange(Math.max(ls, a - n), Math.max(ls, b - n)); }
        } else { ta.setRangeText('  ', ls, ls, 'preserve'); ta.setSelectionRange(a + 2, b + 2); }
        ta.dispatchEvent(new Event('input'));
      }
    });
    ti.addEventListener('input', () => { restampIfFloating(true); S.draft.title = ti.value; refreshChrome(); scheduleSave(); });
    ti.addEventListener('keydown', ev => { if (ev.key === 'Enter') { ev.preventDefault(); ta.focus(); } });
    new ResizeObserver(() => paintBackdrop()).observe($('#editor'));
  }
  if ($('#body [data-asset]')) resolveVisibleMedia().catch(() => {});
  const sel = $('.row.sel'); if (sel) sel.scrollIntoView({ block: 'nearest' });
  if (S.locked) $('#pin')?.focus();
}

/* ---------- events ---------- */
function entryFrom(el) { return S.entries.find(e => e.file === el.dataset.file && e.index === +el.dataset.index); }

document.addEventListener('click', async ev => {
  const mi = ev.target.closest('[data-menu-item]');
  if (mi) { await menuAction(mi.dataset.menuItem).catch(fail); return; }
  const rt = ev.target.closest('[data-rt]');
  if (rt) {
    const a = rt.dataset.rt;
    if (a === 'cancel') return closePopover();
    if (a === 'save') return retimeSave().catch(fail);
    if (a === 'now') { const ts = nowTs(); $('#rt-date').value = ts.slice(0, 10); $('#rt-time').value = ts.slice(11); return; }
    const base = dateObj($('#rt-date').value || today()); base.setDate(base.getDate() - 1);
    $('#rt-date').value = isoOf(base); return;
  }
  if (ev.target.id === 'popover') { if (askConfirm.cancel && ($('#ask-yes') || $('#ask-no'))) askConfirm.cancel(); else closePopover(); return; }
  if (ev.target.closest('a[href^="http"]')) { ev.preventDefault(); invoke('plugin:opener|open_url', { url: ev.target.closest('a').href }).catch(fail); return; }
  const el = ev.target.closest('[data-action]');
  if (!el) {
    if (S.mode === 'write' && ev.target.closest('.page') && !ev.target.closest('.editor, .title-input')) {
      const ta = $('#bodyta'); if (ta) { ta.focus(); ta.setSelectionRange(ta.value.length, ta.value.length); paintBackdrop(); }
    }
    return;
  }
  const a = el.dataset.action;
  try {
    switch (a) {
      case 'view': await switchView(el.dataset.view); break;
      case 'new': if (S.mode === 'write' && !(await leaveWrite())) break; startDraft(); break;
      case 'show-list': S.showList = true; render(); break;
      case 'open': {
        let e = entryFrom(el); if (!e) break;
        if (S.mode === 'write') { if (!(await leaveWrite())) return; e = reresolve(e); if (!e) break; } // saving may have moved it
        if (S.view === 'journal' && S.jview !== 'list') S.jview = 'list';
        S.showList = false;
        if (e.source === 'inbox' && (S.view === 'inbox' || S.view === 'today')) { S.sel = e; editEntry(e); }
        else { S.sel = e; S.mode = 'read'; render(); }
        break;
      }
      case 'open-journal': { const e = entryFrom(el); if (e) await openInJournal(e); else closePopover(); break; }
      case 'open-url': ev.preventDefault(); await invoke('plugin:opener|open_url', { url: el.getAttribute('href') }); break;
      case 'open-asset': { const p = await invoke('asset_path', { rel: el.dataset.rel }); await invoke('plugin:opener|open_path', { path: p }); break; }
      case 'open-folder': await invoke('plugin:opener|open_path', { path: S.folder }); break;
      case 'edit': if (S.sel) editEntry(S.sel); break;
      case 'cancel-edit': await cancelEdit(); break;
      case 'save-edit': await saveEdit(); break;
      case 'file': await fileCurrent(); break;
      case 'file-all': {
        const n = inbox().length;
        if (!(await askConfirm(`File all ${plural(n, 'draft')} to their days?`, 'File all'))) break;
        S.ignoreWatch = Date.now() + 1500;
        const r = await invoke('file_all');
        await load(); S.sel = null;
        if (r.errors?.length) toast(`Filed ${r.filed}${r.skipped ? ` · skipped ${r.skipped} empty` : ''} · ${r.errors.join('; ')}`, 'error');
        else stamp('INBOX_CLEARED', `Filed ${r.filed}${r.skipped ? ` · skipped ${r.skipped} empty` : ''}`);
        render(); break;
      }
      case 'file-transfer': { if (!(await askConfirm('File every entry in transfer.md into its day, then empty it?', 'File'))) break; const n = await invoke('file_transfer', { nowTs: nowTs() }); await load(); toast(`${n} filed from transfer.md`); render(); break; }
      case 'star': await toggleStar(); break;
      case 'delete': await doDelete(); break;
      case 'unfile': await doUnfile(); break;
      case 'retime': openRetime(el); break;
      case 'menu': openMenu(el, el.dataset.menu); break;
      case 'focus': toggleFocus(); break;
      case 'prompt': S.promptReroll++; paintBackdrop(); $('#bodyta')?.focus(); break;
      case 'timer': toggleTimer(); break;
      case 'tag-accept': acceptTag(+el.dataset.i); break;
      case 'task': { const pr = el.closest('.prose'); const e = S.entries.find(x => x.file === pr.dataset.file && x.index === +pr.dataset.index); if (e) await toggleTask(e, +el.dataset.ix, el.checked); break; }
      case 'tag': S.tag = S.tag === el.dataset.tag ? null : el.dataset.tag; S.sel = null; render(); break;
      case 'tag-jump': ev.preventDefault(); ev.stopPropagation(); if (S.mode === 'write' && !(await leaveWrite())) break; S.view = 'journal'; S.jview = 'list'; S.tag = el.dataset.tag; S.query = ''; S.day = null; S.sel = null; S.mode = 'read'; S.showList = true; render(); break;
      case 'random-tag': { const t = countTags(filed()); if (t.length) { S.tag = t[Math.floor(Math.random() * t.length)][0]; S.sel = null; render(); } break; }
      case 'alltags': S.showAllTags = !S.showAllTags; render(); break;
      case 'clearfilter': S.tag = null; S.query = ''; S.day = null; render(); break;
      case 'sort': S.ui.sortNewest = !S.ui.sortNewest; await saveUi(); render(); break;
      case 'jview': S.jview = el.dataset.v; S.sel = null; render(); break;
      case 'day': if (S.mode === 'write' && !(await leaveWrite())) break; S.view = 'journal'; S.jview = 'list'; S.day = S.day === el.dataset.day ? null : el.dataset.day; S.calMonth = [+el.dataset.day.slice(0, 4), +el.dataset.day.slice(5, 7) - 1]; S.sel = null; render(); break;
      case 'print-day-btn': { S.printDay = el.dataset.day; S.sel = null; render(); setTimeout(() => { window.print(); S.printDay = null; render(); }, 150); break; }
      case 'day-jump': if (S.mode === 'write' && !(await leaveWrite())) break; S.view = 'journal'; S.jview = 'list'; S.day = el.dataset.day; S.tag = null; S.query = ''; S.calMonth = [+el.dataset.day.slice(0, 4), +el.dataset.day.slice(5, 7) - 1]; S.sel = null; S.mode = 'read'; render(); break;
      case 'cal': { const now = new Date(); let [y, m] = S.calMonth || [now.getFullYear(), now.getMonth()]; if (el.dataset.d === '0') { y = now.getFullYear(); m = now.getMonth(); } else { m += +el.dataset.d; if (m < 0) { m = 11; y--; } if (m > 11) { m = 0; y++; } } S.calMonth = [y, m]; render(); break; }
      case 'random': randomEntry(); break;
      case 'saved': { const s = S.searches[+el.dataset.i]; S.query = S.query.trim() === s.query ? '' : s.query; S.sel = null; render(); break; }
      case 'pin-search': { const name = await askText('Name this search', 'e.g. Starred this year', S.query.trim()); if (!name) break; S.searches.push({ name, query: S.query.trim() }); await invoke('save_searches_cmd', { list: S.searches }); render(); break; }
      case 'clear-orphans': { const n = await invoke('orphan_count'); if (!n) { toast('No orphan media'); break; } if (!(await askConfirm(`Delete ${n} file${n === 1 ? '' : 's'} in assets/ that no entry links to?`, 'Delete'))) break; const d = await invoke('clear_orphans'); S.assets = null; toast(`Deleted ${d}`); render(); break; }
      case 'system-titlebar': { const m = $('.settings main'), top = m ? m.scrollTop : 0; const custom = await invoke('set_system_titlebar', { on: S.customChrome }); setChrome(custom); render(); const m2 = $('.settings main'); if (m2) m2.scrollTop = top; break; }
      case 'toggle-ui': S.ui[el.dataset.k] = !S.ui[el.dataset.k]; await saveUi(); render(); break;
      case 'lightbox': { ev.preventDefault(); const rel = el.dataset.rel; let url = S.assetUrls.get(rel); if (!url) { url = fileSrc(await invoke('asset_path', { rel })); S.assetUrls.set(rel, url); } const o = el.dataset.file ? entryFrom(el) || null : null; openLightbox(rel, url, o); break; }
      case 'use-jnl-dir': { if (!(await askConfirm('Use your real jnl folder? Quire is a prototype; a copy is safer until you trust it.', 'Use it'))) break; await invoke('set_folder', { path: S.jnlDir }); await invoke('rewatch'); S.sel = null; S.assetUrls.clear(); await load(); toast('Folder set'); render(); break; }
      case 'toggle': if (el.dataset.k === 'lockOn' && !S.ui.lockOn && !S.ui.pinHash) { toast('Set a PIN first'); break; } S.ui[el.dataset.k] = !S.ui[el.dataset.k]; applyUi(); await saveUi(); render(); if (el.dataset.k === 'reminderOn') scheduleReminder(); break;
      case 'set': { const v = el.dataset.v; S.ui[el.dataset.k] = /^\d+$/.test(v) ? +v : v; applyUi(); await saveUi(); if (el.dataset.k === 'timerMins') S.timer.left = null; render(); break; }
      case 'pick-folder': { const p = await invoke('plugin:dialog|open', { options: { directory: true, multiple: false, title: 'Choose your journal folder' } }); if (p) { await invoke('set_folder', { path: p }); await invoke('rewatch'); S.sel = null; S.assetUrls.clear(); await load(); toast('Folder set'); render(); } break; }
      case 'set-path': { const p = $('#pathin').value.trim(); if (!p) break; await invoke('set_folder', { path: p }); await invoke('rewatch'); S.sel = null; S.assetUrls.clear(); await load(); toast('Folder set'); render(); break; }
      case 'use-sample': if (S.mode === 'write' && !(await leaveWrite())) break; await invoke('use_sample'); await invoke('rewatch'); S.sel = null; S.assetUrls.clear(); await load(); render(); break;
      case 'set-split': await invoke('set_split_tags', { tags: $('#splitin').value }); await load(); toast('Split tags saved'); render(); break;
      case 'tpl-edit': S.tplEdit = el.dataset.name; render(); $('#tpl-body')?.focus(); break;
      case 'tpl-new': { const n = await invoke('new_template'); await load(); S.tplEdit = n; render(); $('#tpl-name')?.select(); break; }
      case 'tpl-save': { const name = $('#tpl-name').value.trim(), body = $('#tpl-body').value; if (name !== S.tplEdit) await invoke('rename_template', { from: S.tplEdit, to: name }); await invoke('save_template_cmd', { name, body }); await load(); S.tplEdit = name; toast('Template saved'); render(); break; }
      case 'tpl-delete': { if (!(await askConfirm(`Delete the template “${esc(S.tplEdit)}”?`, 'Delete'))) break; await invoke('delete_template_cmd', { name: S.tplEdit }); S.tplEdit = null; await load(); render(); break; }
      case 'tpl-close': S.tplEdit = null; render(); break;
      case 'set-pin': { const p = await askText('Choose a PIN', '4 or more digits'); if (!p || p.length < 4) { if (p !== null) toast('Use at least 4 characters'); break; } S.ui.pinHash = await invoke('pin_hash', { pin: p }); await saveUi(); toast('PIN set'); render(); break; }
      case 'clear-pin': S.ui.pinHash = ''; S.ui.lockOn = false; await saveUi(); render(); break;
      case 'unlock': await tryUnlock(); break;
      case 'pick-backup': { const p = await invoke('plugin:dialog|open', { options: { directory: true, multiple: false, title: 'Choose a backup folder' } }); if (p) { await invoke('set_backup_dir', { path: p }); S.backups = null; await load(); patchSection('s-backup'); } break; }
      case 'backup-now': { S.backupRunning = true; patchSection('s-backup'); try { const d = await invoke('backup_now'); toast('Backed up to ' + d.split('/').pop()); } finally { S.backups = null; await load().catch(() => {}); S.backupRunning = false; patchSection('s-backup'); } break; }
      case 'backup-interval': { const v = el.dataset.v; await invoke('set_backup_prefs', { interval: v, keep: S.backupKeep }); S.backupInterval = v; patchSection('s-backup'); if (v === 'daily' || v === 'weekly') maybeBackup(); break; }
      case 'backup-keep': { const keep = Math.max(1, Math.min(50, S.backupKeep + +el.dataset.d)); if (keep === S.backupKeep) break; await invoke('set_backup_prefs', { interval: S.backupInterval, keep }); S.backupKeep = keep; patchSection('s-backup'); $(`#s-backup [data-action="backup-keep"][data-d="${el.dataset.d}"]`)?.focus(); break; }
      case 'restore': { if (!(await askConfirm(`Restore “${esc(el.dataset.name)}” over the current folder? A full copy of the current folder is saved first.`, 'Restore'))) break; const safety = await invoke('restore_backup', { name: el.dataset.name }); S.assetUrls.clear(); S.backups = null; await load(); toast(`Restored. Your previous folder is saved as “${safety}”`); render(); break; }
      case 'cleanup': {
        if (!(await askConfirm('Clean up every day file? Punctuation is normalised, days re-sorted, duplicates removed, and split-tagged entries moved to their files.', 'Clean up'))) break;
        const r = await invoke('run_cleanup'); await load();
        toast(`Formatted ${r.formatted}, reordered ${r.reordered}, removed ${r.deduped} duplicate${r.deduped === 1 ? '' : 's'}, extracted ${r.extracted} to split journals${r.errors?.length ? ' · ' + r.errors.join('; ') : ''}`);
        render(); break;
      }
      case 'sort-inbox': { const changed = await invoke('sort_inbox_cmd'); await load(); toast(changed ? 'Inbox sorted' : 'The inbox was already in order'); render(); break; }
      case 'merge-ex-split': {
        if (!(await askConfirm('Merge every root journal that isn’t a current split tag back into its days? Emptied files are removed.', 'Merge'))) break;
        const r = await invoke('merge_ex_split'); await load();
        toast((r.journals ? `Merged ${plural(r.entries, 'entry', 'entries')} from ${plural(r.journals, 'ex-split journal')}` : 'No ex-split journals to merge — every root journal is a current split tag.') + (r.errors?.length ? ' · ' + r.errors.join('; ') : ''));
        render(); break;
      }
      case 'merge-conflict': { const rel = el.dataset.rel; const n = await invoke('merge_conflict', { rel }); await load(); toast(`Merged ${plural(n, 'entry', 'entries')} from ${rel.split('/').pop()}`); render(); break; }
      case 'locate-folder': { const p = await invoke('plugin:dialog|open', { options: { directory: true, multiple: false, title: `Find “${(S.folder || '').split('/').filter(Boolean).pop() || 'your journal'}”` } }); if (!p) break; await invoke('set_folder', { path: p }); await invoke('rewatch'); S.sel = null; S.assetUrls.clear(); await load(); toast(S.folderMissing ? 'Still can’t reach that folder' : 'Folder found'); render(); break; }
      case 'data-saver': { const on = !S.dataSaver; await invoke('set_data_saver', { on }); S.dataSaver = on; patchSection('s-media'); break; }
      case 'compress': {
        if (S.compress) break;
        S.compress = { done: 0, total: 0 }; S.compressReport = null; patchSection('s-media');
        try { const r = await invoke('compress_existing'); S.compressReport = r; toast(compressSummary(r)); }
        finally { S.compress = null; S.dataSaved = await invoke('data_saved').catch(() => S.dataSaved); S.assets = null; S.sizes = null; S.statsExtra = null; patchSection('s-media'); }
        break;
      }
      case 'guard-keep': if (S.draft) { S.draft.keepOne = true; refreshChrome(); scheduleSave(); $('#bodyta')?.focus(); } break;
      case 'guard-import': await guardImport(); break;
      case 'asset-menu': openAssetMenu(el.getBoundingClientRect(), el.dataset.rel); break;
      case 'tag-ignore': { const id = el.dataset.id; if (!S.ui.ignoredTagGroups.includes(id)) S.ui.ignoredTagGroups.push(id); delete S.tagPicks[id]; await saveUi(); const tr = $('#tag-review'); if (tr) tr.innerHTML = tagReviewHtml(); toast('Ignored — it won’t be suggested again'); break; }
      case 'tags-apply': {
        const groups = chosenTagGroups(); if (!groups.length) break;
        // merge_tags takes one {from, to} at a time, so the chosen merges run in turn, with one reload at the end.
        let files = 0, done = 0; const errs = [];
        for (const g of groups) {
          const to = tagPick(g).to, from = g.tags.map(x => x[0]).filter(t => t !== to);
          try { files += await invoke('merge_tags', { from, to }); done++; } catch (e) { errs.push(String(e)); }
        }
        S.tagPicks = {}; S.tagReview = await invoke('tag_review_cmd').catch(() => S.tagReview); await load();
        toast(`Merged ${plural(done, 'group')} · ${plural(files, 'file')} changed${errs.length ? ' · ' + errs.join('; ') : ''}`); render(); break;
      }
      case 'export': { const p = await invoke('plugin:dialog|save', { options: { defaultPath: 'export.md', title: 'Export all entries' } }); if (p) { const n = await invoke('export_cmd', { dest: p }); toast(`${n} entries exported`); } break; }
      case 'import-md': { const p = await invoke('plugin:dialog|open', { options: { directory: true, multiple: false, title: 'Folder of dated markdown files' } }); if (!p) break; const dry = await invoke('import_markdown', { dir: p, dryRun: true }); if (!dry.found) { toast('No dated .md or .txt files found'); break; } if (!(await askConfirm(`${dry.found} entries found; ${dry.written} new, ${dry.skipped} already here. Import the new ones?`, 'Import'))) break; const r = await invoke('import_markdown', { dir: p, dryRun: false }); await load(); toast(`Imported ${r.written}`); render(); break; }
      case 'import-dayone': { const p = await invoke('plugin:dialog|open', { options: { multiple: false, title: 'Day One export (Journal.json or its folder)' } }); if (!p) break; const dry = await invoke('import_dayone', { path: p, dryRun: true }); if (!(await askConfirm(`${dry.found} entries found; ${dry.written} new, ${dry.skipped} already here. Import the new ones?`, 'Import'))) break; const r = await invoke('import_dayone', { path: p, dryRun: false }); await load(); S.assetUrls.clear(); toast(`Imported ${r.written}`); render(); break; }
      case 'tag-review': S.tagReview = await invoke('tag_review_cmd'); S.tagPicks = {}; render(); location.hash = '#s-maint'; break;
      case 'welcome': S.ui.welcomed = false; await saveUi(); showWelcome(); break;
    }
  } catch (err) { fail(err); await load().catch(() => {}); render(); }
});
document.addEventListener('dblclick', ev => { if (ev.target.closest('#timerbtn')) { stopTimer(); S.timer.left = null; refreshTimer(); } });
let searchTimer = null;
document.addEventListener('input', ev => {
  const k = ev.target.dataset.input;
  if (k === 'query') {
    // Debounced: typing stays smooth on big journals; the list catches up 150 ms after the last key.
    S.query = ev.target.value;
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      const cur = $('#search'), had = document.activeElement === cur, pos = cur ? cur.selectionStart : S.query.length;
      render();
      const s = $('#search'); if (s && had) { s.focus(); s.setSelectionRange(pos, pos); }
    }, 150);
  }
  if (k === 'gosearch') { S.view = 'journal'; S.jview = 'list'; S.query = ev.target.value; S.sel = null; render(); const s = $('#search'); s.focus(); s.setSelectionRange(s.value.length, s.value.length); }
});
document.addEventListener('change', async ev => {
  const k = ev.target.dataset.input;
  if (k === 'journal') { S.journal = ev.target.value; S.sel = null; render(); }
  if (k === 'year') { S.year = +ev.target.value; render(); }
  if (k === 'reminderTime') { S.ui.reminderTime = ev.target.value; await saveUi(); scheduleReminder(); }
  if (k === 'asset-sort' || k === 'asset-group') { S.ui[k === 'asset-sort' ? 'assetSort' : 'assetGroup'] = ev.target.value; await saveUi(); render(); $(`[data-input="${k}"]`)?.focus(); }
  if (k === 'merge-on' || k === 'merge-to') {
    const grp = (S.tagReview || []).find(g => tagGroupId(g) === ev.target.dataset.id); if (!grp) return;
    const p = tagPick(grp);
    if (k === 'merge-on') p.on = ev.target.checked;
    else { p.to = ev.target.value; p.on = true; const cb = $(`[data-input="merge-on"][data-id="${CSS.escape(ev.target.dataset.id)}"]`); if (cb) cb.checked = true; }
    const n = chosenTagGroups().length, btn = $('#tags-apply');
    if (btn) { btn.textContent = `Apply (${n})`; btn.disabled = !n; }
  }
});
document.addEventListener('contextmenu', async ev => {
  const row = ev.target.closest('[data-ctx="entry"]');
  if (row) {
    ev.preventDefault();
    let e = entryFrom(row); if (!e) return;
    if (S.mode === 'write') { if (!(await leaveWrite().catch(err => { fail(err); return false; }))) return; e = reresolve(e); if (!e) return; }
    S.sel = e; S.mode = 'read'; render();
    const b = $('[data-action="menu"]'); if (b) openMenu(b, 'read');
    return;
  }
  const at = ev.target.closest('[data-ctx="asset"]');
  if (at) { ev.preventDefault(); openAssetMenu({ left: ev.clientX, bottom: ev.clientY }, at.dataset.rel); return; }
  const sv = ev.target.closest('[data-ctx="saved"]');
  if (sv) { ev.preventDefault(); const i = +sv.dataset.i; askConfirm(`Remove the saved search “${esc(S.searches[i].name)}”?`, 'Remove').then(async ok => { if (ok) { S.searches.splice(i, 1); await invoke('save_searches_cmd', { list: S.searches }); render(); } }); }
});
window.addEventListener('resize', () => { const n = window.innerWidth < 860; if (n !== S.narrow) render(); });

async function switchView(v) {
  if (S.mode === 'write' && !(await leaveWrite())) return;
  S.view = v; S.sel = null; S.focus = false; S.showList = true;
  if (v === 'inbox') S.sel = inbox()[0] || null;
  render();
}
function randomEntry() { const f = filed(); if (!f.length) return; const e = f[Math.floor(Math.random() * f.length)]; S.view = 'journal'; S.jview = 'list'; S.tag = null; S.query = ''; S.day = null; S.sel = e; S.mode = 'read'; S.showList = false; render(); }

/* ---------- timer ---------- */
function refreshTimer() { const b = $('#timerbtn'); if (b) b.outerHTML = timerHtml(); }
function stopTimer() { clearInterval(S.timer.handle); S.timer.handle = null; S.timer.running = false; }
function chime() {
  if (!S.ui.chime) return;
  try { const ac = new AudioContext(); [523.25, 659.25, 783.99].forEach((f, i) => { const o = ac.createOscillator(), g = ac.createGain(); o.frequency.value = f; o.type = 'sine'; g.gain.setValueAtTime(0.0001, ac.currentTime + i * 0.18); g.gain.exponentialRampToValueAtTime(0.18, ac.currentTime + i * 0.18 + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, ac.currentTime + i * 0.18 + 0.6); o.connect(g).connect(ac.destination); o.start(ac.currentTime + i * 0.18); o.stop(ac.currentTime + i * 0.18 + 0.65); }); } catch { /* no audio */ }
}
function toggleTimer() {
  const t = S.timer;
  if (t.left === 0) { t.left = null; refreshTimer(); return; }
  if (t.running) { stopTimer(); refreshTimer(); return; }
  if (t.left == null) t.left = S.ui.timerMins * 60;
  t.running = true;
  t.handle = setInterval(() => { t.left = Math.max(0, t.left - 1); if (t.left === 0) { stopTimer(); chime(); toast('Time — nice work'); } refreshTimer(); }, 1000);
  refreshTimer();
}

/* ---------- reminder ---------- */
let reminderHandle = null;
function scheduleReminder() {
  clearTimeout(reminderHandle);
  if (!S.ui.reminderOn) return;
  if (!/^\d{2}:\d{2}/.test(S.ui.reminderTime || '')) return; // a cleared time input would otherwise give setTimeout(NaN) → an immediate loop
  const [h, m] = S.ui.reminderTime.split(':').map(Number);
  const at = new Date(); at.setHours(h, m, 0, 0);
  if (at <= new Date()) at.setDate(at.getDate() + 1);
  reminderHandle = setTimeout(async () => {
    // Today's inbox drafts count as written.
    if (!S.entries.some(e => e.date === today())) {
      const streak = streakToYesterday();
      const body = streak > 1 ? `Day ${streak + 1} is waiting — keep the streak going.` : 'A few lines is all it takes.';
      try {
        let ok = await invoke('plugin:notification|is_permission_granted');
        if (!ok) ok = (await invoke('plugin:notification|request_permission')) === 'granted';
        if (ok) await invoke('plugin:notification|notify', { options: { title: 'Time to write', body } });
      } catch (e) { console.warn(e); }
      toast(`Time to write. ${body}`);
      if (S.view === 'today' && S.mode !== 'write') render();
    }
    scheduleReminder();
  }, at - new Date());
}

/* ---------- automatic backup ---------- */
/** The back end decides whether a daily/weekly backup is due; called on launch and whenever the window comes forward. */
let backupCheck = null;
async function maybeBackup(loud = false) {
  if (!S.backupDir || S.folderMissing || S.backupInterval === 'off' || backupCheck) return;
  backupCheck = invoke('maybe_backup');
  try {
    const p = await backupCheck;
    if (p) { S.backups = null; await load().catch(() => {}); toast('Backed up to ' + String(p).split('/').pop()); if (S.view === 'settings') patchSection('s-backup'); }
  } catch (e) { if (loud) fail(e); else console.warn(e); }
  finally { backupCheck = null; }
}
T.event.listen('backup-finished', async ev => {
  const p = ev.payload || {};
  if (!p.ok && p.error) toast('Backup failed: ' + p.error);
  S.backups = null;
  try { await load(); } catch { /* keep what we have */ }
  if (S.view === 'settings') patchSection('s-backup');
});

/* ---------- media: background compression and Data Saver progress ---------- */
T.event.listen('media-progress', ev => {
  if (!S.compress) return;
  S.compress = { done: ev.payload?.done || 0, total: ev.payload?.total || 0 };
  const b = $('#compress-btn'); if (b) b.textContent = `Compressing ${S.compress.done}/${S.compress.total}`;
});
T.event.listen('media-compressed', async ev => {
  const { rel, saved } = ev.payload || {}; if (!rel) return;
  S.assets = null; S.sizes = null; S.statsExtra = null;
  if (saved > 0) S.dataSaved += saved;
  const old = S.assetUrls.get(rel);
  if (old) {
    // Same path, new bytes: a cache-busting URL makes the webview fetch it again.
    try {
      const url = fileSrc(await invoke('asset_path', { rel })) + '?v=' + Date.now();
      S.assetUrls.set(rel, url);
      $$('#body img, #body video, #body audio, #popover img').forEach(el => { if (el.getAttribute('src') === old) el.setAttribute('src', url); });
    } catch { S.assetUrls.delete(rel); }
  }
  const ds = $('#data-saved'); if (ds) ds.textContent = decBytes(S.dataSaved);
  if (saved > 0) toast(`${rel.split('/').pop()} compressed · saved ${decBytes(saved)}`);
});

/* ---------- welcome ---------- */
function showWelcome() {
  const layer = $('#popover');
  layer.innerHTML = `<div class="popover corner" role="dialog"><h3>Welcome to Quire</h3>
    <div class="note" style="font-size:14px;line-height:1.6;color:var(--ink)">
      <p style="margin:0 0 10px">Your words live in a plain folder of markdown, one file a day: <span class="mono">inbox/YYYY/MM/DD.md</span> for drafts and <span class="mono">journal/YYYY/MM/DD.md</span> for filed days, in jnl's format. An <span class="mono">inbox.md</span> from jnl or Nook is folded in when Quire opens the folder. Nothing here is locked in.</p>
      <p style="margin:0">Write with <kbd>Ctrl</kbd>+<kbd>N</kbd>, file with <kbd>Ctrl</kbd>+<kbd>J</kbd>, and <kbd>Ctrl</kbd>+<kbd>,</kbd> opens Settings.</p></div>
    <div class="row2"><span></span><button class="btn primary" id="ask-yes">Begin</button></div></div>`;
  layer.classList.add('open');
  $('#ask-yes').onclick = async () => { closePopover(); S.ui.welcomed = true; await saveUi(); };
  askConfirm.cancel = () => { closePopover(); S.ui.welcomed = true; saveUi(); };
}

/* ---------- keyboard ---------- */
document.addEventListener('keydown', async ev => {
  if (ev.isComposing || ev.keyCode === 229) return;
  const typing = /INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName || '');
  const ctrl = ev.ctrlKey || ev.metaKey;
  try {
    if (S.locked) { if (ev.key === 'Enter') { ev.preventDefault(); await tryUnlock(); } return; }
    if ($('#popover').classList.contains('open')) {
      const isAsk = !!($('#ask-yes') || $('#ask-no'));
      if (ev.key === 'Escape') { ev.preventDefault(); if (isAsk && askConfirm.cancel) askConfirm.cancel(); else closePopover(); }
      if (ev.key === 'Enter' && !isAsk && $('#rt-date')) { ev.preventDefault(); await retimeSave(); }
      return;
    }
    if (ctrl && ev.altKey && ev.key.toLowerCase() === 'f') { ev.preventDefault(); toggleFocus(); return; }
    if (ctrl && ev.shiftKey && ev.key.toLowerCase() === 'f') { ev.preventDefault(); if (S.mode === 'write' && !(await leaveWrite())) return; S.view = 'journal'; S.jview = 'list'; S.showList = true; render(); $('#search')?.focus(); return; }
    if (ctrl && !ev.shiftKey && !ev.altKey) {
      const k = ev.key.toLowerCase();
      const ta = document.activeElement?.id === 'bodyta' ? document.activeElement : null;
      if (ta && k === 'b') { ev.preventDefault(); wrapSelection(ta, '**'); return; }
      if (ta && k === 'i') { ev.preventDefault(); wrapSelection(ta, '__'); return; }
      if (ta && k === '`') { ev.preventDefault(); wrapSelection(ta, '`'); return; }
      if (k === 'n') { ev.preventDefault(); if (S.mode === 'write' && !(await leaveWrite())) return; startDraft(); return; }
      if (k === 'j') { ev.preventDefault(); await fileCurrent(); return; }
      if (k === 't') { ev.preventDefault(); const b = $('[data-action="retime"]'); if (b) openRetime(b); return; }
      if (k === 'r') { ev.preventDefault(); if (S.mode === 'write' && !(await leaveWrite())) return; randomEntry(); return; }
      if (k === 'p') { ev.preventDefault(); if (S.sel || S.draft) window.print(); return; }
      if (k === 'l') { ev.preventDefault(); await lockNow(); return; }
      if (k === 's') {
        ev.preventDefault();
        if (S.mode === 'write' && S.draft?.ref && S.draft.ref.source !== 'inbox') await saveEdit();
        else if (S.mode === 'write' && S.draft) {
          if (guardCount(S.draft)) { toast('Choose Import or Keep as one first'); return; }
          clearTimeout(saveTimer); await saveChain; await saveDraftNow(); if (S.draft?.ref) toast('Saved');
        }
        return;
      }
      if (ev.key === 'Enter' && S.mode === 'write') {
        // Save & new: file the edit or save the draft, then open a fresh draft.
        ev.preventDefault();
        if (!(await leaveWrite())) return;
        startDraft();
        return;
      }
      if (ev.key === '[') {
        // Back: Esc while writing, otherwise return to the list.
        ev.preventDefault();
        if (S.focus) { S.focus = false; $('#app').classList.remove('focus'); paintBackdrop(); return; }
        if (S.mode === 'write') {
          if (!isDraftRef(S.draft)) await cancelEdit();
          else await leaveWrite();
          return;
        }
        if (S.sel) { S.sel = null; S.showList = true; render(); }
        return;
      }
      if (k === ',') { ev.preventDefault(); await switchView('settings'); return; }
      const tab = TABS.find(t => t.key === ev.key); if (tab) { ev.preventDefault(); await switchView(tab.id); return; }
    }
    if (ev.key === 'Escape') {
      if (S.focus) { S.focus = false; $('#app').classList.remove('focus'); paintBackdrop(); return; }
      if (S.mode === 'write') {
        if (!isDraftRef(S.draft)) await cancelEdit();
        else await leaveWrite();
        return;
      }
      if (typing) { document.activeElement.blur(); return; }
      if (S.sel) { S.sel = null; S.showList = true; render(); }
      return;
    }
    if (typing) return;
    if (ev.key === 'ArrowDown' || ev.key === 'ArrowUp') {
      const rows = $$('.list-pane .row, .stream .item');
      if (!rows.length) return;
      ev.preventDefault();
      let i = rows.findIndex(r => r.classList.contains('sel') || (S.sel && r.dataset.file === S.sel.file && +r.dataset.index === S.sel.index));
      i = i < 0 ? (ev.key === 'ArrowDown' ? 0 : rows.length - 1) : Math.max(0, Math.min(rows.length - 1, i + (ev.key === 'ArrowDown' ? 1 : -1)));
      const e = entryFrom(rows[i]); if (!e) return;
      if (S.view === 'journal' && S.jview !== 'list') { rows[i].focus(); rows[i].scrollIntoView({ block: 'nearest' }); S.sel = e; return; }
      S.sel = e; S.mode = 'read'; render();
      return;
    }
    if (ev.key === 'Enter' && S.sel && S.mode === 'read' && document.activeElement?.tagName !== 'BUTTON') { ev.preventDefault(); editEntry(S.sel); }
  } catch (err) { fail(err); }
});

/* ---------- live refresh (file watcher + window focus) ---------- */
/** Someone's mid-way through typing (or in Settings): a re-render would throw their input away. */
const busyInput = () => S.view === 'settings' || !!document.activeElement?.closest?.('#body input, #body textarea, #body select');
async function externalChange() {
  if (S.ignoreWatch && Date.now() < S.ignoreWatch) return;
  try {
    await load();
    renderMissing();
    if (S.mode === 'write') { refreshChrome(); return; }
    // Don't wipe in-progress input; the fresh data shows on the next navigation.
    if (busyInput()) { S.stale = true; renderTabs(); return; }
    render();
  } catch (e) { /* keep what we have */ }
}
T.event.listen('journal-changed', externalChange);
window.addEventListener('focus', () => {
  restampIfFloating(false);
  maybeBackup();
  if (S.mode !== 'write') externalChange();
});
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => applyUi());

/* ---------- boot ---------- */
(async function boot() {
  try { await load(); } catch (e) { S.view = 'settings'; toast(String(e)); }
  if (S.ui.lockOn && S.ui.pinHash) S.locked = true;
  render();
  if (!S.ui.welcomed && !S.locked) showWelcome();
  scheduleReminder();
  maybeBackup(true);
})();

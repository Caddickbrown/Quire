"use strict";
/* Nook (Linux/Tauri) — frontend. Talks to the Rust store via invoke(). */

const T = window.__TAURI__;
const invoke = T.core.invoke;
const convertFileSrc = T.core.convertFileSrc;
const listen = T.event.listen;

/* ------------------------------------------------------------------ */
/* Small DOM + util helpers                                            */
/* ------------------------------------------------------------------ */
const $ = (s, r = document) => r.querySelector(s);
const $$ = (s, r = document) => [...r.querySelectorAll(s)];
function el(html) { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstElementChild; }
function esc(s) { return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])); }
function debounce(fn, ms) { let t; const f = (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; f.cancel = () => clearTimeout(t); f.now = (...a) => { clearTimeout(t); return fn(...a); }; return f; }
function fmtBytes(n) { if (n < 1024) return n + " B"; const u = ["KB", "MB", "GB", "TB"]; let i = -1; do { n /= 1024; i++; } while (n >= 1024 && i < u.length - 1); return n.toFixed(n < 10 ? 1 : 0) + " " + u[i]; }
function plural(n, w) { return n + " " + w + (n === 1 ? "" : "s"); }

/* ------------------------------------------------------------------ */
/* Icons (stroke SVG, currentColor)                                    */
/* ------------------------------------------------------------------ */
const ICONS = {
  "square.and.pencil": '<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  tray: '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
  "book.closed": '<path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z"/>',
  star: '<path d="M12 3l2.6 5.3 5.9.86-4.25 4.14 1 5.86L12 16.9l-5.25 2.26 1-5.86L3.5 9.16l5.9-.86z"/>',
  "star.fill": '<path d="M12 3l2.6 5.3 5.9.86-4.25 4.14 1 5.86L12 16.9l-5.25 2.26 1-5.86L3.5 9.16l5.9-.86z" fill="currentColor" stroke="none"/>',
  "star.slash": '<path d="M12 3l2.6 5.3 5.9.86-4.25 4.14 1 5.86L12 16.9l-5.25 2.26 1-5.86L3.5 9.16l5.9-.86z"/><path d="M3 3l18 18"/>',
  bookmark: '<path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"/>',
  number: '<path d="M4 9h16M4 15h16M10 3 8 21M16 3l-2 18"/>',
  "photo.on.rectangle": '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="9" r="1.5"/><path d="M21 15l-5-5L5 21"/>',
  "chart.bar": '<path d="M3 3v18h18"/><path d="M7 16v-6M12 16V8M17 16v-9"/>',
  gearshape: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>',
  timer: '<circle cx="12" cy="13" r="8"/><path d="M12 9v4l2 2M9 2h6"/>',
  shuffle: '<path d="M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5"/>',
  ellipsis: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  archivebox: '<rect x="2" y="3" width="20" height="5" rx="1"/><path d="M4 8v11a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1V8M10 12h4"/>',
  folder: '<path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/>',
  trash: '<path d="M3 6h18M8 6V4a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1v2M19 6l-1 14a1 1 0 0 1-1 1H7a1 1 0 0 1-1-1L5 6"/>',
  paperclip: '<path d="M21.44 11.05l-9.19 9.19a5 5 0 0 1-7.07-7.07l9.19-9.19a3.5 3.5 0 0 1 4.95 4.95l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/>',
  video: '<path d="M23 7l-7 5 7 5V7z"/><rect x="1" y="5" width="15" height="14" rx="2"/>',
  mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M19 10v2a7 7 0 0 1-14 0v-2M12 19v4"/>',
  stop: '<rect x="8" y="8" width="8" height="8" rx="1"/><circle cx="12" cy="12" r="10"/>',
  eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7z"/><circle cx="12" cy="12" r="3"/>',
  pencil: '<path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  "check.circle": '<circle cx="12" cy="12" r="10"/><path d="M9 12l2 2 4-4"/>',
  circle: '<circle cx="12" cy="12" r="9"/>',
  search: '<circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/>',
  refresh: '<path d="M23 4v6h-6M1 20v-6h6"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/>',
  "chevron.left": '<path d="M15 18l-6-6 6-6"/>',
  "chevron.right": '<path d="M9 18l6-6-6-6"/>',
  calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M3 10h18M8 2v4M16 2v4"/>',
  today: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3" fill="currentColor"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M2 12h2M20 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4"/>',
  moon: '<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>',
  auto: '<circle cx="12" cy="12" r="9"/><path d="M12 3v18" /><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none"/>',
  waveform: '<path d="M2 12h2M6 8v8M10 4v16M14 7v10M18 9v6M22 11v2"/>',
  play: '<path d="M6 4l14 8-14 8z" fill="currentColor" stroke="none"/>',
  pause: '<rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  "x.circle": '<circle cx="12" cy="12" r="10"/><path d="M15 9l-6 6M9 9l6 6"/>',
  wand: '<path d="M15 4V2M15 16v-2M8 9h2M20 9h2M17.8 11.8 19 13M17.8 6.2 19 5M3 21l9-9M12.2 6.2 11 5"/>',
  merge: '<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M6 9v6"/><path d="M18 15a9 9 0 0 0-9-9"/><circle cx="18" cy="18" r="3"/>',
  seal: '<circle cx="12" cy="12" r="10"/><path d="M9 12l2 2 4-4"/>',
  copy: '<rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>',
  "arrow.up.to.line": '<path d="M12 20V8M6 12l6-6 6 6M4 4h16"/>',
  download: '<path d="M12 3v12M7 10l5 5 5-5M5 21h14"/>',
  "square.and.arrow.up": '<path d="M12 15V3M8 7l4-4 4 4M4 12v8a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-8"/>',
  drive: '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="M2 12h20M6 16h.01M10 16h.01"/>',
  "arrow.uturn.backward": '<path d="M3 7v6h6"/><path d="M3 13a9 9 0 1 0 3-7.7L3 8"/>',
  "arrow.turn.up.right": '<path d="M15 5l4 4-4 4"/><path d="M4 19v-6a4 4 0 0 1 4-4h11"/>',
  "photo.badge.down": '<rect x="3" y="3" width="18" height="14" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 13l-5-4L5 17"/><path d="M12 20v-4M9 18l3 3 3-3"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  promote: '<path d="M12 19V6M5 12l7-7 7 7"/>',
  "split.import": '<path d="M12 3v12M8 11l4 4 4-4"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
  minus: '<path d="M5 12h14"/>',
};
function icon(name, size = 16) {
  const inner = ICONS[name] || ICONS.circle;
  return `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
}
const badgeIcon = { photo: "photo.on.rectangle", mic: "mic", film: "video", paperclip: "paperclip" };

/* ------------------------------------------------------------------ */
/* Appearance / prefs                                                  */
/* ------------------------------------------------------------------ */
const ACCENTS = {
  blue: "#1C7ED6", indigo: "#5C5CD6", purple: "#945CD6", pink: "#E0568C",
  red: "#E04A4A", orange: "#F08C38", teal: "#24AAA8", green: "#34A86C",
};
const TAG_PALETTE = ["#1C7ED6", "#24AAA8", "#34A86C", "#F08C38", "#E0568C", "#945CD6", "#E04A4A", "#5C5CD6", "#3AB795", "#22B8CF", "#A97142"];
const FONTS = {
  lato: '"Lato", system-ui, sans-serif', system: "system-ui, sans-serif",
  serif: 'Georgia, "Times New Roman", serif', mono: 'ui-monospace, Menlo, monospace',
};
const FONT_SIZES = [16, 18, 20, 22, 24, 26];
const DEFAULTS = {
  colorScheme: "auto", writingFont: "lato", fontSize: 18, accentColor: "blue",
  dateStyle: "weekday", highlightTags: true, firstWeekday: 1, showWeekNumbers: false,
  splitTags: "", dataSaver: false, inboxSort: "newest", archiveSort: "newest", timerMinutes: 15,
  wordGoalEnabled: false, wordGoal: 750, writingPrompts: false,
};

/* Writing prompts — same deck as the Swift app's PromptDeck, stable per day. */
const PROMPTS = [
  "What surprised you today?",
  "What would you tell yourself a year ago?",
  "Describe where you are right now — all five senses.",
  "What's the smallest thing that made you smile lately?",
  "What are you avoiding writing about?",
  "Who did you last have a real conversation with?",
  "What did you almost do today?",
  "What's changed since this time last month?",
  "Write about something you're looking forward to.",
  "What's a question you can't answer yet?",
  "What did you notice on the way somewhere today?",
  "What would you do with a free afternoon tomorrow?",
  "What's worth remembering about this week?",
  "Describe today in exactly three sentences.",
  "What are you carrying that you could put down?",
  "What did you learn the hard way recently?",
  "Write the first paragraph of the story of today.",
  "What sound, smell, or taste took you somewhere else?",
  "What do you want more of? Less of?",
  "Who deserves a thank-you you haven't sent?",
];
function promptOfDay(offset = 0) {
  const day = Math.floor(Date.now() / 86400000);
  return PROMPTS[((day + offset) % PROMPTS.length + PROMPTS.length) % PROMPTS.length];
}
function pref(k) { const v = S.prefs[k]; return v === undefined || v === null ? DEFAULTS[k] : v; }
async function setPref(k, v) { S.prefs[k] = v; await invoke("set_pref", { key: k, value: v }); }

function applyAppearance() {
  const root = document.documentElement;
  const cs = pref("colorScheme");
  root.setAttribute("data-theme", cs);
  root.style.setProperty("--accent", ACCENTS[pref("accentColor")] || ACCENTS.blue);
  root.style.setProperty("--writing-font", FONTS[pref("writingFont")] || FONTS.lato);
  root.style.setProperty("--font-size", pref("fontSize") + "px");
  // Theme native form controls (select popups, date pickers) to match.
  const dark = cs === "dark" || (cs === "auto" && matchMedia("(prefers-color-scheme: dark)").matches);
  root.style.colorScheme = dark ? "dark" : "light";
}

/* ------------------------------------------------------------------ */
/* Dates                                                               */
/* ------------------------------------------------------------------ */
function isoToDate(iso) { const [y, m, d] = iso.split("-").map(Number); return new Date(y, (m || 1) - 1, d || 1); }
function jsNowTs() {
  const d = new Date(), p = n => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}
function timeOf(ts) { return ts.slice(11, 16); }
/* Coerce anything entry-shaped to a jnl timestamp "YYYY-MM-DD HH:MM:SS". */
function normTs(ts) {
  const s = String(ts ?? "").replace("T", " ").trim();
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/.test(s)) return s.slice(0, 19);
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(s)) return s + ":00";
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s + " 00:00:00";
  return jsNowTs();
}
function isoOf(d) { const p = n => String(n).padStart(2, "0"); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`; }
function displayDate(iso, withYear = false) {
  const style = pref("dateStyle"); if (style === "iso") return iso;
  const d = isoToDate(iso); const o = {};
  if (style === "weekday") { Object.assign(o, { weekday: "short", day: "numeric", month: "short" }); if (withYear) o.year = "numeric"; }
  else if (style === "medium") Object.assign(o, { day: "numeric", month: "short", year: "numeric" });
  else Object.assign(o, { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  return d.toLocaleDateString(undefined, o);
}
function sectionDate(iso) { return displayDate(iso, true); }

/* ---- Date & time field ---------------------------------------------
   Deliberately NOT <input type="datetime-local">: WebKitGTK hands that off to a
   native UI-process picker whose popup can wedge the whole window (the app looks
   frozen until it's killed), and it silently truncates the seconds that jnl
   timestamps carry. This is a plain in-app popover instead — same widget on every
   platform, seconds preserved.
   Returns { el, value } where `value` is a "YYYY-MM-DD HH:MM:SS" string. */
function dateField(initial, onChange) {
  let cur = normTs(initial);
  const wrap = el(`<div class="date-wrap"><button class="date-btn" type="button" title="Change date & time">${icon("calendar", 14)}<span class="date-btn-label"></span></button></div>`);
  const b = $(".date-btn", wrap), lab = $(".date-btn-label", wrap);
  const paint = () => { lab.textContent = `${displayDate(cur.slice(0, 10))} · ${cur.slice(11, 19)}`; };
  const set = next => { cur = normTs(next); paint(); onChange(cur); };
  b.onclick = e => { e.stopPropagation(); openDatePopover(b, cur, set); };
  paint();
  return { el: wrap, get value() { return cur; }, set value(v) { cur = normTs(v); paint(); } };
}

/* Popover anchored under `anchor`; calls pick(ts) on every change. Lives in
   #menu-root with class "menu" so the global click-away handler dismisses it. */
function openDatePopover(anchor, cur, pick) {
  closeMenus();
  let ymd = cur.slice(0, 10), hms = cur.slice(11, 19);
  const view = { y: +ymd.slice(0, 4), m: +ymd.slice(5, 7) - 1 };
  const pop = el(`<div class="menu datepop">
    <div class="mc-head"><div class="mc-title"></div><div class="mc-nav"></div></div>
    <div class="dp-grid"></div>
    <div class="dp-time">${icon("clock", 13)}<input class="dp-t" type="text" inputmode="numeric" maxlength="8" spellcheck="false"/><button class="dp-now" type="button">Now</button></div>
  </div>`);
  const nav = $(".mc-nav", pop), timeI = $(".dp-t", pop);
  const prev = el(`<button type="button" title="Previous month">${icon("chevron.left", 13)}</button>`);
  const tod = el(`<button class="mc-today" type="button" title="This month">${icon("today", 13)}</button>`);
  const next = el(`<button type="button" title="Next month">${icon("chevron.right", 13)}</button>`);
  nav.append(prev, tod, next);
  prev.onclick = () => { if (--view.m < 0) { view.m = 11; view.y--; } drawGrid(); };
  next.onclick = () => { if (++view.m > 11) { view.m = 0; view.y++; } drawGrid(); };
  tod.onclick = () => { const n = new Date(); view.y = n.getFullYear(); view.m = n.getMonth(); drawGrid(); };

  function drawGrid() {
    $(".mc-title", pop).textContent = new Date(view.y, view.m, 1).toLocaleDateString(undefined, { month: "long", year: "numeric" });
    const grid = $(".dp-grid", pop); grid.innerHTML = "";
    const offset = (pref("firstWeekday") - 1) % 7;
    const wds = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
    for (let i = 0; i < 7; i++) grid.appendChild(el(`<div class="mc-wd">${wds[(i + offset) % 7]}</div>`));
    const lead = (new Date(view.y, view.m, 1).getDay() - offset + 7) % 7;
    const start = new Date(view.y, view.m, 1 - lead);
    const todayKey = isoOf(new Date());
    for (let i = 0; i < 42; i++) {
      const d = new Date(start); d.setDate(start.getDate() + i);
      const key = isoOf(d);
      const cell = el(`<div class="mc-day pick ${d.getMonth() === view.m ? "inmonth" : ""} ${key === todayKey ? "today" : ""}" data-key="${key}">${d.getDate()}</div>`);
      // Re-class in place rather than redrawing: replacing the clicked node mid-click
      // detaches it, and the click-away handler then can't see it inside .menu and
      // would close the popover on every date pick.
      cell.onclick = () => { ymd = key; markSelected(); pick(`${ymd} ${hms}`); };
      grid.appendChild(cell);
    }
    markSelected();
  }
  function markSelected() {
    $$(".mc-day", pop).forEach(c => c.classList.toggle("sel", c.dataset.key === ymd));
  }
  drawGrid();

  timeI.value = hms;
  const commitTime = () => {
    const m = timeI.value.trim().match(/^(\d{1,2})(?::(\d{1,2}))?(?::(\d{1,2}))?$/);
    if (!m) { timeI.value = hms; return; }
    const cl = (n, hi) => String(Math.min(hi, Math.max(0, +n || 0))).padStart(2, "0");
    hms = `${cl(m[1], 23)}:${cl(m[2] || 0, 59)}:${cl(m[3] || 0, 59)}`;
    timeI.value = hms;
    pick(`${ymd} ${hms}`);
  };
  timeI.onchange = commitTime;
  timeI.onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); commitTime(); closeMenus(); } };
  $(".dp-now", pop).onclick = () => { const n = jsNowTs(); ymd = n.slice(0, 10); hms = n.slice(11, 19); timeI.value = hms; view.y = +ymd.slice(0, 4); view.m = +ymd.slice(5, 7) - 1; drawGrid(); pick(`${ymd} ${hms}`); };

  $("#menu-root").appendChild(pop);
  const a = anchor.getBoundingClientRect(), r = pop.getBoundingClientRect();
  pop.style.left = Math.max(8, Math.min(a.left, innerWidth - r.width - 8)) + "px";
  pop.style.top = (a.bottom + 4 + r.height > innerHeight ? Math.max(8, a.top - r.height - 4) : a.bottom + 4) + "px";
}

/* ------------------------------------------------------------------ */
/* Global state                                                        */
/* ------------------------------------------------------------------ */
const S = {
  prefs: {}, snap: null, sec: "write", sub: null,
  sel: {},                 // per-context selected entry ts
  cal: null,               // {y, m}
  timer: { remaining: 900, running: false, int: null },
  editor: null,            // active EntryEditor (flush on teardown)
  insertMedia: null,       // fn(rel) to append media into the active editor
  newEntry: null,          // fn() the composer's New button, for Ctrl+N
  recorder: null,
  onMediaProgress: null,   // fn(done, total) while Compress Existing Media runs
};

const SECTIONS = [
  ["write", "Write", "square.and.pencil"],
  ["inbox", "Inbox", "tray"],
  ["archive", "Journal", "book.closed"],
  ["starred", "Starred", "star"],
  ["split", "Split Journals", "bookmark"],
  ["tags", "Tags", "number"],
  ["assets", "Assets", "photo.on.rectangle"],
  ["search", "Search", "search"],
];

/* ------------------------------------------------------------------ */
/* Menus, modals, toasts                                               */
/* ------------------------------------------------------------------ */
function closeMenus() { $("#menu-root").innerHTML = ""; }
document.addEventListener("click", e => { if (!e.target.closest(".menu")) closeMenus(); });
function openMenuAt(x, y, items) {
  closeMenus();
  const m = el(`<div class="menu"></div>`);
  for (const it of items) {
    if (it.sep) { m.appendChild(el(`<div class="menu-sep"></div>`)); continue; }
    if (it.label && it.header) { m.appendChild(el(`<div class="menu-label">${esc(it.label)}</div>`)); continue; }
    const b = el(`<button class="menu-item ${it.danger ? "danger" : ""}" ${it.disabled ? "disabled" : ""}>${it.icon ? icon(it.icon) : ""}<span>${esc(it.label)}</span>${it.checked ? '<span class="check">' + icon("check", 14) + "</span>" : ""}</button>`);
    if (!it.disabled) b.onclick = () => { closeMenus(); it.action && it.action(); };
    m.appendChild(b);
  }
  $("#menu-root").appendChild(m);
  const r = m.getBoundingClientRect();
  m.style.left = Math.min(x, innerWidth - r.width - 8) + "px";
  m.style.top = Math.min(y, innerHeight - r.height - 8) + "px";
}
function menuFromButton(btn, items) { const r = btn.getBoundingClientRect(); openMenuAt(r.right - 210, r.bottom + 4, items); }

function modal({ title, bodyEl, foot }) {
  const back = el(`<div class="backdrop"></div>`);
  const m = el(`<div class="modal"></div>`);
  m.appendChild(el(`<div class="modal-head"><div class="view-title">${esc(title)}</div></div>`));
  const body = el(`<div class="modal-body"></div>`); body.appendChild(bodyEl); m.appendChild(body);
  if (foot) { const f = el(`<div class="modal-foot"></div>`); foot.forEach(x => f.appendChild(x)); m.appendChild(f); }
  back.appendChild(m); $("#modal-root").appendChild(back);
  back.onclick = e => { if (e.target === back) close(); };
  function close() { back.remove(); }
  return { close, root: m };
}
function btn(label, { primary, danger, icon: ic } = {}) {
  const b = el(`<button class="btn ${danger ? "danger" : ""}" ${primary ? 'style="background:var(--accent);color:#fff;border-color:var(--accent)"' : ""}>${ic ? icon(ic, 14) : ""}${esc(label)}</button>`);
  return b;
}
function alertModal(title, message) {
  return new Promise(res => {
    const body = el(`<div style="padding:16px 18px;font-size:14px;line-height:1.5">${esc(message)}</div>`);
    const ok = btn("OK", { primary: true });
    const mo = modal({ title, bodyEl: body, foot: [ok] });
    ok.onclick = () => { mo.close(); res(); };
  });
}
function confirmModal(title, message, okLabel = "OK", danger = false) {
  return new Promise(res => {
    const body = el(`<div style="padding:16px 18px;font-size:14px;line-height:1.5">${esc(message)}</div>`);
    const cancel = btn("Cancel"); const ok = btn(okLabel, { primary: !danger, danger });
    const mo = modal({ title, bodyEl: body, foot: [cancel, ok] });
    cancel.onclick = () => { mo.close(); res(false); };
    ok.onclick = () => { mo.close(); res(true); };
  });
}
function promptModal(title, initial = "", label = "") {
  return new Promise(res => {
    const body = el(`<div style="padding:16px 18px;display:flex;flex-direction:column;gap:8px">${label ? `<div class="sub">${esc(label)}</div>` : ""}<input type="text" style="width:100%;padding:8px;font-size:14px;border:1px solid var(--border);border-radius:8px;background:var(--bg-inset);color:var(--text)"/></div>`);
    const input = $("input", body); input.value = initial;
    const cancel = btn("Cancel"); const ok = btn("Save", { primary: true });
    const mo = modal({ title, bodyEl: body, foot: [cancel, ok] });
    setTimeout(() => input.focus(), 30);
    input.onkeydown = e => { if (e.key === "Enter") ok.click(); if (e.key === "Escape") cancel.click(); };
    cancel.onclick = () => { mo.close(); res(null); };
    ok.onclick = () => { mo.close(); res(input.value); };
  });
}
let toastTimer;
function toast(msg, error) {
  const r = $("#toast-root"); r.innerHTML = ""; r.appendChild(el(`<div class="toast ${error ? "error" : ""}">${esc(msg)}</div>`));
  clearTimeout(toastTimer); toastTimer = setTimeout(() => (r.innerHTML = ""), error ? 4000 : 1800);
}

/* ------------------------------------------------------------------ */
/* Disk writes                                                         */
/* ------------------------------------------------------------------ */
/* Every write runs on one chain, so a debounced autosave can't overlap itself
   and fork a draft (two commits passing the same `previous`), and a refresh can
   wait for the write in flight. Never enqueue from inside an enqueued function
   — the chain would deadlock. */
let writeChain = Promise.resolve();
function enqueue(fn) { const p = writeChain.then(fn, fn); writeChain = p.catch(() => {}); return p; }
function writesSettled() { return writeChain; }
/* Writes can fail — a read-only folder, a full disk, an entry whose text no
   longer parses as one. Say so rather than toasting "Saved" over the failure. */
function toastError(e) { toast(String((e && e.message) || e || "Couldn't write to disk"), true); }
async function writeCmd(cmd, args) {
  try { return { ok: true, value: await enqueue(() => invoke(cmd, args)) }; }
  catch (e) { toastError(e); return { ok: false }; }
}
/* commit() resolves true (saved) or false (the write failed and already
   toasted — a bad timestamp arrives this way, refused by the Rust side). */
function saveOutcome(r) { return r === true; }

/* ------------------------------------------------------------------ */
/* Data refresh                                                        */
/* ------------------------------------------------------------------ */
async function refresh(rerender = true) {
  await writesSettled(); // never reload over a save still in flight
  S.snap = await invoke("reload");
  renderStorageBanner();
  S.savedSearches = await invoke("saved_searches").catch(() => []) || [];
  renderSidebar();
  renderMiniCal();
  if (rerender) renderView();
}

/* A chosen journal folder that has gone missing is not a footnote in Settings:
   every write is refused while it's away, so say so where it can't be missed. */
function renderStorageBanner() {
  const existing = $("#storage-banner"); if (existing) existing.remove();
  if (!S.snap || S.snap.storage_mode !== "missing") return;
  const b = el(`<div id="storage-banner" class="storage-banner">${icon("x.circle", 15)}<span>Journal folder unavailable — <span class="mono">${esc(S.snap.base_path)}</span>. Nothing can be saved until it's back.</span><button>Settings</button></div>`);
  $("button", b).onclick = () => setSection("settings");
  document.body.appendChild(b);
}

/* ------------------------------------------------------------------ */
/* Sidebar + footer + mini-calendar                                    */
/* ------------------------------------------------------------------ */
function renderSidebar() {
  const nav = $("#nav"); nav.innerHTML = "";
  for (const [key, label, ic] of SECTIONS) {
    const badge = key === "inbox" && S.snap && S.snap.inbox_drafts.length ? `<span class="badge">${S.snap.inbox_drafts.length}</span>` : "";
    const b = el(`<button class="nav-item ${S.sec === key ? "active" : ""}"><span class="ic">${icon(ic)}</span><span>${label}</span>${badge}</button>`);
    b.onclick = () => setSection(key);
    nav.appendChild(b);
  }
  // Pinned queries from the Search view — smart folders.
  if (S.savedSearches && S.savedSearches.length) {
    nav.appendChild(el(`<div class="menu-label" style="padding:10px 12px 2px">Saved Searches</div>`));
    for (const s of S.savedSearches) {
      const b = el(`<button class="nav-item"><span class="ic">${icon("search")}</span><span>${esc(s.name)}</span></button>`);
      b.onclick = () => { S.searchQuery = s.query; setSection("search"); };
      b.oncontextmenu = e => { e.preventDefault(); openMenuAt(e.clientX, e.clientY, [
        { label: "Remove Pin", icon: "x", danger: true, action: async () => { await invoke("remove_saved_search", { name: s.name }); refresh(false); } },
      ]); };
      nav.appendChild(b);
    }
  }
  renderFooterControls();
}
function renderFooterControls() {
  const f = $("#footer-controls"); f.innerHTML = "";
  f.appendChild(el(`<div class="footer-spacer"></div>`));
  // timer
  const t = S.timer;
  const running = t.running;
  const tb = el(`<button id="timer-btn" class="footer-btn ${running ? "running" : ""} ${running && t.remaining <= 0 ? "zero" : ""}" title="Focus timer">${running ? timerLabel() : icon("timer")}</button>`);
  tb.onclick = () => menuFromButton(tb, [
    { label: t.running ? "Pause" : "Start", icon: t.running ? "pause" : "play", action: toggleTimer },
    { label: "Reset", icon: "refresh", action: resetTimer },
    { sep: true }, { label: "Duration", header: true },
    ...[5, 10, 15, 20, 25, 30].map(m => ({ label: m + " min", checked: pref("timerMinutes") === m, action: () => setTimerMinutes(m) })),
  ]);
  f.appendChild(tb);
  const stats = el(`<button class="footer-btn ${S.sec === "stats" ? "active" : ""}" title="Stats">${icon("chart.bar")}</button>`);
  stats.onclick = () => setSection("stats"); f.appendChild(stats);
  const set = el(`<button class="footer-btn ${S.sec === "settings" ? "active" : ""}" title="Settings">${icon("gearshape")}</button>`);
  set.onclick = () => setSection("settings"); f.appendChild(set);
}
function timerLabel() { const s = Math.max(0, S.timer.remaining); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); }
function toggleTimer() {
  S.timer.running = !S.timer.running;
  if (S.timer.running && !S.timer.int) {
    S.timer.int = setInterval(() => {
      if (!S.timer.running) return;
      S.timer.remaining--; if (S.timer.remaining <= 0) { S.timer.remaining = 0; S.timer.running = false; }
      const b = $("#timer-btn"); if (b) { b.classList.toggle("running", S.timer.running || S.timer.remaining < pref("timerMinutes") * 60); b.classList.toggle("zero", S.timer.remaining <= 0); b.innerHTML = S.timer.remaining <= 0 || S.timer.running ? timerLabel() : icon("timer"); }
    }, 1000);
  }
  renderFooterControls();
}
function resetTimer() { S.timer.running = false; S.timer.remaining = pref("timerMinutes") * 60; renderFooterControls(); }
function setTimerMinutes(m) { setPref("timerMinutes", m); if (!S.timer.running) S.timer.remaining = m * 60; renderFooterControls(); }

function renderMiniCal() {
  if (!S.cal) { const n = new Date(); S.cal = { y: n.getFullYear(), m: n.getMonth() }; }
  const wrap = $("#minical"); wrap.innerHTML = "";
  const { y, m } = S.cal;
  const dayInfo = {}; // "YYYY-MM-DD" -> {has, star, photo, video, audio}
  if (S.snap) for (const d of S.snap.archive_days) dayInfo[d.date] = d;
  const title = new Date(y, m, 1).toLocaleDateString(undefined, { month: "short", year: "numeric" });
  const head = el(`<div class="mc-head"><div class="mc-title">${esc(title)}</div><div class="mc-nav"></div></div>`);
  const nav = $(".mc-nav", head);
  const prev = el(`<button title="Previous">${icon("chevron.left", 13)}</button>`); prev.onclick = () => shiftMonth(-1);
  const tod = el(`<button class="mc-today" title="Today">${icon("today", 13)}</button>`); tod.onclick = () => { const n = new Date(); S.cal = { y: n.getFullYear(), m: n.getMonth() }; renderMiniCal(); };
  const next = el(`<button title="Next">${icon("chevron.right", 13)}</button>`); next.onclick = () => shiftMonth(1);
  nav.append(prev, tod, next); wrap.appendChild(head);

  const wk = pref("showWeekNumbers");
  const grid = el(`<div class="mc-grid ${wk ? "wk" : ""}"></div>`);
  const first = pref("firstWeekday"); // 1=Sun,2=Mon,7=Sat
  const wds = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"];
  const offset = (first - 1) % 7;
  if (wk) grid.appendChild(el(`<div class="mc-wd"></div>`)); // corner above week-number column
  for (let i = 0; i < 7; i++) grid.appendChild(el(`<div class="mc-wd">${wds[(i + offset) % 7]}</div>`));
  const firstDow = new Date(y, m, 1).getDay();
  const lead = (firstDow - offset + 7) % 7;
  const start = new Date(y, m, 1 - lead);
  const todayKey = (() => { const d = new Date(), p = n => String(n).padStart(2, "0"); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`; })();
  for (let i = 0; i < 42; i++) {
    const d = new Date(start); d.setDate(start.getDate() + i);
    if (wk && i % 7 === 0) grid.appendChild(el(`<div class="mc-wk">${isoWeek(d)}</div>`));
    const p = n => String(n).padStart(2, "0");
    const key = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
    const inMonth = d.getMonth() === m;
    const info = dayInfo[key];
    // Media-typed dots under the number (photo / video / audio), the way the
    // Swift mini-calendar marks a day — and what the README has been promising.
    const dots = info ? ["has_photo", "has_video", "has_audio"].filter(k => info[k]).map(k => `<span class="mc-dot ${k.slice(4)}"></span>`).join("") : "";
    const cell = el(`<div class="mc-day ${inMonth ? "inmonth" : ""} ${info ? "has" : ""} ${key === todayKey ? "today" : ""}">${d.getDate()}${info && info.has_starred ? '<span class="mc-star">' + icon("star.fill", 6) + "</span>" : ""}${dots ? `<span class="mc-dots">${dots}</span>` : ""}</div>`);
    if (dots) cell.title = ["photo", "video", "audio"].filter((_, i) => [info.has_photo, info.has_video, info.has_audio][i]).join(" · ");
    if (info) cell.onclick = () => openDay(key);
    grid.appendChild(cell);
  }
  wrap.appendChild(grid);
}
/* ISO-8601 week number (weeks start Monday; week 1 contains the first Thursday). */
function isoWeek(date) {
  const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  const dayNum = (d.getUTCDay() + 6) % 7; // Mon=0 … Sun=6
  d.setUTCDate(d.getUTCDate() - dayNum + 3); // nearest Thursday
  const firstThursday = new Date(Date.UTC(d.getUTCFullYear(), 0, 4));
  const firstDayNum = (firstThursday.getUTCDay() + 6) % 7;
  firstThursday.setUTCDate(firstThursday.getUTCDate() - firstDayNum + 3);
  return 1 + Math.round((d - firstThursday) / (7 * 24 * 3600 * 1000));
}
function shiftMonth(delta) { let { y, m } = S.cal; m += delta; if (m < 0) { m = 11; y--; } if (m > 11) { m = 0; y++; } S.cal = { y, m }; renderMiniCal(); }

/* ------------------------------------------------------------------ */
/* Navigation                                                          */
/* ------------------------------------------------------------------ */
/* Awaited everywhere: the pending autosave has to land before the next view
   reads the journal, or the edit looks lost until the following reload. */
async function teardownEditor() { const ed = S.editor; S.editor = null; S.insertMedia = null; if (ed) await ed.flush(); }
async function setSection(sec) { await teardownEditor(); S.sec = sec; S.sub = null; renderSidebar(); renderFooterControls(); await refresh(false); renderView(); }
async function openDay(date) { await teardownEditor(); S.sec = "archive"; S.sub = { type: "day", date }; renderSidebar(); renderView(); }
async function openJournalFile(name) { await teardownEditor(); S.sec = "split"; S.sub = { type: "journalFile", name }; renderView(); }
async function openTagDetail(tag) { await teardownEditor(); S.sec = "tags"; S.sub = { type: "tag", tag }; renderView(); }
function goBack() { if (S.sub) { S.sub = null; renderView(); } }

/* ------------------------------------------------------------------ */
/* View router                                                         */
/* ------------------------------------------------------------------ */
async function renderView() {
  await teardownEditor();
  const main = $("#main"); main.innerHTML = "";
  if (S.sub) {
    if (S.sub.type === "day") return renderDay(main, S.sub.date);
    if (S.sub.type === "journalFile") return renderJournalFile(main, S.sub.name);
    if (S.sub.type === "tag") return renderTagDetail(main, S.sub.tag);
  }
  switch (S.sec) {
    case "write": return renderWrite(main);
    case "inbox": return renderInbox(main);
    case "archive": return renderArchive(main);
    case "starred": return renderStarred(main);
    case "split": return renderSplit(main);
    case "tags": return renderTags(main);
    case "assets": return renderAssets(main);
    case "search": return renderSearch(main);
    case "stats": return renderStats(main);
    case "settings": return renderSettings(main);
  }
}
function header(title, { back } = {}) {
  const h = el(`<div class="view-header"></div>`);
  if (back) { const b = el(`<button class="tbtn icon" title="Back">${icon("chevron.left")}</button>`); b.onclick = goBack; h.appendChild(b); }
  h.appendChild(el(`<div class="view-title">${esc(title)}</div>`));
  h.appendChild(el(`<div class="header-spacer"></div>`));
  return h;
}
function emptyState(ic, t, s) { return el(`<div class="empty"><div class="big">${icon(ic, 34)}</div><div class="t">${esc(t)}</div><div class="s">${esc(s)}</div></div>`); }
function searchBox(placeholder, oninput) {
  const s = el(`<div class="search">${icon("search", 14)}<input placeholder="${esc(placeholder)}"/></div>`);
  $("input", s).addEventListener("input", e => oninput(e.target.value));
  return s;
}

/* ------------------------------------------------------------------ */
/* WRITE (composer)                                                    */
/* ------------------------------------------------------------------ */
function renderWrite(main) {
  const view = el(`<div class="view"></div>`);
  const h = header("Write");
  const st = { title: "", date: jsNowTs(), text: "", activeTS: null, recording: false };
  // Serialised: two overlapping autosaves would both read the same `previous`
  // and leave the draft forked in two.
  const commit = reindex => enqueue(() => doCommit(reindex));
  const save = debounce(commit, 500);
  async function doCommit(reindex) {
    const ts = normTs(st.date);
    try {
      if (!st.text.trim() && !st.title.trim()) { if (st.activeTS) { await invoke("remove_draft", { timestamp: st.activeTS }); st.activeTS = null; } }
      else st.activeTS = (await invoke("upsert_draft", { previous: st.activeTS, timestamp: ts, title: st.title, body: st.text })) ?? ts;
    } catch (e) { toastError(e); return false; }
    if (reindex) refresh(false).then(renderSidebar);
    return true;
  }
  // toolbar buttons
  const newBtn = el(`<button class="tbtn" title="New entry (Ctrl+N)">${icon("square.and.pencil")}New</button>`);
  const recBtn = el(`<button class="tbtn icon" title="Record audio">${icon("mic")}</button>`);
  const moreBtn = el(`<button class="tbtn icon" title="More">${icon("ellipsis")}</button>`);
  h.append(newBtn, recBtn, moreBtn);
  view.appendChild(h);

  const composer = el(`<div class="composer"><div class="composer-inner">
    <div class="compose-head">
      <input class="title-input" placeholder="Title"/>
      <div class="date-slot"></div>
    </div>
    <div class="divider"></div>
    <div class="compose-body-wrap"><textarea class="body-editor" spellcheck="true"></textarea><div class="placeholder-overlay">Begin writing</div></div>
  </div></div>`);
  const titleI = $(".title-input", composer), bodyI = $(".body-editor", composer), ph = $(".placeholder-overlay", composer);
  // Writing prompts: the empty composer asks a question (stable per day).
  let promptOffset = 0;
  const syncPrompt = () => { ph.textContent = pref("writingPrompts") ? promptOfDay(promptOffset) : "Begin writing"; };
  syncPrompt();
  const dateF = dateField(st.date, ts => { st.date = ts; save(); });
  $(".date-slot", composer).replaceWith(dateF.el);
  const hlUpdate = attachTagHighlight($(".compose-body-wrap", composer), bodyI);
  const syncPh = () => (ph.style.display = bodyI.value ? "none" : "block");
  titleI.oninput = () => { st.title = titleI.value; save(); };
  titleI.onkeydown = e => { if (e.key === "Enter") { e.preventDefault(); bodyI.focus(); } };
  bodyI.oninput = () => { st.text = bodyI.value; syncPh(); save(); };
  view.appendChild(composer);
  main.appendChild(view);
  setTimeout(() => bodyI.focus(), 20);

  // media insertion target
  S.insertMedia = rel => { bodyI.value += (bodyI.value ? "\n\n" : "") + `![](${rel})`; st.text = bodyI.value; syncPh(); hlUpdate(); save.now(true); };
  S.editor = { flush: () => { save.cancel(); return commit(true); } };

  // IMPORTANT: await the save before clearing, else commit()'s async tail resets
  // st.activeTS to the just-saved entry — and the next entry's autosave would then
  // pass it as `previous` and delete the entry we just filed into the inbox.
  // A refused save keeps the text on screen — clearing it would throw the entry away.
  async function reset() { save.cancel(); if (!saveOutcome(await commit(true))) return false; st.title = ""; st.text = ""; st.date = jsNowTs(); st.activeTS = null; titleI.value = ""; bodyI.value = ""; dateF.value = st.date; syncPh(); hlUpdate(); bodyI.focus(); return true; }
  newBtn.onclick = async () => { const had = st.text.trim() || st.title.trim(); if (!(await reset())) return; if (had) toast("Saved to inbox"); };
  // Ctrl+N in the composer means the same thing the button does.
  S.newEntry = newBtn.onclick;
  recBtn.onclick = () => toggleRecord(recBtn, composer);
  moreBtn.onclick = async () => {
    const templates = await invoke("template_names").catch(() => []);
    menuFromButton(moreBtn, [
    { label: "Attach Media", icon: "paperclip", action: attachMedia },
    { label: "Record Video", icon: "video", action: () => recordVideo() },
    { label: "Promote first line to title", icon: "promote", disabled: !st.text.trim(), action: () => { const lines = st.text.split("\n"); const i = lines.findIndex(l => l.trim()); if (i < 0) return; st.title = lines[i].trim(); titleI.value = st.title; lines.splice(i, 1); st.text = lines.join("\n").replace(/^\n+/, ""); bodyI.value = st.text; syncPh(); hlUpdate(); save(); } },
    ...(templates.length ? [{ label: "Insert Template", header: true }] : []),
    ...templates.map(n => ({ label: n, icon: "copy", action: async () => {
      const body = await invoke("template_body", { name: n });
      if (!body) return;
      st.text = st.text ? st.text + "\n\n" + body : body;
      bodyI.value = st.text; syncPh(); hlUpdate(); save(); bodyI.focus();
    } })),
    ...(pref("writingPrompts") ? [{ label: "New Prompt", icon: "shuffle", action: () => { promptOffset++; syncPrompt(); } }] : []),
    { sep: true },
    { label: "Discard", icon: "trash", danger: true, disabled: !st.text.trim() && !st.title.trim() && !st.activeTS, action: async () => { save.cancel(); if (st.activeTS && !(await writeCmd("remove_draft", { timestamp: st.activeTS })).ok) return; st.title = ""; st.text = ""; st.activeTS = null; titleI.value = ""; bodyI.value = ""; syncPh(); hlUpdate(); toast("Discarded"); refresh(false).then(renderSidebar); } },
    { label: "Import as separate entries", icon: "split.import", disabled: !st.text.trim(), action: async () => { save.cancel(); if (st.activeTS) { if (!(await writeCmd("remove_draft", { timestamp: st.activeTS })).ok) return; st.activeTS = null; } const r = await writeCmd("import_drafts", { text: st.text }); if (!r.ok) return; const n = r.value; st.title = ""; st.text = ""; titleI.value = ""; bodyI.value = ""; syncPh(); hlUpdate(); toast(`Imported ${plural(n, "entry").replace("entrys", "entries")}`); refresh(false).then(renderSidebar); } },
  ]);
  };
  syncPh();
}

/* Attach / record helpers (shared by composer + entry editor) */
/* Recordings cross the IPC bridge as the request body, not as JSON: a ten-
   megabyte take used to be serialised as ten million integers in a JSON array,
   which froze the window for seconds while both sides chewed through the text. */
async function saveRecording(blob, ext) {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  try { return await invoke("save_asset", bytes, { headers: { ext } }); }
  catch (e) { toastError(e); return null; }
}
async function attachMedia() {
  const paths = await invoke("pick_media_files");
  for (const p of paths) { const rel = await invoke("import_asset", { src: p }); if (rel && S.insertMedia) S.insertMedia(rel); }
}
async function recordVideo() {
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ video: true, audio: true });
    const rec = new MediaRecorder(stream, { mimeType: "video/webm" }); const chunks = [];
    rec.ondataavailable = e => chunks.push(e.data);
    const stopBtn = btn("Stop Recording", { danger: true });
    const vid = el(`<video autoplay muted playsinline style="width:100%;max-height:50vh;background:#000;border-radius:10px"></video>`); vid.srcObject = stream;
    const body = el(`<div style="padding:16px;display:flex;flex-direction:column;gap:10px"></div>`); body.append(vid);
    const mo = modal({ title: "Record Video", bodyEl: body, foot: [stopBtn] });
    rec.onstop = async () => { stream.getTracks().forEach(t => t.stop()); mo.close(); const rel = await saveRecording(new Blob(chunks, { type: "video/webm" }), "webm"); if (rel && S.insertMedia) S.insertMedia(rel); };
    stopBtn.onclick = () => rec.stop(); rec.start();
  } catch (e) { alertModal("Camera unavailable", "Could not access the camera: " + e.message); }
}
async function toggleRecord(button, container) {
  if (S.recorder) { S.recorder.stop(); return; }
  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    let mime = "audio/ogg;codecs=opus"; if (!MediaRecorder.isTypeSupported(mime)) mime = "audio/webm";
    // A voice memo in a WebM container is `.weba`, not `.webm` — filed as the
    // latter every list, dot and `has:` filter called it a video.
    const ext = mime.startsWith("audio/ogg") ? "ogg" : "weba";
    const rec = new MediaRecorder(stream, { mimeType: mime }); const chunks = [];
    rec.ondataavailable = e => chunks.push(e.data);
    let elapsed = 0; const t0 = Date.now();
    const banner = el(`<div class="rec-banner"><span class="rec-dot"></span><span class="rec-time">Recording 0:00</span><button class="rec-stop">Stop</button></div>`);
    const tick = setInterval(() => { elapsed = Math.floor((Date.now() - t0) / 1000); $(".rec-time", banner).textContent = `Recording ${Math.floor(elapsed / 60)}:${String(elapsed % 60).padStart(2, "0")}`; }, 500);
    (container || $("#main")).appendChild(banner);
    button.classList.add("rec-on"); button.innerHTML = icon("stop");
    $(".rec-stop", banner).onclick = () => rec.stop();
    rec.onstop = async () => { clearInterval(tick); banner.remove(); button.classList.remove("rec-on"); button.innerHTML = icon("mic"); stream.getTracks().forEach(t => t.stop()); S.recorder = null; const rel = await saveRecording(new Blob(chunks, { type: mime }), ext); if (rel && S.insertMedia) S.insertMedia(rel); };
    rec.start(); S.recorder = rec;
  } catch (e) { alertModal("Microphone unavailable", "Could not access the microphone: " + e.message); }
}

/* ------------------------------------------------------------------ */
/* Row rendering (shared list rows)                                    */
/* ------------------------------------------------------------------ */
/* Recompute an entry's display fields client-side after an in-place edit, so the
   list row and a later reselect reflect the save without a full reload. */
function mediaBadgesFor(raw) {
  const re = /!\[[^\]]*\]\(([^)]+)\)/g; let m, img = false, aud = false, vid = false;
  while ((m = re.exec(raw))) { const k = assetKind(m[1]); if (k === "image") img = true; else if (k === "audio") aud = true; else vid = true; }
  const out = []; if (img) out.push("photo"); if (aud) out.push("mic"); if (vid) out.push("film"); return out;
}
function patchEntry(e, ts, title, body, raw) {
  const t = (title || "").trim();
  const starred = t.endsWith("*");
  const dt = starred ? t.replace(/\*+$/, "").trim() : t;
  const firstLine = (body.split("\n").find(l => l.trim()) || "").trim();
  const tags = raw.match(/@[a-zA-Z][a-zA-Z0-9_-]*/g) || [];
  return { ...e, ts, date: ts.slice(0, 10), suffix: t, body, raw, is_starred: starred, display_title: dt, preview: dt || firstLine, tags, media_badges: mediaBadgesFor(raw) };
}

function entryRow(entry, { showTime, fullDate, date, inboxBadge } = {}) {
  const badges = (entry.media_badges || []).map(b => icon(badgeIcon[b] || "paperclip", 13)).join("");
  let trailing = "";
  if (fullDate && date) trailing = `${esc(sectionDate(date))} · ${timeOf(entry.ts)}`;
  else if (showTime) trailing = timeOf(entry.ts);
  const row = el(`<div class="row">
    <div class="r1">${entry.is_starred ? '<span class="star-ic">' + icon("star.fill", 12) + "</span>" : ""}<span class="prev">${esc(entry.preview || "(empty)")}</span>
      <span style="flex:1"></span>${badges ? '<span class="mini-badges">' + badges + "</span>" : ""}
      ${inboxBadge ? '<span class="badge-cap">Inbox</span>' : ""}${trailing ? `<span style="font-size:12px;color:var(--text-2);font-variant-numeric:tabular-nums">${trailing}</span>` : ""}
    </div>
    ${entry.body ? `<div class="r-body">${esc(entry.body)}</div>` : ""}
    ${entry.tags && entry.tags.length ? `<div class="tags">${esc(entry.tags.join(" "))}</div>` : ""}
  </div>`);
  return row;
}

/* ------------------------------------------------------------------ */
/* Generic two-pane                                                    */
/* ------------------------------------------------------------------ */
function twoPane({ entries, sourceFor, showTime, fullDate, groupByDate, oldestFirst, ctxKey, onDelete }) {
  const wrap = el(`<div class="twopane"></div>`);
  const list = el(`<div class="pane-list"></div>`);
  const detail = el(`<div class="pane-detail"></div>`);
  wrap.append(list, detail);

  let items = entries.slice();
  if (groupByDate) items.sort((a, b) => oldestFirst ? a.entry.ts.localeCompare(b.entry.ts) : b.entry.ts.localeCompare(a.entry.ts));
  const key = ctxKey || "pane";

  let currentRow = null;
  async function selectDetail(item, row) {
    await teardownEditor();
    S.sel[key] = item.entry.ts + "|" + item.entry.raw;
    const myRow = row || $$(".row", list).find(r => r._key === S.sel[key]) || null;
    currentRow = myRow;
    $$(".row", list).forEach(r => r.classList.toggle("selected", r === myRow));
    detail.innerHTML = "";
    detail.appendChild(entryEditor(item.entry, item.source, {
      // reindex (flush / star / file): pull a fresh snapshot so other views update.
      onChange: () => refresh(false),
      // every save (incl. autosave): keep this item + its list row in sync, so a
      // later reselect shows the edited text rather than the stale original.
      onSaved: (ts, title, body, raw) => {
        // Patched in place: `item.entry` is the same object the caller's list
        // (for the Inbox, the snapshot itself) holds, so a rebuild after a
        // search or a sort re-seeds the editor with the edit, not the original.
        Object.assign(item.entry, patchEntry(item.entry, ts, title, body, raw));
        if (item.source.kind === "inbox") item.date = item.entry.date;
        const newKey = ts + "|" + raw;
        if (myRow === currentRow) S.sel[key] = newKey;
        if (myRow) {
          myRow._key = newKey;
          const p = myRow.querySelector(".prev"); if (p) p.textContent = item.entry.preview || "(empty)";
          const b = myRow.querySelector(".r-body"); if (b) b.textContent = item.entry.body;
          const tg = myRow.querySelector(".tags"); if (tg) tg.textContent = item.entry.tags.join(" ");
        }
      },
    }));
  }

  function build() {
    list.innerHTML = "";
    if (!items.length) { detail.innerHTML = ""; detail.appendChild(emptyState("book.closed", "Select an entry", "")); return; }
    let lastDate = null;
    for (const item of items) {
      const d = item.date;
      if (groupByDate && d !== lastDate) { lastDate = d; list.appendChild(el(`<div class="list-section-header">${esc(sectionDate(d))}</div>`)); }
      const row = entryRow(item.entry, { showTime, fullDate, date: item.date, inboxBadge: item.source.kind === "inbox" });
      row._key = item.entry.ts + "|" + item.entry.raw;
      // The row keeps its item, so a caller replacing the context menu reads
      // the live entry (patched in place by onSaved) rather than re-deriving it
      // from a key that an edit has already moved on from.
      row._item = item;
      row.classList.toggle("selected", S.sel[key] === row._key);
      row.onclick = () => selectDetail(item, row);
      row.oncontextmenu = e => { e.preventDefault(); rowMenu(e.clientX, e.clientY, item, onDelete); };
      list.appendChild(row);
    }
    // pick selection
    const cur = items.find(i => (i.entry.ts + "|" + i.entry.raw) === S.sel[key]) || items[0];
    if (cur) selectDetail(cur);
  }
  build();
  return { wrap, setEntries(e) { items = e.slice(); if (groupByDate) items.sort((a, b) => oldestFirst ? a.entry.ts.localeCompare(b.entry.ts) : b.entry.ts.localeCompare(a.entry.ts)); build(); }, list, detail };
}

function rowMenu(x, y, item, onDelete) {
  const src = item.source;
  openMenuAt(x, y, [
    { label: item.entry.is_starred ? "Unstar" : "Star", icon: item.entry.is_starred ? "star.slash" : "star", action: async () => { if (!(await writeCmd("toggle_star", { source: src, ts: item.entry.ts, raw: item.entry.raw })).ok) return; (onDelete || (() => refresh()))(); } },
    ...(src.kind !== "inbox" ? [{ label: "Return to Inbox", icon: "tray", action: async () => { if (await invoke("return_to_inbox", { source: src, ts: item.entry.ts, raw: item.entry.raw })) toast("Returned to Inbox"); else toast("Couldn't return that entry to the Inbox", true); (onDelete || (() => refresh()))(); } }] : []),
    { label: "Reveal in Files", icon: "folder", action: () => invoke("reveal_entry", { source: src }) },
    { sep: true },
    { label: "Delete", icon: "trash", danger: true, action: async () => { if (!(await deleteEntryBySource(item.entry, src))) return; (onDelete || (() => refresh()))(); } },
  ]);
}
async function deleteEntryBySource(entry, src) {
  if (src.kind === "inbox") return (await writeCmd("delete_draft", { ts: entry.ts, raw: entry.raw })).ok;
  if (src.kind === "archive") return (await writeCmd("delete_filed_entry", { date: src.arg, ts: entry.ts, raw: entry.raw })).ok;
  if (src.kind === "journal") return (await writeCmd("delete_journal_entry", { name: src.arg, ts: entry.ts, raw: entry.raw })).ok;
  return false;
}

/* ------------------------------------------------------------------ */
/* INBOX                                                               */
/* ------------------------------------------------------------------ */
function sortDrafts(drafts) {
  const s = pref("inboxSort");
  const c = { newest: (a, b) => b.ts.localeCompare(a.ts), oldest: (a, b) => a.ts.localeCompare(b.ts), longest: (a, b) => b.word_count - a.word_count, shortest: (a, b) => a.word_count - b.word_count }[s];
  return drafts.slice().sort(c);
}
function renderInbox(main) {
  const view = el(`<div class="view"></div>`);
  const h = header("Inbox");
  let query = "";
  const search = searchBox("Search drafts", v => { query = v.toLowerCase(); rebuild(); });
  const randBtn = el(`<button class="tbtn icon" title="Random draft">${icon("shuffle")}</button>`);
  const moreBtn = el(`<button class="tbtn icon" title="Options">${icon("ellipsis")}</button>`);
  h.append(search, randBtn, moreBtn); view.appendChild(h);
  const bodyWrap = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`); view.appendChild(bodyWrap);
  main.appendChild(view);

  let pane = null;
  function rebuild() {
    const drafts = S.snap.inbox_drafts;
    if (!drafts.length) { bodyWrap.innerHTML = ""; bodyWrap.appendChild(emptyState("tray", "Inbox is empty", "Drafts you write appear here until you file them.")); return; }
    let list = sortDrafts(drafts);
    if (query) list = list.filter(d => d.raw.toLowerCase().includes(query));
    const items = list.map(e => ({ entry: e, date: e.date, source: { kind: "inbox", arg: null } }));
    bodyWrap.innerHTML = "";
    pane = twoPane({ entries: items, showTime: true, groupByDate: true, oldestFirst: pref("inboxSort") === "oldest", ctxKey: "inbox", onDelete: () => refresh() });
    bodyWrap.appendChild(pane.wrap);
    // override context menu to include Archive/File
    pane.list.querySelectorAll(".row").forEach((row) => {
      row.oncontextmenu = e => {
        e.preventDefault();
        const entry = row._item && row._item.entry; if (!entry) return;
        openMenuAt(e.clientX, e.clientY, [
          { label: "Archive", icon: "archivebox", action: async () => { if (!(await writeCmd("file_draft", { ts: entry.ts, raw: entry.raw })).ok) return; refresh(); } },
          { label: entry.is_starred ? "Unstar" : "Star", icon: entry.is_starred ? "star.slash" : "star", action: async () => { if (!(await writeCmd("toggle_star", { source: { kind: "inbox", arg: null }, ts: entry.ts, raw: entry.raw })).ok) return; refresh(); } },
          { label: "Reveal in Files", icon: "folder", action: () => invoke("reveal_entry", { source: { kind: "inbox", arg: null } }) },
          { sep: true },
          { label: "Delete", icon: "trash", danger: true, action: async () => { if (!(await writeCmd("delete_draft", { ts: entry.ts, raw: entry.raw })).ok) return; refresh(); } },
        ]);
      };
    });
  }
  randBtn.onclick = () => { const d = S.snap.inbox_drafts; if (!d.length) return; const r = d[Math.floor(Math.random() * d.length)]; S.sel.inbox = r.ts + "|" + r.raw; rebuild(); };
  randBtn.disabled = !S.snap.inbox_drafts.length;
  moreBtn.onclick = () => menuFromButton(moreBtn, [
    { label: "Sort", header: true },
    ...[["newest", "Newest first"], ["oldest", "Oldest first"], ["longest", "Longest first"], ["shortest", "Shortest first"]].map(([k, l]) => ({ label: l, checked: pref("inboxSort") === k, action: () => { setPref("inboxSort", k); rebuild(); } })),
    { sep: true },
    { label: "File All", icon: "archivebox", disabled: !S.snap.inbox_drafts.length, action: async () => { const r = await writeCmd("file_all_drafts"); if (r.ok) toast(`Filed ${plural(r.value, "draft")}`); refresh(); } },
    { label: "Sort file by date", icon: "calendar", action: async () => { if (!(await writeCmd("sort_inbox")).ok) return; toast("Inbox sorted"); refresh(); } },
  ]);
  rebuild();
}

/* ------------------------------------------------------------------ */
/* ARCHIVE (Journal)                                                   */
/* ------------------------------------------------------------------ */
async function renderArchive(main) {
  const view = el(`<div class="view"></div>`);
  const h = header("Journal");
  let query = "";
  const search = searchBox("Search entries", v => { query = v.toLowerCase(); rebuild(); });
  const sortBtn = el(`<button class="tbtn icon" title="Sort">${icon("chevron.left")}</button>`); sortBtn.innerHTML = icon("arrow.up.to.line");
  const randBtn = el(`<button class="tbtn icon" title="Random (Ctrl+R)">${icon("shuffle")}</button>`);
  h.append(search, sortBtn, randBtn); view.appendChild(h);
  const bodyWrap = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`); view.appendChild(bodyWrap);
  main.appendChild(view);

  // "On this day" — a banner whenever this calendar day has entries in past years.
  const otd = await invoke("on_this_day").catch(() => []);
  if (otd.length) {
    const count = otd.reduce((n, d) => n + d.entries.length, 0);
    const banner = el(`<button class="tbtn" style="margin:8px 12px 0;justify-content:flex-start">${icon("clock")}<span style="margin-left:6px">On this day — ${plural(count, "entry").replace("entrys", "entries")} from ${plural(otd.length, "past year")}</span></button>`);
    banner.onclick = () => {
      const body = el(`<div style="max-height:60vh;overflow-y:auto"></div>`);
      const thisYear = Number(jsNowTs().slice(0, 4));
      for (const d of otd) {
        const ago = thisYear - Number(d.date.slice(0, 4));
        body.appendChild(el(`<div class="list-section-header">${esc(sectionDate(d.date))} — ${plural(ago, "year")} ago</div>`));
        for (const e of d.entries) {
          const row = entryRow(e, { showTime: true });
          row.onclick = () => { mo.close(); showEntrySheet(e, { kind: "archive", arg: d.date }, d.date); };
          body.appendChild(row);
        }
      }
      const mo = modal({ title: "On This Day", bodyEl: body });
    };
    view.appendChild(banner);
  }

  const days = await invoke("all_entries_by_day");
  let all = [];
  for (const d of days) for (const e of d.entries) all.push({ entry: e, date: d.date, source: { kind: "archive", arg: d.date } });

  function rebuild() {
    let items = all.slice();
    if (query) items = items.filter(i => i.entry.raw.toLowerCase().includes(query));
    bodyWrap.innerHTML = "";
    if (!items.length) { bodyWrap.appendChild(emptyState("book.closed", "No entries yet", "File drafts from your inbox and they'll show up here.")); return; }
    const pane = twoPane({ entries: items, showTime: true, groupByDate: true, oldestFirst: pref("archiveSort") === "oldest", ctxKey: "archive", onDelete: () => renderView() });
    bodyWrap.appendChild(pane.wrap);
  }
  sortBtn.onclick = () => menuFromButton(sortBtn, [
    { label: "Newest first", checked: pref("archiveSort") === "newest", action: () => { setPref("archiveSort", "newest"); rebuild(); } },
    { label: "Oldest first", checked: pref("archiveSort") === "oldest", action: () => { setPref("archiveSort", "oldest"); rebuild(); } },
  ]);
  randBtn.onclick = async () => { const r = await invoke("random_entry"); if (!r) return; showEntrySheet(r.entry, { kind: "archive", arg: r.date }, r.date); };
  rebuild();
}
function showEntrySheet(entry, source, date) {
  const body = el(`<div style="height:60vh;display:flex;flex-direction:column"></div>`);
  body.appendChild(entryEditor(entry, source, { onChange: () => refresh() }));
  modal({ title: date ? displayDate(date) : "Entry", bodyEl: body });
}

/* ------------------------------------------------------------------ */
/* SEARCH (global, with the SearchQuery operator grammar)              */
/* ------------------------------------------------------------------ */
async function renderSearch(main) {
  const view = el(`<div class="view"></div>`);
  const h = header("Search");
  let query = S.searchQuery || "";
  S.searchQuery = null;
  const search = searchBox('tag:work before:2026-03 "phrase"', debounce(v => { query = v; run(); }, 250));
  const pinBtn = el(`<button class="tbtn icon" title="Pin this search to the sidebar">${icon("star")}</button>`);
  h.append(search, pinBtn); view.appendChild(h);
  const bodyWrap = el(`<div style="flex:1;overflow:hidden;display:flex;flex-direction:column"></div>`);
  view.appendChild(bodyWrap); main.appendChild(view);
  const input = $("input", search);
  input.value = query;

  async function run() {
    bodyWrap.innerHTML = "";
    if (!query.trim()) {
      const pins = S.savedSearches || [];
      if (pins.length) {
        const listWrap = el(`<div style="flex:1;overflow-y:auto;padding:8px"></div>`);
        for (const s of pins) {
          const r = el(`<button class="nav-item" style="width:100%"><span class="ic">${icon("search")}</span><span>${esc(s.name)}</span><span class="sub" style="margin-left:auto;font-family:ui-monospace,monospace;font-size:11px">${esc(s.query)}</span></button>`);
          r.onclick = () => { query = s.query; input.value = s.query; run(); };
          r.oncontextmenu = e => { e.preventDefault(); openMenuAt(e.clientX, e.clientY, [
            { label: "Remove Pin", icon: "x", danger: true, action: async () => { await invoke("remove_saved_search", { name: s.name }); await refresh(false); run(); } },
          ]); };
          listWrap.appendChild(r);
        }
        bodyWrap.appendChild(listWrap);
      } else {
        bodyWrap.appendChild(emptyState("search", "Search everything",
          'Searches the inbox, journal and split journals together. Operators: tag:work · before:2026-03 · after:2025 · has:image · is:starred · "exact phrase". Pin a query to keep it in the sidebar.'));
      }
      return;
    }
    const hits = await invoke("global_search", { query });
    if (!hits.length) { bodyWrap.appendChild(emptyState("search", "No matches", "Nothing matches that query.")); return; }
    const items = hits.map(x => ({
      entry: x.entry,
      source: x.source,
      date: x.source.kind === "archive" ? x.source.arg : x.entry.date,
    }));
    const inner = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`);
    inner.appendChild(twoPane({ entries: items, fullDate: true, ctxKey: "gsearch", onDelete: () => renderView() }).wrap);
    bodyWrap.appendChild(inner);
  }
  pinBtn.onclick = async () => {
    if (!query.trim()) return;
    const name = await promptModal("Pin this search", query.slice(0, 30), "Shows up under Saved Searches in the sidebar.");
    if (!name || !name.trim()) return;
    await invoke("add_saved_search", { name: name.trim(), query });
    await refresh(false);
    toast("Pinned");
  };
  run();
}

/* DAY view */
async function renderDay(main, date) {
  const view = el(`<div class="view"></div>`); view.appendChild(header(displayDate(date), { back: true }));
  const entries = await invoke("entries_for_day", { date });
  const wrap = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`);
  const items = entries.map(e => ({ entry: e, date, source: { kind: "archive", arg: date } }));
  if (items.length) wrap.appendChild(twoPane({ entries: items, showTime: true, ctxKey: "day-" + date, onDelete: () => renderView() }).wrap);
  else wrap.appendChild(emptyState("book.closed", "No entries", ""));
  view.appendChild(wrap); main.appendChild(view);
}

/* ------------------------------------------------------------------ */
/* STARRED                                                             */
/* ------------------------------------------------------------------ */
async function renderStarred(main) {
  const view = el(`<div class="view"></div>`); view.appendChild(header("Starred"));
  const list = await invoke("starred_entries");
  const wrap = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`);
  if (!list.length) wrap.appendChild(emptyState("star", "No starred entries", "Star entries to collect them here."));
  else {
    const items = list.map(x => ({ entry: x.entry, source: x.source, date: x.source.kind === "archive" ? x.source.arg : x.entry.date }));
    wrap.appendChild(twoPane({ entries: items, showTime: true, groupByDate: true, oldestFirst: false, ctxKey: "starred", onDelete: () => renderView() }).wrap);
  }
  view.appendChild(wrap); main.appendChild(view);
}

/* ------------------------------------------------------------------ */
/* SPLIT JOURNALS                                                      */
/* ------------------------------------------------------------------ */
function renderSplit(main) {
  const view = el(`<div class="view"></div>`); view.appendChild(header("Split Journals"));
  const sj = S.snap.split_journals;
  if (!sj.length) { view.appendChild(emptyState("bookmark", "No split journals", "Configure split tags in Settings; entries with those @tags file into their own journal.")); main.appendChild(view); return; }
  const listWrap = el(`<div style="flex:1;overflow-y:auto;padding:8px"></div>`);
  for (const j of sj) {
    const r = el(`<button class="nav-item" style="width:100%"><span class="ic">${icon("bookmark")}</span><span>@${esc(j.name)}</span><span class="badge">${j.count}</span></button>`);
    r.onclick = () => openJournalFile(j.name);
    r.oncontextmenu = e => { e.preventDefault(); openMenuAt(e.clientX, e.clientY, [
      { label: "Reveal in Files", icon: "folder", action: () => invoke("reveal_entry", { source: { kind: "journal", arg: j.name } }) },
    ]); };
    listWrap.appendChild(r);
  }
  view.appendChild(listWrap); main.appendChild(view);
}
async function renderJournalFile(main, name) {
  const view = el(`<div class="view"></div>`); view.appendChild(header("@" + name, { back: true }));
  const entries = await invoke("entries_in_journal", { name });
  const items = entries.map(e => ({ entry: e, date: e.date, source: { kind: "journal", arg: name } }));
  const wrap = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`);
  if (items.length) wrap.appendChild(twoPane({ entries: items, showTime: true, groupByDate: true, ctxKey: "jf-" + name, onDelete: () => renderView() }).wrap);
  else wrap.appendChild(emptyState("bookmark", "Empty", ""));
  view.appendChild(wrap); main.appendChild(view);
}

/* ------------------------------------------------------------------ */
/* TAGS                                                                */
/* ------------------------------------------------------------------ */
function tagColor(tag) { let h = 0; for (const c of tag) h = (h + c.codePointAt(0)) % 11; return TAG_PALETTE[h]; }
async function renderTags(main) {
  const view = el(`<div class="view"></div>`);
  const h = header("Tags");
  let query = "";
  const search = searchBox("Search tags", v => { query = v.toLowerCase(); buildRail(); });
  const randBtn = el(`<button class="tbtn icon" title="Random tag">${icon("shuffle")}</button>`);
  h.append(search, randBtn); view.appendChild(h);
  const rail = el(`<div class="tag-rail"></div>`);
  const paneWrap = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`);
  view.append(rail, paneWrap); main.appendChild(view);

  const tags = S.snap.tag_counts;
  if (!tags.length) { paneWrap.appendChild(emptyState("number", "No tags yet", "Write @tags in your entries and they'll show up here.")); return; }
  let selected = S.tagSel && tags.find(t => t.tag === S.tagSel) ? S.tagSel : tags[0].tag;

  function buildRail() {
    rail.innerHTML = "";
    for (const t of tags.filter(t => t.tag.toLowerCase().includes(query))) {
      const col = tagColor(t.tag); const on = t.tag === selected;
      const chip = el(`<button class="chip" style="${on ? `background:${col};color:#fff;border-color:${col}` : `background:color-mix(in srgb,${col} 16%,transparent);color:${col};border-color:color-mix(in srgb,${col} 35%,transparent)`}"><span>${esc(t.tag)}</span><span class="cnt">${t.count}</span></button>`);
      chip.onclick = () => { selected = t.tag; S.tagSel = t.tag; buildRail(); loadTag(); };
      rail.appendChild(chip);
    }
  }
  async function loadTag() {
    const filed = await invoke("entries_tagged_with", { name: selected });
    const inbox = S.snap.inbox_drafts.filter(d => d.tags.includes(selected)).map(e => ({ entry: e, date: e.date, source: { kind: "inbox", arg: null } }));
    const items = inbox.concat(filed.map(x => ({ entry: x.entry, date: x.date, source: { kind: "archive", arg: x.date } })));
    paneWrap.innerHTML = "";
    if (!items.length) paneWrap.appendChild(emptyState("number", "No entries", ""));
    else paneWrap.appendChild(twoPane({ entries: items, showTime: true, fullDate: true, ctxKey: "tag-" + selected, onDelete: () => renderView() }).wrap);
  }
  randBtn.onclick = () => { selected = tags[Math.floor(Math.random() * tags.length)].tag; S.tagSel = selected; buildRail(); loadTag(); };
  buildRail(); loadTag();
}
async function renderTagDetail(main, tag) {
  const view = el(`<div class="view"></div>`); view.appendChild(header(tag, { back: true }));
  const filed = await invoke("entries_tagged_with", { name: tag });
  const items = filed.map(x => ({ entry: x.entry, date: x.date, source: { kind: "archive", arg: x.date } }));
  const wrap = el(`<div style="flex:1;overflow:hidden;display:flex"></div>`);
  wrap.appendChild(items.length ? twoPane({ entries: items, showTime: true, fullDate: true, ctxKey: "tagd-" + tag }).wrap : emptyState("number", "No entries", ""));
  view.appendChild(wrap); main.appendChild(view);
}

/* ------------------------------------------------------------------ */
/* ASSETS                                                              */
/* ------------------------------------------------------------------ */
/* The same extension lists as Rust's `parser::media_kind` and Swift's
   `MediaKind` — keep the three in step. `.weba` is WebM audio, what the voice
   recorder falls back to when the webview can't give us Ogg/Opus. */
const VIDEO_EXTS = ["mov", "mp4", "m4v", "webm", "mkv"];
const AUDIO_EXTS = ["m4a", "mp3", "wav", "aac", "aiff", "caf", "ogg", "oga", "opus", "flac", "weba"];
function assetKind(name) { const e = String(name).split(".").pop().toLowerCase(); if (VIDEO_EXTS.includes(e)) return "video"; if (AUDIO_EXTS.includes(e)) return "audio"; return "image"; }
async function renderAssets(main) {
  const view = el(`<div class="view"></div>`);
  const h = header("Assets");
  const refreshBtn = el(`<button class="tbtn icon" title="Refresh">${icon("refresh")}</button>`);
  h.append(refreshBtn); view.appendChild(h);
  const grid = el(`<div class="assets-grid"></div>`); view.appendChild(grid); main.appendChild(view);
  async function load() {
    const assets = await invoke("all_assets");
    grid.innerHTML = "";
    if (!assets.length) { grid.style.display = "block"; grid.appendChild(emptyState("photo.on.rectangle", "No media yet", "Images, video, and audio you attach to entries live here.")); return; }
    grid.style.display = "grid";
    for (const a of assets) {
      const kind = assetKind(a.name);
      const thumb = kind === "image" ? `<img src="${convertFileSrc(a.abs)}" loading="lazy"/>` : icon(kind === "video" ? "video" : "waveform", 26);
      const cell = el(`<div class="asset-cell"><div class="asset-thumb">${thumb}</div><div class="asset-name">${esc(a.name)}</div></div>`);
      cell.oncontextmenu = e => { e.preventDefault(); assetMenu(e.clientX, e.clientY, a, load); };
      grid.appendChild(cell);
    }
  }
  refreshBtn.onclick = load; load();
}
async function assetMenu(x, y, asset, reload) {
  const usages = await invoke("asset_usages", { fileName: asset.name });
  const items = [];
  if (usages.length === 1) items.push({ label: "Go to Entry", icon: "arrow.turn.up.right", action: () => gotoUsage(usages[0]) });
  else if (usages.length > 1) usages.forEach(u => items.push({ label: `Go to: ${u.source.kind === "inbox" ? "Inbox" : u.source.arg} · ${u.entry.preview.slice(0, 24)}`, icon: "arrow.turn.up.right", action: () => gotoUsage(u) }));
  items.push({ label: "Reveal in Files", icon: "folder", action: () => invoke("reveal_path", { path: asset.abs }) });
  items.push({ sep: true });
  items.push({ label: "Delete", icon: "trash", danger: true, action: async () => { if (await confirmModal("Delete media?", `Delete ${asset.name}? This cannot be undone.`, "Delete", true)) { await invoke("delete_asset", { rel: asset.rel }); reload(); } } });
  openMenuAt(x, y, items);
}
function gotoUsage(u) {
  const src = u.source;
  if (src.kind === "inbox") setSection("inbox");
  else if (src.kind === "archive") openDay(src.arg);
  else if (src.kind === "journal") openJournalFile(src.arg);
}

/* ------------------------------------------------------------------ */
/* ENTRY EDITOR (edit/preview, autosave)                               */
/* ------------------------------------------------------------------ */
function entryEditor(entry, source, { onChange, onSaved } = {}) {
  const container = el(`<div style="flex:1;display:flex;flex-direction:column;overflow:hidden"></div>`);
  const st = {
    title: entry.suffix, date: entry.ts, text: entry.body,
    baseline: entry.raw, mode: source.kind === "inbox" ? "edit" : "preview",
    activeTS: entry.ts, activeRaw: entry.raw,
  };
  const commit = reindex => enqueue(() => doCommit(reindex)); // serialised, like the composer
  const save = debounce(commit, 600);
  function composedRaw() {
    const ts = normTs(st.date); const t = st.title.trim(); const b = st.text.replace(/\n+$/, "");
    if (t && b) return `[${ts}] ${t}\n${b}`; if (t) return `[${ts}] ${t}`; return `[${ts}]\n${b}`;
  }
  async function doCommit(reindex) {
    // No frontend date guard: the field is a popover over `normTs`, which can
    // only ever hand back a full timestamp. A `[]` header would parse to no
    // entry and the save would delete it, so the Rust side still refuses one
    // (BAD_TIMESTAMP) and it surfaces here as an error toast.
    const raw = composedRaw(); if (raw === st.baseline) { if (reindex && onChange) onChange(); return true; }
    const newText = raw;
    try {
      if (source.kind === "inbox") await invoke("update_draft", { ts: st.activeTS, raw: st.activeRaw, newText });
      else if (source.kind === "archive") await invoke("update_filed_entry", { date: source.arg, ts: st.activeTS, raw: st.activeRaw, newText });
      else await invoke("update_journal_entry", { name: source.arg, ts: st.activeTS, raw: st.activeRaw, newText });
    } catch (e) { toastError(e); return false; } // baseline untouched: still dirty, retried on the next save
    st.baseline = raw; st.activeRaw = raw; st.activeTS = normTs(st.date);
    if (onSaved) onSaved(st.activeTS, st.title, st.text, raw);
    if (reindex && onChange) onChange();
    return true;
  }

  // control bar
  const bar = el(`<div class="view-header"></div>`);
  const modeBtn = el(`<button class="tbtn icon"></button>`);
  const starBtn = el(`<button class="tbtn icon"></button>`);
  const recBtn = el(`<button class="tbtn icon" title="Record audio">${icon("mic")}</button>`);
  const moreBtn = el(`<button class="tbtn icon">${icon("ellipsis")}</button>`);
  const saveBtn = el(`<button class="tbtn icon" title="Save">${icon("check")}</button>`);
  const fileBtn = el(`<button class="tbtn icon" title="File into archive">${icon("archivebox")}</button>`);
  const delBtn = el(`<button class="tbtn icon danger" title="Delete">${icon("trash")}</button>`);
  bar.append(modeBtn, el(`<div class="header-spacer"></div>`), starBtn, recBtn, moreBtn, saveBtn);
  if (source.kind === "inbox") bar.append(fileBtn);
  bar.append(delBtn);
  container.appendChild(bar);
  const bodyArea = el(`<div style="flex:1;overflow:hidden;display:flex;flex-direction:column;position:relative"></div>`);
  container.appendChild(bodyArea);

  function updateStar() { starBtn.innerHTML = icon(isStarred() ? "star.fill" : "star"); starBtn.style.color = isStarred() ? "var(--star)" : ""; }
  function isStarred() { return st.title.trim().endsWith("*"); }
  function renderMode() {
    modeBtn.innerHTML = icon(st.mode === "edit" ? "eye" : "pencil");
    modeBtn.title = st.mode === "edit" ? "Preview" : "Edit";
    bodyArea.innerHTML = "";
    if (st.mode === "preview") bodyArea.appendChild(previewPane());
    else bodyArea.appendChild(editPane());
    updateStar();
  }
  function editPane() {
    const p = el(`<div class="composer"><div class="composer-inner">
      <div class="compose-head"><input class="title-input" placeholder="Title"/><div class="date-slot"></div></div>
      <div class="divider"></div>
      <div class="compose-body-wrap"><textarea class="body-editor"></textarea><div class="placeholder-overlay">Begin writing</div></div>
    </div></div>`);
    const ti = $(".title-input", p), bi = $(".body-editor", p), ph = $(".placeholder-overlay", p);
    ti.value = st.title; bi.value = st.text; ph.style.display = st.text ? "none" : "block";
    $(".date-slot", p).replaceWith(dateField(st.date, ts => { st.date = ts; save(); }).el);
    attachTagHighlight($(".compose-body-wrap", p), bi);
    ti.oninput = () => { st.title = ti.value; updateStar(); save(); };
    bi.oninput = () => { st.text = bi.value; ph.style.display = bi.value ? "none" : "block"; save(); };
    S.insertMedia = rel => { bi.value += (bi.value ? "\n\n" : "") + `![](${rel})`; st.text = bi.value; ph.style.display = "none"; save.now(false); };
    setTimeout(() => bi.focus(), 20);
    return p;
  }
  function previewPane() {
    S.insertMedia = rel => { st.text += (st.text ? "\n\n" : "") + `![](${rel})`; save.now(false); renderMode(); };
    return mediaPreview(st.text, st.title, st.date, newBody => { st.text = newBody; save.now(false); renderMode(); });
  }
  renderMode();

  modeBtn.onclick = () => { st.mode = st.mode === "edit" ? "preview" : "edit"; renderMode(); };
  starBtn.onclick = () => { const base = isStarred() ? st.title.trim().replace(/\*$/, "").trim() : st.title.trim(); st.title = isStarred() ? base : (base ? base + " *" : "*"); if (st.mode === "edit") { const ti = $(".title-input", bodyArea); if (ti) ti.value = st.title; } updateStar(); save.now(false); onChange && setTimeout(onChange, 50); };
  recBtn.onclick = () => toggleRecord(recBtn, container);
  saveBtn.onclick = async () => { if (saveOutcome(await save.now(true))) toast("Saved"); };
  fileBtn.onclick = async () => { save.cancel(); if (!saveOutcome(await commit(false))) return; if (!(await writeCmd("file_draft", { ts: st.activeTS, raw: st.activeRaw })).ok) return; toast("Filed"); refresh(); };
  delBtn.onclick = async () => { if (await confirmModal("Delete entry?", "This cannot be undone.", "Delete", true)) { save.cancel(); if (!(await deleteEntryBySource({ ts: st.activeTS, raw: st.activeRaw }, source))) return; onChange ? onChange() : refresh(); } };
  moreBtn.onclick = () => menuFromButton(moreBtn, [
    ...(source.kind !== "inbox" ? [
      { label: "Return to Inbox", icon: "tray", action: async () => { save.cancel(); await commit(false); if (await invoke("return_to_inbox", { source, ts: st.activeTS, raw: st.activeRaw })) { toast("Returned to Inbox"); onChange ? onChange() : refresh(); } else toast("Couldn't return that entry to the Inbox", true); } },
      { sep: true },
    ] : []),
    { label: "Attach Media", icon: "paperclip", action: attachMedia },
    { label: "Record Video", icon: "video", action: recordVideo },
    { label: "Copy text", icon: "copy", action: () => navigator.clipboard.writeText((st.title ? st.title + "\n" : "") + st.text) },
    { label: "Promote first line to title", icon: "promote", disabled: !st.text.trim(), action: () => { const lines = st.text.split("\n"); const i = lines.findIndex(l => l.trim()); if (i < 0) return; st.title = lines[i].trim(); lines.splice(i, 1); st.text = lines.join("\n").replace(/^\n+/, ""); save.now(false); renderMode(); } },
  ]);

  // register editor teardown
  S.editor = { flush: () => { save.cancel(); return commit(true); } };
  return container;
}

/* ------------------------------------------------------------------ */
/* MEDIA PREVIEW                                                       */
/* ------------------------------------------------------------------ */
function parseSegments(body) {
  const re = /!\[([^\]]*)\]\(([^)]+)\)/g; const segs = []; let last = 0, m;
  while ((m = re.exec(body))) { if (m.index > last) segs.push({ type: "text", text: body.slice(last, m.index) }); segs.push({ type: "media", caption: m[1], path: m[2] }); last = re.lastIndex; }
  if (last < body.length) segs.push({ type: "text", text: body.slice(last) });
  return segs;
}
/* @tags matched exactly as jnl / parser.rs extracts them (@[a-zA-Z][a-zA-Z0-9_-]*),
   so what's highlighted always equals what's filed. Gated on the "highlightTags" pref. */
const TAG_HL_RE = /@[a-zA-Z][a-zA-Z0-9_-]*/g;
function hlTags(text) { return esc(text).replace(TAG_HL_RE, '<span class="tag-hl">$&</span>'); }
// Highlight @tags in already-built HTML, only in text between tags (never inside
// tag/attribute markup, so hrefs and code spans stay intact).
function highlightTagsInHtml(html) {
  return html.split(/(<[^>]+>)/).map((seg, i) => i % 2 ? seg : seg.replace(TAG_HL_RE, '<span class="tag-hl">$&</span>')).join("");
}
// Overlay a colour-highlight layer behind a plain <textarea> (textareas can't
// colour inline text). Returns an update() fn to call after programmatic edits.
function attachTagHighlight(wrap, ta) {
  if (!pref("highlightTags")) return () => {};
  const backdrop = el(`<div class="hl-backdrop"><div class="hl-content"></div></div>`);
  const content = backdrop.firstChild;
  wrap.insertBefore(backdrop, wrap.firstChild);
  wrap.classList.add("hl-on");
  const update = () => { content.innerHTML = hlTags(ta.value) + "\n"; };
  const sync = () => { content.style.transform = `translateY(${-ta.scrollTop}px)`; };
  ta.addEventListener("input", () => { update(); sync(); });
  ta.addEventListener("scroll", sync);
  update();
  return update;
}
function inlineMarkdown(t) {
  t = esc(t);
  t = t.replace(/`([^`]+)`/g, "<code>$1</code>");
  t = t.replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>");
  t = t.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<i>$2</i>");
  t = t.replace(/\b__([^_]+)__\b/g, "<i>$1</i>");
  t = t.replace(/\[([^\]]+)\]\((https?:[^)]+)\)/g, '<a href="$2" target="_blank">$1</a>');
  if (pref("highlightTags")) t = highlightTagsInHtml(t);
  return t;
}
function mediaPreview(body, title, date, onUpdate) {
  const wrap = el(`<div class="preview"></div>`);
  const t = (title || "").replace(/\*$/, "").trim();
  wrap.appendChild(el(`<div class="preview-title">${title && title.trim().endsWith("*") ? '<span class="star-ic">' + icon("star.fill", 14) + "</span>" : ""}<span>${esc(t)}</span><span class="preview-date">${esc(displayDate(String(date).slice(0, 10)))}</span></div>`));
  const segs = parseSegments(body);
  const base = S.snap.base_path;
  for (const s of segs) {
    if (s.type === "text") { if (s.text.trim()) wrap.appendChild(el(`<div class="seg-text">${inlineMarkdown(s.text.replace(/^\n+|\n+$/g, ""))}</div>`)); continue; }
    const abs = base + "/" + s.path; const url = convertFileSrc(abs); const kind = assetKind(s.path);
    const media = el(`<div class="seg-media"></div>`);
    if (kind === "image") media.appendChild(el(`<img src="${url}" alt="${esc(s.caption)}"/>`));
    else if (kind === "video") { const v = el(`<video controls src="${url}"></video>`); media.appendChild(v); }
    else { media.appendChild(el(`<div class="audio-inline">${icon("waveform", 18)}<audio controls src="${url}"></audio></div>`)); }
    // caption
    if (onUpdate) {
      const cap = el(`<div class="caption editable">${s.caption ? esc(s.caption) : "Add caption"}</div>`);
      cap.onclick = async () => { const v = await promptModal("Caption", s.caption, "Caption for this media"); if (v === null) return; s.caption = v.replace(/[\]\n]/g, ""); onUpdate(rebuildBody(segs)); };
      media.appendChild(cap);
    } else if (s.caption) media.appendChild(el(`<div class="caption">${esc(s.caption)}</div>`));
    wrap.appendChild(media);
  }
  return wrap;
}
function rebuildBody(segs) { return segs.map(s => s.type === "text" ? s.text : `![${s.caption}](${s.path})`).join(""); }

/* ------------------------------------------------------------------ */
/* STATS                                                               */
/* ------------------------------------------------------------------ */
async function renderStats(main) {
  const view = el(`<div class="view"></div>`); view.appendChild(header("Stats"));
  const s = await invoke("stats");
  const scroll = el(`<div class="settings-scroll"><div class="settings"></div></div>`); const box = $(".settings", scroll);
  const card = (title, rows) => { const c = el(`<div class="card"><h3>${esc(title)}</h3></div>`); rows.forEach(([l, v]) => c.appendChild(el(`<div class="field"><div class="lbl">${esc(l)}</div><div class="sub">${esc(v)}</div></div>`))); return c; };
  box.appendChild(card("Overview", [
    ["Inbox drafts", s.inbox_drafts], ["Inbox size", fmtBytes(s.inbox_bytes)], ["Tags", s.tags],
    ...(s.split_journals ? [["Split journals", s.split_journals]] : []),
    ["Text size", fmtBytes(s.bytes)], ["Media size", fmtBytes(s.media_bytes)], ["Total size", fmtBytes(s.bytes + s.media_bytes)],
  ]));
  box.appendChild(card("Archive", [
    ["Days written", s.days], ["Entries", s.entries], ["Words", s.words.toLocaleString()],
    ...(s.entries ? [["Avg per entry", Math.round(s.words / s.entries) + " words"]] : []),
    ["Archive size", fmtBytes(s.archive_bytes)],
  ]));
  box.appendChild(card("Today", [
    ["Words today", s.words_today],
    ...(pref("wordGoalEnabled") ? [["Daily goal", `${s.words_today} / ${pref("wordGoal")}${s.words_today >= pref("wordGoal") ? " — met" : ""}`]] : []),
  ]));
  box.appendChild(card("Streaks", [["Current", plural(s.current_streak, "day")], ["Best", plural(s.best_streak, "day")]]));
  if (s.longest_day) box.appendChild(card("Highlights", [["Longest day", `${displayDate(s.longest_day)} · ${s.longest_day_words} words`]]));

  // Year in review.
  const years = await invoke("years_with_entries").catch(() => []);
  if (years.length) {
    const yr = el(`<div class="card"><h3>Year in review</h3></div>`);
    const row = el(`<div class="btnrow"></div>`);
    for (const y of years) {
      const b = btn(y, { icon: "book.closed" });
      b.onclick = async () => {
        const r = await invoke("year_review", { year: y });
        const lines = [
          ["Days written", r.days_written], ["Entries", r.entries], ["Words", Number(r.words).toLocaleString()],
          ["Longest streak", plural(r.longest_streak, "day")],
          ...(r.busiest_day ? [["Busiest day", `${displayDate(r.busiest_day)} · ${r.busiest_day_words} words`]] : []),
          ...(r.starred ? [["Starred", r.starred]] : []),
          ...(r.top_tags.length ? [["Top tags", r.top_tags.map(t => `${t.tag} (${t.count})`).join("  ")]] : []),
          ...((r.photos + r.videos + r.audios) ? [["Media", `${r.photos} photos · ${r.videos} videos · ${r.audios} voice memos`]] : []),
          ...(r.first_line ? [["First line", `\u{201C}${r.first_line}\u{201D}`]] : []),
        ];
        const body = el(`<div style="padding:8px 0"></div>`);
        lines.forEach(([l, v]) => body.appendChild(el(`<div class="field" style="padding:6px 18px"><div class="lbl">${esc(l)}</div><div class="sub">${esc(String(v))}</div></div>`)));
        modal({ title: `${y} in review`, bodyEl: body });
      };
      row.appendChild(b);
    }
    yr.appendChild(row);
    box.appendChild(yr);
  }
  view.appendChild(scroll); main.appendChild(view);
}

/* ------------------------------------------------------------------ */
/* SETTINGS                                                            */
/* ------------------------------------------------------------------ */
async function renderSettings(main) {
  const view = el(`<div class="view"></div>`); view.appendChild(header("Settings"));
  const scroll = el(`<div class="settings-scroll"><div class="settings"></div></div>`); const box = $(".settings", scroll);
  view.appendChild(scroll); main.appendChild(view);

  const field = (lbl, control, sub) => { const f = el(`<div class="field"><div class="lbl">${esc(lbl)}${sub ? `<div class="sub">${esc(sub)}</div>` : ""}</div></div>`); f.appendChild(control); return f; };
  const selectCtl = (key, opts, after) => { const s = el(`<select></select>`); opts.forEach(([v, l]) => s.appendChild(el(`<option value="${v}" ${String(pref(key)) === String(v) ? "selected" : ""}>${esc(l)}</option>`))); s.onchange = () => { let v = s.value; if (["fontSize", "firstWeekday"].includes(key)) v = Number(v); setPref(key, v); applyAppearance(); after && after(); }; return s; };
  const toggleCtl = (key, after) => { const t = el(`<div class="switch ${pref(key) ? "on" : ""}"></div>`); t.onclick = () => { setPref(key, !pref(key)); t.classList.toggle("on"); after && after(); }; return t; };
  const seg = (key, opts) => { const w = el(`<div class="seg"></div>`); opts.forEach(([v, l]) => { const b = el(`<button class="${pref(key) === v ? "on" : ""}">${esc(l)}</button>`); b.onclick = () => { setPref(key, v); applyAppearance(); $$(".seg button", w).forEach((x, i) => x.classList.toggle("on", opts[i][0] === v)); }; w.appendChild(b); }); return w; };

  // Appearance
  const appearance = el(`<div class="card"><h3>Appearance</h3></div>`);
  appearance.appendChild(field("Theme", seg("colorScheme", [["auto", "Auto"], ["light", "Light"], ["dark", "Dark"]])));
  appearance.appendChild(field("Writing font", selectCtl("writingFont", [["lato", "Lato"], ["system", "System"], ["serif", "Serif"], ["mono", "Mono"]])));
  appearance.appendChild(field("Text size", selectCtl("fontSize", FONT_SIZES.map(s => [s, s + " px"]))));
  appearance.appendChild(field("Date format", selectCtl("dateStyle", [["weekday", "Mon, 10 May"], ["medium", "10 May 2026"], ["long", "Monday, 10 May 2026"], ["iso", "2026-05-10"]])));
  const swatches = el(`<div class="swatches"></div>`);
  Object.entries(ACCENTS).forEach(([k, c]) => { const sw = el(`<div class="swatch ${pref("accentColor") === k ? "on" : ""}" style="background:${c}">${pref("accentColor") === k ? icon("check", 14) : ""}</div>`); sw.onclick = () => { setPref("accentColor", k); applyAppearance(); $$(".swatch", swatches).forEach((x, i) => { const key = Object.keys(ACCENTS)[i]; x.classList.toggle("on", key === k); x.innerHTML = key === k ? icon("check", 14) : ""; }); }; swatches.appendChild(sw); });
  appearance.appendChild(field("Accent colour", swatches));
  appearance.appendChild(field("Highlight @tags", toggleCtl("highlightTags")));
  appearance.appendChild(field("Start week on", selectCtl("firstWeekday", [[1, "Sunday"], [2, "Monday"], [7, "Saturday"]], renderMiniCal)));
  appearance.appendChild(field("Show week numbers", toggleCtl("showWeekNumbers", renderMiniCal)));
  box.appendChild(appearance);

  // Writing (prompts + word goal)
  const writing = el(`<div class="card"><h3>Writing</h3></div>`);
  writing.appendChild(field("Writing prompts", toggleCtl("writingPrompts"), "A question in the empty composer."));
  writing.appendChild(field("Daily word goal", toggleCtl("wordGoalEnabled", renderView)));
  if (pref("wordGoalEnabled")) {
    writing.appendChild(field("Goal", selectCtl("wordGoal", [100, 250, 500, 750, 1000, 1500, 2000].map(n => [n, n + " words"]))));
  }
  writing.appendChild(el(`<div class="field"><div class="sub">The goal counts everything dated today; progress shows in Stats.</div></div>`));
  box.appendChild(writing);

  // Templates (<folder>/.nook/templates/*.md, shared with the Apple apps)
  const tmplCard = el(`<div class="card"><h3>Templates</h3></div>`);
  const tmplList = el(`<div></div>`);
  async function renderTemplates() {
    const names = await invoke("template_names");
    tmplList.innerHTML = "";
    for (const n of names) {
      const r = el(`<div class="field"><div class="lbl">${icon("copy", 13)} ${esc(n)}</div></div>`);
      const del = el(`<button class="tbtn icon danger" title="Delete template">${icon("trash", 14)}</button>`);
      del.onclick = async () => { await invoke("delete_template", { name: n }); renderTemplates(); };
      r.appendChild(del);
      tmplList.appendChild(r);
    }
  }
  renderTemplates();
  tmplCard.appendChild(tmplList);
  const trow = el(`<div class="btnrow"></div>`);
  const newTmpl = btn("New Template", { icon: "square.and.pencil" });
  newTmpl.onclick = async () => { await invoke("create_template"); renderTemplates(); };
  trow.appendChild(newTmpl);
  tmplCard.appendChild(trow);
  tmplCard.appendChild(el(`<div class="field"><div class="sub">Plain markdown files in &lt;folder&gt;/.nook/templates/ — insert one from the composer's ⋯ menu; {{date}}, {{time}} and {{weekday}} fill in on insert. They sync with the journal and the macOS/iOS apps.</div></div>`));
  box.appendChild(tmplCard);

  // Split tags
  const splitCard = el(`<div class="card"><h3>Split tags</h3></div>`);
  const chips = el(`<div class="tag-chips"></div>`);
  function tagList() { return pref("splitTags").split(/[\s,]+/).filter(Boolean); }
  function renderChips() {
    chips.innerHTML = "";
    for (const t of tagList()) { const c = el(`<span class="tag-edit-chip">@${esc(t)}<button title="Remove">${icon("x", 12)}</button></span>`); $("button", c).onclick = () => { setPref("splitTags", tagList().filter(x => x !== t).join(" ")); renderChips(); }; chips.appendChild(c); }
    const inp = el(`<input type="text" placeholder="Add a tag…" style="min-width:120px"/>`);
    inp.onkeydown = e => { if (e.key === "Enter") { const v = inp.value.replace(/[@\s,]/g, "").trim(); if (v && !tagList().includes(v)) setPref("splitTags", tagList().concat(v).join(" ")); renderChips(); } };
    chips.appendChild(inp);
  }
  renderChips();
  splitCard.appendChild(chips);
  splitCard.appendChild(el(`<div class="field"><div class="sub">Entries containing these @tags file into &lt;folder&gt;/&lt;tag&gt;.md instead of the date journal (jnl JNL_SPLIT_TAGS).</div></div>`));
  box.appendChild(splitCard);

  // Journal folder
  const folderCard = el(`<div class="card"><h3>Journal folder</h3></div>`);
  const MODE_LABEL = { custom: "Custom folder", local: "On this device", missing: "Unavailable" };
  folderCard.appendChild(el(`<div class="field"><div class="lbl">Storage</div><div class="sub">${MODE_LABEL[S.snap.storage_mode] || "On this device"}</div></div>`));
  if (S.snap.storage_mode === "missing") folderCard.appendChild(el(`<div class="field"><div class="sub" style="color:var(--danger)">This folder isn't there right now — an unmounted drive, or one that's been renamed. Nook won't write until it's back, so nothing lands in the wrong place. Reconnect it, or choose another folder below.</div></div>`));
  folderCard.appendChild(el(`<div class="field"><div class="lbl">Location</div><div class="mono">${esc(S.snap.base_path)}</div></div>`));
  const frow = el(`<div class="btnrow"></div>`);
  const choose = btn("Choose Folder…", { icon: "folder" }); choose.onclick = async () => { const snap = await invoke("pick_journal_folder"); if (snap) { S.snap = snap; renderStorageBanner(); toast("Folder changed"); renderView(); renderMiniCal(); renderSidebar(); } };
  frow.appendChild(choose);
  if (S.snap.storage_mode !== "local") { const def = btn("Use Default", { icon: "arrow.uturn.backward", danger: true }); def.onclick = async () => { S.snap = await invoke("use_default_folder"); renderStorageBanner(); toast("Using default folder"); renderView(); renderMiniCal(); renderSidebar(); }; frow.appendChild(def); }
  const showF = btn("Show in Files", { icon: "folder" }); showF.onclick = () => invoke("reveal_base"); frow.appendChild(showF);
  folderCard.appendChild(frow);
  folderCard.appendChild(el(`<div class="field"><div class="sub">Data is plain markdown: inbox.md + journal/YYYY/MM/DD.md — shareable with the jnl CLI.</div></div>`));
  box.appendChild(folderCard);

  // Backup
  const backupCard = el(`<div class="card"><h3>Backup</h3></div>`);
  const bInfo = await invoke("backup_folder_info");
  backupCard.appendChild(el(`<div class="field"><div class="lbl">Backup folder</div><div class="mono">${esc(bInfo.path || "Not set")}</div></div>`));
  const brow = el(`<div class="btnrow"></div>`);
  const chooseB = btn("Choose Backup Folder…", { icon: "folder" }); chooseB.onclick = async () => { const p = await invoke("pick_backup_folder"); if (p) { toast("Backup folder set"); renderView(); } };
  const backupNow = btn("Back Up Now", { icon: "drive" }); backupNow.disabled = !bInfo.path; backupNow.onclick = async () => { const r = await invoke("backup_now"); alertModal("Backup", r.message); };
  const restoreB = btn("Restore…", { icon: "clock" }); restoreB.disabled = !bInfo.path;
  restoreB.onclick = async () => {
    const names = await invoke("list_backups");
    if (!names.length) return alertModal("Restore", "No backups yet — run Back Up Now first.");
    const body = el(`<div style="max-height:50vh;overflow-y:auto;padding:6px"></div>`);
    const mo = modal({ title: "Restore", bodyEl: body });
    for (const n of names) {
      const r = el(`<button class="menu-item">${icon("drive", 15)}<span>${esc(n.replace("Nook-Backup-", ""))}</span></button>`);
      r.onclick = async () => {
        mo.close();
        if (!(await confirmModal("Restore this backup?", "Your current journal is saved as a new backup first, then replaced.", "Restore", true))) return;
        const res = await invoke("restore_backup", { name: n });
        await alertModal("Restore", res.message);
        refresh();
      };
      body.appendChild(r);
    }
  };
  brow.append(chooseB, backupNow, restoreB); backupCard.appendChild(brow);
  box.appendChild(backupCard);

  // Media / Data Saver
  const mediaCard = el(`<div class="card"><h3>Media</h3></div>`);
  mediaCard.appendChild(field("Data Saver", toggleCtl("dataSaver"), "Compress attached media to save space."));
  mediaCard.appendChild(el(`<div class="field"><div class="lbl">Data saved</div><div class="sub">${fmtBytes(S.snap.data_saved)}</div></div>`));
  mediaCard.appendChild(el(`<div class="field"><div class="sub">Images downsample to 2048px; videos re-encode to 720p and audio to low-bitrate (needs ffmpeg). Formats are preserved so links never break.</div></div>`));
  box.appendChild(mediaCard);

  // Maintenance
  const maint = el(`<div class="card"><h3>Maintenance</h3></div>`);
  const mrow = el(`<div class="btnrow"></div>`);
  const clean = btn("Clean Up", { icon: "wand" }); clean.onclick = async () => { const { ok, value: r } = await writeCmd("cleanup"); if (!ok) return; alertModal("Cleanup complete", `Formatted ${r.formatted}, reordered ${r.reordered}, removed ${plural(r.deduped, "duplicate")}, extracted ${r.extracted} to split journals.`); refresh(); };
  const compress = btn("Compress Existing Media", { icon: "photo.badge.down" });
  compress.onclick = async () => {
    compress.disabled = true; compress.textContent = "Compressing…";
    S.onMediaProgress = (done, total) => { compress.textContent = total ? `Compressing ${done}/${total}…` : "Compressing…"; };
    try {
      const r = await invoke("compress_existing_media");
      alertModal("Compression complete", `${r.images} image(s), ${r.videos} video(s), ${r.audios} audio — saved ${fmtBytes(r.bytes_saved)}.`);
      refresh();
    } finally {
      S.onMediaProgress = null;
      compress.disabled = false; compress.innerHTML = icon("photo.badge.down", 14) + "Compress Existing Media";
    }
  };
  const merge = btn("Merge Ex-Split Journals", { icon: "merge" }); merge.onclick = async () => { const { ok, value: r } = await writeCmd("merge_ex_split_journals"); if (!ok) return; alertModal("Merge complete", `Merged ${plural(r.journals, "journal")} (${plural(r.entries, "entry").replace("entrys", "entries")}) back into the main journal.`); refresh(); };
  const tagReview = btn("Tag Review", { icon: "seal" }); tagReview.onclick = openTagReview;
  const orphan = btn("Clear Orphan Media", { icon: "trash" }); orphan.onclick = async () => { const o = await invoke("orphan_assets"); if (!o.length) return alertModal("Orphan media", "No orphan media."); if (await confirmModal("Clear orphan media?", `Delete ${plural(o.length, "unused file")}?`, "Delete", true)) { const n = await invoke("delete_orphan_assets"); alertModal("Done", `Cleared ${plural(n, "file")}.`); refresh(); } };
  const exp = btn("Export…", { icon: "square.and.arrow.up" }); exp.onclick = async () => { const r = await invoke("export_to_file"); if (r.message) alertModal("Export", r.message); };
  async function runImport(cmd, path) {
    const preview = await invoke(cmd, { path, commit: false });
    if (!preview.ok) return alertModal("Nothing to import", preview.message);
    const what = `${plural(preview.entries, "entry").replace("entrys", "entries")}${preview.media ? ` and ${plural(preview.media, "media file")}` : ""}, ${preview.first} to ${preview.last}`;
    if (!(await confirmModal("Import?", `${what}. They'll be filed straight into the journal by date; entries already there are skipped.`, "Import"))) return;
    const r = await invoke(cmd, { path, commit: true });
    alertModal("Import", `Imported ${plural(r.entries, "entry").replace("entrys", "entries")}${r.media ? ` and ${plural(r.media, "media file")}` : ""}${r.skipped ? `; skipped ${r.skipped} already present` : ""}.`);
    refresh();
  }
  const impDO = btn("Import from Day One…", { icon: "download" });
  impDO.onclick = async () => { const p = await invoke("pick_import_path", { folder: false }); if (p) runImport("import_day_one", p); };
  const impMD = btn("Import Markdown Folder…", { icon: "download" });
  impMD.onclick = async () => { const p = await invoke("pick_import_path", { folder: true }); if (p) runImport("import_md_folder", p); };
  mrow.append(clean, compress, merge, tagReview, orphan, exp, impDO, impMD); maint.appendChild(mrow);
  box.appendChild(maint);

  // Shortcuts
  const sc = el(`<div class="card"><h3>Keyboard shortcuts</h3><div class="shortcut-list">
    <div>New entry (Write)</div><div class="k">Ctrl+N</div><div>Save</div><div class="k">Ctrl+S</div>
    <div>Write / Inbox / Journal / Tags</div><div class="k">Ctrl+1…4</div><div>Random entry (Journal)</div><div class="k">Ctrl+R</div>
    <div>Focus mode</div><div class="k">Ctrl+Alt+F</div><div>Settings</div><div class="k">Ctrl+,</div>
  </div></div>`);
  box.appendChild(sc);

  // How to
  const howto = el(`<div class="card howto"><h3>How to</h3></div>`);
  const topics = [
    ["Writing & autosave", "Type freely in Write. Your text saves to the Inbox automatically as one draft. Give it a title or leave it blank. Ctrl+S saves right away; New (Ctrl+N) banks what you've written and starts a fresh entry."],
    ["The Inbox — filing drafts", "The Inbox holds unfiled drafts. Right-click a draft to Archive it (files it into journal/YYYY/MM/DD.md), star it, or delete it. Use File All to file everything."],
    ["The Journal — browsing", "Journal groups every filed entry by day. Search across all entries, sort newest/oldest, or hit Random (Ctrl+R)."],
    ["Tags & Tag Review", "Write @tags anywhere in an entry. The Tags view collects them. Tag Review (Maintenance) finds near-duplicate tags and merges them."],
    ["Photos, video & audio", "Attach media or record audio/video. It's copied into assets/ and linked as ![](assets/…). Preview renders it inline. Add captions by clicking beneath the media."],
    ["Split journals (tag routing)", "Add split tags in Settings. Entries containing those @tags file into their own <tag>.md instead of the dated journal."],
    ["Backup", "Choose a backup folder, then Back Up Now copies your whole journal (inbox, journal, split journals, assets) into a timestamped folder."],
    ["Storage & jnl", "Point Nook at any folder (e.g. a synced Dropbox/Nextcloud folder, or your existing jnl notes). The on-disk format is identical to the jnl CLI."],
  ];
  topics.forEach(([t, b]) => { const d = el(`<details><summary>${esc(t)}</summary><div class="howto-body">${esc(b)}</div></details>`); howto.appendChild(d); });
  box.appendChild(howto);
}

/* Tag Review modal */
async function openTagReview() {
  const body = el(`<div style="padding:12px"><div class="empty" style="padding:20px"><div class="s">Scanning tags…</div></div></div>`);
  const cancel = btn("Cancel"); const apply = btn("Done", { primary: true });
  const mo = modal({ title: "Tag Review", bodyEl: body, foot: [cancel, apply] });
  cancel.onclick = () => mo.close();
  const groups = await invoke("similar_tag_groups");
  const choices = {}; // id -> kept tag
  function render() {
    body.innerHTML = "";
    if (!groups.length) { body.appendChild(el(`<div class="empty" style="padding:30px"><div class="big">${icon("seal", 30)}</div><div class="t">No similar tags</div><div class="s">Your tags look clean — nothing to merge.</div></div>`)); apply.textContent = "Done"; return; }
    let pending = 0;
    for (const g of groups) {
      if (choices[g.id]) pending += g.variants.length - 1;
      const sec = el(`<div style="padding:8px 16px;border-bottom:1px solid var(--border)"><div class="sub" style="margin-bottom:6px">${g.case_only ? "Different case" : "Similar spelling — merge only if they mean the same"}</div></div>`);
      for (const v of g.variants) {
        const on = choices[g.id] === v.tag;
        const r = el(`<button class="menu-item"><span style="color:${on ? "var(--accent)" : "var(--text-3)"}">${icon(on ? "check.circle" : "circle", 16)}</span><span>${esc(v.tag)}</span><span style="margin-left:auto" class="sub">${v.count}</span></button>`);
        r.onclick = () => { choices[g.id] = choices[g.id] === v.tag ? undefined : v.tag; render(); };
        sec.appendChild(r);
      }
      const ign = el(`<button class="menu-item" style="color:var(--text-2)">${icon("x.circle", 15)}<span>Not a match — ignore</span></button>`);
      ign.onclick = async () => { await invoke("ignore_tag_group", { id: g.id }); groups.splice(groups.indexOf(g), 1); render(); };
      sec.appendChild(ign);
      body.appendChild(sec);
    }
    apply.textContent = pending ? `Apply (${pending})` : "Done";
  }
  apply.onclick = async () => {
    const merges = [];
    for (const g of groups) { const keep = choices[g.id]; if (keep) for (const v of g.variants) if (v.tag !== keep) merges.push([v.tag, keep]); }
    mo.close();
    if (merges.length) { if (!(await writeCmd("merge_tags", { pairs: merges })).ok) return; toast(`Merged ${plural(merges.length, "tag")}`); refresh(); }
  };
  render();
}

/* ------------------------------------------------------------------ */
/* Keyboard shortcuts + global events                                  */
/* ------------------------------------------------------------------ */
document.addEventListener("keydown", async e => {
  const mod = e.ctrlKey || e.metaKey;
  if (!mod) return;
  if (e.altKey && (e.key === "f" || e.key === "F")) { e.preventDefault(); document.body.classList.toggle("focus"); return; }
  const inField = ["INPUT", "TEXTAREA"].includes(document.activeElement.tagName);
  switch (e.key) {
    case "n": case "N": e.preventDefault(); if (S.sec === "write" && S.newEntry) S.newEntry(); else setSection("write"); break;
    case "s": case "S": if (S.sec === "write" || S.editor) { e.preventDefault(); if (S.editor && !saveOutcome(await S.editor.flush())) break; toast("Saved"); refresh(false).then(renderSidebar); } break;
    case "1": e.preventDefault(); setSection("write"); break;
    case "2": e.preventDefault(); setSection("inbox"); break;
    case "3": e.preventDefault(); setSection("archive"); break;
    case "4": e.preventDefault(); setSection("tags"); break;
    case "r": case "R": if (S.sec === "archive" && !inField) { e.preventDefault(); invoke("random_entry").then(r => r && showEntrySheet(r.entry, { kind: "archive", arg: r.date }, r.date)); } break;
    case ",": e.preventDefault(); setSection("settings"); break;
  }
});

/* Drag-and-drop files into the composer/editor */
listen("tauri://drag-drop", async e => {
  const paths = e.payload && e.payload.paths ? e.payload.paths : [];
  if (!paths.length || !S.insertMedia) return;
  for (const p of paths) { const rel = await invoke("import_asset", { src: p }); if (rel) S.insertMedia(rel); }
});
/* Compression runs on a worker thread and reports (done, total); whoever
   started it registers a handler so the button can count up instead of just
   sitting there saying "Compressing…". */
listen("media-progress", e => { if (S.onMediaProgress && e.payload) S.onMediaProgress(e.payload.done, e.payload.total); });

/* ------------------------------------------------------------------ */
/* Boot                                                                */
/* ------------------------------------------------------------------ */
(async function boot() {
  S.prefs = await invoke("get_prefs");
  applyAppearance();
  S.timer.remaining = pref("timerMinutes") * 60;
  await refresh(false);
  renderView();
})();

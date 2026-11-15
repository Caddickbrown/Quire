/* Regression checks for what the Linux pages show: On this day, dates that don't exist,
 * links with brackets, plurals, and the pickers after the journal changes under them.
 * Run: node tools/check_linux_views.js. No browser/package dependencies. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const noop = () => {};
const element = { dataset: {}, classList: { toggle: noop, add: noop, remove: noop }, setAttribute: noop, toggleAttribute: noop };
const appWindow = { onResized: noop, onCloseRequested: noop, isMaximized: async () => false };
// A fixed clock, so "this day" and "yesterday" are the same on every run: 12 October 2026, 09:30.
const NOW = new Date(2026, 9, 12, 9, 30, 0).getTime();
class FixedDate extends Date {
  constructor(...args) { if (args.length) super(...args); else super(NOW); }
  static now() { return NOW; }
}
const context = vm.createContext({
  console, setTimeout, clearTimeout, setInterval: noop, clearInterval: noop, Date: FixedDate,
  document: { addEventListener: noop, querySelectorAll: () => [], querySelector: () => element, documentElement: element },
  window: { __TAURI__: { core: { invoke: async () => false, convertFileSrc: p => p }, event: { listen: noop }, window: { getCurrentWindow: () => appWindow } }, addEventListener: noop, matchMedia: () => ({ addEventListener: noop }) },
});
const source = fs.readFileSync('linux/src/app.js', 'utf8');
vm.runInContext(source.slice(0, source.indexOf('/* ---------- boot ---------- */')), context);
const run = text => vm.runInContext(text, context);
const entry = (file, source, ts, title, extra = '') =>
  `{file:'${file}', index:0, source:'${source}', ts:'${ts}', date:'${ts.slice(0, 10)}', time:'${ts.slice(11, 16)}', title:'${title}', body:'x', raw:'[${ts}] ${title}\\nx', words:1, tags:[], starred:false${extra}}`;

assert.equal(run('today()'), '2026-10-12', 'the fixed clock is in use');

// On this day is the main journal's: a split journal's entries are not memories, on Today or on Look back.
run(`S.entries = [
  ${entry('journal/2025/10/12.md', 'journal', '2025-10-12 08:00:00', 'A walk by the canal')},
  ${entry('journal/2024/10/12.md', 'journal', '2024-10-12 08:00:00', 'Two years back')},
  ${entry('split/work/2025/10/12.md', 'split', '2025-10-12 09:00:00', 'Quarterly standup', ", split:'work'")},
  ${entry('split/work/2023/10/12.md', 'split', '2023-10-12 09:00:00', 'Budget review', ", split:'work'")},
  ${entry('inbox/2025/10/12.md', 'inbox', '2025-10-12 10:00:00', 'An old draft')},
  ${entry('journal/2026/10/12.md', 'journal', '2026-10-12 08:00:00', 'This morning')},
  ${entry('journal/2025/10/13.md', 'journal', '2025-10-13 08:00:00', 'The day after')}
]; S.view = 'today';`);
assert.deepEqual(Array.from(run('onThisDay().map(e => e.title)')), ['A walk by the canal', 'Two years back']);
const home = run('renderHome()');
assert.match(home, /A walk by the canal/);
assert.doesNotMatch(home, /Quarterly standup|Budget review|An old draft/);
const otdOf = html => html.slice(html.indexOf('On this day'));
run('S.year = 2026');
const look = otdOf(run('renderLookBack()'));
assert.match(look, /A walk by the canal/);
assert.doesNotMatch(look, /Quarterly standup|Budget review/);
run("S.entries = S.entries.filter(e => e.source !== 'journal')");
assert.match(run('renderHome()'), /Nothing written on this day in earlier years/, 'split entries alone are not On this day');

// Look back is the main journal's; the split journals have a panel of their own, all of them together.
run(`S.entries = [
  ${entry('journal/2026/10/10.md', 'journal', '2026-10-10 08:00:00', 'Main one')},
  ${entry('journal/2026/10/11.md', 'journal', '2026-10-11 08:00:00', 'Main two')},
  ${entry('split/work/2026/10/11.md', 'split', '2026-10-11 09:00:00', 'Standup', ", split:'work'")},
  ${entry('split/work/2026/10/12.md', 'split', '2026-10-12 09:00:00', 'Retro', ", split:'work'")},
  ${entry('split/home/2026/10/12.md', 'split', '2026-10-12 10:00:00', 'Shelves', ", split:'home'")},
  ${entry('split/home/2024/02/03.md', 'split', '2024-02-03 10:00:00', 'Long ago', ", split:'home'")},
  ${entry('inbox/2026/10/12.md', 'inbox', '2026-10-12 11:00:00', 'A draft')}
]; S.entries.forEach((e, i) => { e.words = i + 1; }); S.year = 2026; S.view = 'lookback';`);
assert.deepEqual(JSON.parse(run('JSON.stringify(splitStats())')), { names: ['home', 'work'], entries: 4, words: 3 + 4 + 5 + 6, days: 3 });
assert.deepEqual(JSON.parse(run('JSON.stringify(splitStats(2026))')), { names: ['home', 'work'], entries: 3, words: 3 + 4 + 5, days: 2 });
const page = run('renderLookBack()');
assert.match(page, /<span class="v">2<\/span><span class="l">days written in 2026/, 'the split entry on the 12th is not a day written');
assert.match(page, /<span class="v">3<\/span><span class="l">words in 2026/, 'words: the main journal\'s 1 + 2');
assert.match(page, /<h2>All time<\/h2>[^]*?2 entries over 2 days · 3 words/);
assert.doesNotMatch(page, /<option[^>]*>2024<\/option>/, 'a year with only split entries is not one of the journal\'s years');
const panel = page.slice(page.indexOf('id="split-journals"'), page.indexOf('<h2>Library</h2>'));
assert.match(panel, /<h2>Split journals<\/h2>/);
assert.match(panel, /@home<\/span> <span[^>]*>@work<\/span>/);
assert.match(panel, /4 entries over 3 days · 18 words/);
assert.match(panel, /2026: 3 entries over 2 days · 12 words/);
run('S.year = 2025');
assert.match(run('renderLookBack()'), /2025: nothing written/);
run('S.year = 2026');
// The counters, the reminder's streak and Random are the main journal's too.
assert.equal(run('streakToYesterday()'), 2, 'the 10th and 11th; the split entries and today are not in it');
context.render = noop;
for (let i = 0; i < 40; i++) { run("S.journal = 'work'; randomEntry()"); assert.equal(run('S.sel.source'), 'journal'); assert.equal(run('S.journal'), 'main', 'the list beside it holds the entry'); }
run("S.sel = null; S.entries = S.entries.filter(e => e.source !== 'split')");
assert.doesNotMatch(run('renderLookBack()'), /split-journals/, 'no split journals, no panel');

// Yesterday is the calendar's day before, not 24 hours ago.
assert.equal(run('yesterday()'), '2026-10-11');

// A date that doesn't exist is shown as written, in every format, instead of throwing and blanking the list.
for (const fmt of ['weekday', 'medium', 'long', 'iso']) {
  context.fmt = fmt;
  assert.equal(run("fmtDate('2026-13-45', fmt)"), '2026-13-45', `impossible date, ${fmt}`);
  assert.doesNotThrow(() => run("fmtDate('2026-06-15', fmt)"));
}
assert.equal(run("fmtDate('2026-06-15', 'medium')"), '15 Jun 2026');
run(`S.entries = [
  ${entry('journal/2026/13/45.md', 'journal', '2026-13-45 25:61:00', 'Impossible')},
  ${entry('journal/2026/06/15.md', 'journal', '2026-06-15 08:00:00', 'Possible')}
]; S.view = 'journal'; S.jview = 'list'; S.journal = 'main';`);
assert.match(run('renderList()'), /Impossible/, 'the list still draws');
const charts = run('renderLookBack()');
assert.doesNotMatch(charts, /NaN/, 'one impossible month or hour does not turn the charts into NaN');

// A file name with brackets is one link, as the core reads it.
run("S.assetUrls.set('assets/2026/11/image(1).jpg', 'asset://bracket')");
const prose = run("renderProse('![](assets/2026/11/image(1).jpg) after', 'journal/2026/11/02.md')");
assert.match(prose, /src="asset:\/\/bracket"/);
assert.doesNotMatch(prose, /\.jpg\)/, 'no stray tail of the name left as text');
assert.deepEqual(Array.from(run("mediaOf({file:'journal/2026/11/02.md', body:'![a](assets/x.png \"t\") [b](<assets/two words.pdf>) ![](assets/y(2).jpg)'})")),
  ['assets/x.png', 'assets/two words.pdf', 'assets/y(2).jpg']);

// One of a thing reads as one.
assert.equal(run("plural(1, 'word')"), '1 word');
assert.equal(run("plural(2, 'entry', 'entries')"), '2 entries');
run(`S.entries = [${entry('journal/2026/06/15.md', 'journal', '2026-06-15 08:00:00', 'Only')}]`);
const one = run('renderLookBack()');
assert.match(one, /1 entry over 1 day ·/);
assert.doesNotMatch(one, /(?<!\d)1 (entries|days|words)\b/);

// The year on show is always in Look back's picker, even with nothing written in it.
run('S.year = 2019');
assert.match(run('renderLookBack()'), /<option selected>2019<\/option>/);

// ----- the 14 November review -----
// The reader: headings by level, a rule, fenced code kept whole, nested lists; the task numbering still counts every task line.
const md = run("renderProse('# One\\n\\n## Two\\n\\n#### Four\\n\\n---\\n\\n```js\\nconst a = 1 < 2;\\n\\n- [ ] not a task here\\n```\\n\\n- top\\n  - nested\\n    - deeper\\n\\n- [ ] first real task', 'journal/2026/06/15.md')");
assert.match(md, /<h2>One<\/h2>/); assert.match(md, /<h3>Two<\/h3>/); assert.match(md, /<h4>Four<\/h4>/);
assert.match(md, /<hr>/);
assert.match(md, /<pre><code>const a = 1 &lt; 2;\n\n- \[ \] not a task here<\/code><\/pre>/, 'a blank line inside a fence does not end it, and its text is escaped');
assert.match(md, /<li class="">top<\/li><li class="d1">nested<\/li><li class="d2">deeper<\/li>/);
assert.match(md, /data-ix="1"/, 'the task after the fence is the second task-shaped line, as toggleTask counts');
assert.doesNotMatch(md, /data-ix="0"/);

// Hostile text through every page that draws entries: nothing a title, a body, a tag or a file name holds becomes markup.
const evil = '<img src=x onerror=alert(1)>"\'';
context.evil = evil;
run(`S.entries = [
  {file:'journal/2026/10/11.md', index:0, source:'journal', ts:'2026-10-11 08:00:00', date:'2026-10-11', time:'08:00', title: evil, body: evil + ' [x](javascript:alert(1)) ![' + evil + '](assets/' + evil + '.png)', raw:'[2026-10-11 08:00:00] ' + evil, words:1, tags:['@a'], starred:true},
  {file:'split/' + evil + '/2026/10/12.md', index:0, source:'split', split: evil, ts:'2026-10-12 08:00:00', date:'2026-10-12', time:'08:00', title:'', body: evil, raw:'[2026-10-12 08:00:00]\\n' + evil, words:1, tags:[], starred:false},
  {file:'inbox/2026/10/12.md', index:0, source:'inbox', ts:'2026-10-12 09:00:00', date:'2026-10-12', time:'09:00', title: evil, body: evil, raw:'[2026-10-12 09:00:00] ' + evil, words:1, tags:[], starred:false}
]; S.templates = [{name: evil, body: evil}]; S.searches = [{name: evil, query: evil}]; S.folder = evil; S.year = 2026; S.query = ''; S.day = null; S.tag = null; S.sel = null; S.mode = 'read'; S.draft = null; S.assets = [{rel:'assets/' + evil + '.png', kind:'image', bytes:1, referenced:true}];`);
const pages = {
  today: "S.view='today'; renderList() + renderHome()",
  inbox: "S.view='inbox'; renderList()",
  journal: "S.view='journal'; S.jview='list'; S.journal='all'; renderList()",
  stream: "S.view='journal'; S.journal='all'; renderStream()",
  read: "renderRead(S.entries[0])",
  day: "renderDayPage('2026-10-12')",
  write: "S.draft={ref:null,ts:'2026-10-12 10:00:00',title:evil,body:evil,starred:false}; const h = renderWrite(); S.draft=null; h",
  lookback: "S.view='lookback'; renderLookBack()",
  media: "S.view='media'; renderMedia()",
  settings: "S.view='settings'; S.tplEdit=evil; renderSettings()",
  print: "renderPrintJournal()",
};
for (const [name, code] of Object.entries(pages)) {
  const html = run(code);
  assert.doesNotMatch(html, /<img src=x/, `${name}: raw markup from journal text`);
  assert.doesNotMatch(html, /="[^"<>]*"'/, `${name}: a quote ended an attribute`);
  assert.doesNotMatch(html, /href="javascript:/i, `${name}: a script link`);
}

// A list that stops says so.
run(`S.entries = Array.from({length: 520}, (_, i) => ({file:'journal/2026/01/01.md', index:i, source:'journal', ts:'2026-01-01 08:00:00', date:'2026-01-01', time:'08:00', title:'T' + i, body:'x', raw:'[2026-01-01 08:00:00] T' + i, words:1, tags:[], starred:false})); S.view='journal'; S.jview='list'; S.journal='main'; S.templates=[]; S.searches=[]; S.tplEdit=null; S.folder='/j';`);
assert.match(run('renderList()'), /Showing the first 500 of 520/);
assert.match(run('renderStream()'), /Showing the first 300 of 520/);

// The stylesheet's theme tokens are themes.json's, and so is the picker's copy: nothing drifts unnoticed.
const themes = JSON.parse(fs.readFileSync('themes.json', 'utf8')).themes;
const css = fs.readFileSync('linux/src/style.css', 'utf8');
const lum = hex => { const [r, g, b] = [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16) / 255).map(v => v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4); return 0.2126 * r + 0.7152 * g + 0.0722 * b; };
const ratio = (a, b) => { const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x); return (hi + 0.05) / (lo + 0.05); };
const picker = JSON.parse(run('JSON.stringify(THEMES)'));
for (const t of themes) {
  const at = css.indexOf(`[data-theme="${t.id}"] {`);
  assert.ok(at >= 0, `style.css has a block for ${t.id}`);
  const block = css.slice(at, css.indexOf('}', at));
  for (const [key, value] of Object.entries(t)) {
    if (typeof value !== 'string' || !/^#[0-9A-F]{6}$/i.test(value)) continue;
    const m = block.match(new RegExp(`--${key.replace(/_/g, '-')}: (#[0-9A-Fa-f]{6});`));
    assert.ok(m, `style.css sets --${key.replace(/_/g, '-')} for ${t.id}`);
    assert.equal(m[1].toUpperCase(), value.toUpperCase(), `${t.id} ${key}: style.css and themes.json differ`);
  }
  const row = picker.find(x => x[0] === t.id);
  assert.deepEqual(row.slice(2, 5).map(x => x.toUpperCase()), [t.page, t.ink, t.accent].map(x => x.toUpperCase()), `${t.id}: the theme picker's colours`);
  // Text colours pass WCAG AA (4.5:1) on the page and on a card: ink, muted, the accent, and faint, which placeholders use.
  for (const key of ['ink', 'muted', 'faint', 'accent']) for (const ground of ['page', 'card'])
    assert.ok(ratio(t[key], t[ground]) >= 4.5, `${t.id}: ${key} on ${ground} is ${ratio(t[key], t[ground]).toFixed(2)}:1`);
}

console.log('Linux view checks passed: reader markdown, escaping on every page, list limits, theme tokens against themes.json and their contrast, On this day and Look back without split journals, the Split journals panel, impossible dates, bracketed links, plurals, yesterday and the year picker.');

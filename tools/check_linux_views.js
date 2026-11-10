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

console.log('Linux view checks passed: On this day and Look back without split journals, the Split journals panel, impossible dates, bracketed links, plurals, yesterday and the year picker.');

/* The search grammar in linux/src/app.js against the core's own cases.
 * Run: node tools/check_search.js. No browser or package dependencies.
 *
 * CORE_CASES is core/src/search.rs `grammar_matches_the_other_ports`, case for
 * case, as data: when a case is added there, add it here. MORE follows the
 * core's code (tokenize / Query::parse / Query::matches) for the places the
 * Linux copy used to differ. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const noop = () => {};
const element = { dataset: {}, classList: { toggle: noop, add: noop, remove: noop }, setAttribute: noop, toggleAttribute: noop };
const appWindow = { onResized: noop, onCloseRequested: noop, isMaximized: async () => false };
const context = vm.createContext({
  console, setTimeout, clearTimeout, setInterval: noop, clearInterval: noop,
  document: { addEventListener: noop, querySelectorAll: () => [], querySelector: () => element, documentElement: element },
  window: { __TAURI__: { core: { invoke: async () => false, convertFileSrc: p => p }, event: { listen: noop }, window: { getCurrentWindow: () => appWindow } }, addEventListener: noop, matchMedia: () => ({ addEventListener: noop }) },
});
const source = fs.readFileSync('linux/src/app.js', 'utf8');
vm.runInContext(source.slice(0, source.indexOf('/* ---------- boot ---------- */')), context);
const call = (fn, ...args) => { context.__args = args; return JSON.parse(JSON.stringify(vm.runInContext(`${fn}(...__args)`, context))); };

/** The test helper in search.rs: an entry in journal/x.md at 08:00:00, parsed as the core parses it. */
function entry(date, suffix, body) {
  const ts = `${date} 08:00:00`;
  const raw = suffix ? `[${ts}] ${suffix}\n${body}` : `[${ts}]\n${body}`;
  const starred = /(^|\s)\*$/.test(suffix);
  const title = starred ? suffix.replace(/\s*\*$/, '') : suffix;
  return { file: 'journal/x.md', index: 0, source: 'journal', ts, date, time: '08:00:00', title, starred, body, raw, tags: raw.match(/@[a-zA-Z][a-zA-Z0-9_-]*/g) || [] };
}
const parse = text => call('parseQuery', text);
const matches = (query, e) => vm.runInContext('(q, e) => matchesQuery(e, parseQuery(q))', context)(query, e);
const isEmpty = text => vm.runInContext('q => queryIsEmpty(parseQuery(q))', context)(text);

const FULL = 'coffee tag:Work before:2026-03 after:2025 has:image is:starred';
const dated = entry('2025-06-01', 'Morning', 'nothing numeric here');
const recorded = entry('2026-01-02', '', '![](assets/a.m4a) ![](assets/b.webm) [f](assets/c.pdf)');

const CORE_CASES = [
  ['tokenize', 'plain "two words" tag:work', ['plain', 'two words', 'tag:work']],
  ['parse', FULL, { terms: ['coffee'], tags: ['@work'], before: '2026-03', after: '2025', has: ['image'], starred: true }],
  ['empty', '', true],
  ['partial-date', '26-03', false],
  ['match', FULL, entry('2026-02-10', 'Morning *', 'coffee @work ![](assets/a.png)'), true],
  ['match', FULL, entry('2026-02-10', 'Morning *', 'coffee @work'), false],
  ['match', FULL, entry('2026-03-01', 'Morning *', 'coffee @work ![](assets/a.png)'), false],
  ['match', FULL, entry('2024-12-31', 'Morning *', 'coffee @work ![](assets/a.png)'), false],
  ['match', '"exact phrase"', entry('2026-01-01', '', 'an exact phrase here'), true],
  ['match', '"exact phrase"', entry('2026-01-01', '', 'exact other phrase'), false],
  // Smart punctuation: a phone types “ ” for ", and they quote the same.
  ['tokenize', '\u201Cexact phrase\u201D \u00ABdeux mots\u00BB \u201Ezwei\u201C', ['exact phrase', 'deux mots', 'zwei']],
  ['parse', '\u201Cexact phrase\u201D', { terms: ['exact phrase'], tags: [], before: null, after: null, has: [], starred: false }],
  ['match', '\u201Cexact phrase\u201D', entry('2026-01-01', '', 'an exact phrase here'), true],
  ['match', '\u201Cexact phrase\u201D', entry('2026-01-01', '', 'exact other phrase'), false],
  // Anything quoted is text, never an operator.
  ['parse', '"is:starred"', { terms: ['is:starred'], starred: false }],
  ['match', '"is:starred"', entry('2026-01-01', '', 'type is:starred to filter'), true],
  ['parse', '"tag:work stuff" "@home" "before:2026"', { terms: ['tag:work stuff', '@home', 'before:2026'], tags: [], before: null }],
  // An operator with a value that can't be used is searched as text, so the search never comes back wider than what was asked.
  ['parse', 'coffee before:March has:pdf tag:', { terms: ['coffee', 'before:march', 'has:pdf', 'tag:'], tags: [], before: null, has: [] }],
  ['match', 'coffee before:March has:pdf tag:', entry('2026-01-01', '', 'coffee'), false],
  ['match', 'after:2026-03', entry('2026-03-01', '', 'x'), true],
  ['parse', 'Before:2026-03', { before: '2026-03' }],
  ['parse', 'TAG:Work', { tags: ['@work'] }],
  ['parse', '@Work', { tags: ['@work'] }],
  ['parse', 'Is:Starred', { starred: true }],
  ['match', '2025', dated, false], // a plain term never searches the header
  ['match', 'morning', dated, true],
  ['match', '2025', entry('2025-06-01', '', 'bought it in 2025'), true],
  ['match', 'has:audio', recorded, true],
  ['match', 'has:video', recorded, true],
  ['match', 'has:image', recorded, false],
  ['match', 'has:media', recorded, true],
];

const MORE = [
  // An unclosed quote is a phrase so far, not zero results until it is closed.
  ['tokenize', 'rain "two wor', ['rain', 'two wor']],
  ['match', '"exact phr', entry('2026-01-01', '', 'an exact phrase here'), true],
  // A quote ends the token before it, and an empty pair gives nothing.
  ['tokenize', 'ab"cd"ef ""', ['ab', 'cd', 'ef']],
  // A quoted token is a term whatever it looks like; an unclosed quote still quotes.
  ['parse', '"tag:work"', { terms: ['tag:work'], tags: [] }],
  ['parse', '"@work stuff"', { terms: ['@work stuff'], tags: [] }],
  ['parse', '"@work', { terms: ['@work'], tags: [] }],
  ['parse', '@', { terms: ['@'], tags: [] }],
  ['parse', 'tag:@Work tag: tag:@', { terms: ['tag:', 'tag:@'], tags: ['@work'] }],
  // A before:/after:/has: whose value isn't usable (yet) is a term, not a filter.
  ['parse', 'coffee before:202', { terms: ['coffee', 'before:202'], before: null }],
  ['parse', 'after:2026-3 before:2026-03-1x', { terms: ['after:2026-3', 'before:2026-03-1x'], before: null, after: null }],
  ['parse', 'has:pdf has:', { terms: ['has:pdf', 'has:'], has: [] }],
  ['parse', 'before:2026 before:2025-01', { before: '2025-01' }],
  ['parse', 'is:star', { terms: ['is:star'], starred: false }],
  ['empty', 'before:202', false],
  ['empty', '"" \u201C\u201D', true],
  ['partial-date', '2026-03-15', true],
  ['partial-date', '2026-03-15-01', false],
  ['partial-date', '', false],
  // before: is strict; after: includes the day, month or year it names.
  ['match', 'before:2026-03-01', entry('2026-03-01', '', 'x'), false],
  ['match', 'before:2026-03-01', entry('2026-02-28', '', 'x'), true],
  ['match', 'after:2026', entry('2026-01-01', '', 'x'), true],
  ['match', 'after:2026-03-02', entry('2026-03-01', '', 'x'), false],
  // has:media is anything under assets/, a PDF included; a link elsewhere is not media.
  ['match', 'has:media', entry('2026-01-02', '', '[scan](assets/2026/01/scan.pdf)'), true],
  ['match', 'has:media', entry('2026-01-02', '', '[site](https://example.com/a.png) [note](other.md)'), false],
  ['match', 'has:image', entry('2026-01-02', '', '![](assets/2026/01/image(1).jpg)'), true],
  ['match', 'has:image', entry('2026-01-02', '', '![](<assets/2026/01/two words.png> "t")'), true],
  ['match', 'has:image', entry('2026-01-02', '', '![](../../assets/a.png)'), false], // from journal/x.md this climbs out of the root
  // extras::media_kind: "heif" is the same container as "heic", and an image.
  ['match', 'has:image', entry('2026-01-02', '', '![](assets/a.heif)'), true],
  ['match', 'has:image', entry('2026-01-02', '', '![](assets/a.HEIC)'), true],
  ['match', 'has:image has:audio', recorded, false],
  // Tags compare whole and case-folded; terms search the title and body only.
  ['match', 'tag:work', entry('2026-01-02', '', 'at @Work today'), true],
  ['match', '@wor', entry('2026-01-02', '', 'at @work today'), false],
  ['match', 'is:starred', entry('2026-01-02', 'Plain', 'x'), false],
  ['match', '', entry('2026-01-02', 'Plain', 'x'), false], // an empty query matches nothing
];

let n = 0;
for (const [kind, input, a, b] of [...CORE_CASES, ...MORE]) {
  const label = `${kind} ${JSON.stringify(input)}`;
  if (kind === 'tokenize') assert.deepEqual(call('tokenize', input), a, label);
  else if (kind === 'parse') { const q = parse(input); for (const [k, v] of Object.entries(a)) assert.deepEqual(q[k], v, `${label} → ${k}`); }
  else if (kind === 'empty') assert.equal(isEmpty(input), a, label);
  else if (kind === 'partial-date') assert.equal(call('isPartialDate', input), a, label);
  else if (kind === 'match') assert.equal(matches(input, a), b, `${label} on ${JSON.stringify(a.raw)}`);
  else throw new Error(`unknown case ${kind}`);
  n++;
}
// The lists: an empty query filters nothing; a half-typed operator is text, as in the core, and filters.
assert.equal(vm.runInContext("searchFilter('  \"\" ')", context), null);
assert.equal(vm.runInContext("typeof searchFilter('before:202')", context), 'function');
console.log(`Search checks passed: ${CORE_CASES.length} core cases and ${MORE.length} more against the Linux parseQuery (${n} in all).`);

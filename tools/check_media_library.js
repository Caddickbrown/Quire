/* Regression checks for media navigation and links rewritten by cleanup.
 * Run: node tools/check_media_library.js. No browser/package dependencies. */
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
const run = text => vm.runInContext(text, context);
run(`S.entries = [
  {file:'journal/2026/09/30.md', index:0, source:'journal', ts:'2026-09-30 10:00:00', date:'2026-09-30', body:'![caption](<assets/2026/09/photo one.jpg> "Title") ![](assets/2026/09/a%23b.jpg)'},
  {file:'inbox/2026/10/01.md', index:0, source:'inbox', ts:'2026-10-01 10:00:00', date:'2026-10-01', body:'![](assets/2026/10/photo.jpg)'}
]; S.assets = [
  {rel:'assets/2026/09/photo one.jpg', kind:'image', bytes:100, referenced:true},
  {rel:'assets/2026/10/photo.jpg', kind:'image', bytes:200, referenced:true},
  {rel:'assets/voice.m4a', kind:'audio', bytes:300, referenced:false}
]; S.assetUrls.set('assets/2026/09/photo one.jpg', 'asset://photo'); S.assetUrls.set('assets/2026/09/a#b.jpg','asset://hash');`);
assert.equal(run("TABS.find(t=>t.id==='media').label"), 'Media Library');
assert.equal(run("assetOwners().get('assets/2026/09/photo one.jpg')[0].file"), 'journal/2026/09/30.md');
assert.equal(run("assetOwners().get('assets/2026/10/photo.jpg')[0].source"), 'inbox');
assert.equal(run("resolveRel('journal/2026/09/30.md','../../../assets/2026/09/a%23b.jpg#preview')"), 'assets/2026/09/a#b.jpg');
const prose = run("renderProse(S.entries[0].body,S.entries[0].file)");
assert.match(prose, /src="asset:\/\/photo"/);
assert.match(prose, /src="asset:\/\/hash"/);
assert.doesNotMatch(prose, /&lt;assets/);
assert.match(run('renderMedia()'), /Media Library/);
run("S.assetFilter='audio'");
assert.match(run('renderMedia()'), /voice.m4a/);
assert.doesNotMatch(run('renderMedia()'), /data-rel="assets\/2026\/09\/photo one.jpg"/);
run("S.assetFilter='orphan'");
assert.match(run('renderMedia()'), /voice.m4a/);
run("S.assetQuery='no match'");
assert.match(run('renderMedia()'), /No media matches these filters/);
run("S.assetQuery=''; S.assetFilter='all'; S.ui.assetGroup='month'");
assert.match(run('renderMedia()'), /September 2026/);
assert.match(run('renderMedia()'), /October 2026/);
assert.match(run('renderMedia()'), /Not linked to an entry/);
console.log('Media library checks passed: navigation, cleaned links, exact owners, filters, grouping and empty states.');

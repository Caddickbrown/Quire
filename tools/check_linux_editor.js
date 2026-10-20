/* Editor/search regressions; run with node tools/check_linux_editor.js. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const noop = () => {};
const timers = new Map(), frames = new Map(), nodes = new Map(), writes = [];
let serial = 0, context;
const root = { dataset: {} };
const api = {
  invoke: async (cmd, args) => {
    if (cmd === 'create_draft' || cmd === 'update_entry') {
      writes.push({cmd, ...args});
      const raw = vm.runInContext('makeRaw', context)(args.ts, args.title, args.starred, args.body);
      return {file: 'inbox/2026/10/20.md', index: 0, raw};
    }
    return false;
  },
  convertFileSrc: p => p,
};
context = vm.createContext({
  console,
  setTimeout: (cb, delay) => { const id = ++serial; timers.set(id, {cb, delay}); return id; },
  clearTimeout: id => timers.delete(id), setInterval: noop, clearInterval: noop,
  requestAnimationFrame: cb => { const id = ++serial; frames.set(id, cb); return id; },
  cancelAnimationFrame: id => frames.delete(id),
  document: { addEventListener: noop, querySelectorAll: () => [], querySelector: s => nodes.get(s) || null, documentElement: root },
  window: { __TAURI__: { core: api, event: { listen: noop }, window: { getCurrentWindow: () => ({ onResized: noop, onCloseRequested: noop, isMaximized: async () => false }) } }, addEventListener: noop, matchMedia: () => ({ addEventListener: noop }) },
});
const source = fs.readFileSync('linux/src/app.js', 'utf8');
vm.runInContext(source.slice(0, source.indexOf('/* ---------- boot ---------- */')), context);
const run = text => vm.runInContext(text, context);
(async () => {
  assert.match(run("editorMarkup('*single* _under_ __legacy__ **bold**')"), /<i>\*single\*<\/i>/);
  assert.match(run("editorMarkup('*single* _under_ __legacy__ **bold**')"), /<i>_under_<\/i>/);
  assert.match(run("editorMarkup('`*plain*`')"), /<code>`\*plain\*`<\/code>/);
  assert.doesNotMatch(run("editorMarkup('`*plain*` word_under_score')"), /<i>/);
  assert.doesNotMatch(run("editorMarkup('**bold**')"), /<i>/);
  for (const text of ['_italic_', '*italic*', '**bold**', '`*code*`', '_a & b_']) {
    for (let caret = 0; caret <= text.length; caret++) {
      context.sampleText = text; context.sampleCaret = caret;
      const formatted = run('markupWithCaret(sampleText, sampleCaret)');
      assert.equal(formatted.replace('<span id="caretmark"></span>', ''), run('editorMarkup(sampleText)'), 'formatting survives every caret position, including delimiters');
    }
  }
  const ta = {value:'_italic text_', selectionStart:4, selectionEnd:4, style:{}};
  const bd = {innerHTML:'', offsetHeight:60};
  const title = {style:{}, scrollHeight:96};
  nodes.set('#bodyta',ta); nodes.set('#backdrop',bd); nodes.set('#title',title);
  run("S.mode='write'; S.draft={ref:null,ts:'2026-10-20 10:00:00',title:'A long title',body:'_italic text_',starred:false}; S.focus=false; S.ui.goalOn=false");
  run('paintBackdrop(); resizeTitle()');
  assert.match(bd.innerHTML, /<i>_ita<span id="caretmark"><\/span>lic text_<\/i>/);
  assert.equal(title.style.height,'96px');
  assert.match(run('renderWrite()'), /<textarea class="title-input"[^>]*wrap="soft"/);
  run('queueEditorPaint(); queueEditorPaint()');
  assert.equal(frames.size,1,'input/keyup paints coalesce into one animation frame');
  let tabRenders=0;
  context.countTabs=() => tabRenders++;
  run('renderTabs=countTabs; refreshChrome(false)');
  assert.equal(tabRenders,0,'typing does not rebuild journal-wide tab counters');
  run(`S.entries=[
    {file:'inbox/2026/10/20.md',index:0,source:'inbox',ts:'2026-10-20 10:00:00',date:'2026-10-20',title:'Garden',body:'plant bulbs',tags:['@garden'],words:2},
    {file:'inbox/2026/10/19.md',index:0,source:'inbox',ts:'2026-10-19 10:00:00',date:'2026-10-19',title:'Work',body:'meeting',tags:['@work'],words:1},
    {file:'journal/2026/10/20.md',index:0,source:'journal',ts:'2026-10-20 09:00:00',date:'2026-10-20',title:'Filed garden',body:'garden',tags:['@garden'],words:1}
  ]; S.inboxQuery='tag:garden'; S.query='meeting';`);
  assert.equal(run('inboxList().length'),1);
  assert.equal(run('inboxList()[0].title'),'Garden');
  assert.equal(run('S.query'),'meeting','Inbox query leaves Journal search untouched');
  run('render=()=>{}; S.mode="read"; S.draft=null; S.query=""; S.day=null; S.jview="list"');
  await run("switchView('journal')");
  assert.equal(run('S.sel.source'),'journal');
  assert.match(run('renderPane()'), /aria-label="Entry"/);
  run("S.sel=null; S.day='2026-10-20'");
  assert.match(run('renderPane()'), /aria-label="Day"/,'explicit calendar/day navigation still works');
  // Debounce and navigation flush use the actual save pipeline with a fake clock.
  nodes.clear();
  run("load=async()=>{}; S.mode='write'; S.draft={ref:null,ts:'2026-10-20 10:00:00',title:'Draft',body:'first',starred:false}; S.folderMissing=false; S.ui.goalOn=false");
  run('scheduleSave()');
  assert.equal([...timers.values()][0].delay,1200);
  run("S.draft.body='latest'; scheduleSave()");
  assert.equal(timers.size,1);
  assert.equal(writes.length,0,'no disk write until the user stops typing');
  const pending=[...timers.values()][0]; timers.clear(); pending.cb();
  await run('saveChain');
  assert.equal(writes.length,1);
  assert.equal(writes[0].body,'latest');
  run("S.draft.body='last keystroke before leaving'; scheduleSave()");
  assert.equal(await run('flushDraft(S.draft)'),true);
  assert.equal(timers.size,0);
  assert.equal(writes.at(-1).body,'last keystroke before leaving','leaving flushes edits without waiting for the idle timer');
  assert.equal(run('draftSaved(S.draft)'),true);
  console.log('Linux editor checks passed: wrapping title, inline emphasis/caret, batched painting, isolated Inbox search, Journal landing and safe idle saves.');
})().catch(e => { console.error(e); process.exitCode=1; });

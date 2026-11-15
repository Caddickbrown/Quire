/* Editor/search regressions; run with node tools/check_linux_editor.js. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const noop = () => {};
const timers = new Map(), frames = new Map(), nodes = new Map(), writes = [];
let serial = 0, context;
const root = { dataset: {}, style: { setProperty: noop, removeProperty: noop } };
const hooks = {}, calls = [];
const api = {
  invoke: async (cmd, args) => {
    calls.push(cmd);
    if (hooks[cmd]) return hooks[cmd](args);
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
  console: { log: console.log, warn: noop, error: noop }, // failed saves are logged by the app; the checks assert on state
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
  context.realLoad = run('load');
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

  // ----- reloads, another device's edits, and saves that can't land -----
  const toastEl = { textContent: '', attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, classList: { toggle: noop, add: noop, remove: noop } };
  nodes.set('#toast', toastEl);
  run('load = realLoad');
  const mk = (index, body, extra = {}) => { const ts = '2026-10-21 09:00:00', title = 'Shared'; return { file: 'inbox/2026/10/21.md', index, source: 'inbox', ts, date: ts.slice(0, 10), time: ts.slice(11), title, starred: false, body, tags: [], words: 2, raw: `[${ts}] ${title}\n${body}`, ...extra }; };
  const other = { file: 'inbox/2026/10/21.md', index: 0, source: 'inbox', ts: '2026-10-21 08:00:00', date: '2026-10-21', time: '08:00:00', title: 'Earlier', starred: false, body: 'x', tags: [], words: 1, raw: '[2026-10-21 08:00:00] Earlier\nx' };
  const snap = entries => ({ folder: '/j', entries, ui: {}, templates: [], searches: [], conflicts: [] });
  const open = (entry, body) => { context.openEntry = entry; context.openBody = body; run("S.entries=[openEntry]; S.mode='write'; S.draft={ref:openEntry,ts:openEntry.ts,title:openEntry.title,body:openBody,starred:false,keepOne:false}"); };

  // The same text at a new index: the reference follows it.
  open(mk(0, 'mine'), 'mine');
  hooks.load = async () => snap([other, mk(1, 'mine')]);
  await run('load()');
  assert.equal(run('S.draft.ref.index'), 1);
  assert.equal(run('S.draft.conflict || null'), null);

  // Changed elsewhere, composer clean: the composer takes the version on disk.
  open(mk(0, 'mine'), 'mine');
  hooks.load = async () => snap([mk(0, 'theirs, from the phone')]);
  await run('load()');
  assert.equal(run('S.draft.body'), 'theirs, from the phone');
  assert.equal(run('S.draft.ref.body'), 'theirs, from the phone');

  // Changed elsewhere, composer dirty: the reference is NOT moved to their text, so the core refuses the save.
  open(mk(0, 'mine'), 'mine, with more typed');
  await run('load()');
  assert.equal(run('S.draft.ref.body'), 'mine', 'a dirty composer keeps the reference it started from');
  assert.equal(run('S.draft.body'), 'mine, with more typed');
  assert.equal(run('S.draft.conflict'), 'changed');
  assert.match(run('guardHtml()'), /Keep mine as a new draft[\s\S]*Take theirs/);
  assert.equal(await run('flushDraft(S.draft)'), 'stay', 'leaving waits for the choice');
  const before = writes.length;
  timers.clear(); // the toast's own timer
  run('scheduleSave()');
  assert.deepEqual([...timers.values()].map(x => x.delay), [800], 'no autosave while the versions conflict: only the recovery copy is due');
  calls.length = 0;
  for (const x of [...timers.values()]) { timers.clear(); await x.cb(); }
  assert.ok(calls.includes('save_recovery') && !calls.includes('update_entry'), 'the unsaved version is kept as a recovery copy meanwhile');
  timers.clear();
  // "Keep mine": a new draft is created; the entry on disk is not written over.
  hooks.load = async () => snap([mk(0, 'theirs, from the phone')]);
  run('render=()=>{}');
  await run('resolveConflict(true)');
  assert.equal(writes.length, before + 1);
  assert.equal(writes.at(-1).cmd, 'create_draft');
  assert.equal(writes.at(-1).body, 'mine, with more typed');
  // "Take theirs".
  open(mk(0, 'mine'), 'mine, with more typed');
  await run('load()');
  await run('resolveConflict(false)');
  assert.equal(run('S.draft.body'), 'theirs, from the phone');
  assert.equal(run('S.draft.conflict || null'), null);

  // Our own save read back before its answer arrived is not a conflict.
  open(mk(0, 'mine'), 'mine, saved a moment ago');
  run("S.draft.pendingRaw = composerRaw(S.draft)");
  hooks.load = async () => snap([mk(0, 'mine, saved a moment ago')]);
  await run('load()');
  assert.equal(run('S.draft.conflict || null'), null);
  assert.equal(run('S.draft.body'), 'mine, saved a moment ago');

  // An older answer that arrives after a newer one is dropped.
  run("S.mode='read'; S.draft=null; S.sel=null");
  const gates = [];
  hooks.load = () => new Promise(resolve => gates.push(resolve));
  const first = run('load()'), second = run('load()');
  gates[1](snap([mk(0, 'newer')]));
  await second;
  gates[0](snap([mk(0, 'older')]));
  assert.equal(await first, false);
  assert.equal(run('S.entries[0].body'), 'newer');
  // The same snapshot again reports no change, so the page is not rebuilt.
  hooks.load = async () => snap([mk(0, 'newer')]);
  const kept = run('S.entries');
  assert.equal(await run('load()'), false);
  assert.equal(run('S.entries'), kept, 'unchanged entries keep their array');
  hooks.load = async () => snap([mk(0, 'newer still')]);
  assert.equal(await run('load()'), true);
  // A snapshot that was read while one of our writes finished is read again.
  let reads = 0;
  hooks.load = async () => { reads++; if (reads === 1) await run("invoke('delete_entry', {})"); return snap([mk(0, reads === 1 ? 'before the write' : 'after the write')]); };
  await run('load()');
  assert.equal(reads, 2);
  assert.equal(run('S.entries[0].body'), 'after the write');

  // A saved draft that has been emptied is not "saved".
  open(mk(0, 'mine'), '');
  run("S.draft.title=''");
  assert.equal(run('draftSaved(S.draft)'), false);
  assert.equal(run('pillText(S.draft)'), 'Draft · unsaved');
  assert.equal(run("draftSaved({ref:null,ts:'2026-10-21 09:00:00',title:'',body:'',starred:false})"), true, 'a new, empty draft has nothing to save');

  // A header-shaped line: nothing is filed, but a recovery copy is written and the banner says so.
  timers.clear(); calls.length = 0;
  run("S.draft={ref:null,ts:'2026-10-21 09:00:00',title:'',body:'notes\\n[2026-10-20 08:00:00] pasted',starred:false,keepOne:false}; S.mode='write'");
  run('scheduleSave()');
  assert.equal(timers.size, 1);
  for (const t of [...timers.values()]) { timers.clear(); await t.cb(); }
  assert.ok(calls.includes('save_recovery'));
  assert.ok(!calls.includes('create_draft'));
  assert.match(run('guardHtml()'), /recovery copy is kept meanwhile/);
  assert.equal(run('pillText(S.draft)'), 'Not saved · recovery copy kept');

  // A failing autosave keeps its reference, says "Not saved", and tries again with a growing wait.
  timers.clear();
  hooks.load = async () => snap([mk(0, 'mine')]);
  open(mk(0, 'mine'), 'mine and more');
  hooks.update_entry = async () => { throw new Error('disk full'); };
  run('scheduleSave()');
  let t = [...timers.values()][0]; timers.clear(); t.cb(); await run('saveChain');
  assert.equal(run('S.draft.failed'), 1);
  assert.equal(run('S.draft.ref.body'), 'mine', 'the reference is kept, so a retry cannot make a second draft');
  assert.match(run('pillText(S.draft)'), /^Not saved/);
  const delays = () => [...timers.values()].map(x => x.delay);
  assert.ok(delays().includes(0) && delays().includes(2000), 'a recovery copy now, a retry in two seconds');
  t = [...timers.values()].find(x => x.delay === 2000); timers.clear(); t.cb(); await run('saveChain');
  assert.equal(run('S.draft.failed'), 2);
  assert.ok([...timers.values()].some(x => x.delay === 4000));
  delete hooks.update_entry; timers.clear();
  await run('saveDraftNow()');
  assert.equal(run('S.draft.failed'), 0);
  assert.equal(run('pillText(S.draft)'), 'Draft · saved');

  // Ctrl+I writes _x_; custom accents pick readable text; a template name can't break out of its attribute.
  const sel = { value: 'word', selectionStart: 0, selectionEnd: 4, setRangeText(text, a, b) { this.value = this.value.slice(0, a) + text + this.value.slice(b); }, setSelectionRange: noop, dispatchEvent: noop };
  context.Event = function Event() {}; context.selTa = sel;
  run("wrapSelection(selTa, '_')");
  assert.equal(sel.value, '_word_');
  assert.equal(run("onAccent('#F08C38')"), '#111111');
  assert.equal(run("onAccent('#5C5CD6')"), '#FFFFFF');
  const layer = { innerHTML: '', classList: { add: noop, remove: noop, contains: () => false }, querySelector: () => null, firstElementChild: null };
  nodes.set('#popover', layer); context.innerWidth = 1200; context.innerHeight = 800;
  run(`showMenu({left:0,bottom:0}, [['x', 'tpl:a" onmouseover="alert(1)']])`);
  assert.doesNotMatch(layer.innerHTML, /" onmouseover="/);
  assert.match(layer.innerHTML, /data-menu-item="tpl:a&quot; onmouseover=&quot;alert\(1\)"/);

  // ----- the 14 November review -----
  // An error toast is an alert; anything else a status.
  run("toast('ok')"); assert.equal(toastEl.attrs.role, 'status');
  run("toast('bad', 'error')"); assert.equal(toastEl.attrs.role, 'alert');
  timers.clear();

  // L1: an edit to a filed entry is never autosaved, but every pause keeps a recovery copy that names the entry.
  const filed = { file: 'journal/2026/10/22.md', index: 0, source: 'journal', ts: '2026-10-22 09:00:00', date: '2026-10-22', time: '09:00:00', title: 'Filed', starred: false, body: 'as filed', tags: [], words: 2, raw: '[2026-10-22 09:00:00] Filed\nas filed' };
  context.filedEntry = filed;
  hooks.load = async () => snap([filed]);
  let copy = null;
  hooks.save_recovery = async a => { copy = a.draft; return 'x'; };
  run("S.entries=[filedEntry]; S.folder='/j'; render=()=>{}; editEntry(filedEntry)");
  assert.equal(run('isDirtyEdit(S.draft)'), false);
  calls.length = 0; timers.clear();
  run("S.draft.body='as filed, and half an hour more'; scheduleSave()");
  assert.deepEqual([...timers.values()].map(x => x.delay), [800]);
  for (const x of [...timers.values()]) { timers.clear(); await x.cb(); }
  assert.ok(!calls.includes('update_entry') && !calls.includes('create_draft'), 'a filed edit is not written until Ctrl+S or leaving');
  assert.equal(copy.body, 'as filed, and half an hour more');
  assert.equal(JSON.stringify(copy.entry), JSON.stringify({ file: filed.file, raw: filed.raw }));
  assert.equal(copy.folder, '/j');
  assert.equal(run('S.draft.recovered'), true);
  // Typed and taken back: the copy goes.
  calls.length = 0;
  run("S.draft.body='as filed'; scheduleSave()");
  for (const x of [...timers.values()]) { timers.clear(); await x.cb(); }
  assert.ok(calls.includes('clear_recovery') && !calls.includes('save_recovery'));
  // Saved: the copy goes with the save.
  run("S.draft.body='as filed, then saved'; scheduleSave()");
  for (const x of [...timers.values()]) { timers.clear(); await x.cb(); }
  calls.length = 0;
  hooks.update_entry = async a => ({ file: filed.file, index: 0, raw: run('makeRaw')(a.ts, a.title, a.starred, a.body) });
  hooks.load = async () => snap([{ ...filed, body: 'as filed, then saved', raw: '[2026-10-22 09:00:00] Filed\nas filed, then saved' }]);
  await run('saveEditCore(S.draft)');
  assert.ok(calls.includes('clear_recovery'));
  assert.equal(run('isDirtyEdit(S.draft)'), false);
  delete hooks.update_entry; timers.clear();
  // The copy comes back as an edit to its entry while that entry still reads the same; otherwise as a new draft.
  hooks.load = async () => snap([filed]);
  await run('load()');
  layer.classList.contains = () => false;
  context.askConfirm = async () => true; run('askConfirm = globalThis.askConfirm');
  hooks.read_recovery = async () => ({ ...copy, body: 'recovered text' });
  run("S.mode='read'; S.draft=null; S.recoveryOffered=false; S.locked=false; S.folderMissing=false");
  await run('offerRecovery()');
  assert.equal(run('S.draft.ref.file'), filed.file, 'the composer is on the filed entry');
  assert.equal(run('S.draft.body'), 'recovered text');
  assert.equal(run('isDirtyEdit(S.draft)'), true);
  hooks.read_recovery = async () => ({ ...copy, body: 'recovered text', entry: { file: filed.file, raw: 'something else now' } });
  run("S.mode='read'; S.draft=null; S.recoveryOffered=false");
  await run('offerRecovery()');
  assert.equal(run('S.draft.ref'), null, 'the entry changed since: a new draft, not an edit over it');
  // A copy made in another journal is not offered in this one.
  hooks.read_recovery = async () => ({ ...copy, folder: '/elsewhere' });
  run("S.mode='read'; S.draft=null; S.recoveryOffered=false");
  await run('offerRecovery()');
  assert.equal(run('S.draft'), null);
  delete hooks.read_recovery; delete hooks.save_recovery; timers.clear();

  // An entry edited by hand reads back unlike Quire's own writing of it: opening and leaving it rewrites nothing.
  const hand = { ...filed, title: 'Two  spaces', raw: '[2026-10-22 09:00:00] Two  spaces\n\nas filed' };
  context.handEntry = hand;
  hooks.load = async () => snap([hand]);
  run("S.entries=[handEntry]; editEntry(handEntry)");
  assert.notEqual(run('composerRaw(S.draft)'), hand.raw, 'the case: Quire would write it differently');
  assert.equal(run('isDirtyEdit(S.draft)'), false);
  const writesBefore = writes.length; calls.length = 0;
  assert.equal(await run('flushDraft(S.draft)'), true);
  assert.equal(writes.length, writesBefore);
  assert.ok(!calls.includes('update_entry'));
  await run('load()');
  assert.equal(run('S.draft.conflict || null'), null, 'and a reload does not call it a conflict');

  // L2: a row drawn before a reload still finds its own entry after a sync put another one ahead of it.
  const ea = { ...filed, index: 0, body: 'first', raw: '[2026-10-22 09:00:00] Filed\nfirst' };
  const eb = { ...filed, index: 1, ts: '2026-10-22 10:00:00', time: '10:00:00', body: 'second', raw: '[2026-10-22 10:00:00] Filed\nsecond' };
  context.ea = ea; context.eb = eb;
  run("S.mode='read'; S.draft=null; S.sel=null; S.entries=[ea, eb]");
  const attrs = html => Object.fromEntries([...html.matchAll(/data-([a-z]+)="([^"]*)"/g)].map(m => [m[1], m[2]]));
  context.rowA = { dataset: attrs(run('entryAttrs(ea)')) };
  const synced = { ...filed, index: 0, ts: '2026-10-22 08:00:00', time: '08:00:00', body: 'from the phone', raw: '[2026-10-22 08:00:00] Filed\nfrom the phone' };
  context.es = synced;
  run("S.entries=[es, {...ea, index:1}, {...eb, index:2}]");
  assert.equal(run('entryFrom(rowA).body'), 'first', 'not whatever now sits at the old index');
  assert.equal(run('entryFrom(rowA, true).index'), 1);
  // Rewritten elsewhere: opening finds it by its time; an action that rewrites it does not.
  run("S.entries=[es, {...ea, index:1, body:'first, edited', raw:'[2026-10-22 09:00:00] Filed\\nfirst, edited'}]");
  assert.equal(run('entryFrom(rowA).body'), 'first, edited');
  assert.equal(run('entryFrom(rowA, true)'), null);
  run("S.entries=[es]");
  assert.equal(run('entryFrom(rowA)'), null);

  // L3: a save asked for while the autosave is in flight waits its turn, so a new draft is made once.
  let onDiskNow = [];
  const asEntry = (args, raw) => ({ file: 'inbox/2026/10/23.md', index: 0, source: 'inbox', ts: args.ts, date: args.ts.slice(0, 10), time: args.ts.slice(11), title: args.title, starred: false, body: args.body, tags: [], words: 2, raw });
  hooks.load = async () => snap(onDiskNow);
  delete hooks.create_draft;
  let release; const gate = new Promise(r => { release = r; });
  const sent = [];
  hooks.create_draft = async args => { sent.push('create_draft'); await gate; const raw = run('makeRaw')(args.ts, args.title, args.starred, args.body); onDiskNow = [asEntry(args, raw)]; return { file: 'inbox/2026/10/23.md', index: 0, raw }; };
  hooks.update_entry = async args => { sent.push('update_entry'); const raw = run('makeRaw')(args.ts, args.title, args.starred, args.body); onDiskNow = [asEntry(args, raw)]; return { file: 'inbox/2026/10/23.md', index: 0, raw }; };
  timers.clear();
  run("S.entries=[]; S.mode='write'; S.draft={ref:null,ts:'2026-10-23 10:00:00',title:'',body:'slow folder',starred:false,keepOne:false}; scheduleSave()");
  const idle = [...timers.values()][0]; timers.clear(); idle.cb();          // the autosave starts and hangs
  await Promise.resolve(); await Promise.resolve();
  run("S.draft.body='slow folder, and more'");
  const asked = run('saveDraftQueued()');                                    // Ctrl+S while it hangs
  await Promise.resolve(); await Promise.resolve();
  assert.deepEqual(sent, ['create_draft'], 'the second save has not started');
  release(); await asked;
  assert.deepEqual(sent, ['create_draft', 'update_entry'], 'one draft made, then updated: never two drafts');
  assert.equal(run('draftSaved(S.draft)'), true);
  delete hooks.create_draft; delete hooks.update_entry; timers.clear();

  // L14: a watcher event inside the window after our own save is looked at afterwards, not dropped.
  calls.length = 0;
  run("S.mode='read'; S.draft=null; S.ignoreWatch = Date.now() + 1500");
  await run('externalChange()');
  assert.ok(!calls.includes('load'));
  assert.equal(timers.size, 1, 'a second look is due');
  timers.clear(); run('S.ignoreWatch = 0');

  // L16: text and a picture of it on the clipboard is a paste of the text.
  assert.equal(run("pasteIsImage(true, 'A1\tB1')"), false);
  assert.equal(run("pasteIsImage(true, '')"), true);
  assert.equal(run("pasteIsImage(false, '')"), false);

  // Custom accents are fitted to the theme until they read as text; one that reads already is left alone.
  for (const acc of Object.values(run('ACCENTS')).filter(Boolean)) {
    context.acc = acc;
    const fitted = run("readableAccent(acc, '#1F1A14', ['#F7F1E4', '#F5F0E6', '#EFE8DB', '#FFFDF8'])");
    context.fitted = fitted;
    assert.ok(run("Math.min(...['#F7F1E4', '#F5F0E6', '#EFE8DB', '#FFFDF8'].map(g => contrast(fitted, g)))") >= 4.5, `${acc} on Almanac`);
    const dark = run("readableAccent(acc, '#EDE6D8', ['#16130F', '#242019'])"); context.fitted = dark;
    assert.ok(run("Math.min(contrast(fitted, '#16130F'), contrast(fitted, '#242019'))") >= 4.5, `${acc} on Cinema`);
  }
  assert.equal(run("readableAccent('#8E2F1C', '#1F1A14', ['#F7F1E4'])"), '#8E2F1C');

  // A draft begun on a past day's page is dated that day.
  run("S.mode='read'; S.draft=null; S.view='journal'; startDraft('', '', '2026-03-04')");
  assert.match(run('S.draft.ts'), /^2026-03-04 \d\d:\d\d:\d\d$/);
  assert.equal(run('S.draft.floating'), false);
  run("S.mode='read'; S.draft=null");
  console.log('Linux editor checks passed: wrapping title, inline emphasis/caret, batched painting, isolated Inbox search, Journal landing, safe idle saves, reloads and conflicts, recovery copies and save retries, filed-edit recovery, hand-edited entries, rows after a reload, queued saves, deferred watcher events, pastes and accents.');
})().catch(e => { console.error(e); process.exitCode=1; });

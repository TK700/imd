// imd Windows frontend (reuses shared/preview for rendering)
const { invoke } = window.__TAURI__?.core ?? { invoke: () => Promise.reject('no-tauri') };
const listen = window.__TAURI__?.event?.listen;
const emitTo = window.__TAURI__?.event?.emitTo;

const state = {
  docs: [],            // {id,name,path,text,dirty,isTxt,tocHidden,tab:'preview'|'source'}
  active: 0,
  search: { term: '', replace: '', case: false, ranges: [], idx: -1, visible: false },
  l10n: {},
  snip: { open: false, items: [], sel: 0, rStart: 0, rLen: 0 },
  snippets: [],
};

const TW = window.__TAURI__ || {};
const WebviewWindow = TW.webviewWindow && TW.webviewWindow.WebviewWindow;
const getCurrentWindow = TW.webviewWindow && TW.webviewWindow.getCurrentWindow;
const currentLabel = getCurrentWindow ? getCurrentWindow().label : 'main';

const $ = (id) => document.getElementById(id);
const lang = () => (navigator.language || 'en').toLowerCase().startsWith('zh') ? 'zh-Hans' : 'en';

async function loadL10n() {
  try {
    const r = await fetch(`l10n/${lang()}.json`);
    state.l10n = await r.json();
  } catch (e) { state.l10n = {}; }
  document.querySelectorAll('[data-i18n]').forEach(el => {
    const k = el.getAttribute('data-i18n');
    if (state.l10n[k]) el.textContent = state.l10n[k];
  });
  document.querySelectorAll('[data-i18n-ph]').forEach(el => {
    const k = el.getAttribute('data-i18n-ph');
    if (state.l10n[k]) el.placeholder = state.l10n[k];
  });
}
const t = (k) => state.l10n[k] ?? k;

function parseHeadings(text) {
  const lines = text.split('\n');
  const out = [];
  let inFence = false, offset = 0;
  for (const line of lines) {
    const t = line.trim();
    if (t.startsWith('```') || t.startsWith('~~~')) inFence = !inFence;
    else if (!inFence) {
      const m = /^(#{1,6})\s+(.+?)\s*#*$/.exec(line);
      if (m) out.push({ level: m[1].length, title: m[2], offset });
    }
    offset += line.length + 1;
  }
  return out;
}

function newDoc(isTxt) {
  state.docs.push({ id: crypto.randomUUID(), name: isTxt ? t('untitledTxt') : t('untitledMd'), path: '', text: '', dirty: false, isTxt, tocHidden: false, tab: 'preview' });
  state.active = state.docs.length - 1;
  render();
}

async function openFile() {
  try {
    const d = await invoke('open_file');
    if (d) addDoc(d);
  } catch (e) { console.error(e); }
}

async function openPath(path) {
  try {
    const d = await invoke('open_path', { path });
    if (d) addDoc(d);
  } catch (e) { console.error(e); }
}

function addDoc(d) {
  if (state.docs.some(x => x.path === d.path && d.path)) { state.active = state.docs.findIndex(x => x.path === d.path); }
  else {
    state.docs.push({ id: crypto.randomUUID(), name: d.name, path: d.path, text: d.text, dirty: false, isTxt: d.name.toLowerCase().endsWith('.txt'), tocHidden: false, tab: 'preview' });
    state.active = state.docs.length - 1;
  }
  render();
}

async function saveActive() {
  const d = state.docs[state.active]; if (!d) return;
  if (d.path) { const ok = await invoke('save_file', { path: d.path, content: d.text }); if (ok) d.dirty = false; }
  else {
    const r = await invoke('save_as', { defaultName: d.name, content: d.text });
    if (r) { d.path = r.path; d.name = r.name; d.isTxt = r.name.toLowerCase().endsWith('.txt'); d.dirty = false; }
  }
  render();
}

function closeDoc(i) {
  state.docs.splice(i, 1);
  if (state.active >= state.docs.length) state.active = Math.max(0, state.docs.length - 1);
  render();
}

function activeDoc() { return state.docs[state.active]; }

function setText(v) {
  const d = activeDoc(); if (!d) return;
  if (d.text === v) return;
  d.text = v; d.dirty = true;
  renderTabs(); renderToc(); renderPreview();
}

function addDocRaw(doc) {
  const i = state.docs.findIndex(x => x.id === doc.id);
  if (i >= 0) state.active = i;
  else { state.docs.push(doc); state.active = state.docs.length - 1; }
  render();
}
function outsideWindow(e) {
  const wx = window.screenX, wy = window.screenY;
  return e.screenX < wx || e.screenX > wx + window.outerWidth || e.screenY < wy || e.screenY > wy + window.outerHeight;
}
async function detach(idx) {
  const d = state.docs[idx];
  const label = 'imd-' + Date.now();
  try { await invoke('put_pending', { key: 'label:' + label, doc: JSON.parse(JSON.stringify(d)) }); } catch (e) {}
  if (WebviewWindow) { try { new WebviewWindow(label, { url: 'index.html', width: 900, height: 560, title: 'imd' }); } catch (e) {} }
  closeDoc(idx);
}

function renderTabs() {
  const bar = $('tabbar');
  bar.innerHTML = '';
  state.docs.forEach((d, i) => {
    const el = document.createElement('div');
    el.className = 'tab' + (i === state.active ? ' active' : '');
    el.innerHTML = `<span>${d.name}${d.dirty ? ' •' : ''}</span><b>x</b>`;
    el.onclick = () => { state.active = i; render(); };
    el.querySelector('b').onclick = (e) => { e.stopPropagation(); closeDoc(i); };
    el.addEventListener('mousedown', (e) => { if (e.target.tagName === 'B') return; startTabDrag(e, i, d); });
    bar.appendChild(el);
  });
  const plus = document.createElement('button'); plus.textContent = '+'; plus.className = 'add';
  plus.onclick = () => {
    const r = confirm(`${t('markdown')} / ${t('plainTxt')}? OK=MD, Cancel=TXT`);
    newDoc(!r);
  };
  bar.appendChild(plus);
}

function renderToc() {
  const d = activeDoc();
  const toc = $('toc');
  toc.innerHTML = '';
  const dv = $('divider');
  if (!d || d.tocHidden || d.isTxt) { toc.style.display = 'none'; if (dv) dv.style.display = 'none'; return; }
  toc.style.display = ''; if (dv) dv.style.display = '';
  for (const h of parseHeadings(d.text)) {
    const a = document.createElement('div');
    a.className = 'toc-l' + h.level;
    a.textContent = h.title;
    a.onclick = () => jumpHeading(h);
    toc.appendChild(a);
  }
}

function jumpHeading(h) {
  const d = activeDoc(); if (!d) return;
  if (d.tab === 'source') {
    const src = $('sourcePane');
    src.focus();
    src.setSelectionRange(h.offset, h.offset);
    const line = d.text.slice(0, h.offset).split('\n').length - 1;
    const lh = parseFloat(getComputedStyle(src).lineHeight) || 20;
    src.scrollTop = Math.max(0, line * lh - 40);
  } else {
    const idx = parseHeadings(d.text).findIndex(x => x.offset === h.offset);
    const hs = document.querySelectorAll('#content h1,h2,h3,h4,h5,h6');
    if (hs[idx]) hs[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
  }
}

function renderPreview() {
  const d = activeDoc();
  const pv = $('previewPane'), src = $('sourcePane');
  if (!d) { pv.style.display = 'none'; src.style.display = 'none'; return; }
  if (d.isTxt) { pv.style.display = 'none'; src.style.display = 'block'; src.value = d.text; return; }
  if (d.tab === 'preview') { pv.style.display = 'block'; src.style.display = 'none'; renderMd(d.text); applySearch(); }
  else { pv.style.display = 'none'; src.style.display = 'block'; src.value = d.text; }
}

function updateSeg() {
  const d = activeDoc();
  const isSrc = d && d.tab === 'source';
  $('segPreview').classList.toggle('sel', !isSrc);
  $('segSource').classList.toggle('sel', !!isSrc);
}

function render() {
  const d = activeDoc();
  $('right').style.display = d ? '' : 'none';
  renderTabs(); renderToc(); updateSeg(); renderPreview();
  $('searchbar').style.display = (d && state.search.visible) ? '' : 'none';
}

// search (preview-only highlight; source: select range)
function applySearch() {
  const term = state.search.term;
  if (typeof applyPreviewSearch === 'function') {
    applyPreviewSearch(term, state.search.case);
    if (typeof scrollToMark === 'function') scrollToMark(state.search.idx);
  }
}
function recomputeSearch() {
  const d = activeDoc(); state.search.ranges = [];
  if (!d || !state.search.term) { state.search.idx = -1; $('searchCount').textContent = ''; applySearch(); return; }
  const hay = state.search.case ? d.text : d.text.toLowerCase();
  const needle = state.search.case ? state.search.term : state.search.term.toLowerCase();
  let i = hay.indexOf(needle);
  while (i !== -1) { state.search.ranges.push(i); i = hay.indexOf(needle, i + needle.length); }
  state.search.idx = state.search.ranges.length ? 0 : -1;
  $('searchCount').textContent = state.search.ranges.length ? `${state.search.idx + 1}/${state.search.ranges.length}` : '0';
  applySearch();
}

// snippet hint panel (non-blocking, keyboard-only)
async function loadSnippets() {
  try { const r = await fetch('snippets.json'); state.snippets = await r.json(); } catch (e) { state.snippets = []; }
}
function caretCoords(ta) {
  const m = document.createElement('div');
  const cs = getComputedStyle(ta);
  m.style.cssText = 'position:absolute;visibility:hidden;white-space:pre-wrap;word-wrap:break-word;top:0;left:0;';
  ['fontFamily','fontSize','fontWeight','lineHeight','letterSpacing','padding','borderWidth','boxSizing'].forEach(k => { m.style[k] = cs[k]; });
  m.style.width = ta.clientWidth + 'px';
  const before = ta.value.slice(0, ta.selectionStart);
  m.textContent = before;
  const mark = document.createElement('span'); mark.textContent = '\u200b';
  m.appendChild(mark);
  document.body.appendChild(m);
  const x = mark.offsetLeft, y = mark.offsetTop;
  const lh = parseFloat(cs.lineHeight) || 20;
  m.remove();
  const r = ta.getBoundingClientRect();
  return { x: r.left + x, y: r.top + y - ta.scrollTop + lh };
}
function hideSnip() { state.snip.open = false; $('snip').style.display = 'none'; }
function snipSel(delta) {
  const s = state.snip; if (!s.open) return;
  s.sel = (s.sel + delta + s.items.length) % s.items.length;
  [...$('snip').children].forEach((el, i) => el.classList.toggle('sel', i === s.sel));
  const el = $('snip').children[s.sel]; if (el) el.scrollIntoView({ block: 'nearest' });
}
function snipInsert(i) {
  const s = state.snip, ta = $('sourcePane'), d = activeDoc();
  if (!s.open || i < 0 || i >= s.items.length || !d) return;
  const v = s.items[i].value;
  d.text = d.text.slice(0, s.rStart) + v + d.text.slice(s.rStart + s.rLen);
  d.dirty = true;
  ta.value = d.text;
  const np = s.rStart + v.length;
  ta.setSelectionRange(np, np);
  hideSnip();
  setText(d.text);
  ta.focus();
}
function updateSnip(forceAll) {
  const d = activeDoc(), ta = $('sourcePane'), box = $('snip');
  if (!d || d.isTxt || document.activeElement !== ta) { hideSnip(); return; }
  const pos = ta.selectionStart;
  if (pos !== ta.selectionEnd) { hideSnip(); return; }
  let loc = pos, count = 0;
  while (loc > 0 && count < 6) { if (ta.value[loc - 1] === '\n') break; loc--; count++; }
  const partial = ta.value.slice(loc, pos);
  let items = [], rStart = loc, rLen = partial.length;
  if (partial && ['/', '?', '\uff1f'].includes(partial)) items = state.snippets.slice();
  else if (partial) items = state.snippets.filter(x => x.key.startsWith(partial));
  else if (forceAll) { items = state.snippets.slice(); rStart = pos; rLen = 0; }
  else { hideSnip(); return; }
  if (!items.length) { hideSnip(); return; }
  const s = state.snip;
  s.open = true; s.items = items; s.sel = 0; s.rStart = rStart; s.rLen = rLen;
  box.innerHTML = '';
  items.forEach((it, i) => {
    const row = document.createElement('div');
    row.className = 'snip-row' + (i === 0 ? ' sel' : '');
    const sym = document.createElement('span'); sym.className = 'snip-sym'; sym.textContent = it.key;
    const desc = document.createElement('span'); desc.className = 'snip-desc'; desc.textContent = t(it.desc);
    row.appendChild(sym); row.appendChild(desc);
    box.appendChild(row);
  });
  box.style.display = 'block';
  box.style.width = 'max-content';
  const w = Math.min(box.offsetWidth + 2, 480);
  const c = caretCoords(ta);
  box.style.width = w + 'px';
  box.style.left = Math.min(c.x, window.innerWidth - w - 8) + 'px';
  box.style.top = Math.min(c.y + 4, window.innerHeight - Math.min(box.offsetHeight, 320) - 8) + 'px';
}
$('sourcePane').addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && e.ctrlKey) { e.preventDefault(); e.stopPropagation(); updateSnip(true); return; }
  if (!state.snip.open) return;
  if (e.key === 'ArrowDown') { e.preventDefault(); e.stopPropagation(); snipSel(1); }
  else if (e.key === 'ArrowUp') { e.preventDefault(); e.stopPropagation(); snipSel(-1); }
  else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); snipInsert(state.snip.sel); }
  else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); hideSnip(); }
});
$('sourcePane').addEventListener('keyup', () => { if (!state.snip.open) updateSnip(false); });
$('sourcePane').addEventListener('blur', () => hideSnip());

// divider resize
(function () {
  const dv = $('divider'); if (!dv) return;
  let sx = 0, sw = 0, on = false;
  dv.addEventListener('mousedown', (e) => { on = true; sx = e.clientX; sw = $('toc').offsetWidth; e.preventDefault(); });
  window.addEventListener('mousemove', (e) => { if (!on) return; $('toc').style.width = Math.min(Math.max(sw + (e.clientX - sx), 140), 480) + 'px'; });
  window.addEventListener('mouseup', () => { on = false; });
})();

// tab drag: detach (drop outside) / merge (drop on other imd window)
let tabDrag = null, ghost = null;
function startTabDrag(e, idx, doc) {
  if (e.button !== 0) return;
  tabDrag = { idx, id: doc.id, doc: JSON.parse(JSON.stringify(doc)), sx: e.clientX, sy: e.clientY, moved: false };
}
window.addEventListener('mousemove', (e) => {
  if (!tabDrag) return;
  if (!tabDrag.moved) {
    if (Math.abs(e.clientX - tabDrag.sx) < 5 && Math.abs(e.clientY - tabDrag.sy) < 5) return;
    tabDrag.moved = true;
    ghost = document.createElement('div');
    ghost.id = 'dragGhost';
    ghost.textContent = tabDrag.doc.name;
    document.body.appendChild(ghost);
  }
  ghost.style.left = (e.clientX + 10) + 'px';
  ghost.style.top = (e.clientY + 8) + 'px';
});
window.addEventListener('mouseup', async (e) => {
  if (!tabDrag || !tabDrag.moved) { tabDrag = null; return; }
  const { idx, id, doc } = tabDrag;
  tabDrag = null;
  if (ghost) { ghost.remove(); ghost = null; }
  const dpr = window.devicePixelRatio || 1;
  let target = null;
  try { target = await invoke('window_at', { x: e.screenX * dpr, y: e.screenY * dpr, exclude: currentLabel }); } catch (err) {}
  const cur = state.docs.findIndex(x => x.id === id);
  if (target && emitTo) {
    try { await emitTo(target, 'imd:adopt', doc); } catch (err) {}
    if (cur >= 0) closeDoc(cur);
  } else if (cur >= 0 && state.docs.length > 1 && outsideWindow(e)) {
    detach(cur);
  }
});

// stop webview navigating when a file is dropped
document.addEventListener('dragover', (e) => e.preventDefault());
document.addEventListener('drop', (e) => e.preventDefault());

// events
$('sourcePane').addEventListener('input', (e) => { setText(e.target.value); updateSnip(false); });
$('segPreview').onclick = () => { const d = activeDoc(); if (d) { d.tab = 'preview'; render(); } };
$('segSource').onclick = () => { const d = activeDoc(); if (d) { d.tab = 'source'; render(); } };
$('tocBtn').onclick = () => { const d = activeDoc(); if (d) { d.tocHidden = !d.tocHidden; renderToc(); } };
$('searchInput').addEventListener('input', (e) => { state.search.term = e.target.value; recomputeSearch(); });
$('nextBtn').onclick = () => { if (state.search.ranges.length) { state.search.idx = (state.search.idx + 1) % state.search.ranges.length; $('searchCount').textContent = `${state.search.idx + 1}/${state.search.ranges.length}`; applySearch(); } };
$('prevBtn').onclick = () => { if (state.search.ranges.length) { state.search.idx = (state.search.idx - 1 + state.search.ranges.length) % state.search.ranges.length; $('searchCount').textContent = `${state.search.idx + 1}/${state.search.ranges.length}`; applySearch(); } };
$('caseBtn').onclick = () => { state.search.case = !state.search.case; recomputeSearch(); };
$('replaceBtn').onclick = () => {
  const d = activeDoc(); if (!d || state.search.idx < 0) return;
  const at = state.search.ranges[state.search.idx];
  d.text = d.text.slice(0, at) + state.search.replace + d.text.slice(at + state.search.term.length);
  d.dirty = true; $('sourcePane').value = d.text; recomputeSearch(); renderPreview();
};
$('replaceAllBtn').onclick = () => {
  const d = activeDoc(); if (!d || !state.search.term) return;
  const re = new RegExp(state.search.term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), state.search.case ? 'g' : 'gi');
  d.text = d.text.replace(re, state.search.replace);
  d.dirty = true; $('sourcePane').value = d.text; recomputeSearch(); renderPreview();
};
$('searchClose').onclick = () => { state.search.visible = false; render(); };

document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 'f') { e.preventDefault(); state.search.visible = true; render(); $('searchInput').focus(); }
  else if ((e.metaKey || e.ctrlKey) && e.key === 's') { e.preventDefault(); saveActive(); }
  else if ((e.metaKey || e.ctrlKey) && e.key === 'o') { e.preventDefault(); openFile(); }
  else if ((e.metaKey || e.ctrlKey) && e.key === 'n') { e.preventDefault(); newDoc(false); }
  else if (e.key === 'Escape') { if (state.search.visible) { state.search.visible = false; render(); } }
});

// boot
loadL10n().then(async () => {
  await loadSnippets();
  if (listen) listen('imd:adopt', e => { if (e && e.payload) addDocRaw(e.payload); });
  if (listen) listen('imd:open-paths', e => {
    const paths = typeof e.payload === 'string' ? JSON.parse(e.payload) : e.payload;
    (paths || []).forEach(p => openPath(p));
  });
  let opened = false;
  if (currentLabel !== 'main') {
    let doc = null;
    try { doc = await invoke('take_pending', { key: 'label:' + currentLabel }); } catch (e) {}
    if (doc) { addDocRaw(doc); opened = true; }
  }
  if (!opened) {
    try {
      const paths = await invoke('startup_paths');
      if (Array.isArray(paths) && paths.length) { paths.forEach(openPath); opened = true; }
    } catch (e) {}
  }
  if (!opened) newDoc(false);
  render();
});

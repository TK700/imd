// imd Windows frontend (reuses shared/preview for rendering)
const { invoke } = window.__TAURI__?.core ?? { invoke: () => Promise.reject('no-tauri') };
const listen = window.__TAURI__?.event?.listen;

const state = {
  docs: [],            // {id,name,path,text,dirty,isTxt,tocHidden,tab:'preview'|'source'}
  active: 0,
  search: { term: '', replace: '', case: false, ranges: [], idx: -1, visible: false },
  l10n: {},
};

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
  const re = /^(#{1,6})\s+(.+?)\s*#*$/gm;
  const out = [];
  let m;
  while ((m = re.exec(text)) !== null) out.push({ level: m[1].length, title: m[2] });
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

function renderTabs() {
  const bar = $('tabbar');
  bar.innerHTML = '';
  state.docs.forEach((d, i) => {
    const el = document.createElement('div');
    el.className = 'tab' + (i === state.active ? ' active' : '');
    el.innerHTML = `<span>${d.name}${d.dirty ? ' •' : ''}</span><b>x</b>`;
    el.onclick = () => { state.active = i; render(); };
    el.querySelector('b').onclick = (e) => { e.stopPropagation(); closeDoc(i); };
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
  if (!d || d.tocHidden || d.isTxt) { toc.style.display = 'none'; return; }
  toc.style.display = '';
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
  const heads = parseHeadings(d.text);
  const idx = heads.indexOf(h);
  if (d.tab === 'preview') scrollToMark ? null : null; // noop
  // scroll preview heading
  const hs = document.querySelectorAll('#content h1,h2,h3,h4,h5,h6');
  if (hs[idx]) hs[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
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

// events
$('sourcePane').addEventListener('input', (e) => setText(e.target.value));
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
  if (listen) listen('imd:open-paths', e => {
    const paths = typeof e.payload === 'string' ? JSON.parse(e.payload) : e.payload;
    (paths || []).forEach(p => openPath(p));
  });
  try {
    const paths = await invoke('startup_paths');
    if (Array.isArray(paths) && paths.length) paths.forEach(openPath);
    else newDoc(false);
  } catch (e) { newDoc(false); }
  render();
});

marked.setOptions({ gfm: true, breaks: true });
marked.use({ extensions: [{
  name: 'imdHl',
  level: 'inline',
  start: function(src){ var i = src.indexOf('=='); return i === -1 ? undefined : i; },
  tokenizer: function(src){
    var m = /^==([^=\n]+)==/.exec(src);
    if (m) { return { type: 'imdHl', raw: m[0], tokens: this.lexer.inlineTokens(m[1]) }; }
  },
  renderer: function(tok){ return '<mark class="imd-mark">' + this.parser.parseInline(tok.tokens) + '</mark>'; }
}] });
function imdEsc(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function renderMd(md){
  var el=document.getElementById('content');
  try {
    md = md.replace(/\$\$([\s\S]+?)\$\$/g, function(m,c){ return '\n<div class="imd-math-block">'+imdEsc(c.trim())+'</div>\n'; });
    md = md.replace(/\$([^$\n]+)\$/g, function(m,c){ return '<span class="imd-math">'+imdEsc(c)+'</span>'; });
    var defs={}; var order=[];
    md = md.replace(/^\[\^([^\]]+)\]:\s*(.+)$/gm, function(m,id,txt){ defs[id]=txt; return ''; });
    md = md.replace(/\[\^([^\]]+)\]/g, function(m,id){
      if(!(id in defs)) return m;
      var i=order.indexOf(id); if(i===-1){ order.push(id); i=order.length-1; }
      return '<sup id="imd-fnref-'+i+'" class="imd-fnref"><a href="#imd-fn-'+i+'">['+(i+1)+']</a></sup>';
    });
    var html = marked.parse(md);
    if(order.length){
      var lis=order.map(function(id,i){ return '<li id="imd-fn-'+i+'">'+marked.parseInline(defs[id])+' <a href="#imd-fnref-'+i+'">↩</a></li>'; }).join('');
      html += '<section class="imd-footnotes"><hr><ol>'+lis+'</ol></section>';
    }
    el.innerHTML = html;
    enhanceTasks();
  } catch(e){ el.textContent = String(e); }
}
function enhanceTasks(){
  var idx = 0;
  document.querySelectorAll('#content li').forEach(function(li){
    var cb = li.querySelector('input[type="checkbox"]');
    if(!cb) return;
    li.classList.add('task-item');
    cb.disabled = false;
    if(cb.checked) li.classList.add('done');
    cb.setAttribute('data-task-index', idx);
    cb.onchange = function(){
      li.classList.toggle('done', cb.checked);
      window.webkit.messageHandlers.taskToggle.postMessage({ index: idx, checked: cb.checked });
    };
    idx++;
  });
}
function scrollToHeading(i){ var hs=document.querySelectorAll('h1,h2,h3,h4,h5,h6'); if(hs[i]){ hs[i].scrollIntoView({behavior:'smooth', block:'start'}); } }
function findOccurrences(text, term, cs){
  var res=[];
  var hay = cs ? text : text.toLowerCase();
  var needle = cs ? term : term.toLowerCase();
  if(!needle) return res;
  var i = hay.indexOf(needle);
  while(i !== -1){ res.push(i); i = hay.indexOf(needle, i + needle.length); }
  return res;
}
function clearMarks(){
  document.querySelectorAll('mark.imd-hl').forEach(function(m){
    var p=m.parentNode; p.replaceChild(document.createTextNode(m.textContent), m); p.normalize();
  });
}
function applyPreviewSearch(term, cs){
  clearMarks();
  window.__imdMarks=[];
  if(!term) return;
  var root=document.getElementById('content');
  var walker=document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  var nodes=[];
  while(walker.nextNode()) nodes.push(walker.currentNode);
  nodes.forEach(function(node){
    var text=node.nodeValue;
    var hits=findOccurrences(text, term, cs);
    if(!hits.length) return;
    var frag=document.createDocumentFragment();
    var last=0;
    hits.forEach(function(start){
      if(start>last) frag.appendChild(document.createTextNode(text.slice(last,start)));
      var mk=document.createElement('mark'); mk.className='imd-hl'; mk.textContent=text.substr(start, term.length);
      frag.appendChild(mk);
      last=start+term.length;
    });
    if(last<text.length) frag.appendChild(document.createTextNode(text.slice(last)));
    node.parentNode.replaceChild(frag,node);
  });
  window.__imdMarks=Array.prototype.slice.call(document.querySelectorAll('mark.imd-hl'));
}
function scrollToMark(i){
  var ms=window.__imdMarks||[];
  ms.forEach(function(m){ m.classList.remove('cur'); });
  if(ms[i]){ ms[i].classList.add('cur'); ms[i].scrollIntoView({block:'center',behavior:'smooth'}); }
  return ms.length;
}


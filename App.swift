import SwiftUI
import AppKit
import WebKit
import Combine
import UniformTypeIdentifiers

// MARK: - Model

struct Heading: Identifiable, Hashable {
    let id = UUID()
    let level: Int
    let title: String
    let sourceRange: NSRange
}

struct Block: Identifiable {
    let id: UUID
    let heading: Heading?
    let body: String
    init(heading: Heading) { self.id = heading.id; self.heading = heading; self.body = "" }
    init(body: String) { self.id = UUID(); self.heading = nil; self.body = body }
}

enum ActiveTab: String, Hashable { case preview = "预览", source = "源码" }

struct ScrollRequest: Equatable {
    let id = UUID()
    let headingID: UUID
}

struct SearchSel: Equatable {
    let id = UUID()
    let range: NSRange
}

struct CaretRequest: Equatable {
    let id = UUID()
    let location: Int
}

struct MDDoc: Identifiable {
    let id = UUID()
    var text: String
    var fileURL: URL?
    var dirty: Bool = false
    var isTxt: Bool = false
    var headings: [Heading] = []
    var blocks: [Block] = []
    var name: String { fileURL?.lastPathComponent ?? NSLocalizedString(isTxt ? "untitledTxt" : "untitledMd", comment: "") }
    var tocHidden: Bool = false
}

// MARK: - Multi-window globals

extension Notification.Name {
    static let imdOpenWindow = Notification.Name("imdOpenWindow")
}

final class DragState: ObservableObject {
    static let shared = DragState()
    @Published var docID: UUID? = nil
    @Published var fromWindow: Int? = nil
    var merged = false
}

enum AppGlobals {
    static var byWindow: [Int: EditorController] = [:]
    static var pendingDetach: MDDoc? = nil

    static func front() -> EditorController? {
        if let k = NSApp.keyWindow, let c = byWindow[k.windowNumber] { return c }
        return NSApp.windows.first { $0.isVisible && byWindow[$0.windowNumber] != nil }.flatMap { byWindow[$0.windowNumber] }
    }

    @MainActor
    static func openDetachedWindow() {
        let hc = NSHostingController(rootView: ContentView())
        let w = NSWindow(contentViewController: hc)
        w.title = "imd"
        w.setContentSize(NSSize(width: 900, height: 560))
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    static var pendingOpen: [URL] = []

    static func closeWindow(for c: EditorController) {
        guard let w = NSApp.windows.first(where: { byWindow[$0.windowNumber] === c }) else { return }
        byWindow = byWindow.filter { $0.value !== c }
        w.close()
    }

    static func cleanup() {
        DragState.shared.docID = nil
        DragState.shared.fromWindow = nil
        DragState.shared.merged = false
    }

    @discardableResult
    static func handleTabDrop(target: EditorController, onTabBar: Bool) -> Bool {
        let st = DragState.shared
        guard let id = st.docID, let from = st.fromWindow, let src = byWindow[from] else { return false }
        defer { cleanup() }
        if src === target {
            guard !onTabBar, src.docs.count > 1, let doc = src.removeDoc(id: id) else { return true }
            pendingDetach = doc
            NotificationCenter.default.post(name: .imdOpenWindow, object: src)
            return true
        }
        if let doc = src.removeDoc(id: id) {
            target.adopt(doc)
            if src.docs.isEmpty { closeWindow(for: src) }
        }
        return true
    }
}

struct WindowBinder: NSViewRepresentable {
    let controller: EditorController
    final class V: NSView {
        var controller: EditorController?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let w = window, let c = controller { AppGlobals.byWindow[w.windowNumber] = c }
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.controller = controller; return v }
    func updateNSView(_ v: V, context: Context) {
        v.controller = controller
        if let w = v.window { AppGlobals.byWindow[w.windowNumber] = controller }
    }
}

// MARK: - Controller

final class EditorController: ObservableObject {
    @Published var docs: [MDDoc] = []
    @Published var active: Int = 0
    @Published var recentFiles: [URL] = []
    @Published var scrollRequest: ScrollRequest? = nil
    @Published var showSearch = false
    @Published var searchText = ""
    @Published var replaceText = ""
    @Published var matchCase = false
    @Published var matchRanges: [NSRange] = []
    @Published var matchIndex = -1
    @Published var searchSelection: SearchSel? = nil
    @Published var caretRequest: CaretRequest? = nil
    @Published var lastReplaceCount = 0
    @Published var requestedTab: ActiveTab? = nil

    private let recentKey = "recentFiles"
    private var undoStacks: [UUID: [String]] = [:]
    private var redoStacks: [UUID: [String]] = [:]
    private var lastEditTime = Date.distantPast

    init() { loadRecent() }

    var activeDoc: MDDoc? {
        docs.indices.contains(active) ? docs[active] : nil
    }
    var activeText: String { activeDoc?.text ?? "" }
    var activeHeadings: [Heading] { activeDoc?.headings ?? [] }
    var activeBlocks: [Block] { activeDoc?.blocks ?? [] }

    // MARK: file ops

    func openDialog() {
        let panel = NSOpenPanel()
        panel.title = NSLocalizedString("openFilePanel", comment: "")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "markdown"), UTType(filenameExtension: "txt")].compactMap { $0 }
        if panel.runModal() == .OK {
            for url in panel.urls { open(url: url) }
        }
    }

    func open(url: URL) {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { NSSound.beep(); return }
        if let idx = docs.firstIndex(where: { $0.fileURL == url }) {
            docs[idx].text = s
            docs[idx].dirty = false
            undoStacks[docs[idx].id] = []
            redoStacks[docs[idx].id] = []
            active = idx
        } else {
            var d = MDDoc(text: s, fileURL: url)
            d.isTxt = url.pathExtension.lowercased() == "txt"
            let (h, b) = parseDocument(s)
            d.headings = h
            d.blocks = b
            docs.append(d)
            active = docs.count - 1
        }
        reparseActive()
        pushRecent(url)
    }

    func newDoc(asTxt: Bool) {
        var d = MDDoc(text: "", fileURL: nil)
        d.isTxt = asTxt
        let (h, b) = parseDocument("")
        d.headings = h
        d.blocks = b
        docs.append(d)
        active = docs.count - 1
        if !asTxt { requestedTab = .source }
    }

    func newDocDialog() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("newDoc", comment: "")
        alert.informativeText = NSLocalizedString("chooseType", comment: "")
        alert.addButton(withTitle: NSLocalizedString("markdown", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("plainTxt", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn: newDoc(asTxt: false)
        case .alertSecondButtonReturn: newDoc(asTxt: true)
        default: break
        }
    }

    func closeDoc(at idx: Int) {
        guard docs.indices.contains(idx) else { return }
        let id = docs[idx].id
        docs.remove(at: idx)
        undoStacks[id] = nil
        redoStacks[id] = nil
        if docs.isEmpty { active = 0 }
        else if active >= docs.count { active = docs.count - 1 }
        else if active > idx { active -= 1 }
    }

    @discardableResult
    func removeDoc(id: UUID) -> MDDoc? {
        guard let idx = docs.firstIndex(where: { $0.id == id }) else { return nil }
        let d = docs[idx]
        closeDoc(at: idx)
        return d
    }

    func adopt(_ doc: MDDoc) {
        if docs.contains(where: { $0.id == doc.id }) { return }
        docs.append(doc)
        active = docs.count - 1
        reparseActive()
    }

    func toggleToc() {
        guard docs.indices.contains(active) else { return }
        docs[active].tocHidden.toggle()
    }

    func selectTab(_ idx: Int) {
        if docs.indices.contains(idx) {
            active = idx
            recomputeMatches()
        }
    }

    func setText(_ s: String, newGroup: Bool = false) {
        guard docs.indices.contains(active) else { return }
        if docs[active].text == s { return }
        recordUndo(old: docs[active].text, new: s, newGroup: newGroup)
        commit(s)
    }

    private func commit(_ s: String) {
        docs[active].text = s
        docs[active].dirty = true
        let (h, b) = parseDocument(s)
        docs[active].headings = h
        docs[active].blocks = b
        recomputeMatches()
    }

    private func recordUndo(old: String, new: String, newGroup: Bool) {
        let id = docs[active].id
        var stack = undoStacks[id] ?? []
        let typing = abs((new as NSString).length - (old as NSString).length) <= 1
        let grouped = !newGroup && typing && !stack.isEmpty
            && Date().timeIntervalSince(lastEditTime) < 0.8
        if !grouped {
            stack.append(old)
            if stack.count > 200 { stack.removeFirst(stack.count - 200) }
            undoStacks[id] = stack
            redoStacks[id] = []
        }
        lastEditTime = Date()
    }

    var canUndo: Bool { activeDoc.map { !(undoStacks[$0.id] ?? []).isEmpty } ?? false }
    var canRedo: Bool { activeDoc.map { !(redoStacks[$0.id] ?? []).isEmpty } ?? false }

    func undo() {
        guard let id = activeDoc?.id, var stack = undoStacks[id], let prev = stack.popLast() else {
            NSSound.beep(); return
        }
        undoStacks[id] = stack
        var redo = redoStacks[id] ?? []
        redo.append(docs[active].text)
        redoStacks[id] = redo
        lastEditTime = .distantPast
        commit(prev)
    }

    func redo() {
        guard let id = activeDoc?.id, var stack = redoStacks[id], let next = stack.popLast() else {
            NSSound.beep(); return
        }
        redoStacks[id] = stack
        var undo = undoStacks[id] ?? []
        undo.append(docs[active].text)
        undoStacks[id] = undo
        lastEditTime = .distantPast
        let old = docs[active].text
        commit(next)
        caretRequest = CaretRequest(location: changedRegionEnd(old: old, new: next))
    }

    private func changedRegionEnd(old: String, new: String) -> Int {
        let o = Array(old.utf16), n = Array(new.utf16)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        return n.count - s
    }

    func reparseActive() {
        guard docs.indices.contains(active) else { return }
        let s = docs[active].text
        let (h, b) = parseDocument(s)
        docs[active].headings = h
        docs[active].blocks = b
        recomputeMatches()
    }

    func save() {
        guard let d = activeDoc else { return }
        if let url = d.fileURL {
            do {
                try d.text.write(to: url, atomically: true, encoding: .utf8)
                docs[active].dirty = false
                pushRecent(url)
            } catch { NSSound.beep() }
        } else {
            saveAs()
        }
    }

    func saveAs() {
        guard docs.indices.contains(active) else { return }
        let panel = NSSavePanel()
        panel.title = NSLocalizedString("saveAsPanel", comment: "")
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), UTType(filenameExtension: "txt")].compactMap { $0 }
        panel.nameFieldStringValue = activeDoc?.name ?? "未命名.md"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try docs[active].text.write(to: url, atomically: true, encoding: .utf8)
                docs[active].fileURL = url
                docs[active].isTxt = url.pathExtension.lowercased() == "txt"
                docs[active].dirty = false
                pushRecent(url)
            } catch { NSSound.beep() }
        }
    }

    func toggleTask(index: Int, checked: Bool) {
        var lines = activeText.components(separatedBy: "\n")
        var count = 0
        guard let re = try? NSRegularExpression(pattern: "^(\\s*[-*+]\\s+\\[)([ xX])(\\])") else { return }
        for i in lines.indices {
            let ns = lines[i] as NSString
            if let m = re.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) {
                if count == index {
                    lines[i] = ns.replacingCharacters(in: m.range(at: 2), with: checked ? "x" : " ")
                    setText(lines.joined(separator: "\n"))
                    return
                }
                count += 1
            }
        }
    }

    func renumberOrderedLists() {
        var lines = activeText.components(separatedBy: "\n")
        var counter = 0
        guard let re = try? NSRegularExpression(pattern: "^(\\s*)(\\d+)\\.\\s") else { return }
        for i in lines.indices {
            let ns = lines[i] as NSString
            if let m = re.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) {
                counter += 1
                let indent = ns.substring(with: m.range(at: 1))
                let rest = ns.substring(from: m.range.location + m.range.length)
                lines[i] = indent + "\(counter). " + rest
            } else {
                if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { counter = 0 }
            }
        }
        setText(lines.joined(separator: "\n"))
    }

    func jump(to heading: Heading) {
        scrollRequest = ScrollRequest(headingID: heading.id)
    }

    func headingByID(_ id: UUID) -> Heading? {
        activeHeadings.first { $0.id == id }
    }

    // MARK: search & replace

    func toggleSearch() {
        showSearch.toggle()
        if showSearch {
            recomputeMatches()
            selectCurrentMatch()
        }
    }

    func recomputeMatches() {
        matchRanges = []
        matchIndex = -1
        guard !searchText.isEmpty else { return }
        let hay = activeText as NSString
        let opts: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
        var loc = 0
        while loc < hay.length {
            let r = hay.range(of: searchText, options: opts, range: NSRange(location: loc, length: hay.length - loc))
            if r.location == NSNotFound { break }
            matchRanges.append(r)
            loc = r.location + max(r.length, 1)
        }
        if !matchRanges.isEmpty { matchIndex = 0 }
    }

    private func selectCurrentMatch() {
        guard matchIndex >= 0, matchIndex < matchRanges.count else { return }
        searchSelection = SearchSel(range: matchRanges[matchIndex])
    }

    func findNext() {
        guard !matchRanges.isEmpty else { return }
        matchIndex = (matchIndex + 1) % matchRanges.count
        selectCurrentMatch()
    }

    func findPrevious() {
        guard !matchRanges.isEmpty else { return }
        matchIndex = (matchIndex - 1 + matchRanges.count) % matchRanges.count
        selectCurrentMatch()
    }

    func replaceCurrent() {
        guard matchIndex >= 0, matchIndex < matchRanges.count else { return }
        let r = matchRanges[matchIndex]
        let ns = activeText as NSString
        setText(ns.replacingCharacters(in: r, with: replaceText), newGroup: true)
        searchSelection = SearchSel(range: NSRange(location: r.location, length: (replaceText as NSString).length))
    }

    func replaceAll() {
        guard !matchRanges.isEmpty else { return }
        let mutable = NSMutableString(string: activeText)
        for r in matchRanges.reversed() {
            mutable.replaceCharacters(in: r, with: replaceText)
        }
        lastReplaceCount = matchRanges.count
        setText(mutable as String, newGroup: true)
    }

    // MARK: recent

    func loadRecent() {
        recentFiles = (UserDefaults.standard.array(forKey: recentKey) as? [String] ?? [])
            .compactMap { URL(string: $0) }
    }

    func pushRecent(_ url: URL) {
        let s = url.absoluteString
        var list = recentFiles.map { $0.absoluteString }.filter { $0 != s }
        list.insert(s, at: 0)
        if list.count > 12 { list = Array(list.prefix(12)) }
        UserDefaults.standard.set(list, forKey: recentKey)
        loadRecent()
    }

    func clearRecent() {
        UserDefaults.standard.removeObject(forKey: recentKey)
        recentFiles = []
    }
}

// MARK: - Markdown parsing

private let headingRegex: NSRegularExpression = {
    do { return try NSRegularExpression(pattern: "^(#{1,6})\\s+(.+?)\\s*#*$") }
    catch { fatalError("invalid regex") }
}()

private func matchHeading(_ line: String) -> (level: Int, title: String)? {
    let ns = line as NSString
    guard let m = headingRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
        return nil
    }
    let level = ns.substring(with: m.range(at: 1)).count
    let title = ns.substring(with: m.range(at: 2))
    return (level, title)
}

func parseDocument(_ src: String) -> (headings: [Heading], blocks: [Block]) {
    var heads: [Heading] = []
    var blocks: [Block] = []
    var body = ""
    var offset = 0
    var inFence = false

    func flushBody() {
        if !body.isEmpty { blocks.append(Block(body: body)); body = "" }
    }

    src.enumerateLines { line, _ in
        let ns = line as NSString
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            inFence.toggle()
            body += line + "\n"
            offset += ns.length + 1
            return
        }
        if !inFence, let h = matchHeading(line) {
            flushBody()
            let heading = Heading(level: h.level, title: h.title, sourceRange: NSRange(location: offset, length: ns.length))
            heads.append(heading)
            blocks.append(Block(heading: heading))
        } else {
            body += line + "\n"
        }
        offset += ns.length + 1
    }
    flushBody()
    return (heads, blocks)
}

// MARK: - Preview (WKWebView + marked.js)

private let previewCSS = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: #ffffff; color: #1d1d1f;
  font: 16px/1.65 -apple-system, "Helvetica Neue", "PingFang SC", sans-serif; }
#content { width: 90%; max-width: 1100px; margin: 0 auto; padding: 28px 0 80px; }
h1 { font-size: 30px; font-weight: 700; margin: 20px 0 10px; line-height: 1.25; }
h2 { font-size: 26px; font-weight: 700; margin: 22px 0 10px; line-height: 1.25; }
h3 { font-size: 22px; font-weight: 600; margin: 20px 0 8px; }
h4 { font-size: 19px; font-weight: 600; margin: 18px 0 6px; }
h5 { font-size: 17px; font-weight: 600; margin: 16px 0 6px; }
h6 { font-size: 15px; font-weight: 600; margin: 14px 0 6px; color: #6e6e73; }
p { margin: 0 0 12px; }
a { color: #0066cc; text-decoration: none; }
a:hover { text-decoration: underline; }
ul, ol { margin: 0 0 12px; padding-left: 26px; }
li { margin: 2px 0; }
hr { border: none; border-top: 1px solid #d2d2d7; margin: 18px 0; }
img { max-width: 100%; height: auto; }
code { font-family: "SF Mono", ui-monospace, Menlo, monospace; font-size: 14px;
  background: rgba(0,0,0,0.06); padding: 2px 5px; border-radius: 5px; }
pre { background: #f5f5f7; padding: 14px 16px; border-radius: 10px; overflow: auto; margin: 0 0 14px; }
pre code { background: none; padding: 0; font-size: 13px; line-height: 1.5; }
blockquote { border-left: 4px solid #d2d2d7; margin: 0 0 12px; padding: 6px 16px;
  color: #4a4a4f; background: rgba(0,0,0,0.03); border-radius: 0 6px 6px 0; }
mark.imd-hl { background: #ffd60a; color: #000; border-radius: 3px; padding: 0 1px; }
mark.imd-hl.cur { background: #ff3b30; color: #fff; }
#content ul li.task-item { list-style: none; margin-left: -22px; }
#content ul li.task-item input[type="checkbox"] {
  appearance: none; -webkit-appearance: none;
  width: 16px; height: 16px; margin-right: 8px; vertical-align: -3px;
  border: 1.5px solid #9a9aa0; border-radius: 4px; background: transparent;
  cursor: pointer; position: relative; transition: all .15s ease;
}
#content ul li.task-item input[type="checkbox"]:hover { border-color: #007aff; }
#content ul li.task-item input[type="checkbox"]:checked { background: #007aff; border-color: #007aff; }
#content ul li.task-item input[type="checkbox"]:checked::after {
  content: ""; position: absolute; left: 4.5px; top: 1.5px;
  width: 4px; height: 8px; border: solid #fff; border-width: 0 2px 2px 0;
  transform: rotate(45deg);
}
#content ul li.task-item.done { text-decoration: line-through; opacity: 0.55; }
mark.imd-mark { background: #ffd60a; color: #000; border-radius: 3px; padding: 0 2px; }
.imd-math { font-family: "Times New Roman", Georgia, serif; font-style: italic; }
.imd-math-block { text-align: center; margin: 14px 0; padding: 10px; border-radius: 8px;
  font-family: "Times New Roman", Georgia, serif; font-style: italic; font-size: 17px;
  background: rgba(0,0,0,0.03); }
.imd-footnotes { font-size: 13px; color: #6e6e73; }
.imd-footnotes hr { margin: 24px 0 8px; }
.imd-footnotes ol { padding-left: 20px; }
sup.imd-fnref { font-size: 11px; }
table { border-collapse: collapse; width: 100%; margin: 0 0 14px; font-size: 14px; display: block; overflow-x: auto; }
th, td { border: 1px solid #d2d2d7; padding: 7px 12px; text-align: left; }
th { background: rgba(0,0,0,0.04); font-weight: 600; }
@media (prefers-color-scheme: dark) {
  html { background: #1d1d1f; }
  body { background: #1d1d1f; color: #e8e8ea; }
  a { color: #4ea2ff; }
  h6 { color: #8e8e93; }
  hr { border-color: #3a3a3c; }
  code { background: rgba(255,255,255,0.10); }
  pre { background: #161617; }
  pre code { color: #e8e8ea; }
  blockquote { border-color: #3a3a3c; color: #b0b0b5; background: rgba(255,255,255,0.04); }
  .imd-math-block { background: rgba(255,255,255,0.05); }
  .imd-footnotes { color: #98989d; }
  th, td { border-color: #3a3a3c; }
  th { background: rgba(255,255,255,0.06); }
}
"""

private func shellHTML() -> String {
    var markedSrc = "/* marked missing */"
    if let url = Bundle.main.url(forResource: "marked", withExtension: "min.js"),
       let src = try? String(contentsOf: url, encoding: .utf8) {
        markedSrc = src
    }
    return """
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>\(previewCSS)</style>
<script>\(markedSrc)</script>
</head><body><div id="content"></div>
<script>
marked.setOptions({ gfm: true, breaks: true });
marked.use({ extensions: [{
  name: 'imdHl',
  level: 'inline',
  start: function(src){ var i = src.indexOf('=='); return i === -1 ? undefined : i; },
  tokenizer: function(src){
    var m = /^==([^=\\n]+)==/.exec(src);
    if (m) { return { type: 'imdHl', raw: m[0], tokens: this.lexer.inlineTokens(m[1]) }; }
  },
  renderer: function(tok){ return '<mark class="imd-mark">' + this.parser.parseInline(tok.tokens) + '</mark>'; }
}] });
function imdEsc(s){ return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
function renderMd(md){
  var el=document.getElementById('content');
  try {
    md = md.replace(/\\$\\$([\\s\\S]+?)\\$\\$/g, function(m,c){ return '\\n<div class="imd-math-block">'+imdEsc(c.trim())+'</div>\\n'; });
    md = md.replace(/\\$([^$\\n]+)\\$/g, function(m,c){ return '<span class="imd-math">'+imdEsc(c)+'</span>'; });
    var defs={}; var order=[];
    md = md.replace(/^\\[\\^([^\\]]+)\\]:\\s*(.+)$/gm, function(m,id,txt){ defs[id]=txt; return ''; });
    md = md.replace(/\\[\\^([^\\]]+)\\]/g, function(m,id){
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
</script>
</body></html>
"""
}

private func jsString(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s], options: [])) ?? Data()
    var raw = String(data: data, encoding: .utf8) ?? "[\"\"]"
    raw.removeFirst()
    raw.removeLast()
    return raw
}

struct PreviewView: NSViewRepresentable {
    @EnvironmentObject var controller: EditorController
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "taskToggle")
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.unregisterDraggedTypes()
        web.navigationDelegate = context.coordinator
        context.coordinator.webView = web
        web.loadHTMLString(shellHTML(), baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        if c.ready {
            var needApply = false
            if c.lastText != text {
                c.lastText = text
                web.evaluateJavaScript("renderMd(\(jsString(text)))")
                needApply = true
            }
            let term = controller.showSearch ? controller.searchText : ""
            if c.lastTerm != term || c.lastCase != controller.matchCase || c.lastShow != controller.showSearch {
                needApply = true
            }
            c.lastTerm = term
            c.lastCase = controller.matchCase
            c.lastShow = controller.showSearch
            if needApply {
                web.evaluateJavaScript("applyPreviewSearch(\(jsString(term)),\(controller.matchCase ? "true" : "false"))")
                web.evaluateJavaScript("scrollToMark(\(controller.matchIndex))")
            }
            if let sel = controller.searchSelection, c.lastScrollID != sel.id {
                c.lastScrollID = sel.id
                web.evaluateJavaScript("scrollToMark(\(controller.matchIndex))")
            }
            if let req = controller.scrollRequest, c.lastTocScrollID != req.id {
                c.lastTocScrollID = req.id
                if let idx = controller.activeHeadings.firstIndex(where: { $0.id == req.headingID }) {
                    web.evaluateJavaScript("scrollToHeading(\(idx))")
                }
            }
        } else {
            c.pendingText = text
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let controller: EditorController
        weak var webView: WKWebView?
        var ready = false
        var pendingText: String? = nil
        var lastText: String = ""
        var lastScrollID: UUID? = nil
        var lastTocScrollID: UUID? = nil
        var lastTerm: String? = nil
        var lastCase: Bool? = nil
        var lastShow: Bool? = nil

        init(controller: EditorController) { self.controller = controller }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let p = pendingText {
                webView?.evaluateJavaScript("renderMd(\(jsString(p)))")
                lastText = p
                pendingText = nil
            }
        }

        func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard msg.name == "taskToggle",
                  let body = msg.body as? [String: Any],
                  let idx = body["index"] as? Int,
                  let checked = body["checked"] as? Bool else { return }
            controller.toggleTask(index: idx, checked: checked)
        }
    }
}

// MARK: - Source editor

final class NoUndoTextView: NSTextView {
    override var undoManager: UndoManager? { nil }

    override var rangeForUserCompletion: NSRange {
        let caret = selectedRange().location
        let ns = string as NSString
        let r = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let start = r.location == NSNotFound ? 0 : r.location + 1
        return NSRange(location: start, length: caret - start)
    }
}

private let mdSnippets: [(key: String, value: String, desc: String)] = [
    ("#", "# ", "snip.h1"),
    ("##", "## ", "snip.h2"),
    ("###", "### ", "snip.h3"),
    ("####", "#### ", "snip.h4"),
    ("#####", "##### ", "snip.h5"),
    ("######", "###### ", "snip.h6"),
    (">", "> ", "snip.quote"),
    ("-", "- ", "snip.ul"),
    ("- [", "- [ ] ", "snip.task"),
    ("1.", "1. ", "snip.ol"),
    ("[", "[文本](url)", "snip.link"),
    ("![", "![描述](url)", "snip.image"),
    ("`", "`代码`", "snip.code"),
    ("```", "```swift\n\n```\n", "snip.codeblock"),
    ("**", "**粗体**", "snip.bold"),
    ("*", "*斜体*", "snip.italic"),
    ("~~", "~~删除线~~", "snip.strike"),
    ("==", "==高亮==", "snip.mark"),
    ("[^", "[^1]", "snip.footnote"),
    ("$$", "$$\n公式\n$$\n", "snip.mathblock"),
    ("$", "$公式$", "snip.math"),
    ("|", "| 列1 | 列2 | 列3 |\n| --- | --- | --- |\n|  |  |  |\n", "snip.table"),
    ("---", "---\n", "snip.hr"),
]

// MARK: - Snippet panel (non-blocking)

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class SnippetPanel: NSPanel {
    private let host = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let container = FlippedView()
    var onSelect: ((Int) -> Void)?
    private var panelWidth: CGFloat = 360
    private let rowH: CGFloat = 26
    private let maxVisible: CGFloat = 320

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        host.material = .menu
        host.state = .active
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = container
        host.addSubview(scroll)
        contentView = host
    }
    required init?(coder: NSCoder) { fatalError() }

    func scrollBy(_ dy: CGFloat) {
        let clip = scroll.contentView
        var o = clip.bounds.origin
        let maxY = max(0, container.bounds.height - clip.bounds.height)
        o.y = min(max(o.y - dy, 0), maxY)
        clip.setBoundsOrigin(o)
    }

    private var selected = 0
    private var rowButtons: [NSButton] = []

    override func sendEvent(_ e: NSEvent) {
        if e.type == .scrollWheel { scroll.scrollWheel(with: e); return }
        super.sendEvent(e)
    }

    private func applyHighlight() {
        let hi = selected
        for (i, b) in rowButtons.enumerated() {
            b.wantsLayer = true
            b.layer?.backgroundColor = (i == hi)
                ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
                : nil
        }
        scrollToSelected()
    }
    private func scrollToSelected() {
        guard selected < rowButtons.count else { return }
        let rowRect = NSRect(x: 0, y: 6 + CGFloat(selected) * rowH, width: panelWidth, height: rowH)
        scroll.contentView.scrollToVisible(rowRect)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    func selectNext() { guard !rowButtons.isEmpty else { return }; selected = (selected + 1) % rowButtons.count; applyHighlight() }
    func selectPrev() { guard !rowButtons.isEmpty else { return }; selected = (selected - 1 + rowButtons.count) % rowButtons.count; applyHighlight() }
    func insertCurrent() { onSelect?(selected) }

    func show(candidates: [(sym: String, desc: String)], at screenPoint: NSPoint, select: @escaping (Int) -> Void) {
        onSelect = select
        selected = 0
        container.subviews.forEach { $0.removeFromSuperview() }
        rowButtons = []

        // 量最宽行, 面板宽 = 内容宽 * 1.3, 夹在 [220, 屏宽*0.8]
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        let sys = NSFont.systemFont(ofSize: 12)
        var maxW: CGFloat = 0
        for c in candidates {
            let symW = (c.sym.replacingOccurrences(of: "\n", with: "⏎") as NSString).size(withAttributes: [.font: mono]).width
            let descW = (("   " + c.desc) as NSString).size(withAttributes: [.font: sys]).width
            maxW = max(maxW, symW + descW)
        }
        let screenW = NSScreen.main?.visibleFrame.width ?? 800
        panelWidth = min(max(maxW * 1.3 + 24, 220), screenW * 0.8)

        let totalH = CGFloat(candidates.count) * rowH + 12
        let visibleH = min(totalH, maxVisible)
        container.frame = NSRect(x: 0, y: 0, width: panelWidth, height: totalH)
        scroll.frame = NSRect(x: 0, y: 0, width: panelWidth, height: visibleH)
        for (i, c) in candidates.enumerated() {
            let b = NSButton()
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.alignment = .left
            b.tag = i
            b.target = self
            b.action = #selector(rowClick(_:))
            b.frame = NSRect(x: 6, y: 6 + CGFloat(i) * rowH, width: panelWidth - 20, height: rowH)
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: c.sym.replacingOccurrences(of: "\n", with: "⏎"),
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
            attr.append(NSAttributedString(string: "   " + c.desc,
                attributes: [.font: sys, .foregroundColor: NSColor.secondaryLabelColor]))
            b.attributedTitle = attr
            container.addSubview(b)
            rowButtons.append(b)
        }
        applyHighlight()
        var x = screenPoint.x
        if let vf = NSScreen.main?.visibleFrame, x + panelWidth > vf.maxX { x = vf.maxX - panelWidth }
        setFrame(NSRect(x: x, y: screenPoint.y - visibleH, width: panelWidth, height: visibleH), display: true)
        orderFront(nil)
    }

    @objc private func rowClick(_ sender: NSButton) { onSelect?(sender.tag) }
    func hide() { orderOut(nil) }
}

struct SourceEditor: NSViewRepresentable {
    @Binding var text: String
    @EnvironmentObject var controller: EditorController
    var monospaced: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, text: $text, md: monospaced) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NoUndoTextView()
        tv.isEditable = true
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.textColor = NSColor.textColor
        tv.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
            : NSFont.systemFont(ofSize: 15)
        tv.autoresizingMask = [.width]
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.size = NSSize(width: 0, height: 0)
        tv.insertionPointColor = NSColor.controlAccentColor
        tv.usesFindBar = false
        tv.unregisterDraggedTypes()
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        tv.delegate = context.coordinator
        context.coordinator.textView = tv
        tv.string = text
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        let composing = tv.hasMarkedText()
        if !composing, tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            let len = (text as NSString).length
            let loc = min(sel.location, len)
            tv.setSelectedRange(NSRange(location: loc, length: min(sel.length, len - loc)))
            context.coordinator.panel.hide()
        }
        if let req = controller.scrollRequest,
           context.coordinator.lastScrollID != req.id,
           let h = controller.headingByID(req.headingID) {
            context.coordinator.lastScrollID = req.id
            scrollToHeadingTop(tv, range: h.sourceRange)
        }
        if let sel = controller.searchSelection,
           context.coordinator.lastSearchID != sel.id {
            context.coordinator.lastSearchID = sel.id
            tv.setSelectedRange(NSRange(location: sel.range.location, length: 0))
            tv.scrollRangeToVisible(sel.range)
        }
        if let req = controller.caretRequest,
           context.coordinator.lastCaretID != req.id {
            context.coordinator.lastCaretID = req.id
            let loc = min(req.location, (tv.string as NSString).length)
            tv.setSelectedRange(NSRange(location: loc, length: 0))
            tv.scrollRangeToVisible(NSRange(location: loc, length: 0))
        }
        context.coordinator.refreshHighlights()
    }

    private func scrollToHeadingTop(_ tv: NSTextView, range: NSRange) {
        guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
        guard let scroll = tv.enclosingScrollView else {
            tv.scrollRangeToVisible(range)
            return
        }
        let pad: CGFloat = 8
        let originY = max(0, rect.minY - pad)
        let visible = NSRect(x: 0, y: originY, width: scroll.bounds.width, height: scroll.bounds.height)
        _ = tv.scrollToVisible(visible)
        tv.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: EditorController
        var binding: Binding<String>
        let md: Bool
        weak var textView: NSTextView?
        var lastScrollID: UUID?
        var lastSearchID: UUID?
        var lastCaretID: UUID?
        var lastHL: [NSRange] = []
        let panel = SnippetPanel()
        private var mouseMonitor: Any?
        private var bag = Set<AnyCancellable>()

        init(controller: EditorController, text: Binding<String>, md: Bool) {
            self.controller = controller
            self.binding = text
            self.md = md
            super.init()
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
                if let p = self?.panel, p.isVisible, !p.frame.contains(NSEvent.mouseLocation) {
                    p.hide()
                }
                return e
            }
            controller.$matchRanges.sink { [weak self] _ in self?.refreshHighlights() }.store(in: &bag)
            controller.$matchIndex.sink { [weak self] _ in self?.refreshHighlights() }.store(in: &bag)
            controller.$showSearch.sink { [weak self] _ in self?.refreshHighlights() }.store(in: &bag)
        }

        deinit {
            if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        }

        func refreshHighlights() {
            guard let tv = textView, let ts = tv.textStorage else { return }
            guard !tv.hasMarkedText() else { return }
            let full = NSRange(location: 0, length: ts.length)
            for r in lastHL {
                let loc = max(0, min(r.location, full.length))
                let len = max(0, min(r.length, full.length - loc))
                guard len > 0 else { continue }
                let cr = NSRange(location: loc, length: len)
                ts.removeAttribute(.backgroundColor, range: cr)
                ts.removeAttribute(.foregroundColor, range: cr)
            }
            lastHL = []
            guard controller.showSearch, !controller.matchRanges.isEmpty else { return }
            let otherBG = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.04, alpha: 1)
            let curBG = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
            var applied: [NSRange] = []
            for (i, r) in controller.matchRanges.enumerated() {
                guard r.location >= 0, r.location + r.length <= ts.length else { continue }
                let isCurrent = i == controller.matchIndex
                ts.addAttribute(.backgroundColor, value: isCurrent ? curBG : otherBG, range: r)
                ts.addAttribute(.foregroundColor, value: isCurrent ? NSColor.white : NSColor.black, range: r)
                applied.append(r)
            }
            lastHL = applied
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            guard !tv.hasMarkedText() else { return }
            let new = tv.string
            if new != binding.wrappedValue {
                binding.wrappedValue = new
            }
            updateSnippetPanel(tv)
        }

        // MARK: snippet panel

        private func partialBeforeCaret(_ tv: NSTextView) -> (text: String, range: NSRange)? {
            let sel = tv.selectedRange()
            guard sel.length == 0 else { return nil }
            let ns = tv.string as NSString
            var loc = sel.location
            var count = 0
            while loc > 0, count < 6 {
                if ns.substring(with: NSRange(location: loc - 1, length: 1)) == "\n" { break }
                loc -= 1
                count += 1
            }
            let range = NSRange(location: loc, length: sel.location - loc)
            guard range.length > 0 else { return nil }
            return (ns.substring(with: range), range)
        }

        func updateSnippetPanel(_ tv: NSTextView, forceAll: Bool = false) {
            guard md, !tv.hasMarkedText() else { panel.hide(); return }
            var cands: [(key: String, value: String, desc: String)] = []
            var replaceRange: NSRange? = nil
            if let p = partialBeforeCaret(tv) {
                replaceRange = p.range
                if ["/", "?", "？"].contains(p.text) {
                    cands = mdSnippets
                } else {
                    cands = mdSnippets.filter { $0.key.hasPrefix(p.text) }
                }
            } else if forceAll {
                cands = mdSnippets
                replaceRange = NSRange(location: tv.selectedRange().location, length: 0)
            } else {
                panel.hide(); return
            }
            guard !cands.isEmpty, let range = replaceRange else { panel.hide(); return }
            let rect = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            let rows = cands.map { (sym: $0.key, desc: NSLocalizedString($0.desc, comment: "")) }
            panel.show(candidates: rows, at: NSPoint(x: rect.minX, y: rect.minY)) { [weak self, weak tv] idx in
                guard let self, let tv, idx < cands.count else { return }
                tv.insertText(cands[idx].value, replacementRange: range)
                self.panel.hide()
            }
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSTextView.complete(_:)) {
                updateSnippetPanel(tv, forceAll: true)
                return true
            }
            if panel.isVisible {
                if sel == #selector(NSResponder.moveDown(_:)) { panel.selectNext(); return true }
                if sel == #selector(NSResponder.moveUp(_:)) { panel.selectPrev(); return true }
                if sel == #selector(NSResponder.insertNewline(_:)) { panel.insertCurrent(); return true }
                if sel == #selector(NSResponder.cancelOperation(_:)) { panel.hide(); return true }
            }
            return false
        }
    }
}

// MARK: - TOC

struct TocView: View {
    @EnvironmentObject var controller: EditorController

    var body: some View {
        List {
            ForEach(controller.activeHeadings) { h in
                tocRow(h)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func tocRow(_ h: Heading) -> some View {
        Button {
            controller.jump(to: h)
        } label: {
            Text(h.title)
                .font(rowFont(h.level))
                .lineLimit(1)
                .foregroundColor(.primary)
                .padding(.leading, CGFloat((h.level - 1) * 12))
        }
        .buttonStyle(.plain)
    }

    private func rowFont(_ level: Int) -> Font {
        let size = CGFloat(max(11, 16 - (level - 1)))
        return .system(size: size, weight: level <= 2 ? .semibold : .regular)
    }
}

// MARK: - Tab bar

struct TabBar: View {
    @EnvironmentObject var controller: EditorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(controller.docs.enumerated()), id: \.element.id) { idx, doc in
                    tabItem(idx: idx, doc: doc)
                }
                Button { controller.newDocDialog() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 30)
                }
                .buttonStyle(.plain)
                .help("new")
            }
        }
        .frame(height: 30)
        .background(Color(NSColor.windowBackgroundColor))
        .onDrop(of: [.text], isTargeted: nil) { _ in
            AppGlobals.handleTabDrop(target: controller, onTabBar: true)
        }
    }

    @ViewBuilder
    private func tabItem(idx: Int, doc: MDDoc) -> some View {
        let isActive = idx == controller.active
        HStack(spacing: 6) {
            Text(doc.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isActive ? .primary : .secondary)
            if doc.dirty {
                Circle().fill(Color.secondary).frame(width: 5, height: 5)
            }
            Button {
                controller.closeDoc(at: idx)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("closeTab")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(isActive ? Color(NSColor.textBackgroundColor) : Color.clear)
        .overlay(alignment: .bottom) {
            if isActive { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.selectTab(idx) }
        .onDrag {
            DragState.shared.docID = doc.id
            DragState.shared.fromWindow = NSApp.keyWindow?.windowNumber
            DragState.shared.merged = false
            return NSItemProvider(object: doc.id.uuidString as NSString)
        }
        .contextMenu {
            Button("close") { controller.closeDoc(at: idx) }
            Button("save") { controller.selectTab(idx); controller.save() }
        }
    }
}

// MARK: - Search bar

struct SearchBar: View {
    @EnvironmentObject var controller: EditorController
    @FocusState private var searchFocused: Bool

    private var hasMatch: Bool { !controller.matchRanges.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)

            TextField("searchPlaceholder", text: $controller.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 170)
                .focused($searchFocused)
                .onSubmit { controller.findNext() }

            Text(countText)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 52)

            Button { controller.findPrevious() } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(!hasMatch).help("prevMatch")
            Button { controller.findNext() } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(!hasMatch).help("nextMatch")

            Divider().frame(height: 16)

            TextField("replacePlaceholder", text: $controller.replaceText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            Button("replace") { controller.replaceCurrent() }
                .disabled(!hasMatch)
            Button("replaceAll") { controller.replaceAll() }
                .disabled(!hasMatch)

            Button { controller.matchCase.toggle() } label: {
                Image(systemName: controller.matchCase ? "textformat.alt" : "textformat")
                    .foregroundColor(controller.matchCase ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("matchCase")

            Spacer()

            if controller.lastReplaceCount > 0 {
                Text(String(format: NSLocalizedString("replaceDone", comment: ""), controller.lastReplaceCount))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }

            Button { controller.showSearch = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("closeSearch")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { searchFocused = true }
        .onChange(of: controller.searchText) { _ in controller.recomputeMatches() }
        .onChange(of: controller.matchCase) { _ in controller.recomputeMatches() }
    }

    private var countText: String {
        if controller.searchText.isEmpty { return "" }
        if controller.matchRanges.isEmpty {
            return String(format: NSLocalizedString("matchCount", comment: ""), 0)
        }
        return "\(controller.matchIndex + 1)/\(controller.matchRanges.count)"
    }
}

// MARK: - Content

struct ContentView: View {
    @StateObject private var controller = EditorController()
    @ObservedObject private var dragState = DragState.shared
    @State private var tab: ActiveTab = .preview
    @State private var dragOver = false


    private var textBinding: Binding<String> {
        Binding(
            get: { controller.activeText },
            set: { controller.setText($0) }
        )
    }

    @ViewBuilder
    private var contentRegion: some View {
        if controller.docs.isEmpty {
            emptyState
        } else if controller.activeDoc?.isTxt == true {
            txtLayout
        } else {
            mdLayout
        }
    }

    @ViewBuilder
    private var tabDragOverlay: some View {
        if dragState.docID != nil {
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    AppGlobals.handleTabDrop(target: controller, onTabBar: false)
                }
        }
    }

    @ViewBuilder
    private var txtLayout: some View {
        VStack(spacing: 0) {
            if controller.showSearch {
                SearchBar()
                Divider()
            }
            SourceEditor(text: textBinding, monospaced: false)
        }
    }

    private var mdLayout: some View {
        HSplitView {
            TocView()
                .frame(
                    minWidth: controller.activeDoc?.tocHidden == true ? 0 : 200,
                    idealWidth: controller.activeDoc?.tocHidden == true ? 0 : 260,
                    maxWidth: controller.activeDoc?.tocHidden == true ? 0 : 420
                )
                .opacity(controller.activeDoc?.tocHidden == true ? 0 : 1)
                .disabled(controller.activeDoc?.tocHidden == true)

            VStack(spacing: 0) {
                ZStack {
                    Picker("", selection: $tab) {
                        Text("preview").tag(ActiveTab.preview)
                        Text("source").tag(ActiveTab.source)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)

                    HStack {
                        Button { controller.toggleToc() } label: {
                            Image(systemName: controller.activeDoc?.tocHidden == true ? "sidebar.leading" : "sidebar.left")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("toggleToc")
                        Spacer()
                    }
                }
                .padding(8)

                if controller.showSearch {
                    SearchBar()
                    Divider()
                }

                Divider()

                switch tab {
                case .preview: PreviewView(text: controller.activeText)
                case .source: SourceEditor(text: textBinding, monospaced: true)
                }
            }
            .frame(minWidth: 480)
        }
        .background(SplitStyleApplier())
    }

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Divider()
            contentRegion
                .overlay(tabDragOverlay)
        }
        .environmentObject(controller)
        .background(dragOver ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            handleDrop(providers)
        }
        .background(WindowBinder(controller: controller))
        .onAppear {
            DispatchQueue.main.async {
                if let d = AppGlobals.pendingDetach {
                    controller.adopt(d)
                    AppGlobals.pendingDetach = nil
                }
                if controller.docs.isEmpty, !AppGlobals.pendingOpen.isEmpty {
                    AppGlobals.pendingOpen.forEach { controller.open(url: $0) }
                    AppGlobals.pendingOpen = []
                }
            }
        }
        .onDisappear {
            AppGlobals.byWindow = AppGlobals.byWindow.filter { $0.value !== controller }
        }
        .onReceive(NotificationCenter.default.publisher(for: .imdOpenWindow)) { note in
            if note.object as? EditorController === controller {
                AppGlobals.openDetachedWindow()
            }
        }
        .onOpenURL { url in
            let u = url.isFileURL ? url : URL(fileURLWithPath: url.path)
            guard ["md", "markdown", "mdown", "mkd", "txt"].contains(u.pathExtension.lowercased()) else { return }
            let target = AppGlobals.front() ?? controller
            target.open(url: u)
            if target !== controller && controller.docs.isEmpty {
                AppGlobals.closeWindow(for: controller)
            }
        }
        .onChange(of: controller.requestedTab) { req in
            if let req = req {
                tab = req
                controller.requestedTab = nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Text("emptyHint")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        if providers.isEmpty { return false }
        var handled = false
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    guard let url = url as? URL else { return }
                    let u = url.isFileURL ? url : URL(fileURLWithPath: url.path)
                    if ["md", "markdown", "mdown", "mkd", "txt"].contains(u.pathExtension.lowercased()) {
                        controller.open(url: u)
                    }
                }
            }
        }
        return handled
    }
}

// MARK: - App

struct SplitStyleApplier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window, let sv = findSplit(w.contentView) else { return }
            sv.dividerStyle = .paneSplitter
        }
    }
    private func findSplit(_ v: NSView?) -> NSSplitView? {
        guard let v = v else { return nil }
        if let sv = v as? NSSplitView { return sv }
        for sub in v.subviews { if let r = findSplit(sub) { return r } }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    func application(_ application: NSApplication, open urls: [URL]) {
        let md = urls.filter { ["md", "markdown", "mdown", "mkd", "txt"].contains($0.pathExtension.lowercased()) }
        guard !md.isEmpty else { return }
        if let c = AppGlobals.front() {
            md.forEach { c.open(url: $0) }
            NSApp.windows.first { AppGlobals.byWindow[$0.windowNumber] === c }?.makeKeyAndOrderFront(nil)
        } else {
            AppGlobals.pendingOpen += md
        }
    }
}

@main
struct MDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Window("imd", id: "main") {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("new") { AppGlobals.front()?.newDocDialog() }.keyboardShortcut("n", modifiers: .command)
                Button("open") { AppGlobals.front()?.openDialog() }.keyboardShortcut("o", modifiers: .command)
                Divider()
                Menu("openRecent") {
                    let rec = AppGlobals.front()?.recentFiles ?? []
                    if rec.isEmpty {
                        Text("none").foregroundStyle(.secondary)
                    } else {
                        ForEach(rec, id: \.self) { url in
                            Button(url.lastPathComponent) { AppGlobals.front()?.open(url: url) }
                        }
                        Divider()
                        Button("clearRecent") { AppGlobals.front()?.clearRecent() }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                Button("save") { AppGlobals.front()?.save() }.keyboardShortcut("s", modifiers: .command)
                Button("saveAs") { AppGlobals.front()?.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("closeTab") {
                    if let c = AppGlobals.front(), !c.docs.isEmpty { c.closeDoc(at: c.active) }
                }.keyboardShortcut("w", modifiers: .command)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("undo") { AppGlobals.front()?.undo() }.keyboardShortcut("z", modifiers: .command)
                Button("redo") { AppGlobals.front()?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandMenu("tools") {
                Button("renumberOl") { AppGlobals.front()?.renumberOrderedLists() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .textEditing) {
                Button("findNext") { AppGlobals.front()?.findNext() }.keyboardShortcut("g", modifiers: .command)
                Button("findPrev") { AppGlobals.front()?.findPrevious() }.keyboardShortcut("g", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .toolbar) {
                Button("preview") { AppGlobals.front()?.requestedTab = .preview }.keyboardShortcut("1", modifiers: .command)
                Button("source") { AppGlobals.front()?.requestedTab = .source }.keyboardShortcut("2", modifiers: .command)
                Divider()
                Button("findReplace") { AppGlobals.front()?.toggleSearch() }.keyboardShortcut("f", modifiers: .command)
            }
        }
    }
}

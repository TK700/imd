# imd

极简 macOS Markdown 阅读 / 编辑器。单窗口多标签，左侧目录、右侧预览/源码双视图，黑白主题跟随系统。

- 主页: https://github.com/TK700
- 协议: MIT

## 特性

- 单窗口多标签，点击标签切换文件，支持同时打开多个文件
- 左侧自动生成目录（TOC），点击跳转；源码视图跳转后标题置顶
- 右侧双视图：渲染预览（marked.js，完整 GFM：表格/引用/列表/代码块/删除线/任务列表）与可编辑源码
- 黑白主题随系统自动切换
- 全文搜索/替换（⌘F）：计数、上/下个匹配、替换、全部替换、区分大小写；源码与预览双高亮
- 支持 txt：txt 为整窗编辑模式（无目录、无预览切换）；md / txt 混合多标签
- 新建文档可选 Markdown / 纯文本 (txt) 类型
- 界面随系统语言自适应中文 / 英文（zh-Hans / en 本地化）
- Markdown 符号智能提示浮窗：输入 `#` `>` `-` `` ` `` 等弹出候选+说明，↑/↓ 选择、回车插入、Esc 关闭；输入 `/` 或 `?` 或 ⌘Esc 查看全部；宽度自适应、可滚轮滚动
- 预览任务列表复选框可点击：勾选回写源码 `- [ ]`↔`- [x]` 并加删除线
- 工具 → 重排有序列表编号（⌘⌥R）：有序块标记重写为连续 1..n
- 多窗口：拖标签脱离标签区 → 分离为独立窗口；拖他窗标签入本窗 → 合并（源窗空自动关闭）
- 双击 / 打开文件自动并入最前窗口，不另开新窗
- 每文档独立隐藏 / 展开目录（左侧按钮）
- 目录分隔条为系统 paneSplitter，原生拖拽调宽与光标
- 拖拽 `.md` 到窗口即可打开；⌘O 多选打开；最近文件菜单
- 代码围栏内的 `#` 注释不会误入目录
- 无需 App Store，直接安装 `.app`

## 系统要求

- macOS 14.0 及以上（Apple Silicon / Intel）
- Windows 10/11 x64

## 安装

### macOS
1. 下载 Releases 中的 `imd-1.5.0.dmg`
2. 双击挂载，把 `imd` 拖到 `Applications`
3. 首次打开若被 Gatekeeper 拦截：右键 `imd.app` → 打开；或执行 `xattr -cr /Applications/imd.app`

### Windows
1. 下载 `imd_1.5.0_x64-setup.exe`（NSIS，推荐）或 `imd_1.5.0_x64_en-US.msi`（企业部署）
2. 双击安装

## 从源码构建

```bash
# macOS
cd macos && ./build.sh && ./make_dmg.sh   # build/imd.app → dist/imd-1.5.0.dmg

# Windows（需 GitHub Actions windows runner 或本机 Rust+Node）
cd windows && npm install && npx tauri icon src-tauri/icons/icon.png && npx tauri build
```

依赖：mac — Xcode CLT + Python 3（dmgbuild）；Win — Rust + Node + Tauri CLI。

## 项目结构

```
shared/                 两平台共用：preview/{preview.css,preview.js,marked.min.js}, l10n/{en,zh-Hans}.json, snippets.json
macos/                  原生 macOS（Swift/AppKit）：App.swift, Info.plist, build.sh, make_*.swift, make_dmg.{py,sh}
windows/                Tauri v2（Rust+静态前端）：src/{index.html,app.js,styles.css}, src-tauri/{Cargo.toml,tauri.conf.json,src/main.rs}, copy-shared.js
.github/workflows/windows.yml   CI 出 msi/nsis
```

## 第三方

- [marked](https://github.com/markedjs/marked) (MIT) — Markdown → HTML 渲染
- [Tauri](https://tauri.app) (MIT/Apache) — Windows 壳

## 许可

MIT © 2026 Thinking

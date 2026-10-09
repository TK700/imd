# imd

极简的 Markdown / 纯文本阅读编辑器，macOS 与 Windows 双平台。单窗口多标签，左侧目录、右侧预览/源码，黑白主题跟随系统，界面随系统语言中英自适应。

- 主页: https://github.com/TK700
- 协议: MIT

## 主要功能

- **多标签**：一个窗口同时打开多个 md / txt，点击切换
- **目录跳转**：左侧自动生成标题目录，点击定位
- **预览 + 源码**：右侧渲染预览（完整 GFM：表格、引用、列表、代码块、任务列表等）与可编辑源码一键切换
- **全文搜索替换**：⌘F，计数、逐个定位、批量替换、区分大小写，源码与预览同步高亮
- **任务列表勾选**：预览中点复选框，自动回写源码 `- [ ]` ↔ `- [x]` 并加删除线
- **符号提示**：输入 `#` `>` `-` `` ` `` 等弹出候选与说明，↑/↓ 选择回车插入
- **多窗口**：拖标签分离成独立窗口，拖回合并；双击文件并入已有窗口
- **txt 模式**：纯文本整窗编辑，与 md 混合多标签
- **本地化**：中文 / 英文随系统语言自动切换
- **主题**：黑白随系统

## 系统要求

- macOS 14.0+（Apple Silicon / Intel）
- Windows 10 / 11 x64

## 安装

### macOS
1. Releases 下载 `imd-1.5.0.dmg`
2. 双击挂载，拖 `imd` 到 `Applications`
3. 首次若被拦：右键 `imd.app` → 打开，或 `xattr -cr /Applications/imd.app`

### Windows
1. Releases 下载 `imd_1.5.0_x64-setup.exe`（推荐）或 `.msi`（企业部署）
2. 双击安装

## 从源码构建

```bash
# macOS
cd macos && ./build.sh && ./make_dmg.sh

# Windows（Rust + Node）
cd windows && npm install && npx tauri icon src-tauri/icons/icon.png && npx tauri build
```

## 项目结构

```
shared/    两平台共用：预览 (css/js/marked)、本地化、符号表
macos/     原生 macOS（Swift / AppKit）
windows/   Tauri v2（Rust + Webview）
```

## 第三方

- [marked](https://github.com/markedjs/marked) (MIT) — Markdown 渲染
- [Tauri](https://tauri.app) — Windows 壳

## 许可

MIT © 2026 Thinking

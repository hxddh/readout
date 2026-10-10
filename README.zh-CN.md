<p align="center"><img src="tools/icon-1024.png" width="128" alt=""></p>

<h1 align="center">Readout</h1>

<p align="center">为 AI Agent 产物打造的 macOS 原生 Markdown 阅读器<br>
<a href="README.md">English</a></p>

---

Agent 会把计划、规格、分析报告和代码解释写成很长的 Markdown，而且会反复改写。Readout 是为此设计的只读阅读器：瞬间打开、排版干净、跟随 Agent 的写入实时更新，并清楚标出自你上次阅读以来哪里变了。

## 功能

- **实时更新，不丢阅读位置。** 监听文件（包括"写临时文件再 rename"式的原子写入），按段落增量更新，你正在读的段落不会跳动；停在文末时会像终端一样自动跟随。
- **标出变更。** 新增和修改的段落在左侧有一条细线，删除处留有可展开的小标记。真正读过后标记自动消退。按 <kbd>N</kbd> 跳到下一处，<kbd>⌘K</kbd> 全部标为已读。阅读进度跨重启保留。
- **高质量渲染。** 完整 GFM：表格、任务列表、提示块（Alerts），针对中英混排调校的排版，Shiki 代码高亮，KaTeX 数学公式，Mermaid 图表。`src/app/main.swift:42` 这样的代码引用可直接在编辑器中打开。
- **带进度的大纲。** 侧边栏列出标题，以及每个章节的任务完成数。
- **聚焦新增内容。** 一键只看未读变更（<kbd>⇧⌘K</kbd>），标题栏与侧边栏显示字数与预计阅读时长，悬停标题可复制章节链接。欢迎窗口列出最近文件，一键重新打开。
- **一键打开最新文件。** 添加 Agent 写入的文件夹（自动包含 Claude Code 的 `~/.claude/plans`），在任何地方按 <kbd>⌥⌘R</kbd> 即可打开最新的 Markdown 文件。
- **Quick Look。** 在访达中选中 `.md` 文件按空格预览。
- **始终只读。** Readout 从不写入你的文件。

## 安装

从 [Releases](https://github.com/hxddh/readout/releases) 下载 `Readout-x.y.z.dmg`，打开后把 Readout 拖进"应用程序"。需要 macOS 26 或更高版本。

如果下载的版本未经公证，首次打开会被系统拦截：打开**系统设置 → 隐私与安全性**，找到关于 Readout 的提示，点击**仍要打开**。

Readout 会检查 GitHub Releases 获取新版本（**Readout → 检查更新…**）。

## 命令行与 Agent hook

选择 **Readout → 安装命令行工具…** 后可使用 `readout`：

```sh
readout plan.md          # 打开并切换到 Readout
readout -b plan.md       # 打开但不切换应用
```

想让 Claude Code 每写完一个 Markdown 文件就在 Readout 中打开，在 `~/.claude/settings.json` 中加入：

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "readout --hook" }]
      }
    ]
  }
}
```

`readout --hook` 会读取 hook 的输入，只有 `tool_input.file_path` 是 Markdown 文件时才在后台打开。

## 快捷键

| 按键 | 作用 |
| --- | --- |
| <kbd>N</kbd> / <kbd>⇧N</kbd>（或 <kbd>⌘]</kbd> / <kbd>⌘[</kbd>） | 下一处 / 上一处未读变更 |
| <kbd>⌘K</kbd> | 全部标为已读 |
| <kbd>⌘F</kbd>、<kbd>⌘G</kbd> | 查找、查找下一个 |
| <kbd>⌘+</kbd> / <kbd>⌘-</kbd> / <kbd>⌘0</kbd> | 文字大小 |
| <kbd>⌥⌘\</kbd> | 窄栏 / 宽栏 |
| <kbd>⌃⌘S</kbd> | 显示 / 隐藏侧边栏 |
| <kbd>⌘E</kbd> | 在编辑器中打开当前文件 |
| <kbd>J</kbd> / <kbd>K</kbd>、<kbd>G</kbd> / <kbd>⇧G</kbd> | 滚动、跳到开头 / 结尾 |

## 构建

```sh
brew install xcodegen node
make app        # 构建网页资源、生成 Xcode 工程并编译 Readout.app
make test       # 核心模块测试
```

## 许可

MIT

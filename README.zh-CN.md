<p align="center"><img src="tools/icon/readout-1024.png" width="128" alt=""></p>

<h1 align="center">Readout</h1>

<p align="center">为 AI Agent 产物打造的 macOS 原生 Markdown 阅读器<br>
<a href="README.md">English</a></p>

---

Agent 会把计划、规格、分析报告和代码解释写成很长的 Markdown，而且会反复改写。Readout 是为此设计的只读阅读器：瞬间打开、排版干净、跟随 Agent 的写入实时更新，并清楚标出自你上次阅读以来哪里变了。

## 功能

- **实时更新，不丢阅读位置。** 监听文件（包括"写临时文件再 rename"式的原子写入），按段落增量更新，你正在读的段落不会跳动；停在文末时会像终端一样自动跟随。
- **标出变更。** 新增和修改的段落在左侧有一条细线；点击修改段落的细线，可以看到自上次阅读以来具体改了哪些词。删除处留有小标记，展开可查看被删的完整原文。真正读过后标记自动消退。按 <kbd>N</kbd> 跳到下一处，<kbd>⌘K</kbd> 全部标为已读。阅读进度跨重启保留。
- **高质量渲染。** 完整 GFM：表格、任务列表、提示块（Alerts），针对中英混排调校的排版，Shiki 代码高亮，KaTeX 数学公式，Mermaid 图表。`src/app/main.swift:42` 这样的代码引用可直接在编辑器中打开。
- **带进度的大纲。** 侧边栏列出标题，以及每个章节的任务完成数。
- **聚焦新增内容。** 一键只看未读变更（<kbd>⇧⌘K</kbd>），标题栏显示任务完成进度，悬停标题可复制章节链接。
- **自动打开 Agent 写的文档。** 在设置里添加 Agent 写入的文件夹（自动包含 Claude Code 的 `~/.claude/plans`）。Agent 在这里新建的 Markdown 文档会自动在 Readout 中打开，在后台进行，不会抢走终端的焦点（修改已有文件，比如 README，不会弹出）。在任何地方按 <kbd>⌃⌥⌘R</kbd> 可打开最近写入的一个。使用 Codex？在设置里添加你的项目文件夹即可。
- **Quick Look。** 在访达中选中 `.md` 文件按空格预览。
- **始终只读。** Readout 从不写入你的文件。

## 安装

从 [Releases](https://github.com/hxddh/readout/releases) 下载 `Readout-x.y.z.dmg`，打开后把 Readout 拖进"应用程序"。需要 macOS 26 或更高版本。

如果下载的版本未经公证，首次打开会被系统拦截：打开**系统设置 → 隐私与安全性**，找到关于 Readout 的提示，点击**仍要打开**。

Readout 会检查 GitHub Releases 获取新版本（**Readout → 检查更新…**）。

## 隐私

渲染文档时不会发出任何网络请求：远程图片与媒体只显示为注明来源的占位按钮。只有当你点击时，Readout 才会亲自下载图片（不携带 cookie）并显示；视频与音频则改用浏览器打开。应用唯一的自动联网行为是每周一次的更新检查，可在设置中关闭。

## 命令行（可选）

配合 Agent 使用无需任何配置，设置里的文件夹就够了。如果还想要 `readout` 命令，把 App 里自带的脚本链接出来：

```sh
mkdir -p ~/.local/bin && ln -sf /Applications/Readout.app/Contents/Resources/readout ~/.local/bin/readout
```

（`~/.local/bin` 需要在 `PATH` 中。）之后 `readout plan.md` 打开文件，`readout -b plan.md` 在后台打开（作为标签页排在正在阅读的文档之后），不切换应用。

如果想用 Claude Code hook 代替文件夹监视（不需要链接 `readout`），把下面的内容加入 `~/.claude/settings.json`；Claude Code 写入或修改的每个 Markdown 文件都会在后台打开：

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          { "type": "command", "command": "/Applications/Readout.app/Contents/Resources/readout --hook" }
        ]
      }
    ]
  }
}
```

## 快捷键

| 按键 | 作用 |
| --- | --- |
| <kbd>N</kbd> / <kbd>⇧N</kbd>（或 <kbd>⌘]</kbd> / <kbd>⌘[</kbd>） | 下一处 / 上一处未读变更 |
| <kbd>D</kbd> | 从上到下依次显示视野内修改段落的具体变更；全部显示后再按一次收起 |
| <kbd>⌘K</kbd> | 全部标为已读 |
| <kbd>⇧⌘K</kbd> | 只看变更 |
| <kbd>⇧⌘O</kbd> | 打开最新的 Agent 文件 |
| <kbd>⌃⌥⌘R</kbd> | 在任何地方打开最新的 Agent 文件（全局快捷键，可在设置中更改或关闭） |
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

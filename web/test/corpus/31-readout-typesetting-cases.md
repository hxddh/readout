# Typesetting cases

Synthetic: written for Readout's rendering baselines, not taken from a repository. Each section is a construct agents write that the real documents in this corpus do not cover.

## Code inside an alert

> [!NOTE]
> Build the reader before running the tests:
>
> ```bash
> cd web && npm ci && npm run build
> BROWSER=webkit npm test
> ```

> [!WARNING]
> Baselines come from CI's WebKit, not a developer machine.

## A terminal transcript

```console
$ npm run corpus
ok: 01-sdd-fix-loop-plan-light (412 blocks, 31002 px)
$ git status --short
 M web/src/reader.css
```

## A directory tree

```text
web/
├── src/
│   ├── reader/
│   │   ├── enhance.js
│   │   └── mermaid.js
│   └── reader.css
└── test/
    └── typography.test.mjs
```

## Short cells and identifiers

| Action | Current | Latest | Risk | Notes |
| --- | --- | --- | --- | --- |
| `actions/configure-pages` | `v5.0.0` | `v7.0.0` | 🟡 Medium | Inputs changed between majors; check the changelog before bumping. |
| `actions/upload-pages-artifact` | `v3` | `v4` | S1 / GREEN | Drop-in. |
| `actions/deploy-pages` | `v4.0.5` | `v4.0.5` | 部分覆盖 | Path: `docs/superpowers/plans/2026-07-15-sdd-fix-loop-redesign.md` |

## Superscripts and footnotes

The cost grows as n<sup>2</sup> with the number of blocks, and H<sub>2</sub>O is just an example of a subscript in running text that wraps onto a second line.[^1]

[^1]: A footnote reference sits on the same line pitch as the text around it.

## 中文排版

这一段测试着重号：*强调文字*不用斜体，标点*不加点。——也不加*，混排的*调用 API 接口*只在汉字下加点。下一行的行距应当与上一行完全相同，不因为着重号而变大。

长的强调：*正确性属性是系统在所有有效执行中都应保持为真的特征或行为，本质上是关于系统应该做什么的形式化陈述*。

*整段强调的段落不加着重号，而是略微加重字重。*

- [x] 已完成：检查复选框与这一行居中
- [ ] 未完成：Latin task item in a CJK list

日本語の段落：*強調は傍点*で示します。

## Code that runs past the column

```ts
const result = await client.send(new GetObjectCommand({ Bucket: bucket, Key: key, Range: "bytes=0-1023", ChecksumMode: "ENABLED" }));
```

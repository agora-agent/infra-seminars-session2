# Slides — Session 2

本目录是 Session 2 的现场 slides，基于 `nv-slides-lab` 的 **diagram-native** Typst/Touying
模板，但**已把模板源码 vendored 到 `theme/`**，因此：

- 只依赖 `typst`（≥ 0.15.1）与 Typst 官方 preview 包（`touying`、`cetz`、`codly`，首次编译自动下载）；
- 不依赖 `nv-slides-lab` 仓库，同学 clone 本 repo 后即可构建；
- 字体（思源黑体 CN / JetBrains Mono）已随 `theme/_assets/fonts` 打包，中文排版不会漂移。

## 构建

```sh
make            # 生成 build/session2.pdf
make clean      # 删除 build/
```

或直接：

```sh
typst compile --font-path theme/_assets/fonts session2.typ build/session2.pdf
```

用 VS Code 预览时，在 Tinymist 的 `fontPaths` 中加入 `slides/theme/_assets/fonts`。

## 目录结构

```text
slides/
├── Makefile
├── README.md
├── session2.typ      # deck 入口（框架）
└── theme/            # vendored nv-slides-lab 源码（勿手工修改）
```

## 框架约定

- 正文用 `#todo[...]` 标记占位，按页面内注释逐步替换为真实内容。
- 章节结构遵循 `docs/seminar-outline.md` 的三幕结构 + 同学 Labs（saxpy / reduce / NCU）。
- 图表优先使用 CeTZ `figures.*` 持久图与 `layouts.diagram` / `layouts.code-focus` 等语义布局；
  不要在页面里硬编码 margin / 页眉 / 页脚。
- 定量结论在 slides 上保留 `docs/evidence-checklist.md` 的证据标签口径（CUDA contract /
  architecture-scoped / NCU model / A100 measured / course design）。

## 同步模板

`theme/` 是一次性 vendored 的模板快照。如需升级，从 `nv-slides-lab/src` 重新拷贝以下内容：

```sh
cp -R nv-theme.typ layouts.typ code-components.typ arch-components.typ lib.typ \
      typst.toml LICENSE _assets _vendor <本目录>/theme/
```

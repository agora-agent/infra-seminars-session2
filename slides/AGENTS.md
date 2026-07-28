# AGENTS.md — slides/

本目录的 deck 基于 vendored 的 `nv-slides-lab` diagram-native 模板。任何人（人或 AI agent）
在此编辑 slides，都必须遵守下面的方向性约束，否则会破坏整套视觉与叙事体系。

## 构建与验证

```sh
make            # 生成 build/session2.pdf
make clean
```

首次编译会下载 Typst preview 依赖（touying / cetz / codly）。`theme/` 是模板快照，
**不要改动**；升级时从 nv-slides-lab 重新拷贝（见 README.md）。

## 核心方向：diagram-native

1. 图是讲解过程中的持久对象，不是每页替换的截图。
2. 同一张图的几何结构尽量跨 subslide、跨相邻页面保持稳定；变化优先表达为
   状态 / 强调 / 注释，而不是重新排版或重画。
3. 文本承担旁白和结论，图承担结构与机制。
4. 页面面向现场投影，不是论文排版。

## 三层职责

- `theme/nv-theme.typ`：母版（安全区、页眉页脚、section/slide 标题、页码、颜色、字体）。
- `theme/layouts.typ`：语义 region（figure / support / card / plain / canvas）。
- figure 模块：只负责几何与状态。

不要在内容页里复制页眉页脚或硬编码 margin；新布局应组合 `layouts.region`。
CeTZ 图一律用 `responsive-canvas`（逻辑坐标），不用页面相关的 mm 值。

## 颜色语义

- 绿 = 结构、可用状态、模板层级。
- 橙 = 当前关注路径 / 问题 / 关键转折；不作为普通装饰。
- 紫可用于 memory / MIO 等不同语义层。
- 描边要轻，避免大块纯白和大量纯黑硬边。

## 动画三模式（按场景选，不要混用）

1. reducer-native（`animated-canvas` + `(pause,)`）：图在原地累积生长的架构图。
2. callback state（`slide(repeat: n, self => ...)`）：换色、时间线、trace、计算状态。
3. data-driven state machine：状态构造器 + 转移函数 + trace + 纯 renderer + derived metrics。

## 图与旁白耦合

- 每个视觉状态配一句短口头 claim。
- reducer-native 里用 `meanwhile` + `alternatives` 同步旁白。
- 旁白固定在一列，高度变化不要影响图的 bounding box。

## 复用优先于重画

相邻页之间保留基础几何。变化优先级：
1. 增删 annotation；
2. 改语义 highlight；
3. 加测量值；
4. 只有当心智模型本身改变时才改几何。

## 代码展示

- 用 `code.code-block`（Codly），不用 Typst 默认 raw 作最终样式。
- 每页约 5–12 行；一次只高亮一组相关行。
- 说明放 narration rail，不在代码块周围堆小字。
- 动态代码用 `touying-raw` 的 `pause` / `meanwhile` 注释。

## 本 deck 的特殊要求

- 定量结论必须带证据标签：`[CUDA contract]` / `[architecture-scoped]` /
  `[NCU model]` / `[A100 measured]` / `[course design]`
  （口径见 `docs/evidence-checklist.md`）。
- 版本号、TFLOP/s、% cuBLAS 等数字只使用 `docs/` 里已验证的口径与测量边界。
- 框架页用 `#todo[...]` 占位；替换成正文时删除对应 TODO 说明。
- `session2.typ` 定义了自定义 `title-slide`（shadow 模板版本），用于去掉模板自带的
  “schematic whiteboard / cetz-native diagrams” 徽标和 “Design Direction / Workflow”
  元文案；右侧 panel 由 `extra` 控制，左侧徽标由 `chips` 控制。不要改回模板的 title-slide。

## 明确避免

- 嵌入 NVIDIA 课件截图冒充自绘图。
- 复制一套 theme 到新项目（本目录已 vendored，勿再复制）。
- 用页面相关的绝对 mm 值调 CeTZ 图。
- 用 `stage == 1/2/3` 同时硬编码状态、metrics 与 narration。
- 无语义的高饱和颜色或大面积纯白。
- 每个 section 都固定放右侧绿色图块。
- 按字符数离散切换标题字号。

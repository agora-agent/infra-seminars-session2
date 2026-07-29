# AGENTS.md — slides/

本目录的 deck 基于 vendored 的 `nv-slides-lab` diagram-native 模板。任何人（人或 AI agent）
在此编辑 slides，都必须遵守下面的方向性约束，否则会破坏整套视觉与叙事体系。

## 构建与验证

```sh
make            # 生成 build/session2.pdf
make clean
```

首次编译会下载 Typst preview 依赖（touying / cetz / codly）。`theme/` 源自 vendored
模板快照，但**已按 `Session 2.pptx` 母版定制**：白底、标题下通栏 accent 分隔线、
右上角 wmhpc + lcpu logo 组、封面/章节页左下角 linuxproj 徽章（见
`theme/nv-theme.typ` 的 `brand-chrome` / `brand-badge-corner`）；标题一律用
`title-text`（黑体中文 + Times New Roman 英文，英文大写、首字母放大），正文统一
微软雅黑（缺失时回退思源黑体），无页码。后续 chrome 调整直接在 theme 内维护，
重新 vendor 会覆盖这些定制。

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

- 白底黑字为底；`palette.accent`（#156082）= 唯一彩色（母版 chrome + 图中
  当前关注对象 / 关键数据点）；`palette.muted` 灰 = 次要 / 反例 / 退化一侧。
- `palette.lime / orange` 映射到 accent 蓝，`palette.teal / violet` 映射到灰，
  仅为兼容旧图元调用 —— 新图不要引入其他彩色。
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

- 内容原则：slide 上只出现说明性的图和关键字，不出现说明性文字；结论由讲者口头给出。
- 文案风格：文字只起关键词 / 关键提示作用 —— 用短句、箭头（→ ⇒ ←）、
  符号（× ÷ ↑ ↓ ≠）和数据；不写大段介绍，不用文字下结论、作定义。
  问题式短句（“为什么……？”）作为引导是鼓励的。
  注意：Typst 里行首 `= ` 是标题语法，行文不要让 `=` 出现在行首；
  行首 `+ ` 是有序列表语法，表示“加”时用“与”。
- 标题（`=` / `==`）一律是短语（名词 / 动宾短语），不是短句；格式为
  “中文短语 English Phrase”（如 `== 每线程 Per Thread`），英文部分由 `title-text`
  自动渲染为大写 + 首字母放大。不用“把”字句、“被”字句，不用“这张图说了什么”
  这类表述；术语直接用英文（in-flight bytes 等），不生硬翻译。
- 强调只用 pptx 的思路：关键词加粗（`#accent[...]`，黑），不用颜色、
  不用圆角矩形框（callout / region / code-block 全部无框，`chip` 为纯文本
  `[label]`）。配色为白底黑字 + 单一 accent 蓝（#156082）+ 灰色层次，
  不引入其他彩色。
- 图注格式 `"Title", from xxx`（如 `Hopper SM, from NVIDIA Hopper whitepaper`）：
  title 尽量小、from 尽量简洁。图注只在确实需要出处时使用。
- 不用灰色小字补充说明（`note` 为黑色小字，只放实测数字 / 测量边界）。

- 定量结论必须带证据标签：`[CUDA contract]` / `[architecture-scoped]` /
  `[NCU model]` / `[A100 measured]` / `[course design]`
  （口径见 `docs/evidence-checklist.md`）。
- 版本号、TFLOP/s、% cuBLAS 等数字只使用 `docs/` 里已验证的口径与测量边界。
- 框架页用 `#todo[...]` 占位；替换成正文时删除对应 TODO 说明。
- `session2.typ` 定义了自定义 `title-slide`（shadow 模板版本），对齐 `Session 2.pptx`
  封面：居中的 “Weiming HPC Training Camp × LCPU AI Infra Seminars” 联名标题 +
  会话标题（取自 `config-info` 的 title / author / date）+ 两家组织中英文名称，
  左下角 linuxproj 徽章。不要改回模板的 title-slide。
- Act / Part 章节页（`new-section-slide`）同样对齐 pptx：页面中部居中大标题 +
  作者 / 日期 / 组织，左下角徽章；`section-intro` 的 objective / question 以灰色
  小字居中放在标题与作者信息之间，不再使用左侧竖条 + 右侧 panel 的版式。

## 明确避免

- 嵌入 NVIDIA 课件截图冒充自绘图。
- 复制一套 theme 到新项目（本目录已 vendored，勿再复制）。
- 用页面相关的绝对 mm 值调 CeTZ 图。
- 用 `stage == 1/2/3` 同时硬编码状态、metrics 与 narration。
- 无语义的高饱和颜色或大面积纯白。
- 每个 section 都固定放右侧绿色图块。
- 按字符数离散切换标题字号。

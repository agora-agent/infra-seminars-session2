// Session 2 — Memory Hierarchy and Fast SIMT GEMM
// Diagram-native deck framework built on the vendored `nv-slides-lab` theme.
//
// 使用说明
//   1. 本 deck 只依赖 vendored theme（./theme/）与 Typst 官方 preview 包
//      （touying / cetz / codly），不依赖 nv-slides-lab 仓库。
//   2. 构建：`make`（见 slides/Makefile），或直接
//      `typst compile --font-path theme/_assets/fonts session2.typ build/session2.pdf`
//   3. 本文是“框架”：已排好 section / slide 结构与推荐 layout，正文留空。
//      用 #todo[...] 标记每个页面预期内容，逐步替换为真实内容。

#import "@preview/touying:0.6.3": *
#import "@preview/cetz:0.5.1"
#import "./theme/nv-theme.typ": *
#import "./theme/layouts.typ" as layouts
#import "./theme/arch-components.typ" as figures
#import "./theme/code-components.typ" as code

#show: code.code-theme

#let todo(it) = note(it)

// sm-mental-model-live 的带高亮变体：在 4 段 reducer 构建之后追加第 5 段，
// 把 4 个 SMSP 的 Tensor 单元点亮为橙色（语义 spotlight / 当前关注路径）。
// 复用 figures 模块内部的 _sm-* 图元，避免复制几何。
#let sm-mental-model-live-highlight() = figures.animated-canvas(
  logical-size: (108, 70),
  padding: 6pt,
  {
    import cetz.draw: *
    set-style(stroke: 0.75pt + palette.border)
    figures._sm-shell()
    figures._sm-scheduler(4, 0)

    (pause,)

    figures._sm-scheduler(29, 1)
    figures._sm-scheduler(58, 2)
    figures._sm-scheduler(83, 3)

    (pause,)

    figures._sm-mio()

    (pause,)

    figures._sm-cache()

    (pause,)

    figures._sm-scheduler(4, 0, highlight: true)
    figures._sm-scheduler(29, 1, highlight: true)
    figures._sm-scheduler(58, 2, highlight: true)
    figures._sm-scheduler(83, 3, highlight: true)
  },
)

// ============================================================================
// Labs 专用组件
//
// 这些图元只服务 Labs 章节（saxpy / reduce）。约定与 theme 一致：
//   - 一律走 figures.responsive-canvas（逻辑坐标），不用页面相关的 mm 值；
//   - 颜色只从 palette 取：绿 = 结构/可用，橙 = 当前关注路径/问题，紫 = memory 层，
//     teal 用于"退化 / 反例"一侧的数值；
//   - 表格统一用 metric-table，避免每页各写一套 stroke。
// ============================================================================

// 课程数值表：表头下一条实线，行间细线，无竖线。
#let metric-table(size: 0.72em, ..args) = {
  set text(size: size)
  set table(
    stroke: (x, y) => (
      bottom: if y == 0 { 0.9pt + palette.border } else { 0.4pt + palette.grid },
    ),
    inset: (x: 0.55em, y: 0.34em),
    fill: none,
  )
  show table.cell.where(y: 0): strong
  table(..args)
}

// Roofline：两段屋顶 + 若干算子样例点。saxpy 用橙色（当前关注路径）。
#let saxpy-roofline() = figures.responsive-canvas(
  logical-size: (112, 62),
  padding: 6pt,
  {
    import cetz.draw: *
    let W = 104.0
    let H = 50.0
    let rx = 50.0
    let ry = 36.0

    set-style(stroke: 0.75pt + palette.border)
    line((6, 6), (W, 6), mark: (end: ">"))
    line((6, 6), (6, H + 6), mark: (end: ">"))
    content((W / 2, 1.6), text(size: 7.2pt, fill: palette.muted)[算存比 $I$ (FLOP/Byte)，对数轴])
    content((1.8, (H + 6) / 2), angle: 90deg, text(size: 7.2pt, fill: palette.muted)[可达性能])

    // memory-bound 斜边与 compute roof
    line((9, 8), (rx, ry), stroke: 2.0pt + palette.teal)
    line((rx, ry), (W - 4, ry), stroke: 2.0pt + palette.lime-dark)
    content((26, 15), text(size: 7pt, fill: palette.teal)[斜率 = 带宽])
    content((78, ry + 3.4), text(size: 7pt, fill: palette.lime-dark)[峰值算力])

    line((rx, 6), (rx, ry), stroke: (dash: "dashed", paint: palette.grid, thickness: 0.6pt))
    content((rx, 3.4), text(size: 6.6pt, fill: palette.muted)[$I_"ridge" approx 10$])

    let pt(x, y, label, c, dx: 0.0, dy: 4.0) = {
      circle((x, y), radius: 1.0, fill: c, stroke: none)
      content((x + dx, y + dy), text(size: 6.8pt, fill: c)[#label])
    }
    pt(13.5, 9.6, [saxpy], palette.orange, dx: 6.2, dy: -1.2)
    pt(21.0, 15.0, [dot], palette.teal, dx: -3.4, dy: 3.0)
    pt(32.0, 22.8, [GEMV], palette.teal, dx: -4.6, dy: 2.8)
    pt(84.0, ry, [GEMM], palette.lime-dark, dx: 0.0, dy: -4.2)

    content((26, H + 3), text(size: 7.4pt, fill: palette.teal, weight: "bold")[memory-bound])
    content((78, H + 3), text(size: 7.4pt, fill: palette.lime-dark, weight: "bold")[compute-bound])
  },
)

// GEMM：计算是立方的，数据是平方的 —— 唯一"天然"能 compute-bound 的算子。
#let gemm-shape-figure() = figures.responsive-canvas(
  logical-size: (96, 48),
  padding: 6pt,
  {
    import cetz.draw: *
    let s = 15.0
    let box(x, y, lbl, fill, stroke-c) = {
      rect((x, y), (x + s, y + s), fill: fill, stroke: 0.8pt + stroke-c, radius: 1.4)
      content((x + s / 2, y + s / 2), text(size: 8.5pt, weight: "bold", fill: palette.ink)[#lbl])
    }
    let y0 = 26.0
    box(14, y0, "C", palette.orange.lighten(60%), palette.orange)
    content((33.5, y0 + s / 2), text(size: 8.5pt, fill: palette.ink)[=])
    box(38, y0, "A", palette.surface-muted, palette.teal)
    content((57.5, y0 + s / 2), text(size: 8.5pt, fill: palette.ink)[×])
    box(62, y0, "B", palette.surface-muted, palette.teal)

    line((14, y0 - 2.2), (29, y0 - 2.2), stroke: 0.6pt + palette.muted,
      mark: (start: ">", end: ">", scale: 0.4))
    content((21.5, y0 - 5.0), text(size: 6.6pt, fill: palette.muted)[$n$])

    content((48, 17.0), text(size: 7.4pt, fill: palette.ink)[
      数据 $tilde 3n^2$ #h(0.8em) 计算 $tilde 2n^3$
    ])
    content((48, 10.4), text(size: 8.0pt, weight: "bold", fill: palette.orange)[
      计算是立方的，数据是平方的
    ])
    content((48, 4.4), text(size: 7.0pt, fill: palette.muted)[
      → $n$ 越大，$I$ 越高，越 compute-bound
    ])
  },
)

// GEMV：batch=1 时权重读一次只用一次；batching 相当于免费提高 I。
#let gemv-batching-figure() = figures.responsive-canvas(
  logical-size: (100, 46),
  padding: 6pt,
  {
    import cetz.draw: *
    let W = 24.0
    let y0 = 14.0

    // batch = 1
    rect((4, y0), (4 + W, y0 + W), fill: palette.surface-muted, stroke: 0.8pt + palette.teal, radius: 1.4)
    content((4 + W / 2, y0 + W / 2), text(size: 8.5pt, weight: "bold", fill: palette.ink)[$W$])
    rect((4 + W + 2.6, y0), (4 + W + 5.4, y0 + W), fill: palette.orange, stroke: none, radius: 0.8)
    content((4 + W + 4.0, y0 - 3.2), text(size: 6.6pt, fill: palette.ink)[$x$])
    content((4 + W / 2, y0 - 3.2), text(size: 6.6pt, fill: palette.muted)[读 $n^2$ 个权重])
    content((4 + W / 2, y0 + W + 3.6), text(size: 7.6pt, weight: "bold", fill: palette.ink)[
      batch = 1 #h(0.4em) $I approx 1$
    ])

    content((44.0, y0 + W / 2), text(size: 11pt, fill: palette.orange)[→])

    // batch = B
    let x0 = 50.0
    rect((x0, y0), (x0 + W, y0 + W), fill: palette.surface-muted, stroke: 0.8pt + palette.teal, radius: 1.4)
    content((x0 + W / 2, y0 + W / 2), text(size: 8.5pt, weight: "bold", fill: palette.ink)[$W$])
    for k in range(4) {
      rect(
        (x0 + W + 2.6 + k * 3.3, y0),
        (x0 + W + 5.4 + k * 3.3, y0 + W),
        fill: palette.orange,
        stroke: none,
        radius: 0.8,
      )
    }
    content((x0 + W + 8.0, y0 - 3.2), text(size: 6.6pt, fill: palette.ink)[$X$（B 列）])
    content((x0 + W / 2, y0 - 3.2), text(size: 6.6pt, fill: palette.muted)[权重还是读 $n^2$ 个])
    content((x0 + W / 2 + 4.0, y0 + W + 3.6), text(size: 7.6pt, weight: "bold", fill: palette.orange)[
      batch = B #h(0.4em) $I approx B$
    ])

    content((50, 5.0), text(size: 7.2pt, fill: palette.ink)[
      分母不变、分子 ×B —— batching 是免费的 $I$
    ])
  },
)

// Hierarchical roofline：每一级存储都有自己的斜边，实际性能取三者最小值。
#let hierarchical-roofline-figure() = figures.responsive-canvas(
  logical-size: (100, 62),
  padding: 6pt,
  {
    import cetz.draw: *
    set-style(stroke: 0.75pt + palette.border)
    // 对数坐标映射：I ∈ [0.1, 1e3] → x ∈ [10, 88]；P ∈ [1, 1e3] → y ∈ [8, 46]
    let X(ai) = 10.0 + (calc.log(ai) + 1) * 19.5
    let Y(p) = 8.0 + calc.log(p) * 12.6

    line((6, 8), (94, 8), mark: (end: ">"))
    line((6, 8), (6, 56), mark: (end: ">"))
    for (ai, lbl) in ((0.1, "0.1"), (1, "1"), (10, "10"), (100, "100"), (1000, "1e3")) {
      line((X(ai), 8), (X(ai), 6.4), stroke: 0.5pt + palette.grid)
      content((X(ai), 4.2), text(size: 6.0pt, fill: palette.muted)[#lbl])
    }
    content((52, 1.2), text(size: 6.8pt, fill: palette.muted)[$I$（相对各级存储）])
    content((2.0, 32), angle: 90deg, text(size: 6.8pt, fill: palette.muted)[可达性能])

    // compute roof
    let peak = 989.0
    line((X(1), Y(peak)), (X(1000), Y(peak)), stroke: 2.0pt + palette.lime-dark)
    content((X(320), Y(peak) + 3.4), text(size: 6.6pt, weight: "bold", fill: palette.lime-dark)[峰值算力])

    // 每级存储一条斜边，止于自己的脊点；标签贴在斜边中段外侧
    let roof(bw, lbl, col, th, ly) = {
      let ridge = peak / bw
      line((X(0.1), Y(bw * 0.1)), (X(ridge), Y(peak)), stroke: th + col)
      line((X(ridge), 8), (X(ridge), Y(peak)),
        stroke: (dash: "dashed", paint: col, thickness: 0.45pt))
      content((X(ridge) + 1.0, ly), anchor: "west", text(size: 6.4pt, weight: "bold", fill: col)[#lbl])
    }
    roof(30, [SMEM ~30 TB/s], palette.violet.darken(30%), 1.4pt, 20.0)
    roof(7, [L2 ~7 TB/s], palette.teal.lighten(25%), 1.4pt, 15.0)
    roof(3.35, [DRAM 3.35 TB/s], palette.teal, 2.0pt, 10.0)

    content((30, 46), text(size: 7.0pt, fill: palette.ink)[
      实际性能 = 三条 roof 的#emph[最小值]
    ])
  },
)

// Wave quantization：最后一个 wave 铺不满，剩下的 SM 纯粹空转。
#let wave-quantization-figure() = figures.responsive-canvas(
  logical-size: (86, 44),
  padding: 6pt,
  {
    import cetz.draw: *
    let row(y, lbl, filled, total) = {
      content((11.0, y + 2.2), text(size: 6.4pt, fill: palette.ink)[#lbl])
      for i in range(total) {
        rect(
          (16.0 + i * 5.4, y),
          (16.0 + i * 5.4 + 4.4, y + 4.4),
          fill: if i < filled { palette.orange } else { palette.surface-muted },
          stroke: if i < filled { none } else { 0.5pt + palette.grid },
          radius: 0.8,
        )
      }
    }
    content((43, 39.6), text(size: 7.2pt, weight: "bold", fill: palette.ink)[133 个 block，12 个 SM 示意])
    row(30.0, [wave 1], 12, 12)
    row(23.0, [wave 2], 12, 12)
    row(16.0, [wave 3], 1, 12)
    content((84, 18.2), anchor: "east", text(size: 6.6pt, weight: "bold", fill: palette.orange)[11/12 空转])

    line((11, 13.0), (84, 13.0), stroke: (dash: "dashed", paint: palette.grid, thickness: 0.6pt))
    content((45, 9.4), text(size: 6.6pt, fill: palette.muted)[耗时 = 3 个 wave，有效工作 = 2.08 个])
    content((45, 3.8), text(size: 8.0pt, weight: "bold", fill: palette.orange)[利用率 69%])
  },
)

// 低占用 = 发射槽之间大段空洞；高占用 = 不同 warp 的访存指令背靠背。
#let issue-timeline-figure() = figures.responsive-canvas(
  logical-size: (108, 34),
  padding: 6pt,
  {
    import cetz.draw: *
    set-style(stroke: 0.7pt + palette.border)

    let cell(x, y, w, c, label) = {
      rect((x, y), (x + w, y + 5.2), fill: c, stroke: none, radius: 0.9)
      if label != none {
        content((x + w / 2, y + 2.6), text(size: 5.8pt, fill: palette.on-accent)[#label])
      }
    }

    content((11, 27.2), text(size: 7.2pt, weight: "bold", fill: palette.ink)[低占用])
    cell(22, 24.6, 8.4, palette.orange, "LD")
    cell(31.6, 24.6, 48.0, palette.surface-muted, none)
    cell(80.8, 24.6, 8.4, palette.orange, "LD")
    content((55.6, 27.2), text(size: 6.2pt, fill: palette.muted)[等待 (stall)])
    content((99.0, 27.2), text(size: 6.4pt, fill: palette.teal)[总线空闲])

    content((11, 11.0), text(size: 7.2pt, weight: "bold", fill: palette.ink)[高占用])
    let cols = (
      palette.orange,
      palette.lime-dark,
      palette.orange.darken(15%),
      palette.violet.darken(18%),
      palette.orange,
      palette.lime-dark,
      palette.orange.darken(15%),
      palette.violet.darken(18%),
    )
    for i in range(8) {
      cell(22 + i * 8.6, 8.4, 8.0, cols.at(i), "LD")
    }
    content((99.0, 11.0), text(size: 6.4pt, fill: palette.lime-dark)[总线打满])
    content((55.6, 4.4), text(size: 6.2pt, fill: palette.muted)[不同 warp 的访存指令背靠背发出])
  },
)

// 所有线程的原子请求汇到同一个 L2 slice，在那里排队串行。
#let atomic-serialization-figure() = figures.responsive-canvas(
  logical-size: (66, 46),
  padding: 6pt,
  {
    import cetz.draw: *
    set-style(stroke: 0.7pt + palette.border)

    for i in range(6) {
      let y = 38.0 - i * 5.4
      rect((2, y), (17, y + 4.0), fill: palette.surface-strong, stroke: 0.5pt + palette.grid, radius: 1.0)
      content((9.5, y + 2.0), text(size: 6.0pt, fill: palette.ink)[t#i])
      line((17.4, y + 2.0), (37.0, 22.6), stroke: 0.6pt + palette.orange, mark: (end: ">"))
    }
    content((9.5, 5.6), text(size: 7.5pt, fill: palette.muted)[⋮])

    rect((37.5, 19.2), (61.0, 26.0), fill: palette.orange, stroke: none, radius: 1.6)
    content((49.2, 22.6), text(size: 6.6pt, fill: palette.on-accent, weight: "bold")[L2 slice])
    content((49.2, 13.4), text(size: 6.4pt, fill: palette.orange)[串行 RMW])
  },
)

// V2 的活跃 lane 散布在整个 warp 里；V4 的活跃 lane 连续，后面的 warp 可整体退出。
#let lane-occupancy-figure() = figures.responsive-canvas(
  logical-size: (76, 46),
  padding: 6pt,
  {
    import cetz.draw: *
    set-style(stroke: 0.7pt + palette.border)

    let lane-row(y, active-fn, caption) = {
      for k in range(16) {
        let x = 3.0 + k * 4.5
        let act = active-fn(k)
        rect(
          (x, y),
          (x + 3.9, y + 4.6),
          fill: if act { palette.orange } else { palette.surface-muted },
          stroke: none,
          radius: 0.8,
        )
        content(
          (x + 1.95, y + 2.3),
          text(size: 5.0pt, fill: if act { palette.on-accent } else { palette.muted })[#k],
        )
      }
      content((38, y - 3.0), text(size: 6.2pt, fill: palette.muted)[#caption])
    }

    content((38, 42.4), text(size: 7.0pt, weight: "bold", fill: palette.ink)[stride = 1 时的一个 warp])
    lane-row(33.0, k => calc.rem(k, 2) == 0, [16/32 活跃，但整个 warp 都在跑])

    content((38, 18.6), text(size: 7.0pt, weight: "bold", fill: palette.ink)[V4 的排布])
    lane-row(9.2, k => k < 8, [活跃线程连续 → 整 warp 可退出])
  },
)

// smem 路径需要"写 → 同步 → 读"；shuffle 是一条指令走 crossbar。
#let shuffle-vs-smem-figure() = figures.responsive-canvas(
  logical-size: (78, 40),
  padding: 6pt,
  {
    import cetz.draw: *
    set-style(stroke: 0.7pt + palette.border)

    let reg-box(x, y) = {
      rect((x, y), (x + 14, y + 5.6), fill: palette.surface-strong, stroke: 0.5pt + palette.grid, radius: 1.0)
      content((x + 7, y + 2.8), text(size: 6.0pt, fill: palette.ink)[reg])
    }

    content((7.5, 33.4), text(size: 6.8pt, weight: "bold", fill: palette.ink)[smem])
    reg-box(17, 28.0)
    rect((39, 28.0), (57, 33.6), fill: palette.violet.darken(12%), stroke: none, radius: 1.0)
    content((48, 30.8), text(size: 6.0pt, fill: palette.on-accent)[shared])
    reg-box(61, 28.0)
    line((31.4, 30.8), (38.6, 30.8), mark: (end: ">"))
    line((57.4, 30.8), (60.6, 30.8), mark: (end: ">"))
    content((48, 23.4), text(size: 6.0pt, fill: palette.muted)[写 → 同步 → 读])

    content((7.5, 13.6), text(size: 6.8pt, weight: "bold", fill: palette.ink)[shuffle])
    reg-box(17, 8.2)
    reg-box(61, 8.2)
    line((31.4, 11.0), (60.6, 11.0), stroke: 1.6pt + palette.orange, mark: (end: ">"))
    content((46, 15.2), text(size: 6.0pt, fill: palette.orange)[crossbar])
    content((46, 4.2), text(size: 6.0pt, fill: palette.muted)[一条指令，几个 cycle])
  },
)

// 蝶形归约：三轮 xor，结束后全部 lane 都持有 sum。
#let butterfly-figure() = figures.responsive-canvas(
  logical-size: (86, 40),
  padding: 6pt,
  {
    import cetz.draw: *
    set-style(stroke: 0.7pt + palette.border)

    let cw = 5.0
    let gap = 8.4
    let x0 = 14.0

    for step in range(3) {
      let y = 30.0 - step * 9.6
      for k in range(8) {
        let x = x0 + k * gap
        rect((x, y), (x + cw, y + 4.0), fill: palette.surface-muted, stroke: 0.4pt + palette.grid, radius: 0.8)
        content((x + cw / 2, y + 2.0), text(size: 5.8pt, fill: palette.ink)[#k])
      }
      let m = int(calc.pow(2, 2 - step))
      for k in range(8) {
        let partner = int(calc.rem(k + m, 2 * m)) + int(k / (2 * m)) * 2 * m
        if partner > k {
          let x1 = x0 + k * gap + cw / 2
          let x2 = x0 + partner * gap + cw / 2
          line(
            (x1, y - 0.3),
            ((x1 + x2) / 2, y - 3.0),
            (x2, y - 0.3),
            stroke: 0.85pt + palette.orange,
          )
        }
      }
      content((6.5, y + 2.0), text(size: 6.4pt, fill: palette.muted)[off = #m])
    }

    for k in range(8) {
      let x = x0 + k * gap
      rect((x, 1.6), (x + cw, 5.6), fill: palette.orange, stroke: none, radius: 0.8)
    }
    content((6.5, 3.6), text(size: 6.4pt, fill: palette.muted)[全为 sum])
  },
)

// V7 的 Speed-of-Light：DRAM 已经接近饱和，SM 远未饱和。
#let sol-bars-figure() = figures.responsive-canvas(
  logical-size: (44, 34),
  padding: 4pt,
  {
    import cetz.draw: *
    let H = 26.0
    rect((4, 4), (16, 4 + H), fill: palette.surface-muted, stroke: none, radius: 0.8)
    rect((4, 4), (16, 4 + H * 0.839), fill: palette.orange, stroke: none, radius: 0.8)
    content((10, 4 + H * 0.42), text(size: 7.0pt, fill: palette.on-accent, weight: "bold")[83.9%])
    content((10, 1.6), text(size: 6.4pt, fill: palette.ink)[DRAM])

    rect((26, 4), (38, 4 + H), fill: palette.surface-muted, stroke: none, radius: 0.8)
    rect((26, 4), (38, 4 + H * 0.101), fill: palette.teal, stroke: none, radius: 0.8)
    content((32, 4 + H * 0.101 + 2.6), text(size: 6.6pt, fill: palette.ink)[10.1%])
    content((32, 1.6), text(size: 6.4pt, fill: palette.ink)[SM])
  },
)

// V1 → V7 的带宽柱状图，虚线为 A100 HBM2e 引脚速率。
#let reduce-bandwidth-figure() = figures.responsive-canvas(
  logical-size: (104, 34),
  padding: 4pt,
  {
    import cetz.draw: *
    let data = (
      ("V1", 1.4),
      ("V2", 161.0),
      ("V3", 308.0),
      ("V4", 344.0),
      ("V5", 1074.0),
      ("V6", 1087.0),
      ("V7", 1572.0),
    )
    let maxv = 1935.0
    let H = 24.0
    let bw = 9.6
    let gap = 13.4
    let x0 = 5.0

    for (i, d) in data.enumerate() {
      let x = x0 + i * gap
      let h = d.at(1) / maxv * H
      rect(
        (x, 4.4),
        (x + bw, 4.4 + h),
        fill: if i == 6 { palette.orange } else if i == 0 { palette.teal } else { palette.lime-dark },
        stroke: none,
        radius: 0.8,
      )
      content((x + bw / 2, 4.4 + h + 2.0), text(size: 5.8pt, fill: palette.ink)[#d.at(1)])
      content((x + bw / 2, 1.8), text(size: 6.2pt, fill: palette.ink)[#d.at(0)])
    }
    line(
      (2, 4.4 + H),
      (102, 4.4 + H),
      stroke: (dash: "dashed", paint: palette.muted, thickness: 0.7pt),
    )
    content((84, 4.4 + H + 2.4), text(size: 6.0pt, fill: palette.muted)[A100 峰值 1935 GB/s])
  },
)

// 自定义 title slide：去掉模板自带的 “schematic whiteboard / cetz-native diagrams”
// 徽标与 “Design Direction / Workflow” 元文案，右侧 panel 完全由 deck 的 extra 控制。
#let title-slide(
  config: (:),
  subtitle: none,
  chips: none,
  extra: none,
  ..args,
) = touying-slide-wrapper(self => {
  self = utils.merge-dicts(
    self,
    config-common(freeze-slide-counter: true),
    config-page(fill: palette.page, margin: 1.45em),
    config,
  )
  let info = self.info + args.named()

  let left = [
    #if info.institution != none [
      #kicker(info.institution)
      #v(0.65em)
    ]
    #text(size: 1.82em, weight: "bold")[#info.title]
    #if subtitle != none [
      #v(0.35em)
      #text(size: 0.90em, fill: palette.muted)[#subtitle]
    ]
    #if chips != none [
      #v(0.75em)
      #chips
    ]
    #v(0.9em)
    #if info.author != none [
      #text(size: 0.76em)[#info.author]
    ]
    #if info.date != none [
      #h(0.7em)
      #note(info.date)
    ]
  ]

  let right = if extra != none {
    panel-box(fill: palette.panel, [
      #panel-box[
        #extra
      ]
    ])
  } else {
    []
  }

  touying-slide(
    self: self,
    grid(
      columns: (1.35fr, 1fr),
      column-gutter: 1.2em,
      inset: 0pt,
      align: top,
      left,
      right,
    ),
  )
})

#show: schematic-theme.with(
  config-info(
    title: [Session 2: Memory Hierarchy and Fast SIMT GEMM],
    author: [周宇轩 · 林若瑜],
    date: [2026-07 · Weiming HPC Training Camp × LCPU AI Infra Seminars],
    institution: [Infra Seminars · Session 2],
  ),
)

#title-slide(
  subtitle: [],
  chips: [#chip("") #h(0.5em) #chip("")],
  // extra: [
  //   // #kicker("Talk structure")
  //   // #v(0.2em)
  //   // #text(size: 0.64em)[
  //   //   约 2 小时 · Act I Preview → Act II Explain → 同学 Labs (saxpy / reduce / NCU) → Act III Rebuild
  //   // ]
  //   // #v(0.5em)
  //   // #note[目标不是复刻 cuBLAS，而是能解释并实现：coalescing、shared-memory tiling、register tiling、bank-aware mapping、latency hiding。]
  // ],
)

// ============================================================================
// Part 1 — saxpy 与硬件基础
//
// 从"一个 kernel 最快能跑多快"出发：Roofline 给出上限，Little's Law 给出
// 能拿到多少。沿途按需引入硬件（SM / sub-partition / warp scheduler / occupancy）。
// ============================================================================
= Part 1 — saxpy 与硬件基础

#section-intro(
  objective: [用一个最简单的 memory-bound kernel，建立"在飞字节"这一定量模型，并按需打开硬件。],
  question: [一个 kernel 最快能跑多快？谁决定了这个上限？],
)


== 一个 kernel 最快能跑多快
// 内容：开场问题。先把"限制速度的因素"摆出来，再引入 Roofline 作为第一个模型。
#layouts.stack(
  rows: (auto, auto),
  top-role: "card",
  bottom-role: "plain",
  [
    #align(center)[
      #text(size: 1.05em, weight: "bold")[一个 kernel 最快能跑多快？]
    ]
    #v(0.25em)
    #align(center)[
      #note[写下 kernel 之前，先问它的天花板在哪里 —— 以及天花板由谁决定]
    ]
  ],
  [
    #v(0.45em)
    #block(height: 6.4em, layouts.triptych(
      [
        #kicker[算]
        #v(0.3em)
        #text(size: 0.76em)[
          #accent[峰值算力]：每秒能做多少 FLOP。
          受限于执行单元数量与频率。
        ]
      ],
      [
        #kicker[搬]
        #v(0.3em)
        #text(size: 0.76em)[
          #accent[峰值带宽]：每秒能从 DRAM 搬多少字节。
          绝大多数 kernel 卡在这里。
        ]
      ],
      [
        #kicker[等]
        #v(0.3em)
        #text(size: 0.76em)[
          #accent[延迟]：数据从发出请求到返回要多久。
          必须用足够多的并行工作把它盖住。
        ]
      ],
    ))
    #v(0.5em)
    #callout("先看前两个")[
      #text(size: 0.80em)[
        "算"和"搬"的比值决定了 kernel 落在哪一侧 —— 这就是 #accent[Roofline]。
        第三个因素（延迟）Roofline 不管，我们放到后面再谈。
      ]
    ]
  ],
)

== Roofline 只回答"在哪一边"
// 内容：算存比定义 + 常见算子的 I；GEMM 是唯一能靠增大分块推过脊点的。
#layouts.stack(
  top-role: "support",
  bottom-role: "plain",
  [
    #text(size: 0.84em)[
      $ I = "浮点运算次数" / "DRAM 访问字节数" quad ["FLOP/Byte"] $
      脊点 $I_"ridge" = "峰值算力" \/ "峰值带宽"$；A100 FP32 约
      $19.5 "TFLOPS" \/ 1.94 "TB/s" approx$ #accent[10] FLOP/B
      #h(0.6em) #chip("architecture-scoped")
    ]
  ],
  [
    #v(0.3em)
    #metric-table(
      size: 0.66em,
      columns: (1.4fr, auto, auto, 1.5fr),
      align: (left, center, center, left),
      [算子], [FLOP], [Bytes], [$I$],
      [`saxpy` $y = a x + y$], [$2n$], [$12n$], [#accent[0.17] —— 深度 memory-bound],
      [向量点积 $x dot y$], [$2n$], [$8n$], [0.25],
      [ReLU / LayerNorm 等 elementwise], [$~n$], [$8n$], [~0.1],
      [GEMV $y = A x$], [$2n^2$], [$4n^2$], [0.5],
      [GEMM $C = A B$（$N times N$，分块）], [$2N^3$], [$~12N^2$], [#accent[$~N\/6$] —— 可以 compute-bound],
    )
    #v(0.4em)
    #align(center)[
      #note[
        GEMM 是唯一靠#emph[增大分块]就能把 $I$ 推过脊点的常见算子；
        其余绝大多数算子天生在左边 —— 这正是 Act I 的出发点
      ]
    ]
  ],
)

== Roofline 图
// 内容：两段屋顶 + 样例点；roofline 假设"只要在左边就能跑满带宽"，这个假设是错的。
#layouts.diagram(
  [#saxpy-roofline()],
  [
    #build-step("01", "上限")[
      Roofline 告诉我们 saxpy 的上限是带宽。
    ]
    #v(0.6em)
    #callout("但它没有告诉我们")[
      #text(size: 0.78em)[
        一个完美 coalesced 的 memory-bound kernel，
        到底能拿到这个上限的百分之多少？
      ]
      #v(0.3em)
      #note[
        roofline 假设"只要在左边，就能跑满带宽"——
        下面这个例子说明这个假设是错的。
      ]
    ]
  ],
)

== 大 GEMM: $I$ 随规模线性增长
// 内容：唯一"天然" compute-bound 的算子。计算 O(n^3)、数据 O(n^2)，
//       所以 I = n/3 随规模线性增长 —— 前提是每个元素只从 DRAM 读一次（即 tiling）。
#layouts.diagram(
  ratio: (1.85fr, 0.95fr),
  [#gemm-shape-figure()],
  [
    #text(size: 0.74em)[
      $"FLOP" = 2 M N K$
      #linebreak()
      $"Bytes" = 2(M K + K N + M N)$ #h(0.3em) (fp16)
      #linebreak()
      方阵 $M = N = K = n$ 时： $I = (2 n^3) / (6 n^2) = n \/ 3$
    ]
    #v(0.45em)
    #metric-table(
      size: 0.66em,
      columns: (auto, auto, 1fr),
      align: (right, right, left),
      [$n$], [$I$], [相对 H100 TC 脊点 295],
      [128], [43], [memory-bound],
      [1024], [341], [刚过脊点],
      [8192], [#accent[2731]], [#accent[远在右侧]],
    )
    #v(0.4em)
    #note[
      这是#emph[理想 $I$]，前提是每个元素只从 DRAM 读一次 ——
      而这正是 Part 2 里 tiling 要做到的事。
    ]
  ],
)

== Decode GEMV: LLM 推理慢的根本原因
// 内容：batch=1 时每个权重读进来只用一次乘加，I ≈ 1，深度 memory-bound；
//       batching / 量化 / 投机解码本质上都是在 roofline 上往右往上挪。
#layouts.diagram(
  ratio: (1.85fr, 0.95fr),
  [#gemv-batching-figure()],
  [
    #text(size: 0.74em)[
      batch = 1 时每一层就是#accent[矩阵 × 向量]：权重 $W$（$n times n$）乘激活 $x$（$n times 1$）。
      #linebreak()
      $"FLOP" = 2 n^2$，$"Bytes" approx 2 n^2$ #h(0.3em) $=>$ #h(0.3em) $I approx 1$
    ]
    #v(0.3em)
    #text(size: 0.74em)[#accent[每个权重从 DRAM 读进来，只参与一次乘加就被丢掉。]]
    #v(0.4em)
    #metric-table(
      size: 0.64em,
      columns: (1fr, auto),
      align: (left, right),
      [70B fp16 模型，H100], [],
      [每 token 需搬权重], [140 GB],
      [HBM3 带宽], [3.35 TB/s],
      [#accent[带宽下限 → 每 token]], [#accent[≈ 42 ms]],
      [对应上限], [≈ 24 tok/s],
    )
    #v(0.3em)
    #note[
      #text(size: 0.90em)[
        #accent[权重量化]（缩小分母）与#accent[投机解码]（等价于提高 batch）之所以有效，
        都是同一件事：在 roofline 上往右、往上挪。
      ]
    ]
  ],
)

== axpy: 一个再简单不过的 kernel
// 内容：kernel 本身挑不出毛病 —— 完美 coalesced、零分支、高 occupancy。
//       模板参数 scalar_t 让同一份代码可以换 datatype 跑，正是下一页的实验设计。
#layouts.code-focus(
  [
    #code.code-block(title: "axpy")[
      ```cuda
      template < typename scalar_t >
      __global__ void axpy_naive(scalar_t a, const scalar_t * x, scalar_t * y, int n) {
          int tid = threadIdx.x + blockIdx.x * blockDim.x;
          if (tid < n) {
              y[tid] = a * x[tid] + y[tid];
          }
      }
      ```
    ]
  ],
  [
    #callout("挑不出毛病")[
      #text(size: 0.78em)[
        - 完美 #accent[coalesced]：相邻线程访问相邻地址
        - 零分支、零同步、零 shared memory
        - 100% #accent[occupancy]（只用十几个寄存器）
        - embarrassingly parallel，无数据依赖
      ]
    ]
    #v(0.5em)
    #note[
      模板参数 `scalar_t` 让#emph[同一份代码]换不同 datatype 编译 ——
      下一页就用它做实验。
    ]
  ],
)

== 
// 内容：核心提问页。同一份代码只换 scalar_t，带宽却差一大截；
//       且 A100 上 fp32/fp64 都接近 STREAM，B200 上却明显掉队。
#layouts.diagram(
  [#image("assets/axpy_performance.png")],
  [
    #build-step("01", "两个问题")[
      #text(size: 0.86em)[
        代码一个字没改，只换了 `scalar_t`。
      ]
    ]
    #v(0.5em)
    #callout("① 为什么窄类型更慢？")[
      #text(size: 0.76em)[
        fp8 / fp16 搬的字节更少，
        却离 STREAM #accent[更远]。
      ]
    ]
    #v(0.4em)
    #callout("② 为什么卡越新越明显？")[
      #text(size: 0.76em)[
        A100 上 fp32 / fp64 都#accent[接近饱和]；
        B200 上同样的代码却明显掉队。
      ]
    ]
  ],
)

== 把差距量化
// 内容：把上一页的柱状图读成百分比。窄类型的缺口随卡变新而扩大 ——
//       这不是"新卡优化得更差"，而是同一个模型在更高带宽下的必然结果。
#layouts.stack(
  top-role: "card",
  bottom-role: "plain",
  [
    #text(size: 0.80em)[
      每格为 achieved / STREAM #h(0.5em) #chip("A100 measured") #h(0.3em) #chip("course design")
    ]
    #v(0.4em)
    #metric-table(
      columns: (auto, auto, auto, auto, auto),
      align: (left, right, right, right, right),
      [GPU], [fp8], [fp16], [fp32], [fp64],
      [A100], [41%], [69%], [88%], [#accent[94%]],
      [H200], [25%], [47%], [77%], [#accent[95%]],
      [B200], [#text(fill: palette.teal)[18%]], [#text(fill: palette.teal)[34%]], [53%], [#accent[83%]],
    )
  ],
  [
    #v(0.4em)
    #text(size: 0.82em)[
      沿每一行往左走，缺口变大；沿每一列往下走，缺口也变大。
      #accent[两个方向的共同点是：每个线程一次搬的字节太少。]
    ]
    #v(0.4em)
    #callout("同一个解释")[
      #text(size: 0.78em)[
        fp8 每线程只搬 1 字节，fp64 搬 8 字节 —— 差 8 倍。
        而 B200 的带宽是 A100 的 4 倍，#accent[要填满它需要的在途数据也成倍增加]。
        Roofline 里没有任何一项能表达这件事。
      ]
    ]
    #v(0.3em)
    #note[缺的这个量叫 #accent[在飞字节（bytes in flight）] —— 下面先用一部扶梯把它讲清楚。]
  ],
)

== 先看一部扶梯
// 内容：Little's Law 的日常直觉版。并发量 = 带宽 × 延迟，先在扶梯上算一遍，
//       下一页再换成内存系统的说法。
#layouts.diagram(
  [#image("assets/escalator.png")],
  [
    #kicker[扶梯参数]
    #v(0.35em)
    #text(size: 0.78em)[
      - 一级台阶站 #accent[1 个人]
      - 每 #accent[2 秒] 来一级台阶
        #h(0.3em) → #accent[带宽] = 0.5 人/秒
      - 梯身 #accent[20 级]
        #h(0.3em) → #accent[延迟] = 40 秒
    ]
    #v(0.55em)
    #callout("要占满这部扶梯，需要多少人同时在梯上？")[
      #text(size: 0.78em)[
        并发量 = 带宽 × 延迟
        #v(0.15em)
        #h(1.2em) = 0.5 人/秒 × 40 秒
        #v(0.1em)
        #h(1.2em) = #accent[20 人]
      ]
      #v(0.3em)
      #note[少于 20 人，梯上就有空台阶。]
    ]
  ],
  figure-role: "plain",
)

== Little's Law: 带宽不是免费的
// 内容：在飞字节 = 带宽 × 延迟；A100 约 1 MB；摊到每线程 ~4.7 B。
// 承接上一页的扶梯：把"人"换成"字节"，把"梯身"换成"内存系统"。
#layouts.stack(
  top-role: "card",
  bottom-role: "plain",
  [
    #align(center)[
      #text(size: 1.15em, weight: "bold")[$ "在飞字节" = "带宽" times "延迟" $]
    ]
    #v(0.2em)
    #align(center)[
      #note[
        把扶梯上的"人"换成"字节" —— Little's Law（$L = lambda W$）在内存系统上的形式
        #h(0.5em) #chip("course design")
      ]
    ]
  ],
  [
    #v(0.4em)
    #block(height: 6.6em, layouts.compare(
      [
        #kicker[含义]
        #v(0.3em)
        #text(size: 0.80em)[
          想让内存总线以带宽 $B$ 持续吐数据，就必须#accent[始终]有
          $B times L$ 字节的请求#accent[已经发出、但还没返回]。
          凑不够这个数，总线就有空档。
        ]
      ],
      [
        #kicker[代入 A100]
        #v(0.3em)
        #align(center)[
          #text(size: 0.92em)[
            $1935 "GB/s" times 500 "ns" approx$ #accent[1 MB]
          ]
        ]
        #v(0.2em)
        #align(center)[#note[必须同时在途]]
        #v(0.35em)
        #note[
          H100：3.35 TB/s × ~600 ns ≈ 2 MB；#accent[越新的卡这个数越大]
        ]
      ],
    ))
    #v(0.45em)
    #callout("回答开头的问题②")[
      #text(size: 0.78em)[
        延迟没怎么变，带宽却翻了几倍 ——
        所以#accent[越新的卡，要填满它需要的在飞字节越多]。
        同一份代码在 B200 上离饱和更远，不是代码变差了，是门槛变高了。
      ]
    ]
  ],
)

== 摊到每个线程头上
// 内容：22 万线程 / 1 MB ≈ 4.7 B；朴素 saxpy 每线程 8 B，正好卡在膝点。
#layouts.stack(
  top-role: "support",
  bottom-role: "plain",
  [
    #text(size: 0.84em)[
      A100 满占用：108 SM × 2048 线程 = #accent[22 万] 个线程
      $ "每线程需要的在飞字节" = (1 "MB") / (22 "万") approx #h(0.2em) 4.7 "B" $
    ]
  ],
  [
    #v(0.4em)
    #text(size: 0.86em)[
      回头看朴素 saxpy：每个线程发 #accent[2 条 4 B load]（读 `x`、读 `y`）= 8 B 在飞。
    ]
    #v(0.5em)
    #metric-table(
      columns: (auto, auto, auto),
      align: (left, right, left),
      [], [每 SM 在飞], [],
      [朴素 saxpy（满占用，8 B/线程）], [16 KB], [勉强够],
      [Little's Law 膝点（实测）], [16\~32 KB], [#accent[正好卡在边缘]],
    )
    #v(0.5em)
    #callout("回答开头的问题①")[
      #text(size: 0.80em)[
        8 B/线程 × 满占用 = 16 KB/SM，#accent[正好落在膝点上]，
        实测 82%（曲线预测 ~80%）。
        #accent[换成 fp16 就只剩 4 B/线程]，掉到膝点左边 —— 这就是窄类型变慢的原因。
      ]
    ]
  ],
)

== 
// 内容：30 个配置，一条曲线；硬件只关心乘积。
#layouts.diagram(
  [#image("assets/fig1_littles_law.png")],
  [
    #build-step("01", "扫描")[
      固定 `c = 2a`，二维扫描「每 SM 驻留 block 数」×「每线程在飞 load 数（MLP）」。
    ]
    #v(0.5em)
    #note[
      横轴 = 每 SM 在飞字节 = 驻留 warp 数 × 32 × 16 B × MLP。
    ]
    #v(0.5em)
    #callout("结论")[
      #text(size: 0.80em)[
        #accent[30 个配置，一条曲线]
        #h(0.4em) #chip("A100 measured")
      ]
    ]
  ],
)

== 这张图说了什么
// 内容：occupancy 差 8 倍、MLP 差 8 倍，带宽差 2%；硬件只关心乘积。
#layouts.stack(
  top-role: "card",
  bottom-role: "plain",
  [
    #metric-table(
      columns: (auto, 1fr, auto),
      align: (right, left, right),
      [每 SM 在飞], [配置], [GB/s],
      [16 KB], [32 warp × MLP 1], [1568],
      [16 KB], [16 warp × MLP 2], [1562],
      [16 KB], [8 warp × MLP 4], [1561],
      [16 KB], [4 warp × MLP 8], [1534],
    )
  ],
  [
    #v(0.45em)
    #text(size: 0.90em)[
      四个配置的 occupancy 差 #accent[8 倍]、MLP 差 #accent[8 倍]，带宽差 #accent[2%]。
    ]
    #v(0.5em)
    #callout("于是提高带宽只有两条路")[
      #text(size: 0.82em)[
        硬件#accent[只关心乘积]，不关心你是靠哪个因子凑出来的：
        #accent[更多的 warp]（occupancy），
        或者#accent[每个 warp 发更多 / 更宽的访存]（ILP / 向量化）。
      ]
    ]
  ],
)

== 路线一: 为什么 occupancy 能变成带宽
// 内容：SM 切成 4 个 sub-partition，每个都是相对独立的调度机器。
#layouts.split(
  [
    #image("assets/sm_arch.jpg", height: 86%)
    #v(0.2em)
    #align(center)[#note[Hopper SM · 引自 NVIDIA Hopper 架构白皮书]]
  ],
  [
    #text(size: 0.80em)[
      一个 SM 被切成 #accent[4 个 sub-partition]，
      每个都是一台#accent[相对独立的调度机器]：
    ]
    #v(0.4em)
    #image("assets/sm_subpartition.png", width: 100%)
    #v(0.45em)
    #text(size: 0.76em)[
      - 自己的 #accent[warp scheduler] + dispatch unit
      - 自己的 #accent[16384 × 32-bit 寄存器堆]
      - 一个 SM 共 #accent[64 K] 寄存器、最多驻留 #accent[64 warp]
    ]
    #v(0.35em)
    #note[
      底部的 256 KB L1 / shared memory 是 4 个 partition #emph[共享]的。
      图为 Hopper；A100 的四分区结构相同，但 L1/shared 容量为 192 KB。
      #h(0.4em) #chip("architecture-scoped")
    ]
  ],
  ratio: (0.86fr, 1.14fr),
  primary-role: "canvas",
  primary-align: center + horizon,
)

== 
// 内容：warp scheduler 每 cycle 挑一个 eligible warp；切换 0 cycle。
// 用法：复用 figures.render-warp-trace（与 Part 2 的 NCU Scheduler 统计同一张持久图），
//       callback 模式逐 cycle 推进；右侧旁白随 subslide 换成 0-cycle 切换的解读。
#slide(
  repeat: figures.default-warp-trace.len(),
  self => {
    let trace = figures.default-warp-trace
    let cycle = trace.at(self.subslide - 1)
    let step-number = if self.subslide < 10 {
      "0" + str(self.subslide)
    } else {
      str(self.subslide)
    }
    layouts.diagram(
      [#figures.render-warp-trace(trace, upto: self.subslide)],
      [
        #build-step(step-number, cycle.label)[
          #if cycle.issue == "bubble" [
            没有 eligible warp，这个 cycle 的发射槽#accent[空置]。
          ] else [
            scheduler 从 eligible 的 warp 里选中一个并#accent[发射]。
          ]
        ]
        #v(0.6em)
        #callout("0 cycle 切换")[
          #text(size: 0.76em)[
            每个 scheduler 手上驻留多个 warp slot，#accent[每个 cycle] 重新选一个。
            切换 warp #accent[不需要保存/恢复现场] ——
            每个 warp 的寄存器#accent[一直在寄存器堆里]。
          ]
          #v(0.2em)
          #note[
            CPU 换线程要几百到几千 cycle；GPU 换 warp 是 #accent[0 cycle]。
          ]
        ]
      ],
    )
  },
)

== 于是访存指令可以连续发射
// 内容：低占用总线空闲 vs 高占用总线打满。
#layouts.stack(
  rows: (52%, auto),
  top-role: "canvas",
  bottom-role: "plain",
  [#issue-timeline-figure()],
  [
    #v(0.35em)
    #text(size: 0.80em)[
      - warp A 发完 load 就 stall → scheduler 立刻从 warp B 发下一条 load
      - 每条 load 都在#accent[总线上叠加]，在飞字节线性增长
      - 直到凑够 $"带宽" times "延迟"$，总线才真正被填满
    ]
    #v(0.4em)
    #note[
      注意#accent[不是]"更多 warp 算得更快"—— 计算根本不是瓶颈
      （`issue_active` 实测只有 1.5%\~4.3%）。是#accent[更多 warp 能同时挂起更多访存请求]。
    ]
  ],
)

== 实测: 占用扫描
// 内容：6.25% → 100%，带宽 2.6 倍；唯一可能造成数量级差距的因素。
#layouts.stack(
  top-role: "card",
  bottom-role: "plain",
  [
    #text(size: 0.80em)[
      `c = 2a`，固定 MLP=1、标量访存，只改每 SM 驻留的 warp 数
      #h(0.5em) #chip("A100 measured")
    ]
    #v(0.4em)
    #metric-table(
      columns: (auto, auto, auto, auto),
      align: (center, center, right, right),
      [每 SM warp 数], [occupancy], [每 SM 在飞], [GB/s],
      [4], [6.25%], [2 KB], [#text(fill: palette.teal)[620]],
      [8], [12.5%], [4 KB], [1033],
      [16], [25%], [8 KB], [1442],
      [32], [50%], [16 KB], [1568],
      [64], [100%], [32 KB], [#accent[1602]],
    )
  ],
  [
    #v(0.45em)
    #text(size: 0.88em)[
      从 6.25% 到 100%，带宽 #accent[2.6 倍]。这是所有因素里#accent[唯一可能造成数量级差距]的。
    ]
    #v(0.45em)
    #callout("推论")[
      #text(size: 0.80em)[
        #accent[grid 一定要够大]。只 launch 108 个 block（每 SM 恰好 1 个）
        会比满 grid 慢 23%\~61%。
      ]
    ]
  ],
)


== 路线二: 提高单指令的字节数
// 内容：在飞字节 = occupancy × 32 × 单指令字节 × MLP；LSU 支持 32/64/128 bit。
#layouts.stack(
  top-role: "card",
  bottom-role: "plain",
  [
    #align(center)[
      #text(size: 0.86em)[
        $"每 SM 在飞字节" = underbrace(#text(fill: palette.teal)[驻留 warp 数], "occupancy")
        times 32 times underbrace(#text(fill: palette.orange)[单指令字节数], "向量化")
        times underbrace(#text(fill: palette.violet.darken(30%))["MLP"], "展开")$
      ]
    ]
  ],
  [
    #v(0.4em)
    #text(size: 0.82em)[
      occupancy 有硬上限（64 warp），而且常常被寄存器 / smem 压着。
      那就从#accent[第二个因子]下手 —— 让一条指令搬更多字节。
    ]
    #v(0.45em)
    #metric-table(
      columns: (auto, auto, auto, 1fr),
      align: (left, center, center, left),
      [类型], [位宽], [SASS], [一个 warp 的请求],
      [`float`], [32 bit], [`LDG.E`], [128 B = 1 条 cache line],
      [`float2`], [64 bit], [`LDG.E.64`], [256 B],
      [`float4`], [128 bit], [#accent[`LDG.E.128`]], [512 B = 4 条 cache line],
    )
  ],
)

== 标量 vs 向量化
// 内容：每线程在飞 8 B → 32 B；指令条数顺带降到 1/4。
#layouts.code-compare(
  [
    #kicker[标量]
    #v(0.3em)
    #code.code-block(numbers: false)[
      ```cuda
      int i = blockIdx.x * blockDim.x
            + threadIdx.x;
      if (i < n)
          y[i] = a * x[i] + y[i];
      ```
    ]
    #v(0.35em)
    #text(size: 0.76em)[
      - 每线程 2 条 4 B load
      - 在飞 #accent[8 B]
    ]
  ],
  [
    #kicker[向量化]
    #v(0.3em)
    #code.code-block(numbers: false)[
      ```cuda
      int i = blockIdx.x * blockDim.x
            + threadIdx.x;
      if (i < n/4) {
        float4 vx = ((float4*)x)[i];
        float4 vy = ((float4*)y)[i];
        vy.x = a*vx.x + vy.x;  // ...
        ((float4*)y)[i] = vy;
      }
      ```
    ]
    #v(0.35em)
    #text(size: 0.76em)[
      - 每线程 2 条 16 B load
      - 在飞 #accent[32 B]
    ]
  ],
)

== 实测: 向量宽度
// 内容：fp32 float4 +12%；窄数据类型差距才拉开。
#layouts.stack(
  top-role: "card",
  bottom-role: "card",
  [
    #metric-table(
      size: 0.72em,
      columns: (1fr, auto, auto, auto),
      align: (left, center, right, right),
      [写法], [单指令字节], [GB/s], [占峰值],
      [`float` 标量], [4 B], [1498], [77.4%],
      [`float2`], [8 B], [1669], [86.3%],
      [`float4`], [16 B], [#accent[1685]], [#accent[87.1%]],
    )
    #v(0.35em)
    #text(size: 0.78em)[
      fp32 上 `float4` 相对标量 #accent[+12%] —— 真实，但不是数量级差别。
      窄数据类型下差距才真正拉开：
    ]
  ],
  [
    #metric-table(
      size: 0.72em,
      columns: (1fr, auto, auto, auto),
      align: (left, center, right, right),
      [写法], [每线程元素], [GB/s], [占峰值],
      [`__half` 一元素一线程（16-bit load）], [1], [#text(fill: palette.teal)[1112]], [57.5%],
      [`__half2`（32-bit）], [2], [1427], [73.8%],
      [`half8`（128-bit）], [8], [#accent[1592]], [#accent[82.3%]],
    )
    #v(0.35em)
    #align(center)[
      #note[
        标量 fp16 只有 2 B/线程在飞，满占用也只有 8 KB/SM —— #accent[膝点左边]
      ]
    ]
  ],
)

== 两条路是可以互相替代的
// 内容：低占用 + 高 MLP ≈ 满占用；满占用时 MLP 完全无所谓。
#layouts.stack(
  top-role: "card",
  bottom-role: "plain",
  [
    #text(size: 0.80em)[低占用时，靠每线程多发几条 load（ILP）几乎可以#accent[完全补偿]：]
    #v(0.4em)
    #metric-table(
      columns: (1fr, auto, auto),
      align: (left, right, right),
      [4 warp/SM（6.25% 占用）], [每 SM 在飞], [GB/s],
      [MLP = 1], [2 KB], [#text(fill: palette.teal)[620]],
      [MLP = 4], [8 KB], [1393],
      [MLP = 8], [16 KB], [#accent[1534]],
      [参照：满占用最好成绩], [32 KB], [1602],
    )
  ],
  [
    #v(0.45em)
    #text(size: 0.88em)[
      6.25% 占用 + MLP=8 达到 1534 GB/s，与满占用最好成绩#accent[只差 4%]。
    ]
    #v(0.45em)
    #callout("反过来也成立")[
      #text(size: 0.80em)[
        #accent[满占用时 MLP 完全无所谓]。64 warp/SM 下 MLP=1 是 1602，MLP=32 是 1587 ——
        一条 128-bit load 就够了，因为已经越过膝点。
      ]
    ]
  ],
)

== 实测热力图
// 内容：等值带沿反对角线分布 —— "乘积决定一切"的形状。
#layouts.diagram(
  [#image("assets/fig2_heatmap.png")],
  [
    #build-step("01", "形状")[
      等值带沿#accent[反对角线]分布。
    ]
    #v(0.5em)
    #callout("读法")[
      #text(size: 0.78em)[
        这正是"乘积决定一切"的形状：
        沿反对角线移动，occupancy 与 MLP 此消彼长，
        乘积不变 → 带宽不变。
      ]
    ]
  ],
)

== 回头看 Roofline: 它是一个一阶模型
// 内容：把 Part 1 一路踩到的坑归位。Roofline 只有两个参数，所以只能回答一个问题；
//       它成立依赖四条隐含前提，每条被打破都对应一类真实瓶颈。
//       前提三就是刚讲完的 Little's Law，剩下三条下面逐页展开。
#layouts.stack(
  top-role: "card",
  bottom-role: "plain",
  [
    #text(size: 0.82em)[
      Roofline 只有#accent[两个参数]（峰值算力、峰值带宽），所以它只能回答一个问题：
      #accent[如果唯一的瓶颈是 DRAM 带宽或算力，我最快能到多少。]
    ]
  ],
  [
    #v(0.4em)
    #metric-table(
      size: 0.70em,
      columns: (auto, 1fr, auto),
      align: (left, left, center),
      [隐含前提], [被打破时的真实瓶颈], [],
      [DRAM 是唯一的带宽层级], [SMEM / L2 先饱和 → hierarchical roofline], [破例一],
      [指令只有访存和浮点], [地址计算、循环、类型转换把 issue slot 吃光], [破例二],
      [延迟总能被并发掩盖], [在飞请求不够，带宽根本没被激发出来], [#text(fill: palette.muted)[已讲]],
      [工作量能均匀铺满整卡], [tail effect / wave quantization，SM 空转], [破例三],
    )
    #v(0.45em)
    #callout("不是说 roofline 没用")[
      #text(size: 0.80em)[
        #accent[它是唯一能给出"还差多远"这个数的模型]。但它给的是#accent[上界]，
        而打不到上界的原因，都在这四条里 —— 第三条就是刚讲完的 Little's Law。
      ]
    ]
  ],
)

== 破例一: hierarchical roofline
// 内容：每一级存储都有自己的 I（分母换成"从该级搬的字节数"），于是每一级都有自己的斜边。
//       tiling 把 DRAM 的 I 推上去，但 SMEM 的 I 一点没变 —— 搬运只是被推到了下一级。
#layouts.diagram(
  ratio: (1.7fr, 1.05fr),
  [#hierarchical-roofline-figure()],
  [
    #text(size: 0.76em)[
      DRAM 那条斜边不是唯一的天花板。同一个 kernel 在#accent[每一级存储]上都有自己的 $I$
      （分母换成"从该级搬的字节数"），于是每级都有自己的斜边 ——
      带宽越高，斜边越陡、脊点越靠右。
    ]
    #v(0.45em)
    #callout("tiling 只是把搬运推到下一级")[
      #text(size: 0.72em)[
        shared-memory tiling 让 DRAM 的 $I$ 变大，#accent[但 SMEM 的 $I$ 一点没变]。
        所以 Part 2 里的 #accent[register tiling] 才是必需的 ——
        它提高的是#emph[相对 SMEM 的 $I$]。
        #v(0.3em)
        离 DRAM 峰值还远却上不去，很可能是 #accent[L2 / L1 先饱和] —— 看 NCU 的 SOL 谁占用最高。
      ]
    ]
  ],
)

== 破例二: issue bound —— 瓶颈是指令条数，不是字节数
// 内容：Roofline 只数浮点和字节，但每个 scheduler 每 cycle 只能发射 1 条指令，
//       地址计算 / 循环控制 / 边界判断全都要占 issue slot。
//       这正好解释了前面 float4 的收益里有一部分不来自带宽。
#layouts.code-focus(
  [
    #code.code-block(title: "每个元素 1 条 LDG + 一堆整数指令")[
      ```cuda
      for (int i = tid; i < n; i += stride) {
          int r = i / W;            // IMAD + 移位
          int c = i - r * W;        // IMAD
          out[r * W + c] = in[r * W + c] * s;
      }
      ```
    ]
    #v(0.4em)
    #align(left)[
      #text(size: 0.78em)[
        解法都是"用#accent[更少的指令]搬同样多的字节"：
        - #accent[向量化]（`float4`）：字节数不变，指令数变 1/4
        - #accent[`#pragma unroll`]：摊薄循环的比较与自增
        - #accent[预算好索引]：不变量提到循环外，别重复整数乘除
        - #accent[Hopper TMA]：一条指令描述整个多维 tile，地址计算开销归零
      ]
    ]
  ],
  [
    #text(size: 0.78em)[
      每个 scheduler #accent[每 cycle 只能发射 1 条指令]，而地址计算、循环控制、
      边界判断、类型转换全都要占 issue slot。
    ]
    #v(0.45em)
    #callout("典型症状")[
      #text(size: 0.76em)[
        NCU 里 Compute 和 Memory #accent[两个 SOL 都不高]，
        但 `smsp__inst_executed` 很大，warp stall 主要是
        `no_instruction` / `dispatch_stall`。
      ]
    ]
    #v(0.4em)
    #note[
      回看前面 `float4` 的 +12%：#accent[一部分是在飞字节变多]（路线二），
      另一部分是#accent[指令条数变成 1/4] —— 后者 Roofline 里根本没有对应的项。
    ]
  ],
)

== 破例三: tail effect / wave quantization
// 内容：GPU 以 wave 为粒度铺 block，最后一个 wave 铺不满就纯粹空转。
//       132 SM 上 launch 133 个 block → 利用率腰斩。呼应前面"grid 一定要够大"。
#layouts.diagram(
  ratio: (1.7fr, 1.05fr),
  [#wave-quantization-figure()],
  [
    #text(size: 0.74em)[
      GPU 以 #accent[wave] 为粒度铺 block：一个 wave = 所有 SM 各驻留满一批 block。
      最后一个 wave 没铺满，剩下的 SM 就#accent[纯粹空转]，而 kernel 必须等它跑完。
    ]
    #v(0.35em)
    #metric-table(
      size: 0.62em,
      columns: (auto, auto, auto),
      align: (right, center, right),
      [block 数], [wave 数], [利用率],
      [132], [1], [100%],
      [133], [2], [#accent[50.4%]],
      [264], [2], [100%],
      [265], [3], [66.9%],
      [1320], [10], [100%],
      [1321], [11], [#accent[91.0%]],
    )
    #v(0.3em)
    #callout("GEMM 里的对应现象")[
      #text(size: 0.68em)[
        block 数越大量化误差越被摊薄，这是"#accent[grid 一定要够大]"的另一半理由。
        GEMM 里的对应物叫 #accent[tile quantization]：8192 被 tile $128 times 128$ 整除，
        改成 8200 就多出一排几乎空转的 tile。
      ]
    ]
  ],
)


// ============================================================================
// Part 2 — GEMM（三幕：Preview / Explain / Rebuild）
// 本部分内容维持原三幕结构不变。
// ============================================================================

// ============================================================================
// Act I — Preview
// ============================================================================
= Act I — Preview

#section-intro(
  objective: [从 GEMM 语义、data reuse 与简单 Roofline 建立完整优化地图。],
  question: [哪些数据值得复用？复用到哪一层？],
)

== GEMM Workload: 计算语义与 Reuse
// 内容：C = A·B；每个输出需要的 A/B 元素；同行/同列输出共享哪些数据；
//       "数据移动 / FMA" 才是 GEMM 的价值所在。
#layouts.full(
  role: "figure",
  [#todo[GEMM 语义、三个 workload-level 问题、reuse 结论。]],
)

== 第一次引入 Roofline
// 内容：arithmetic intensity = useful computation / data moved；
//       P <= min(P_compute, BW * AI)；只有 HBM roof 与 compute roof。
#layouts.diagram(
  [#todo[CeTZ Roofline: 两段屋顶 + memory-bound / compute-bound 区域。]],
  [#todo[每搬一个 byte 只做少量计算时，性能受数据移动限制。]],
)

== GEMM 的 Roofline Paradox
// 内容：算法级 AI ~= N/6（高），naive 代码级 AI ~= 0.25（低）。
//       三种 AI 口径：Algorithmic / Code-level / Measured。
#layouts.compare(
  [#todo[算法级: Bytes_min ≈ 4(MK+KN+MN), AI ≈ N/6。]],
  [#todo[Naive 代码级: Bytes ≈ 8MNK, AI ≈ 0.25 FLOP/byte。]],
)

== 用 Tiling 说明 Reuse 的数量级
// 内容：T x T tile，AI_global-to-shared = T/4；T=32 时约 8 FLOP/byte（↑32x）。
//       shared memory 在这里只给 workload 级定义（block 内共享的临时存储）。
#layouts.diagram(
  [#todo[CeTZ: 一个 block 的 C tile + A/B tile 装载一次、复用多次。]],
  [#todo[shared tiling 的首要价值是捕获 block-level reuse，减少高层数据移动。]],
)

== GEMM Evolution Map (V0 → V6)
// 内容：完整优化路线预览，不展开硬件细节：
//       V0 naive → V1 warp-friendly mapping → V2 shared tiling →
//       V3 1D register → V4 2D outer product → V5 vectorized → V6 bank-aware。
#layouts.full(
  role: "figure",
  [#todo[CeTZ: 一条 V0→V6 的路线图（持久图，后续 Act III 逐版本回访）。]],
)

// ============================================================================
// Act II — Explain
// ============================================================================
= Act II — Explain

#section-intro(
  objective: [逐层打开 GPU 硬件，用设计约束解释每项优化为什么存在。],
  question: [为什么相邻线程最好访问相邻地址？为什么 shared memory 需要显式管理？],
)

== Episode 1 — SIMT 与 Warp 执行
// 内容：SIMT 折中（scalar threads → 32-thread warp → 共享控制 → 并行 lane）；
//       规则控制流/地址摊薄成本，不规则仍正确但吞吐下降。
#layouts.diagram(
  [#todo[CeTZ: warp = 32 scalar threads，共享 instruction issue，32 lanes。]],
  [#todo[软件写 scalar code，硬件以 warp 为执行/发射单位。]],
)

== Episode 1 — Coalescing 与 Sector
// 内容：CC 6.0+ 的 32-byte sector 模型；一条 warp memory instruction 的
//       participating-lane 地址集合覆盖多少 sectors；request/sector 是 NCU 概念。
#layouts.diagram(
  [#todo[CeTZ: 32 lanes x 4B 连续 load → 4 个对齐 32B sector；跨 boundary 变多。]],
  [#todo[coalescing 提高每个 request 的有效性，不等于固定 128-byte transaction。]],
)

== Episode 1 — Copy 微基准与 NCU
// 内容：code/memory-layout 的 contiguous vs stride copy；
//       actual/ideal/excessive sectors、useful bandwidth、L1TEX/L2/DRAM。
#layouts.code-focus(
  [#todo[code-block: out[i] = in[i]; 与 stride/转置式访问。]],
  [#todo[先隔离 coalescing，再回到 GEMM。]],
)

== Episode 2 — A100 SM 教学模型 (SMSP)
// 内容：一个 SM 按 4 个 SMSP 理解；每个 SMSP 有自己的 scheduler、register file、FP/INT 单元；
//       Nsight Compute 的 SMSP 是 profiler 模型，不是 CUDA 对所有 GPU 的保证。
// 用法：sm-mental-model-live-highlight() 是 reducer-native 持久图，内部用 (pause,) 分段；
//       第 5 段把 4 个 SMSP 的 Tensor 单元点亮为橙色；右侧旁白用 #meanwhile + #alternatives
//       与图的 subslide 同步推进。
#layouts.diagram(
  [#sm-mental-model-live-highlight()],
  [
    #meanwhile
    #alternatives[
      #build-step("01", "Anchor")[
        SM 外壳 + 第一个 SMSP：warp scheduler、register file、FP/INT 执行单元。
      ]
    ][
      #build-step("02", "Partitions")[
        补齐 4 个 SMSP，每个都有自己的 scheduler 与寄存器堆。
      ]
    ][
      #build-step("03", "MIO")[
        执行结果经输出总线汇入 MIO：ADU / RTCore / LSU / TEX。
      ]
    ][
      #build-step("04", "Cache")[
        接上 L1TEX + Shared Memory 与 IDC\$，向下连 L2。
      ]
    ][
      #build-step("05", "Spotlight")[
        语义 spotlight：4 个 SMSP 的 Tensor 单元高亮——当前关注的计算路径。
      ]
    ]
  ],
)

== Episode 2 — Scoreboard 与 Latency Hiding
// 内容：resident / eligible / issued 三个状态；scoreboard 跟踪未完成依赖；
//       scheduler 在连续 issue cycle 选不同 eligible warp 覆盖等待。
#layouts.diagram(
  [#todo[CeTZ: cycle 时间线，W0:LD 发出后 consumer 等待，其他 warp 发射。]],
  [#todo[GPU 不把 dependent load 变便宜，而是用其他独立工作覆盖延迟。]],
)

== Episode 2 — Occupancy 与 In-Flight Work
// 内容：occupancy = active warps / max warps；theoretical vs achieved 口径；
//       Little's Law 数量级；"足够 occupancy" 而非 "最大 occupancy"。
#layouts.full(
  role: "figure",
  [#todo[occupancy 公式、theoretical/achieved 区分、in-flight work 来源。]],
)

== Episode 2 — NCU Scheduler 统计
// 内容：Active/Eligible/Issued Warps Per Scheduler；No Eligible；Long Scoreboard；
//       Long Scoreboard 高 ≠ DRAM bound。
// 用法：trace 数据驱动，callback 模式（slide repeat + self.subslide）逐 cycle 推进
//       render-warp-trace；metrics 由 warp-trace-metrics 从同一 trace 派生。
#slide(
  repeat: figures.default-warp-trace.len(),
  self => {
    let trace = figures.default-warp-trace
    let visible = trace.slice(0, self.subslide)
    let cycle = trace.at(self.subslide - 1)
    let metrics = figures.warp-trace-metrics(visible)
    let step-number = if self.subslide < 10 {
      "0" + str(self.subslide)
    } else {
      str(self.subslide)
    }
    layouts.diagram(
      [#figures.render-warp-trace(trace, upto: self.subslide)],
      [
        #build-step(step-number, cycle.label)[
          #if cycle.issue == "bubble" [
            Issue = bubble：没有 eligible warp，发射槽空置。
          ] else if cycle.issue == "issued" [
            Issue = issued：scheduler 选中一个 warp 并发射。
          ] else [
            Issue = none。
          ]
        ]
        #v(0.7em)
        #callout("Derived metrics")[
          #note[
            #metrics.warps-active active · #metrics.warps-eligible eligible · #metrics.warps-stalled stalled · #metrics.issue-bubbles bubble
          ]
        ]
      ],
    )
  },
)

== Episode 3 — 按 Reuse Scope 看 Memory Hierarchy
// 内容：Registers(单线程) / Shared(block) / L1 / L2 / HBM 的复用作用域与控制者；
//       A100 192KB unified L1/shared，最大 164KB shared，离散 carveout。
#layouts.full(
  role: "figure",
  [#todo[五层 hierarchy 表：scope / controller / 课程例子。]],
)

== Episode 3 — 为什么 Cache 不替代 Shared Memory
// 内容：cache 机会性捕获复用但非语义保证；shared 显式表达 block-level reuse。
#layouts.compare(
  [#todo[Cache: 硬件管理、机会性、可能被替换/竞争。]],
  [#todo[Shared: 显式寻址、block-scoped、需要 load/sync/layout 设计。]],
)

== Episode 3 — Tiled GEMM 与两个 Barrier
// 内容：As/Bs 装载、两个 __syncthreads() 的可见性/复用理由；K-tail zero-fill。
#layouts.code-focus(
  [#todo[code-block: V2 tiled GEMM 主循环（含两个 barrier）。]],
  [#todo[barrier 1: tile 装载完整；barrier 2: 安全覆盖 shared buffer。]],
)

== Episode 3 — 第一次 Roofline 右移
// 内容：AI_naive ≈ 0.25 → AI_tiled ≈ T/4；global bytes 下降需实测；
//       DRAM % peak 下降不一定是回退。
#layouts.diagram(
  [#todo[CeTZ: Roofline 上 naive → tiled 的 AI 右移。]],
  [#todo[shared tiling 减少 logical global loads；实测 bytes/FLOP 决定右移幅度。]],
)

== Episode 4 — 片上资源与 Occupancy Trade-off
// 内容：register / shared / thread / block slots 有限；tile 越大 reuse 越高但
//       resident 越少、latency-hiding 越弱。
#layouts.stack(
  top-role: "support",
  bottom-role: "figure",
  [#todo[larger tile → more reuse → faster；larger tile → fewer resident warps → slower。]],
  [#todo[occupancy 是 trade-off 的一侧，不是最终目标。]],
)

== Episode 5 — Banked Shared SRAM
// 内容：32 banks × 32-bit/cycle；bank = (byte_addr/4) mod 32；conflict/broadcast/multicast。
#layouts.diagram(
  [#todo[CeTZ: 32 banks 环形映射；同一 bank 不同地址 = conflict，同地址 = broadcast。]],
  [#todo[高 aggregate bandwidth，而不是 32 个完全独立任意地址端口。]],
)

== Episode 5 — Transpose 微基准与 Padding
// 内容：code/memory-layout T0–T4；[32][32] vs [32][33]；
//       Source page actual/ideal/excessive wavefronts。
#layouts.code-compare(
  [#todo[code-block: #raw("__shared__ float tile[32][32];") 列访问冲突。]],
  [#todo[code-block: #raw("__shared__ float tile[32][33];") row stride +1 打散冲突。]],
)

== Episode 6 — Register File 与 Microtiles
// 内容：每线程多输出；acc[TM][TN] 在 register；shared bytes/FLOP 下降；ILP 增加；
//       代价是 register pressure / occupancy / spill 风险。
#layouts.code-focus(
  [#todo[code-block: V3/V4 outer-product 主循环（reg_a/reg_b/acc）。]],
  [#todo[HBM/L2 → shared 捕获 block-level reuse；shared → register 捕获 thread-level reuse。]],
)

== Episode 7 — L2 Locality 与 Block Ordering (附录)
// 内容：可选拓展。block swizzle 只提高 locality 概率，不保证执行顺序/cache hit。
#layouts.full(
  role: "figure",
  [#todo[physical blockIdx → logical tile 的映射；只谈概率，不保证顺序。]],
)


// ============================================================================
// Part 3 — reduce
//
// 把 Part 1 的"在飞字节"与 Part 2 的 shared memory / bank 知识用到一个
// 有跨线程依赖的 workload 上：竞争往下推一层，代价小一个数量级。
// ============================================================================
= Part 3 — reduce

#section-intro(
  objective: [在一个有跨线程归约依赖的 workload 上复用前两部分的推理链。],
  question: [竞争应该发生在哪一层？每往下推一层能省多少？],
)


== reduce: 问题
// 内容：求和；实测环境说明。
#layouts.full(
  role: "figure",
  placement: center + horizon,
  [
    #align(center)[
      #text(size: 0.92em)[给定长度 $N$ 的数组，求和：]
      #v(0.8em)
      #text(size: 1.15em)[$ "out" = sum_(i=0)^(N-1) x_i $]
      #v(1.0em)
      #note[
        实测环境：NVIDIA A100 80GB PCIe · CUDA 12.9 · $N = 2^26$（256 MB, float32）
      ]
      #v(0.4em)
      #chip("A100 measured")
    ]
  ],
)

== V1: 每个线程一次 atomicAdd
// 内容：最直接的并行化；197 ms，1.4 GB/s，慢了三个数量级。
#layouts.split(
  [
    #code.code-block(numbers: false)[
      ```cuda
      __global__ void reduce_v1(
          const float* x, float* out, int n)
      {
          int i = blockIdx.x * blockDim.x
                + threadIdx.x;
          if (i < n)
              atomicAdd(out, x[i]);
      }
      ```
    ]
    #v(0.5em)
    #text(size: 0.80em)[
      最直接的并行化：$N$ 个线程，
      每个线程把自己那个数加到#accent[同一个地址]上。
      正确性由硬件保证 —— `atomicAdd`
      的读-改-写不会被打断。
    ]
    #v(0.45em)
    #callout("实测 197 ms，1.4 GB/s")[
      #text(size: 0.80em)[慢了三个数量级。]
    ]
  ],
  [#image("assets/reduce_cpu_1.png", width: 78%)],
  ratio: (1.06fr, 1fr),
  secondary-align: center + horizon,
)

== V1 为什么这么慢
// 内容：原子加在 L2 slice 上完成；同一地址的请求必须排队串行。
#layouts.split(
  [
    #text(size: 0.80em)[
      原子加#accent[不是在线程里做的]。SM 把
      「地址 + 操作数 + 操作码」打包成请求，
      送到该地址所属的 #accent[L2 slice]，
      由 L2 里的 ALU 完成读-改-写。
    ]
    #v(0.4em)
    #text(size: 0.80em)[
      原子性来自#accent[只有一个执行点]，不需要锁 ——
      但同一个地址的请求也因此必须#accent[排队串行]。
    ]
    #v(0.45em)
    #callout("瓶颈在哪")[
      #text(size: 0.78em)[
        不是带宽，也不是延迟，
        而是#accent[单个 L2 slice 对同一地址的 RMW 吞吐]。
      ]
    ]
    #v(0.4em)
    #code.code-block(numbers: false)[
      ```
      l1tex__t_requests_..._op_red = 131,072
      lts__t_sectors_op_red        = 7,560,448
      ```
    ]
    #v(0.2em)
    #note[每个请求在 L2 上放大 58 倍，全部堆在一个地址上排队 #h(0.4em) #chip("NCU model")]
  ],
  [#atomic-serialization-figure()],
  ratio: (1.1fr, 1fr),
  secondary-role: "canvas",
  secondary-align: center + horizon,
)



== V2: Shared Memory 树形归约
// 内容：block 内先归约成 1 个数再 atomic 一次；原子操作从 N 降到 N/256。
#layouts.split(
  [
    #code.code-block(numbers: false)[
      ```cuda
      __shared__ float s[BLOCK];
      int tid = threadIdx.x;
      int i = blockIdx.x*blockDim.x + tid;
      s[tid] = (i < n) ? x[i] : 0.0f;
      __syncthreads();

      for (int stride = 1;
           stride < blockDim.x; stride *= 2) {
          if (tid % (2*stride) == 0)
              s[tid] += s[tid + stride];
          __syncthreads();
      }
      if (tid == 0) atomicAdd(out, s[0]);
      ```
    ]
    #v(0.4em)
    #text(size: 0.80em)[
      每个 block 先在#accent[自己的 smem 里]归约成 1 个数，再 atomic 一次。
      原子操作从 $N$ 次降到 $N\/256$ 次。
    ]
    #v(0.3em)
    #note[1.67 ms，160 GB/s —— 比 V1 快 #accent[118 倍]]
  ],
  [#image("assets/reduce_gpu_3.png", width: 88%)],
  ratio: (1.06fr, 1fr),
  secondary-align: center + horizon,
)

== V2 的问题: 活跃线程是散开的
// 内容：tid % (2*stride) == 0 → 活跃线程均匀散布；整个 warp 都被调度。
#layouts.split(
  [
    #text(size: 0.80em)[
      看图里圈出的线程号：`0, 2, 4, 6, ...`
    ]
    #v(0.35em)
    #text(size: 0.80em)[
      条件是 `tid % (2*stride) == 0`，
      活跃线程#accent[均匀散布在整个 block 里]。
    ]
    #v(0.35em)
    #text(size: 0.80em)[
      一个 warp 的 32 个 lane 中，第一轮只有 16 个干活，第二轮 8 个……
      但#accent[整个 warp 都必须被调度]，没干活的 lane 只是被 predicate 掉。
    ]
    #v(0.45em)
    #callout("代价在指令条数上")[
      #text(size: 0.80em)[
        V2 执行了 #accent[1.55 亿] 条 warp 指令。
      ]
    ]
  ],
  [#lane-occupancy-figure()],
  ratio: (1fr, 0.92fr),
  secondary-role: "canvas",
  secondary-align: center + horizon,
)

== V3: 让活跃线程连续
// 内容：idx = 2*stride*tid；后面的 warp 可以整个退出；指令数 ÷2.5。
#layouts.split(
  [
    #code.code-block(numbers: false)[
      ```cuda
      for (int stride = 1;
           stride < blockDim.x; stride *= 2) {
          int idx = 2 * stride * tid;
          if (idx < blockDim.x)
              s[idx] += s[idx + stride];
          __syncthreads();
      }
      ```
    ]
    #v(0.45em)
    #text(size: 0.80em)[
      改用 `idx = 2*stride*tid`：干活的是 #accent[tid 0,1,2,3...]，连续。
    ]
    #v(0.35em)
    #text(size: 0.80em)[
      图里圈出的线程号变成了 `0, 1, 2, 3, ...` ——
      后面的 warp 可以#accent[整个退出]。
    ]
    #v(0.35em)
    #text(size: 0.80em)[
      指令数从 1.55 亿降到 #accent[6167 万]（÷2.5）。
    ]
    #v(0.3em)
    #note[0.87 ms，308 GB/s —— 比 V2 快 #accent[1.9 倍]]
  ],
  [#image("assets/reduce_gpu_4.png", width: 88%)],
  ratio: (1.06fr, 1fr),
  secondary-align: center + horizon,
)

== 但 V3 引入了 bank conflict
// 内容：V3 的 bank conflict 多 170 倍，但仍然更快；指令数是主导。
#layouts.compare(
  [
    #text(size: 0.80em)[
      `s[idx]`，`idx = 2*stride*tid` —— 访问是#accent[跨步的]。
    ]
    #v(0.35em)
    #text(size: 0.80em)[
      smem 有 32 个 bank，跨步 2 → 一半 lane 撞同一 bank，
      跨步 4 → 1/4……#accent[一次请求要拆成多个 wavefront]。
    ]
    #v(0.5em)
    #metric-table(
      size: 0.68em,
      columns: (auto, auto, auto),
      align: (left, right, right),
      [], [bank conflict], [wavefront/请求],
      [V2], [40 093], [1.01],
      [*V3*], [#text(fill: palette.teal)[6 934 667]], [#text(fill: palette.teal)[1.49]],
      [V4], [34 354], [1.01],
    )
  ],
  [
    #callout("一个值得注意的细节")[
      #text(size: 0.80em)[
        V3 的 bank conflict 比 V2 #accent[多了 170 倍]，但它仍然#accent[更快]。
      ]
      #v(0.3em)
      #text(size: 0.80em)[
        因为 V2 的瓶颈是#accent[指令条数]（1.55 亿），
        V3 用 2.5× 的指令削减，盖过了 conflict 带来的 1.49× wavefront 放大。
      ]
    ]
    #v(0.45em)
    #note[
      V3 比 V4 多出的 699 万个 wavefront，
      与它的 693 万次 bank conflict 几乎完全对应。
    ]
  ],
)

== V4: Sequential Addressing
// 内容：stride 从大到小折半；同时消掉 divergence 与 bank conflict。
#layouts.split(
  [
    #code.code-block(numbers: false)[
      ```cuda
      for (int stride = blockDim.x / 2;
           stride > 0; stride >>= 1) {
          if (tid < stride)
              s[tid] += s[tid + stride];
          __syncthreads();
      }
      ```
    ]
    #v(0.45em)
    #text(size: 0.80em)[
      stride #accent[从大到小折半]，活跃线程始终是#accent[前 stride 个]。
    ]
    #v(0.4em)
    #text(size: 0.80em)[
      两个好处同时拿到：
      - 活跃线程连续 → #accent[无 divergence]
      - `s[tid]` 连续访问 → #accent[无 bank conflict]
    ]
    #v(0.35em)
    #note[bank conflict: 693 万 → 3.4 万 #h(0.6em) 0.78 ms，344 GB/s]
  ],
  [#image("assets/reduce_gpu_5.png", width: 88%)],
  ratio: (1.06fr, 1fr),
  secondary-align: center + horizon,
)

== V5: 让每个线程多干活
// 内容：grid-stride 循环；全场最大的一步（3.1×）。
#layouts.split(
  [
    #text(size: 0.80em)[
      前面几版都是#accent[一个元素一个线程]，
      $2^26$ 个元素要开 26 万个 block。
      而且载入后第一轮就有一半线程闲置。
    ]
    #v(0.4em)
    #text(size: 0.80em)[
      改成#accent[固定网格 + grid-stride 循环]：每个线程先串行累加多个元素。
    ]
    #v(0.4em)
    #code.code-block(numbers: false)[
      ```cuda
      float sum = 0.0f;
      for (int i = blockIdx.x*blockDim.x + tid;
           i < n; i += gridDim.x*blockDim.x)
          sum += x[i];
      s[tid] = sum;
      __syncthreads();
      // ... 之后照常折半归约
      ```
    ]
  ],
  [
    #callout("这一步是全场最大的提升")[
      #text(size: 0.92em)[0.78 ms → #accent[0.25 ms]]
      #v(0.2em)
      #text(size: 0.82em)[344 GB/s → #accent[1074 GB/s]]
    ]
    #v(0.5em)
    #text(size: 0.78em)[
      原因：
      - 每线程有#accent[多个独立的加法在飞] → 访存并行度（MLP）上来了
      - block 数固定为 SM×16，#accent[不再有启动开销和尾部效应]
      - 归约的树只需要做#accent[一次]，而不是 26 万次
    ]
    #v(0.45em)
    #note[指令数：5276 万 → #accent[560 万]（÷9.4）]
  ],
  ratio: (1.05fr, 1fr),
  secondary-align: center + horizon,
)

== V6: Warp Shuffle
// 内容：warp 内直接交换寄存器，不经过 shared memory。
#layouts.split(
  [
    #text(size: 0.80em)[
      折半归约到 `stride ≤ 16` 时，参与的线程#accent[全在一个 warp 内]。
    ]
    #v(0.35em)
    #text(size: 0.80em)[
      warp 内的 32 个 lane 可以#accent[直接交换寄存器]，
      根本不需要经过 shared memory。
    ]
    #v(0.4em)
    #code.code-block(numbers: false)[
      ```cuda
      __device__ float warp_reduce_sum(float v)
      {
      #pragma unroll
          for (int off = 16; off > 0; off >>= 1)
              v += __shfl_xor_sync(0xffffffff,
                                   v, off);
          return v;
      }
      ```
    ]
    #v(0.25em)
    #note[SASS: `SHFL.BFLY PT, R3, R4, 0x10, 0x1f`]
  ],
  [#shuffle-vs-smem-figure()],
  ratio: (1fr, 0.95fr),
  secondary-role: "canvas",
  secondary-align: center + horizon,
)

== Shuffle 指令族
// 内容：四条指令的语义与典型用途。
#layouts.stack(
  top-role: "plain",
  bottom-role: "card",
  [
    #code.code-block(numbers: false)[
      ```cuda
      T __shfl_sync     (unsigned mask, T var, int srcLane,    int width = 32);
      T __shfl_up_sync  (unsigned mask, T var, unsigned delta, int width = 32);
      T __shfl_down_sync(unsigned mask, T var, unsigned delta, int width = 32);
      T __shfl_xor_sync (unsigned mask, T var, int laneMask,   int width = 32);
      ```
    ]
  ],
  [
    #text(size: 0.80em)[
      语义统一：#accent[每个 lane 交出自己的 `var`，再按规则取回某个 lane 的值]。
      #h(0.5em) #chip("CUDA contract")
    ]
    #v(0.35em)
    #metric-table(
      size: 0.68em,
      columns: (auto, 1fr, auto),
      align: (left, left, left),
      [指令], [lane $i$ 拿到谁的值], [典型用途],
      [`__shfl_sync`], [lane `srcLane`（任意指定）], [广播、置换],
      [`__shfl_up_sync`], [lane $i -$ `delta`], [prefix sum、stencil],
      [`__shfl_down_sync`], [lane $i +$ `delta`], [归约（结果在 lane 0）],
      [`__shfl_xor_sync`], [lane $i xor$ `laneMask`], [蝶形归约（全 lane 得结果）],
    )
    #v(0.3em)
    #align(center)[
      #note[越界的 lane（如 up 时 $i <$ delta）#emph[保留自己原来的值]，不是 0]
    ]
  ],
)

== 蝶形归约的过程
// 内容：xor 全 lane 得结果 vs down 只有 lane 0 有效。
#layouts.stack(
  rows: (62%, auto),
  top-role: "canvas",
  bottom-role: "plain",
  [#butterfly-figure()],
  [
    #v(0.3em)
    #layouts.compare(
      [
        #text(size: 0.78em)[
          *`xor`（蝶形）*：#accent[所有 lane] 都拿到结果。
          后面每个 lane 都要用这个值时（softmax 除以 sum）省一次广播。
        ]
      ],
      [
        #text(size: 0.78em)[
          *`down`（折半）*：只有 #accent[lane 0] 有效。
          指令条数完全相同，选哪个取决于#accent[结果要出现在几个 lane 上]。
        ]
      ],
      panel: false,
    )
    #v(0.25em)
    #align(center)[#note[图示 width = 8；实际 warp 为 32，5 轮完成]]
  ],
)

== mask 与 width
// 内容：mask 在分支内部写全 1 是未定义行为；width 把 warp 切成子段。
#layouts.compare(
  [
    #kicker[`mask`：哪些 lane 参与这条指令]
    #v(0.35em)
    #text(size: 0.78em)[
      - 通常写 `0xffffffff`（全 32 个 lane）
      - 但在#accent[分支内部]，若有 lane 没执行到这条指令，
        写全 1 是#accent[未定义行为]
      - 此时应当用 `__activemask()`，或精确的常量掩码
    ]
    #v(0.45em)
    #callout("Volta 之后")[
      #text(size: 0.76em)[
        independent thread scheduling 引入后，warp 内不再保证隐式锁步，
        旧的无 `_sync` 版本 `__shfl` #accent[已被移除]。
        忘记 mask 是一个很隐蔽、且只在特定 GPU 上复现的 bug。
      ]
    ]
  ],
  [
    #kicker[`width`：把 warp 切成若干子段]
    #v(0.35em)
    #text(size: 0.78em)[
      - 默认 32；设为 8 则 warp 分成 4 段，
        shuffle #accent[只在段内进行]
      - 适合「每 8 个 lane 处理一行」这类布局
    ]
    #v(0.45em)
    #note[
      两个参数都属于 CUDA 编程契约，不随架构变化 ——
      但它们保证的是#emph[正确性]，不是性能。
    ]
  ],
)

== V6 完整实现: 两级归约
// 内容：warp 内 shuffle → 每 warp 写 1 个值 → 第一个 warp 再归约一次。
#layouts.stack(
  top-role: "plain",
  bottom-role: "plain",
  [
    #code.code-block(numbers: false)[
      ```cuda
      __global__ void reduce_v6(const float* x, float* out, int n) {
          float sum = 0.0f;
          for (int i = blockIdx.x * blockDim.x + threadIdx.x; i < n;
               i += gridDim.x * blockDim.x)
              sum += x[i];

          sum = warp_reduce_sum(sum);              // ① warp 内：纯 shuffle

          __shared__ float warp_sum[32];           // 一个 block 最多 32 个 warp
          int lane = threadIdx.x & 31, wid = threadIdx.x >> 5;
          if (lane == 0) warp_sum[wid] = sum;      // ② 每 warp 写 1 个值
          __syncthreads();                         //    整个 kernel 只同步一次

          if (wid == 0) {                          // ③ 第一个 warp 再归约一次
              sum = (lane < blockDim.x / 32) ? warp_sum[lane] : 0.0f;
              sum = warp_reduce_sum(sum);
              if (lane == 0) atomicAdd(out, sum);
          }
      }
      ```
    ]
  ],
  [
    #align(center)[
      #note[
        smem 用量 4 KB → #accent[128 B]；`__syncthreads()` 8 次 → #accent[1 次]
      ]
    ]
  ],
)

== V7: 再加上向量化访存
// 内容：float4 读输入；83.9% of DRAM peak，compute 仅 10.1%。
#layouts.split(
  [
    #text(size: 0.80em)[
      到 V6 为止，瓶颈已经完全回到#accent[读输入]上了。
      一次 `float4` 读 16 字节，#accent[指令条数减少到 1/4]。
    ]
    #v(0.4em)
    #code.code-block(numbers: false)[
      ```cuda
      const float4* x4 = (const float4*)x;
      for (int i = ...; i < n4; i += stride) {
          float4 v = x4[i];
          sum += v.x + v.y + v.z + v.w;
      }
      ```
    ]
    #v(0.35em)
    #note[指令数 460 万 → 185 万]
  ],
  [
    #callout("0.17 ms，1572 GB/s")[
      #text(size: 0.80em)[
        ncu 报告：#accent[83.9% of DRAM peak]
        #v(0.2em)
        Compute throughput 仅 10.1%
      ]
    ]
    #v(0.5em)
    #sol-bars-figure()
  ],
  ratio: (1.05fr, 1fr),
  secondary-align: center + horizon,
)

== 实测结果
// 内容：V1→V7 完整表 + 带宽柱状图。
#layouts.stack(
  top-role: "card",
  bottom-role: "canvas",
  [
    #metric-table(
      size: 0.62em,
      columns: (auto, auto, auto, auto, auto, auto),
      align: (left, right, right, right, right, center),
      [版本], [时间], [带宽], [vs V1], [warp 指令], [结果正确],
      [V1 global atomic], [197.4 ms], [1.4 GB/s], [1×], [—], [#text(fill: palette.teal)[✗]],
      [V2 smem，散开], [1.67 ms], [161 GB/s], [118×], [1.55 亿], [✓],
      [V3 连续线程], [0.87 ms], [308 GB/s], [227×], [6167 万], [✓],
      [V4 sequential], [0.78 ms], [344 GB/s], [253×], [5276 万], [✓],
      [V5 grid-stride], [0.25 ms], [1074 GB/s], [790×], [560 万], [✓],
      [V6 warp shuffle], [0.247 ms], [1087 GB/s], [799×], [460 万], [✓],
      [*V7 + float4*], [*0.17 ms*], [*1572 GB/s*], [*1156×*], [185 万], [✓],
    )
    #v(0.2em)
    #note[
      A100 80GB PCIe · $N = 2^26$ · 20 次平均 · 排序在 $2^22 tilde 2^28$ 范围内稳定
      #h(0.4em) #chip("A100 measured")
    ]
  ],
  [#reduce-bandwidth-figure()],
)

== 小结
// 内容：五条收束；竞争往下推一层，代价小一个数量级。
#layouts.full(
  role: "figure",
  [
    #text(size: 0.82em)[
      + *reduce 的上限是把输入读一遍的时间*，所有优化都在逼近这条线
      + *V1 的问题不是带宽，是竞争*：原子操作在 L2 上串行，
        而且 float32 累加到 $2^24$ 就#accent[停止增长]
      + *V2→V3 的收益来自指令数，不是 divergence 本身*：
        V3 的 bank conflict 反而多了 170 倍，但指令少了 2.5 倍，所以更快
      + *V4 同时消掉两者*；#accent[V5 的 grid-stride 是全场最大的一步]（3.1×）
      + *V6 用 shuffle 省掉同步和 smem*，为后续融合（softmax / norm）留出空间
    ]
    #v(0.55em)
    #align(center)[
      #text(size: 0.95em, fill: palette.orange, weight: "bold")[
        竞争往下推一层，代价小一个数量级
      ]
    ]
  ],
)


== NCU 详细走查
// 内容：完整 ncu 命令与 section 解读：SpeedOfLight / MemoryWorkload /
//       SchedulerStats / WarpStateStats / SourceCounters；
//       固定分析顺序：Duration → SOL → Memory → Scheduler → Warp → Source → Occupancy。
#layouts.code-focus(
  [#todo[code-block: 一条典型 ncu 命令行（--section 列表）。]],
  [#todo[解释指标：sectors、Long/Short Scoreboard、excessive wavefronts、% peak。]],
)


// ============================================================================
// Act III — Rebuild
// ============================================================================
= Act III — Rebuild

#section-intro(
  objective: [按 V0 → V6 重建 kernel，用 correctness harness 与 NCU 验证瓶颈迁移。],
  question: [每一步在消除哪个瓶颈？下一个瓶颈是什么？],
)

== 通用 Kernel 设计流程
// 内容：identify reuse → 选择协作作用域 → 放到匹配 memory level →
//       warp lane 映射 → 物理资源检查 → 保留足够独立工作 → 测量验证。
#layouts.triptych(
  [#todo[Workload: 找出复用、判断 scope。]],
  [#todo[Hardware: 放到匹配的 memory level、按 warp 推 lane 映射。]],
  [#todo[Measurement: 检查 banks/registers、保留 in-flight work、NCU 验证。]],
)

== V0 — Naive GEMM
// 内容：一行程一个输出；block(16,16)；主要问题不是 uncoalesced，而是未捕获 reuse。
#layouts.code-focus(
  [#todo[code-block: gemm_v00_naive 内核。]],
  [#todo[AI_code ≈ 0.25；预期 NCU：global loads 多、Long Scoreboard 可能高、FP32 利用率低。]],
)

== V1 — Warp-Friendly Mapping
// 内容：交换 threadIdx.x / threadIdx.y；controllled bad mapping 作反例；
//       分析单位是一条 warp instruction 的 lane-address set。
#layouts.code-compare(
  [#todo[code-block: 错误 mapping（threadIdx.x → row）。]],
  [#todo[code-block: 修正 mapping（threadIdx.x → col）。]],
)

== V2 — Shared-Memory Block Tiling
// 内容：BM=BN=BK=32, 1024 threads；两个 barrier；AI_global-to-shared = 8。
//       仍非高性能形态（每线程一输出、shared load/FMA 比例高）。
#layouts.code-focus(
  [#todo[code-block: V2 tiled 主循环。]],
  [#todo[预期 NCU：DRAM/L2 bytes 下降、AI_HBM 上升、shared/barrier 开始可见。]],
)

== V3 — 1D Register Tiling
// 内容：一个线程算 TM×1 输出；一个 B shared load 服务 8 个 FMA；
//       shared bytes/FLOP 下降、ILP 增加。
#layouts.code-focus(
  [#todo[code-block: V3 1D register 主循环。]],
  [#todo[shared tiling 减 global traffic；register tiling 开始减 shared traffic。]],
)

== V4 — 2D Register Outer Product
// 内容：TM=TN=8，acc[8][8]；AI_shared,requested = 2 FLOP/byte；代价：register pressure、
//       连续 microtile 导致 B bank conflict。
#layouts.code-focus(
  [#todo[code-block: V4 outer-product 主循环。]],
  [#todo[提高 register reuse 的 ownership 不一定天然适合 shared banks。]],
)

== V5 — Vectorized Global Loads
// 内容：float4 加载；减少 LDG 指令/地址计算/LSU 压力；不一定减少 sectors/DRAM bytes。
#layouts.code-focus(
  [#todo[code-block: V5 load_A_tile / load_B_tile 的 float4 路径。]],
  [#todo[Vector width 与 warp-level coalescing 是不同问题。]],
)

== V6 — Bank-Aware Lane Ownership
// 内容：striped ownership（row = tr + i*16, col = tc + j*16）；B 变 multicast；
//       C store 仍 coalesced；自然布局无需 padding。
#layouts.code-focus(
  [#todo[code-block: V6 striped 主循环 + C store。]],
  [#todo[Thread tile 同时规定 register reuse、shared banks 与 global coalescing。]],
)

== NCU 验证工作流
// 内容：固定分析顺序 + 建议 section 列表；performance 来自 CUDA events，
//       NCU 只用来解释；不要用 replay duration 当 benchmark。
#layouts.code-focus(
  [#todo[code-block: 一条完整 ncu 命令行（--section ... -o ...）。]],
  [#todo[顺序: Duration → SOL → Memory → Scheduler → Warp → Source → Occupancy。]],
)

== 结果与验收标准
// 内容：4096³ 实测表（V0–V6 + pedantic FP32 cuBLAS 76%）；验收等级；
//       明确测量边界：GPU/CC/CUDA/NCU/clock/warmup/iters。
#layouts.full(
  role: "figure",
  [#todo[表格: V0 0.43 → V6 10.97 TFLOP/s；cuBLAS pedantic 14.41；76%。]],
)

// ============================================================================
// Summary & Takeaways
// ============================================================================
= Summary

#section-intro(
  variant: "minimal",
)

== Takeaways
// 内容：Reuse tells us what to keep close; hardware tells us where it can stay.
//       瓶颈迁移：HBM/L2 → shared → registers → FP32 pipelines。
#layouts.full(
  role: "figure",
  [#todo[三条 takeaway 收束 + 瓶颈迁移图。]],
)

== 后续课程接口
// 内容：cp.async / LDGSTS / TMA / double buffering / software pipeline / Tensor Core
//       只预告要解决什么问题。
#layouts.full(
  role: "figure",
  [#todo[当前 load→wait→compute→wait→load；后续如何隐藏剩余数据移动。]],
)

// ============================================================================
// Appendix — 60 分钟裁剪与延后主题
// ============================================================================
= Appendix

#section-intro(variant: "minimal")

== 裁剪与延后主题
// 60 分钟版本：L2 ordering、register spilling、swizzle 实现、hierarchical Roofline 进附录。
#layouts.full(
  role: "figure",
  [#todo[60 分钟裁剪清单 + 延后主题（双缓冲、cp.async、TMA、Tensor Core）。]],
)

== Hierarchical Roofline (Multi-Boundary)
// 内容：AI_HBM / AI_L2 / AI_shared,requested 使用不同 byte denominator，
//       不能无说明地画在同一 AI 横轴。
#layouts.diagram(
  [#todo[CeTZ: 多边界 roofline 的层级示意。]],
  [#todo[不同 memory level 用不同 denominator；shared roof 是 pattern-specific 课程模型。]],
)

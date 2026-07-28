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
// Labs — 同学详细例子 (saxpy / reduce / NCU)
// ============================================================================
= Labs: 详细例子

#section-intro(
  variant: "question",
  question: [三个小例子如何用同一套 NCU 推理链解释？],
)

== Lab — saxpy: 内存受限 kernel
// 内容：y = a*x + y；每 element 2 FLOP / 8+ bytes；AI 很低；
//       DRAM/L2 throughput 饱和 → bandwidth-bound；coalescing 是关键。
#layouts.diagram(
  [#todo[CeTZ: saxpy 的 element→byte 映射 + AI 数量级。]],
  [#todo[测 DRAM bytes、sectors、duration；解释为何 memory-bound。]],
)

== Lab — reduce: 延迟隐藏与 occupancy
// 内容：reduction 是 occupancy/latency 教学案例；block-level tree reduce、
//       shared memory 聚合、warp-level reduce；观察 eligible warps / Long Scoreboard。
#layouts.code-focus(
  [#todo[code-block: 一个 tree reduce 内核（shared + syncthreads）。]],
  [#todo[比较不同 blocks/threads 下 eligible warps、issue rate、duration。]],
)

== Lab — NCU 详细走查
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

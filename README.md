# Session 2: Memory Abstraction & Hierarchy

**Weiming HPC Training Camp × LCPU AI Infra Seminars**

## Overview

本讲目标是让大家学会 memory hierarchy，并且能写出一个 CUDA core FP32 GEMM 并懂得其中的优化技巧；同时建立一个硬件出发的理解，知道 coalesce、bank conflicts、latency hiding 之类分别都对应什么硬件设计问题。

选择 CUDA core FP32 GEMM 是因为这是接触 data reuse，进而了解 memory abstraction 的最简例子，同时 FP32 本身把 tensor core 和流水之类的内容推后了，也做一个零前置知识的铺垫。

**主线思路**: Workload → Hardware → Measurement/Profiling/Writing Kernel

## Schedule (Tentative)

为了把这团互相依赖的知识拆成一个 DAG，采用逐层递进的形式：
1. 先总体讲 GEMM evolution，从 strawman GEMM 到 data reuse
2. 从硬件视角讲 SM 的结构（硬件限制来自哪里，硬件 trade-off）
3. 最后讲一个完整 kernel 的写法以及调优

### Act I — GEMM Evolution Preview

- 从计算语义出发，先写个每线程负责一个元素的 strawman GEMM（15-779 的例子）
- 考虑 C[i,j] 和 C[i, j+1] 的数据复用，引出"搬入的数据是否服务了足够多的 FMA"
- 复习 shared memory 等内容，并指出可以用这个 scratchpad 复用数据
- 引入 Roofline Model，并定量分析 tiling 的 data reuse 数量级
- LLM Workload 中的 GEMM："权重量化和 speculative decoding 就是在 roofline 上往右挪"

### Act II — Hardware Explanation

1. **Warp 执行和 Coalescing**
   - 回顾 SIMT：软件上期望有成千上万的逻辑 threads，但硬件不能都有自己的 instruction fetch、scheduler、memory port（面积、功耗成本）
   - 软件写的是 scalar-thread 式代码，但必须意识到硬件以 warp 为主要的执行和发射单位
   - 认识到需要规则的控制流和地址模式

2. **SMSP, Warp Scheduling, and Latency Hiding**
   - 即使访存 coalesced，一次 HBM/L2 miss 仍然非常长，如何避免 SM 完全停住？
   - SM 的（教学简化）模型：4 个 SMSP，resident warps 每 issue cycle 被 scheduler 选出 eligible 的
   - In-Flight Bytes（Occupancy × MLP），覆盖延迟
   - Occupancy：提供候选的 resident warps，有限的 on-chip 资源和 occupancy 的 trade-off (revisit roofline)

3. **Shared Memory 语义和 Tiling**
   - Shared Memory 可以被理解为硬件管理的 L1 cache 被分了一部分
   - 为什么 cache 不能完全代替 shared memory？机会性 vs 几乎固定的规整 workload，程序显式表达
   - Shared Memory 的可见性与 `__syncthreads`

4. **Banked Shared Memory (Padding & Swizzle)**
   - 为什么 shared memory 在片上，但还是可能因为地址模式变慢？
   - 一个真正支持 32 个独立并发 read port 的 SRAM 带来很高的面积和 routing 成本，实际做法是划分成 banks
   - 调整访问模式来适应 bank 结构
   - 数学 trick：padding 和 XOR 如何打乱访问顺序

5. **Register File and Per-thread Microtiles**

6. **(附录) L2 Locality and Block Ordering**
   - Block 间仍会有相同 A/B tiles 读取，device-wide 地看还有 L2
   - 目标：让时间上相近的 CTA 访问的 working set 尽可能小

### Act III — Writing/Profiling

- 决定 CTA 计算哪个 C tile
- 决定 thread microtile
- Warp Lanes 映射到输出坐标，尽可能 coalesce
- 协作加载 A/B tiles
- 选择 shared memory physical layout
- 根据片上资源 tune 各种 tile 大小和资源分配的选择
- **需要附有 NCU 实践**（至少以截图形式）

## Repository Structure

```
.
├── README.md          # This file
├── slides/            # Presentation materials
├── code/              # CUDA kernel implementations
│   ├── 00-strawman-gemm/
│   ├── 01-tiled-gemm/
│   └── 02-optimized-gemm/
├── exercises/         # Hands-on exercises
└── references/        # Reference materials and papers
```

## Contributors

- @周宇轩
- @林若瑜

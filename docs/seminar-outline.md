# CUDA Memory Hierarchy Seminar

## 课程定位

这是 CUDA 和并行编程简介之后的第二讲。本讲围绕非 Tensor Core FP32 GEMM，讨论如何利用 memory hierarchy 设计和优化 CUDA kernel。

本讲不以罗列硬件参数或优化技巧为目标，而是建立一套从 workload 到 hardware、再到 measurement 的推理方式：

> Workload 决定哪些数据值得复用；硬件决定数据能放在哪一层、怎样被并行访问，以及这种放置会消耗什么资源。

最终希望听众能够回答：

1. 一个 kernel 的主要数据复用在哪里？
2. 这些复用应放在 register、shared memory、cache 还是更高层处理？
3. warp 的线程到数据映射是否适合 memory coalescing？
4. shared-memory layout 是否适合 banked SRAM？
5. register/shared-memory 使用是否保留了足够的 resident 和 eligible warps？
6. 如何用 Nsight Compute 验证瓶颈及其迁移？

后续课程再深入讨论 Tensor Core、`cp.async`、LDGSTS、TMA、double buffering 和 software pipelining。本讲仅在结尾说明这些机制要解决什么问题。

### 本课的四层证据

1. **CUDA programming contract**：thread/block/warp 语义、shared-memory scope、同步语义等，CUDA 程序可以依赖这些语义保证正确性。
2. **Architecture-scoped documented model**：例如 CC 6.0+ 的 global coalescing 规则、目标架构的 shared-bank 组织和 A100 资源容量。必须注明 compute capability 或 GPU 范围。
3. **Tool/version-scoped metric model**：例如指定 NCU 版本中的 request、sector、wavefront、stall reason 和 counter 定义。
4. **Course measurement**：指定 GPU、SASS、输入、工具版本和测量设置得到的 counter 与性能结果；不视为架构常数或 NVIDIA 规定的优化顺序。

---

## 核心教学结构

整讲采用三幕结构：

1. **Act I: Preview**：从 GEMM workload、数据复用和 Roofline 出发，先建立完整优化地图。
2. **Act II: Explain**：逐层打开 GPU 硬件，用设计约束解释每项优化为什么存在。
3. **Act III: Rebuild**：重新组装一个 tiled GEMM，形成可迁移到其他 workload 的 kernel 设计流程。

这不是两条彼此独立的长线。第一幕回答 **what**，第二幕回答 **why**，第三幕回答 **how**。

```text
Workload and reuse
       |
       v
Simple Roofline and optimization preview
       |
       v
Hardware constraints explain each optimization
       |
       v
Rebuild the kernel and verify with NCU
```

---

# Act I: GEMM Evolution Preview

## 1. 从 GEMM Workload 开始

首先只建立计算语义：

\[
C_{ij}=\sum_{k=0}^{K-1}A_{ik}B_{kj}
\]

最简单的 CUDA 实现让每个线程计算一个输出元素：

```cpp
int row = blockIdx.y * blockDim.y + threadIdx.y;
int col = blockIdx.x * blockDim.x + threadIdx.x;

float acc = 0.0f;
for (int k = 0; k < K; ++k) {
    acc += A[row * K + k] * B[k * N + col];
}
C[row * N + col] = acc;
```

此时先不讨论 warp、cache 或 shared-memory banks，而是问三个 workload-level 问题：

1. 一个 `C[i,j]` 需要哪些 A 和 B 元素？
2. `C[i,j]` 和 `C[i,j+1]` 是否使用相同的数据？
3. `C[i,j]` 和 `C[i+1,j]` 是否使用相同的数据？

结论：

- 同一行的多个输出复用 A 的一行。
- 同一列的多个输出复用 B 的一列。
- 一个 `A[i,k]` 和一个 `B[k,j]` 都会参与多次乘加。
- GEMM 具有很强的算法级数据复用，但 naive implementation 不一定显式捕获这些复用。

> GEMM 的关键不只是存在大量 FMA，而是每次搬入的数据能否服务足够多的 FMA。

## 2. 第一次引入 Roofline

Roofline 在这里作为 workload reasoning tool，而不是完整的 profiler 模型。

定义 arithmetic intensity：

\[
AI=\frac{\text{useful computation}}{\text{data moved}}
\]

最简单的性能上界为：

\[
P\leq\min(P_{\text{compute peak}}, BW\times AI)
\]

第一遍只保留 HBM bandwidth roof 和 compute roof：

```text
Performance
    ^
    |                         compute roof
    |                    -------------------
    |                  /
    |                /
    |              /        compute-bound
    |            /
    |          / memory-bound
    +--------------------------------------> Arithmetic intensity
```

这一页只需要传达：

1. 每搬一个 byte 只做少量计算时，性能受数据移动限制。
2. data reuse 让同一份数据支持更多计算，从而提高 arithmetic intensity。
3. Roofline 给出吞吐上限，但尚不能解释 kernel 为什么低于这个上限。

## 3. GEMM 的 Roofline Paradox

GEMM 在算法层面具有很高的 arithmetic intensity。

若 A、B 各从 HBM 读取一次，C 写回一次：

\[
\text{Bytes}_{\min}\approx4(MK+KN+MN)
\]

因此：

\[
AI_{\text{algorithm}}
\approx
\frac{2MNK}{4(MK+KN+MN)}
\]

对于方阵 `M=N=K=N`：

\[
AI_{\text{algorithm}}\approx\frac{N}{6}
\]

但在忽略 cache reuse 的 naive 实现中，每个输出独立读取 K 个 A 和 K 个 B：

\[
\text{Bytes}_{\text{naive}}\approx8MNK
\]

\[
AI_{\text{naive, code}}\approx\frac{2MNK}{8MNK}=0.25\ \text{FLOP/byte}
\]

这里形成全讲的第一个核心反差：

```text
GEMM algorithm:
    high potential arithmetic intensity

Naive GEMM implementation:
    low code-level arithmetic intensity
```

需要明确：`0.25 FLOP/byte` 是忽略 cache reuse 的代码请求层面估算，不是实际 HBM traffic 的预测。

本课采用三种 arithmetic-intensity 分析口径；这不是 NCU 官方规定的三个 metric：

| 口径 | 含义 |
|---|---|
| Algorithmic AI | 在明确 `C=AB`、FP32、无需读取旧 C 的语义下，充分捕获复用后的数据移动下界 |
| Code-level AI | 根据源码或 SASS 的逻辑 load/store 估算，忽略 cache、transaction granularity、predication 和 replay |
| Measured AI | 同一测量范围内的 FLOPs 除以穿过某个明确 memory boundary 的实测 bytes |

> Arithmetic intensity 不只是 workload 的属性，也是 implementation 与某一级 memory hierarchy 之间的属性。

## 4. 用 Tiling 说明 Reuse 的数量级

考虑一个 block 计算 `T x T` 的 C tile，并处理宽度为 T 的 K tile。

计算量为：

\[
2T^3\ \text{FLOPs}
\]

若 A 和 B tile 各从 global hierarchy 加载一次：

\[
2T^2\times4\ \text{bytes}
\]

因此：

\[
AI_{\text{global-to-shared}}
=
\frac{2T^3}{8T^2}
=
\frac{T}{4}\ \text{FLOP/byte}
\]

例如 `T=32` 时约为 `8 FLOP/byte`，相比 naive 代码级估算的 `0.25 FLOP/byte` 提高约 32 倍。

此时只给 shared memory 一个 workload-level 定义：

> 我们需要一块 block 内线程都能访问的临时存储，使 A/B tile 只从较高层 memory hierarchy 搬入一次，然后被重复使用。CUDA 将这种显式管理的存储称为 shared memory。

不要在这里先强调 shared memory 的低延迟。它的首要价值是捕获 block-level reuse，减少高层数据移动。

## 5. GEMM Evolution Map

第一幕最后给出完整路线，但不展开硬件细节：

```text
V0: one thread computes one output
             |
             v
V1: choose a warp-friendly output mapping
             |
             v
V2: a block cooperatively computes a C tile
             |
             v
V3: stage A/B tiles in shared memory
             |
             v
V4: each thread computes multiple outputs
             |
             v
V5: refine shared-memory and block layouts
```

| 版本 | 第一遍只讲什么 |
|---|---|
| Naive GEMM | 每个线程独立计算一个输出 |
| Warp-friendly mapping | 相邻线程访问相邻数据 |
| Shared tiling | 一次加载，block 内多次使用 |
| Register blocking | 一个线程保存多个部分和，进一步复用 |
| Layout refinement | 逻辑矩阵不变，物理布局更适合硬件 |

第一幕结束时提出第二幕要回答的问题：

- 为什么 GPU 以 warp 为单位执行？
- 为什么相邻线程最好访问相邻地址？
- 为什么 HBM load 很慢时 SM 仍能继续工作？
- 为什么需要 programmer-managed shared memory，而不只依赖 cache？
- 为什么 tile 不能无限增大？
- 为什么 shared memory 还会有 bank conflict？

---

# Act II: Explain from Hardware

第二幕采用拉链式结构：每次从 GEMM 的一个现象开始，只打开解释该现象所需的一层硬件，然后回到 kernel 修改并用 NCU 验证。

```text
Observe a GEMM problem
        |
        v
Open one layer of hardware
        |
        v
Explain the design trade-off
        |
        v
Modify the kernel
        |
        v
Verify with NCU
```

## Episode 1: Warp Execution and Coalescing

### 问题

为什么只是交换 `threadIdx.x` 和 `threadIdx.y` 对应的数据维度，性能就可能明显变化？

### 硬件约束

如果每个 GPU thread 都拥有独立的 instruction fetch、复杂 scheduler 和任意 memory port，面积、功耗和布线成本都会过高。

GPU 采用 SIMT 折中：

```text
many scalar CUDA threads
          |
          v
32 threads form a warp
          |
          v
shared instruction issue and control
          |
          v
parallel execution lanes
```

软件仍然写 scalar-thread code，硬件以 warp 为主要执行和发射单位。规则的控制流和地址模式能够摊薄控制和数据移动成本；不规则模式仍然正确，但吞吐会下降。

### 为什么需要 Coalescing

一条 warp memory instruction 最多产生 32 个 lane addresses。两个极端方案都不理想：

```text
Expensive hardware:
32 lanes x fully independent cache/memory ports

Hard-to-program software:
programmer manually constructs every vector access

SIMT compromise:
software provides scalar addresses
hardware coalesces them into sectors
```

对本课程目标 A100（CC 8.0），CUDA Best Practices Guide 的 CC 6.0+ coalescing 规则可按覆盖 participating lanes 地址所需的 32-byte transactions 分析；在 NCU cache 指标中，对应的对齐 32-byte 数据块称为 sector：

```text
32 lanes x 4-byte contiguous load
    = 128 useful bytes
    = 4 aligned 32-byte sectors, if the first address is 32-byte aligned
```

coalescing 的分析单位是：

> 同一个 warp 执行同一条 memory instruction 时，所有 active lanes 的地址集合覆盖了多少个 sectors。

若首地址跨越额外的 32-byte boundary，同样的 128 useful bytes 会覆盖更多 sectors。不要将其简化为“一个 warp 总是合并成一个 128-byte transaction”。

| 术语 | 本课含义 |
|---|---|
| Warp memory instruction | 一个 warp 的 participating lanes 执行的一条 load/store |
| Request | NCU 的 Volta+ L1TEX 模型中，该 warp instruction 形成的请求 |
| Sector | NCU cache metric 中对齐的 32-byte 数据块 |
| Cache line | cache tag/data 组织单位；不是 warp request 或 DRAM burst 的同义词 |
| Transaction | 文档上下文相关；必须注明是 coalescing、层间还是 DRAM 层级 |
| Wavefront | NCU 中 L1TEX pipeline 的 work package |

对于无重复地址的简单 load/store，可近似定义：

\[
\text{sector utilization}
\approx
\frac{\text{unique requested bytes}}
{\text{number of sectors}\times32}
\]

若 lanes 读取重复地址，必须先说明 useful-byte 去重口径，不能直接按 lane bytes 求和。poor coalescing 的直接可见结果通常是更多 sectors per request。根据 cache 命中和 pipeline 限制，它还可能增加 wavefronts、下游 sectors/bytes、队列压力或依赖等待；这些后果必须分别测量。

### 回到 GEMM

推荐映射为：

```cpp
int row = blockIdx.y * blockDim.y + threadIdx.y;
int col = blockIdx.x * blockDim.x + threadIdx.x;
```

固定 `k` 时：

- `B[k, col]` 通常由连续 lanes 读取连续地址。
- `C[row, col]` 通常由连续 lanes 写连续地址。
- `A[row, k]` 在同一行的 lanes 中经常是相同 global address。就 coalescing 而言，这些地址通常只覆盖很少的 sectors，后续 reuse 可能由 cache 捕获；不要将其称为 shared-memory bank broadcast。

当前实践使用 `16 x 16` block，因此一个 warp 由两个相邻的 16-thread rows 组成，而不是固定对应完整的一行。A 通常形成两组同地址读取，B/C 则形成两组规整的 16-element 访问。

因此 naive GEMM 慢的主要原因通常不是所有访问都 uncoalesced，而是没有显式捕获跨输出的数据复用。

### 实验

先使用独立 copy microbenchmark 隔离 coalescing：

```cpp
out[i] = in[i];
```

对比 stride 或二维转置式访问。观察：

- actual/ideal/excessive sectors；
- useful bandwidth 和实际 DRAM traffic；
- L1TEX/L2/DRAM throughput；
- Long Scoreboard，但不单独据此下结论。

### Takeaway

> 在这里采用的 A100/NCU global-memory 模型中，以一条 warp memory instruction 的 participating-lane 地址集合分析 request formation 和 coalescing。

## Episode 2: SMSP, Warp Scheduling, and Latency Hiding

### 问题

即使访问已经 coalesced，一次 HBM 或 L2 miss 的延迟仍然很长。GPU 为什么没有完全停住？

### A100 的 SM 教学模型

在本课程目标 A100（GA100，CC 8.0）上，一个 SM 可按 4 个 processing partitions 理解；Nsight Compute 将这一层称为 SM subpartitions，即 SMSP：

```text
                              SM
       +------------+------------+------------+------------+
       |   SMSP 0   |   SMSP 1   |   SMSP 2   |   SMSP 3   |
       | scheduler  | scheduler  | scheduler  | scheduler  |
       | registers  | registers  | registers  | registers  |
       | FP/INT/... | FP/INT/... | FP/INT/... | FP/INT/... |
       +------------+------------+------------+------------+
                              |
                    L1TEX / shared subsystem
                              |
                              L2
```

更准确的表述是：

> 按 Nsight Compute 的模型，resident warps 被分配到 SM 内的 scheduler/SMSP。每个 scheduler 管理自己的 warp pool，从 eligible 集合中选择一个 issued warp，并从该 warp 发出一条或多条指令；没有 eligible warp 时，相应 issue slot 空置。

需要保留的限定：

- 不是一个 scheduler 从整个 SM 的所有 warps 中统一选择。
- `eligible` 比笼统的 `ready` 更准确。
- resident warp 的 PC、register state 等上下文保留在片上。
- scheduler 可以在连续 instruction-issue cycles 中选择不同 resident warps；这些 warps 的上下文已驻留片上，不需要 CPU OS-thread 式保存和恢复状态。
- 上述“无切换成本”只指 resident warps 之间的调度，不包括 GPU context switching、compute preemption 或罕见的 block suspension。
- “4 个 SMSP”是 A100 架构事实和 NCU profiler 模型，不是 CUDA 对所有当前及未来 GPU 的保证。
- 按 NCU 模型，warp 在开始到完成期间归属于同一个 SMSP；CUDA 程序不能观察或依赖 warp-to-SMSP mapping。
- 精确 scheduler 数量、dual issue 条件和 pipeline 组织依架构而异。

### Scoreboard 和时间线

```text
cycle       0       1       2       3       4       5
SMSP 0    W0:LD   W1:FMA  W2:LD   W3:ALU  W1:FMA  W4:LD
W0 state  issued  waiting waiting waiting waiting waiting
```

W0 发出 load 后，其 consumer instruction 在结果就绪前不能发射，scheduler 可以选择其他 eligible warp。课程可用 scoreboard 表示硬件跟踪未完成依赖的概念，但 CUDA Programming Guide 并未公开其具体数据结构、容量或 pending-bit 实现。

区分三个概念：

| 状态 | 含义 |
|---|---|
| Resident/active | 已在 SM 上分配执行上下文和资源 |
| Eligible | 下一条指令的依赖满足且执行管线可以接受 |
| Issued | 当前 issue cycle 真正被 scheduler 选择 |

这里的 NCU `active warp` 表示 resident warp，不等于“正在执行”。它也不同于 CUDA Programming Guide 中参与当前 warp instruction 的 `active threads`。

> GPU 不会让 dependent load 本身变得便宜，而是尽量用其他独立工作覆盖等待时间。

### In-Flight Work

可以用 Little's Law 建立覆盖延迟所需并发量的数量级直觉。在近似稳态、且 byte throughput 与 residence time 使用同一 memory interface 口径时：

\[
\text{average transferred bytes in flight}
\approx
\text{byte throughput at that interface}\times\text{average residence time}
\]

来源包括：

- 更多 resident warps；
- 单 warp 内更多独立 loads 和 arithmetic instructions；
- 更多 concurrent blocks 和 SMs；
- 后续课程中的 async copy 和 software pipeline。

这是性能工程模型，不是 CUDA 硬件保证。实际并发受 instruction dependencies、issue、cache hit level、request queues 和架构容量限制。“很多 load”不等于“很多独立 load”；poor coalescing 也可能消耗更多 sectors 和 tracking resources，却没有增加 useful bytes in flight。pointer chasing 中后一条 load 的地址依赖前一条结果，无法提供足够 MLP。

### Occupancy

\[
\text{occupancy}
=
\frac{\text{active warps per SM}}
{\text{maximum supported active warps per SM}}
\]

Theoretical occupancy 使用 launch/resource limits 允许的 resident warps；achieved occupancy 使用运行期间测得的平均 active warps。二者都除以架构最大 active warps，但口径不能混用。

Occupancy 提供候选 warp 池，但不保证：

- warp 当前 eligible；
- scheduler 持续发射；
- memory latency 已隐藏；
- kernel 达到高利用率或高性能。

> 目标是保留 enough occupancy，而不是追求 maximum occupancy。

### NCU 对应

- Active Warps Per Scheduler
- Eligible Warps Per Scheduler
- Issued Warps Per Scheduler
- No Eligible / skipped issue slots
- Warp State Statistics
- Long Scoreboard

Long Scoreboard 表示 warp 的下一条指令在等待经 L1TEX 路径处理的未完成 memory dependency。它可能来自 global load、local-memory spill/fill 或其他相关路径。

```text
High Long Scoreboard
    != DRAM bandwidth-bound
    != cache miss rate high
    != coalescing is poor
    != occupancy is necessarily too low
```

只有结合 eligible warps、issue rate、memory throughput、sectors、local-memory traffic 和 Source/SASS，才能判断根因。

在本课 NCU 2025.3.1 的 stall-reason 定义中，Short Scoreboard 表示等待非 L1TEX 的 MIO operation dependency，最常见于 shared memory，也可能来自部分 special math 或动态分支；它不是由 CUDA 公开的固定 latency 阈值定义的“所有短依赖”。普通 fixed-latency execution dependency 还应检查 `Wait` stall reason。

### Takeaway

> Coalescing 提高每个请求的有效性；occupancy 和 ILP/MLP 提高等待时仍有工作可做的概率。两者解决不同问题。

## Episode 3: Memory Hierarchy and Shared Tiling

### 问题

naive GEMM 可能已经拥有较多 warps，B/C 访问也已经 coalesced，为什么性能仍然较低？

### 按 Reuse Scope 介绍 Memory Hierarchy

不要主要依赖固定 latency 数字，而应按复用作用域介绍：

| 层级 | 主要复用作用域 | 控制者 |
|---|---|---|
| Registers | 单线程 | 编译器和程序 |
| Shared memory | 单 thread block | 程序显式管理 |
| L1 | SM 侧访问 | 硬件 cache |
| L2 | 全 GPU、跨 SM/block | 硬件 cache |
| HBM/GDDR | 全设备数据集 | memory system |

在 A100（CC 8.0）上，L1 data cache 与 shared memory 位于统一的 192 KB data-cache/shared-memory subsystem 中；最大 shared-memory capacity 为 164 KB/SM，具体 carveout 是设备支持的离散配置偏好。不同架构的总容量和 carveout 选项不同，不能按一比一关系任意切割。编程语义也不同：

- L1 是硬件管理 cache。
- shared memory 是显式寻址、block-scoped 的 scratchpad。
- shared memory 不会因 cache miss 自动填充。
- shared memory 需要显式 load、同步和 layout 设计。

### 为什么 Cache 不完全替代 Shared Memory

cache 可以机会性捕获复用，但：

- 数据是否仍驻留通常不是程序语义保证；
- 并发 blocks 可能造成竞争和替换；
- 即使命中 L1，重复 load 仍消耗 instruction issue、L1TEX work 和相关 tracking；未在 L1 满足的访问还会消耗 L2 及更下游资源；
- GEMM 已明确知道 block 中哪些线程会复用哪些 A/B 元素。

shared memory 让程序显式表达这种 block-level reuse。

### Tiled GEMM

```cpp
__shared__ float As[T][T];
__shared__ float Bs[T][T];

float acc = 0.0f;

for (int kb = 0; kb < K; kb += T) {
    As[ty][tx] = A[row * K + kb + tx];
    Bs[ty][tx] = B[(kb + ty) * N + col];

    __syncthreads();

    #pragma unroll
    for (int k = 0; k < T; ++k) {
        acc += As[ty][k] * Bs[k][tx];
    }

    __syncthreads();
}

C[row * N + col] = acc;
```

两个 barrier 分别保证：

1. 所有线程都完成 tile 装载后再开始读取。
2. 所有线程都完成当前 tile 的读取后再覆盖 shared memory。

### 第一次回到 Roofline

此时重新使用第一幕中的结论：

\[
AI_{\text{naive, code}}\approx0.25
\]

\[
AI_{\text{tiled, global-to-shared}}\approx\frac{T}{4}
\]

shared tiling 的首要作用不是把 global load 替换成“更快的 load”，而是减少 logical global loads 和 global-hierarchy demand。实际 L2/HBM bytes 是否下降、下降多少必须分别测量；只有使用同一 memory-boundary byte denominator 比较时，bytes/FLOP 下降才对应 Roofline 点向右移动。

预期 NCU 变化：

- 动态 global-load SASS instructions/requests 预计下降，具体口径必须注明；
- DRAM/L2 bytes per output 预计下降，但幅度取决于原版本的 cache reuse；
- measured `AI_HBM` 可能上升；
- Long Scoreboard 可能下降；
- FP32 utilization 上升；
- shared-memory traffic 和 barriers 出现；
- occupancy 可能下降，但整体性能仍提高。

优化后 DRAM `% peak` 下降不一定是回退，因为 kernel 可能使用更少的 DRAM traffic 完成相同 FLOPs。

### Takeaway

> Shared memory 的核心价值是让程序显式捕获 block-level reuse，从而减少更高层 memory hierarchy 的数据移动。

## Episode 4: Finite On-Chip Resources and Occupancy Trade-Off

### 问题

tile 越大，理论复用越高，为什么不无限增大 tile？

### 物理资源限制

一个 SM/SMSP 上只有有限的：

- warp 和 thread slots；
- block slots；
- register-file capacity；
- shared-memory capacity；
- scoreboard 和 request-tracking resources。

若每线程使用 R 个 registers、每 block 有 T 个 threads，则 register 需求大致随 `R x T` 增长，实际分配还受架构相关粒度影响。

shared memory 对 resident blocks 的限制可近似理解为：

\[
\text{resident blocks}
\leq
\left\lfloor
\frac{\text{shared memory per SM}}
{\text{shared memory per block}}
\right\rfloor
\]

概念上，residency 是 thread、warp、CTA、register、shared memory 以及其他架构资源限制共同作用后的最小值；精确结果应使用目标架构的 occupancy API 或 NCU Launch Statistics。

因此 tile size 存在基本权衡：

```text
larger tile
    -> more reuse
    -> fewer global bytes
    -> potentially faster

larger tile
    -> more registers/shared memory
    -> fewer resident blocks/warps
    -> less latency-hiding capacity
    -> potentially slower
```

### Takeaway

> Kernel optimization balances reuse and ILP against resident parallelism; occupancy is one side of this trade-off, not the final objective.

## Episode 5: Banked Shared SRAM, Padding, and Swizzle

### 问题

为什么 shared memory 已经在片上，仍然可能因地址模式而变慢？

### 为什么需要 Banks

一个真正支持 32 个任意并发读取端口的大型 SRAM 会带来很高的面积、功耗和 routing 成本。更实际的设计是将 shared SRAM 划分为多个 banks，以较低成本获得高 aggregate bandwidth。

对本课程使用的 A100（CC 8.0），以及 CUDA Best Practices Guide 所述 CC 5.x 及更新设备，可使用以下 FP32 模型：shared memory 有 32 个 banks，每个 bank 每个 clock cycle 提供 32-bit bandwidth，连续 32-bit words 映射到连续 banks。

\[
\text{bank}
=
\left(\frac{\text{byte address}}{4}\right)\bmod32
\]

```text
word 0  -> bank 0
word 1  -> bank 1
...
word 31 -> bank 31
word 32 -> bank 0
```

对一条 warp shared-memory instruction：

- 不同 lanes 访问不同 banks：可以并行服务。
- 多个 lanes 读取同一个 shared-memory location：可 broadcast，不构成 bank conflict。
- 同一 request 中存在来自不同 banks 的多组 broadcast 时，CUDA Best Practices Guide 将其称为 multicast。
- 多个 lanes 访问同一 bank 中的不同地址：发生 bank conflict。按照 CUDA Best Practices Guide 的表述，硬件将该 request 拆成所需数量的 conflict-free requests 并串行处理。

冲突定义作用于一个 warp 的一条 shared-memory instruction 所形成的 request。不同 warps 可能竞争 shared-memory/L1TEX 吞吐，但不应称为该 request 内的 bank conflict。

多个线程非原子地写同一个 shared-memory location 不是 broadcast store；最终由哪个线程成功写入是未定义的。

### 不要在 Canonical GEMM 上凭空制造问题

经典 tiled GEMM 中：

```cpp
As[ty][k]
Bs[k][tx]
```

常分别对应 broadcast 和连续 bank access，不一定有严重 conflict。因此不应把 `[T][T+1]` 当作所有 GEMM 的魔法模板。

### 使用 Shared Transpose Microbenchmark

冲突版本：

```cpp
__shared__ float tile[32][32];
```

当 warp 以列方向访问时，相邻 lane 的 word address 相差 32，可能映射到同一 bank 的不同地址。

padding 版本：

```cpp
__shared__ float tile[32][33];
```

row stride 从 32 变为 33，使每行的 bank phase 移动一个，从而打散冲突。

### Swizzle

padding 改变固定 row stride；swizzle 更一般地改变 logical coordinate 到 physical address/bank 的映射。例如概念式：

```cpp
physical_col = logical_col ^ ((logical_row & mask) << shift);
```

本讲只强调 layout 是性能接口，不进入 CUTLASS/CuTe layout algebra，也不承诺 swizzle 一定优于 padding。

### NCU 对应

- Shared Memory table 中的 Requests、Wavefronts 和 Bank Conflicts
- Source page 中同一指令的 L1 Wavefronts Shared、Ideal 和 Excessive
- shared bank conflict counters，在目标架构支持时使用
- Short Scoreboard
- MIO Throttle
- L1TEX/shared throughput
- kernel duration

`wavefront` 是 Nsight Compute 的 L1TEX work-package 概念，不是 CUDA 编程模型中的执行单位。在 NCU 对 Volta 及更新架构的简化模型中，一条实际执行的 shared-memory instruction 形成一个 request；L1TEX 可能使用一个或多个 wavefronts 处理它，不同 wavefronts 串行通过相关 pipeline stage。bank conflict 会增加所需 wavefronts，但 wavefront 数还受访问宽度、active mask 和具体指令影响。

在本课使用的 NCU 2025.3.1 中，Source page 的 Excessive 是 actual 相对 ideal 的额外 shared wavefronts，可用于定位产生额外序列化的指令。raw `l1tex__data_bank_conflicts_*` metric 的精确定义和可用性依 GPU 与 NCU 版本而异，应以目标机器上的 metric description 为准，不能脱离 Source 指标和 duration 单独使用。

bank conflict 非零不自动意味着它是主瓶颈，仍需结合 L1TEX throughput、Short Scoreboard/MIO Throttle 和 duration。

### Takeaway

> Shared memory 提供高 aggregate bandwidth，而不是 32 个完全独立的任意地址端口。规则访问获得高吞吐，不规则访问仍正确但需要分阶段服务。

## Episode 6: Register File and Per-Thread Microtiles

### 问题

shared tiling 降低了 global traffic，但每次 FMA 仍可能需要从 shared memory 取操作数。能否进一步复用？

### Register Blocking

让每个线程计算少量多个输出：

```cpp
float acc[4] = {0, 0, 0, 0};

for (int k = 0; k < BK; ++k) {
    float a = As[row_in_tile][k];

    #pragma unroll
    for (int j = 0; j < 4; ++j) {
        acc[j] += a * Bs[k][col_base + j];
    }
}
```

收益：

- 一个 shared A load 服务多个 FMA；
- 多个 accumulator 保存在 registers；
- shared bytes/FLOP 下降；
- 单 warp 内 ILP 增加。

代价：

- registers/thread 增加；
- occupancy 可能下降；
- blocking 太大时可能 spill；
- CUDA local memory 是线程私有地址空间，但通常位于 cache/device-memory hierarchy，并非低延迟片上 register。

可以 sweep `1x1`、`1x2`、`1x4`、`2x2` 和故意过大的版本，观察性能、registers/thread、occupancy 和 local-memory traffic 的倒 U 型关系。

### Takeaway

```text
HBM/L2 -> shared memory
    captures block-level reuse

shared memory -> registers
    captures thread-level reuse
```

## Episode 7: L2 Locality and Block Ordering

这一部分适合作为拓展或附录。

shared tiling 可在完整 tile 路径中显著减少 block 内重复的 logical global loads，但不同 blocks 仍可能读取相同 A/B tiles。device-wide L2 可以捕获部分跨 block reuse。

thread-block swizzle/grouped ordering 改变的是：

```text
physical blockIdx -> logical matrix tile
```

目标是在硬件恰好同时或相近执行一组 CTAs 时，使其 logical tiles 更可能具有重叠 working sets；程序不能保证哪些 CTAs 会形成该组。

必须强调：

- CUDA 不保证 blocks 按 block ID 顺序执行。
- swizzle 不能成为正确性条件。
- 它只提高 locality 的概率。
- 效果依赖矩阵形状、L2 容量、SM 数和调度行为。
- 不应只看 L2 hit rate，还要看 L2 sectors、DRAM bytes 和 duration。

> Shared tiling 可显著减少 block 内重复的 logical global loads；block ordering 只能提高不同 CTAs 的剩余访问在共享 L2 中获得 locality 的概率，不保证执行顺序、cache residency 或 cache hit。

## 第二次 Roofline：Multi-Boundary View

讲完 shared tiling、register blocking 和实际 memory hierarchy 后，再升级分析。NCU Roofline 使用的 work、traffic boundary 和 roofs 取决于工具版本及 section 配置；下面的 HBM/L2/shared 组合是本课自定义的 multi-boundary throughput model，不假定它等同于 NCU 默认 Roofline：

\[
AI_{\text{HBM}}=
\frac{\text{FLOPs}}{\text{HBM bytes}}
\]

\[
AI_{\text{L2}}=
\frac{\text{FLOPs}}{\text{selected NCU L2-boundary bytes}}
\]

\[
AI_{\text{shared, requested}}=
\frac{\text{FLOPs}}{\text{requested shared operand bytes}}
\]

概念上的多层吞吐上界为：

\[
P\leq\min(
P_{\text{compute}},
BW_{\text{shared, pattern}}AI_{\text{shared, requested}},
BW_{\text{L2}}AI_{\text{L2}},
BW_{\text{HBM}}AI_{\text{HBM}}
)
\]

不同 memory level 使用不同的 byte denominator，因此不能把这些 roofs 不加说明地画在同一个 AI 横轴上。L2 必须注明所选 NCU row/metric 和方向；shared sustained bandwidth 又依赖 instruction width、active mask、broadcast/multicast 和 bank mapping，不能只用 `32 banks x 4 bytes x SM clock` 作为所有 shared patterns 的普适 roof。若要定量使用，应为目标 access pattern 通过 microbenchmark 测量 sustained bandwidth。

### 用 Roofline 描述瓶颈迁移

```text
Naive GEMM
    -> many global load requests
    -> low effective AI at upper hierarchy
    -> memory latency/bandwidth pressure

Shared tiled GEMM
    -> fewer global bytes per FLOP
    -> higher AI_HBM and AI_L2
    -> shared traffic, barriers, or FP32 become visible

Register blocked GEMM
    -> fewer shared bytes per FLOP
    -> higher AI_shared and more ILP
    -> FP32 issue or register pressure may dominate
```

### Roofline 的边界

Roofline 描述吞吐上界，但不直接建模：

- memory latency 和不足的 in-flight work；
- dependency chains；
- occupancy；
- poor coalescing 的 request overhead；
- bank conflicts；
- barriers；
- instruction issue；
- address calculation；
- register spilling；
- 小 grid 和 launch overhead。

> Roofline explains the throughput ceiling; scheduler and memory-system analysis explain why a kernel may fall below that ceiling.

---

# Act III: Rebuild the Kernel

第三幕重新组装一个 tiled、register-blocked GEMM，把前面的局部机制整理成可迁移的设计流程。

## Step 1: 决定 Block 计算哪个 C Tile

```text
one block -> BM x BN output tile
```

依据：

- block 是 shared memory 和 block synchronization 的作用域；
- tile 中的输出能够共同复用 A/B；
- tile size 决定 reuse、shared-memory cost 和 block residency。

## Step 2: 决定每个 Thread 计算哪些输出

```text
one thread -> TM x TN output microtile
```

依据：

- accumulators 放入 registers；
- 捕获 thread-level reuse；
- 提供一定 ILP；
- 控制 register pressure 和 spill 风险。

## Step 3: 将 Warp Lanes 映射到输出坐标

依据：

- warp 内连续 lanes 应尽量访问连续或相同地址；
- global load/store 应覆盖接近 ideal 的 sectors；
- 分析必须基于“一条 warp instruction 的 lane-address set”。

## Step 4: 协作加载 A/B Tiles

依据：

- global access 尽量 coalesced；
- 每个高层数据元素搬入一次后被多次使用；
- block 中应产生足够的独立 memory requests；
- 用同步保证 shared-memory tile 完整和安全覆盖。

## Step 5: 选择 Shared-Memory Physical Layout

依据：

- compute 阶段的访问分布到不同 banks；
- 同地址读取可利用 broadcast；
- 只有存在实际 conflict 时才使用 padding/swizzle；
- layout 变化不能破坏 global load 的规整性。

## Step 6: 检查片上资源

检查：

- registers/thread；
- static/dynamic shared memory/block；
- resident blocks 和 warps；
- theoretical/achieved occupancy；
- register spills 和 local-memory traffic；
- eligible warps 和 issue rate。

## Step 7: 用 NCU 验证瓶颈

固定分析顺序：

1. Duration 和 GFLOP/s：是否真的更快？
2. Speed Of Light：哪个大类资源接近吞吐上限？
3. Memory Workload Analysis：sectors、bytes、L2 和 DRAM 如何？
4. Scheduler Statistics：是否缺少 eligible warps？
5. Warp State Statistics：warp 为什么不能发射？
6. Source/SASS：具体是哪条 producer/consumer instruction？
7. Occupancy/Launch Statistics：受什么片上资源限制？

## 通用 Kernel 设计流程

```text
1. Identify reuse.
2. Assign reuse to a cooperation scope.
3. Place data at the matching memory level.
4. Map warp lanes to addresses.
5. Check physical resource conflicts.
6. Preserve enough independent work to hide latency.
7. Measure and verify bottleneck migration.
```

对应中文：

1. 找出数据复用。
2. 判断复用发生在线程、block 还是 blocks 之间。
3. 把数据放到作用域匹配的 memory level。
4. 按 warp 推理线程到地址的映射。
5. 检查 banks、registers 和 shared-memory capacity 等物理约束。
6. 保留足够的 resident/eligible work 和独立请求来隐藏延迟。
7. 用测量验证瓶颈是否消除以及迁移到了哪里。

---

# Nsight Compute 实验安排

## 编译

使用优化和 line info，不使用 `-G`：

```bash
nvcc -O3 --generate-line-info -Xptxas=-v \
  -arch=sm_XX demo.cu -o demo
```

## 快速瓶颈分类

```bash
ncu \
  --kernel-name regex:'copy_|gemm_' \
  --launch-count 1 \
  --section SpeedOfLight \
  --section LaunchStats \
  --section Occupancy \
  ./demo
```

## 单 Kernel 详细分析

```bash
ncu \
  --kernel-name regex:'gemm_tiled' \
  --launch-count 1 \
  --section SpeedOfLight \
  --section MemoryWorkloadAnalysis \
  --section ComputeWorkloadAnalysis \
  --section SchedulerStats \
  --section WarpStateStats \
  --section Occupancy \
  --section LaunchStats \
  --section SourceCounters \
  -o gemm_tiled \
  ./demo
```

section 和 metric 随 NCU 及架构变化。现场前确认：

```bash
ncu --version
ncu --list-sections
ncu --query-metrics
```

不建议现场直接使用 `--set full`，因为 replay pass 较多。可以提前离线生成完整报告。

## 推荐实验序列

| 实验 | 主要变量 | 主要观察 |
|---|---|---|
| Contiguous vs stride copy | lane-address pattern | ideal/excessive sectors、useful bandwidth |
| Good vs bad GEMM mapping | warp 到 row/col 的映射 | global sectors 和 duration |
| Naive GEMM block shapes | resident warps | eligible warps、issue rate、Long Scoreboard |
| Naive vs shared tiled GEMM | block-level reuse | DRAM/L2 bytes、AI、FP32 utilization |
| Tile size sweep | reuse vs residency | shared memory、occupancy、duration |
| `[32][32]` vs `[32][33]` transpose | bank mapping | excessive shared wavefronts |
| Register microtile sweep | thread-level reuse | registers、occupancy、spill、FP32 utilization |
| Block ordering，可选 | cross-block locality | L2 sectors、DRAM bytes、duration |

## 指标解释原则

| 问题 | 主要证据 |
|---|---|
| 是否真的优化 | Duration、GFLOP/s |
| global access 是否规整 | actual/ideal/excessive sectors |
| 是否带宽饱和 | DRAM/L2 throughput 和 bytes |
| latency 是否暴露 | eligible warps、No Eligible、issue rate |
| 在等待哪类依赖 | Long/Short Scoreboard，加 Source/SASS |
| shared 是否冲突 | actual/ideal/excessive shared wavefronts |
| occupancy 被什么限制 | registers、shared memory、threads、blocks |
| 是否转向计算瓶颈 | FP32/FMA pipeline utilization |

不要从单个 metric 直接推导根因：

- Long Scoreboard 高不等于 DRAM bandwidth-bound。
- DRAM throughput 高不等于 useful bandwidth 高。
- DRAM throughput 低不等于没有 memory latency 问题。
- L2 hit rate 高不等于数据移动已经最优。
- occupancy 高不等于 scheduler 有足够 eligible warps。
- bank conflict 非零不等于它是主瓶颈。
- 某类 stall 占比下降不等于 kernel 变快。

---

# 课程时间线

## 90 分钟版本

| 时间 | 内容 |
|---|---|
| 0-12 分钟 | GEMM workload、reuse、第一次 Roofline、evolution preview |
| 12-25 分钟 | warp/SIMT、thread mapping、coalescing、copy experiment |
| 25-38 分钟 | SMSP、scheduler、scoreboard、latency hiding、NCU |
| 38-58 分钟 | memory hierarchy、shared tiled GEMM、Roofline 右移 |
| 58-68 分钟 | finite resources、tile size、occupancy trade-off |
| 68-78 分钟 | shared banks、broadcast、padding/swizzle |
| 78-84 分钟 | register blocking、register pressure |
| 84-90 分钟 | hierarchical Roofline、重组 kernel、总结和后续预告 |

## 60 分钟版本

| 时间 | 内容 |
|---|---|
| 0-10 分钟 | GEMM reuse、简单 Roofline、evolution preview |
| 10-22 分钟 | warp、coalescing、copy experiment |
| 22-32 分钟 | scheduler、occupancy、Long Scoreboard |
| 32-47 分钟 | shared tiled GEMM、Roofline 右移 |
| 47-55 分钟 | bank conflict 和 padding |
| 55-60 分钟 | kernel reconstruction、takeaways |

60 分钟版本中，L2 block ordering、register spilling、swizzle 实现和 hierarchical Roofline 细节放入附录。

---

# 知识依赖关系

```text
GEMM semantics
      |
      +-- repeated use of A/B
      |         |
      |         +-- arithmetic intensity
      |         +-- simple Roofline
      |         +-- tiling motivation
      |
CUDA thread/block/warp
      |
      +-- lane-to-address mapping
      |         +-- coalescing
      |
      +-- resident warps
      |         +-- scheduler
      |         +-- scoreboard
      |         +-- latency hiding
      |
      +-- block cooperation
                +-- shared memory
                +-- synchronization

finite on-chip resources
      |
      +-- register pressure
      +-- shared-memory capacity
      +-- occupancy

banked shared SRAM
      |
      +-- bank conflict
      +-- broadcast
      +-- padding/swizzle

all of the above
      |
      +-- tiled and register-blocked GEMM
      +-- measured hierarchical Roofline
```

为降低认知负担，课程实际顺序将 DAG 近似线性化：

```text
GEMM reuse
-> simple Roofline
-> optimization preview
-> warp execution
-> coalescing
-> scheduler and latency hiding
-> shared tiling
-> resource and occupancy trade-off
-> shared banks
-> register blocking
-> hierarchical Roofline
-> final reconstruction
```

第一遍中的 shared tiling 是 forward declaration：只要求理解“共同保存并复用”；第二遍再补充 banks、capacity、synchronization 和 occupancy 细节。

---

# 术语引入顺序

## Act I 可以出现

- GEMM
- output tile
- reuse
- data movement
- arithmetic intensity
- simple Roofline
- global memory
- shared memory
- registers

## 讲 Warp Mapping 时再引入

- active lane
- coalescing
- request
- sector
- alignment

## 讲 Latency Hiding 时再引入

- SMSP
- warp scheduler
- resident/active/eligible/issued
- scoreboard
- Long Scoreboard
- occupancy
- ILP/MLP

## 讲 Shared 实现时再引入

- bank
- bank conflict
- broadcast
- wavefront
- padding
- swizzle

## 本讲只预告

- `cp.async`
- LDGSTS
- TMA
- double buffering
- software pipeline
- Tensor Core

---

# 常见误区

1. **把 naive GEMM 慢完全归因于 uncoalesced access。** 正常 mapping 下 B/C 通常规整，A 常是 warp 内同地址或分组同地址的 global load；核心不足是没有显式捕获 reuse。shared-memory broadcast 是另一套 bank 规则，不应混用。
2. **把 shared memory 理解为更快的 global memory。** 它首先是 programmer-managed、block-scoped reuse mechanism。
3. **把 coalescing 说成固定的 128-byte transaction。** 更稳妥的模型是一条 warp instruction 覆盖若干 32-byte sectors。
4. **把 occupancy 当作 utilization 或性能目标。** 它只描述 resident-warp capacity。
5. **把 active warp 当作 eligible warp。** 已驻留不代表下一条指令可以发射。
6. **看到 Long Scoreboard 就宣布 DRAM bound。** 需要结合 scheduler、memory hierarchy、Source/SASS 和 local-memory traffic。
7. **认为二维 shared tile 天生需要 padding。** canonical GEMM 常见访问可能是 broadcast 加连续 bank access。
8. **把同地址 shared read 当作 conflict。** 同地址 read 通常可以 broadcast。
9. **认为 tile 越大越好。** reuse 会提高，但 register/shared-memory cost 会降低 residency。
10. **只看 L2 hit rate 或 bandwidth percentage。** 必须同时看总请求、bytes、useful work 和 duration。
11. **认为 block swizzle 保证执行顺序。** 它只改变 logical tile mapping，提高 locality 概率。
12. **认为 Roofline 是完整性能模型。** 它给出吞吐 ceiling，不直接解释 latency、dependency、bank conflict 和 issue bottleneck。

---

# 最终 Takeaways

## Workload 视角

1. GEMM 的算法价值来自高数据复用，而不只是大量 FMA。
2. Arithmetic intensity 衡量每个 memory byte 支持多少 useful computation。
3. tiling 的目的，是把算法中存在的 reuse 转化为实现中更少的高层数据移动。

## Hardware 视角

1. Warp execution 摊薄控制成本，但要求软件提供相对规则的控制流和地址模式。
2. Coalescing 减少一条 warp global-memory instruction 覆盖的无用 sectors。
3. Resident warp contexts、scoreboard 和 eligible-warp scheduling 用其他工作隐藏长延迟。
4. Shared memory 用 banked SRAM 提供高 aggregate bandwidth，而不是任意地址下的完全独立端口。
5. Registers 和 shared memory 都是有限片上资源；更高 reuse 会消耗 residency。

## Kernel 优化视角

1. Shared-memory tiling 捕获 block-level reuse，减少 global/L2/HBM traffic。
2. Register blocking 捕获 thread-level reuse，减少 shared traffic并增加 ILP。
3. Padding/swizzle 改变 physical layout，以适配 banked shared memory。
4. Occupancy、ILP/MLP 和 block mapping 决定剩余延迟与 locality 能否被隐藏或捕获。
5. 优化不是让所有 metrics 都下降，而是消除当前主瓶颈并观察下一个瓶颈出现。

全讲可以收束为：

> Reuse tells us what data should stay close; hardware tells us where it can stay, how many accesses can happen in parallel, and what resources that choice consumes.

以及：

```text
reduce useless bytes
-> capture reuse at the right scope
-> keep enough independent work in flight
-> observe the bottleneck move from HBM/L2
   to shared memory, synchronization, registers, and FP32 pipelines
```

---

# 后续课程接口

当前 tiled GEMM 仍然执行：

```text
load tile
-> wait
-> compute
-> wait
-> load next tile
```

Ampere 的 `cp.async`/LDGSTS 和 Hopper 的 TMA 进一步优化 global-to-shared data movement；double buffering 和 software pipelining 尝试让下一 tile 的数据搬运与当前 tile 的计算重叠；Tensor Core 则改变计算侧的吞吐上限。

本讲只留下问题：

> 当数据移动量已经通过 tiling 降低后，如何进一步隐藏剩余的数据移动时间，并提高计算单元吞吐？

这将自然连接后续 Tensor Core、TMA 和 pipelining 课程。

---

# 参考资料

- [CUDA C++ Best Practices Guide](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html)
- [CUDA Programming Guide: Hardware Implementation](https://docs.nvidia.com/cuda/cuda-programming-guide/03-advanced/advanced-kernel-programming.html#hardware-implementation)
- [CUDA Programming Guide: Asynchronous Data Copies](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/async-copies.html)
- [CUDA Programming Guide: Compute Capabilities](https://docs.nvidia.com/cuda/cuda-programming-guide/05-appendices/compute-capabilities.html)
- [Nsight Compute Profiling Guide](https://docs.nvidia.com/nsight-compute/ProfilingGuide/index.html)
- [Nsight Compute CLI Guide](https://docs.nvidia.com/nsight-compute/NsightComputeCli/index.html)
- [NVIDIA Ampere Architecture In-Depth](https://developer.nvidia.com/blog/nvidia-ampere-architecture-in-depth/)
- [Optimizing Compute Shaders for L2 Locality Using Thread-Group ID Swizzling](https://developer.nvidia.com/blog/optimizing-compute-shaders-for-l2-locality-using-thread-group-id-swizzling/)

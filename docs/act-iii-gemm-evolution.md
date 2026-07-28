# Act III: From Naive GEMM to a Fast SIMT Kernel

## 1. 目标与边界

这一实践从最简单的 FP32 GEMM 出发，逐步构造一个性能较好的 CUDA Core/SIMT kernel：

\[
C_{M\times N}=A_{M\times K}B_{K\times N}
\]

固定语义：

- A、B、C 都是 row-major FP32。
- 第一阶段只实现 `C = A * B`，即 `alpha=1`、`beta=0`。
- 每个版本使用同一个 benchmark 和 correctness harness。
- 每个版本突出一个主要教学机制；若同时改变 tile、线程数或编译结果，性能归因必须依赖额外 ablation，而不能只比较相邻版本。
- 主性能实验使用大方阵，正确性测试必须包含非方阵和非 tile 整除尺寸。

本实践刻意不使用：

- Tensor Core、TF32、WMMA、MMA；
- `cp.async`、LDGSTS、TMA；
- shared-memory double buffering；
- software pipelining；
- persistent kernel、split-K 或 warp specialization。

这些机制可以进一步提高性能，但属于后续课程。这里的最终 kernel 仍然采用：

```text
load one K tile
-> synchronize
-> compute one K tile
-> synchronize
-> load the next K tile
```

因此“性能非常好”在本文中表示：

> 在不使用 Tensor Core 和数据搬运流水线的约束下，得到一个具有高 arithmetic intensity、良好 global coalescing、较低 shared bank conflict、无 register spill，并能有效使用 FP32 pipelines 的强 SIMT baseline。

它不等于在所有 GPU 和矩阵形状上接近 cuBLAS。本课程实现在 A100 80GB PCIe 上，对 4096³ 稳定复现 pedantic FP32 cuBLAS 的约 76%；8192³ 曾观测到 90.4%，但后续在两张空闲 A100 上复验为约 81%。这类单次高值不是跨 GPU 或跨形状的预期保证。

---

## 2. 优化路线总览

主线使用以下版本：

| 版本 | 主要新增机制 | CTA tile `BM x BN x BK` | Thread tile `TM x TN` | Threads |
|---|---|---:|---:|---:|
| V0 | 一线程一个输出 | `16 x 16 x K` | `1 x 1` | 256 |
| V1 | 修正 warp-to-data mapping | `16 x 16 x K` | `1 x 1` | 256 |
| V2 | shared-memory block tiling | `32 x 32 x 32` | `1 x 1` | 1024 |
| V3 | 1D register tiling | `64 x 32 x 8` | `8 x 1` | 256 |
| V4 | 2D register outer product | `128 x 128 x 8` | `8 x 8` | 256 |
| V5 | vectorized global loads | `128 x 128 x 8` | `8 x 8` | 256 |
| V6 | bank-aware lane ownership | `128 x 128 x 8` | `8 x 8` | 256 |
| V7 | 参数搜索和形状特化 | 多组候选 | 多组候选 | 128/256 |

其中 V0 和 V1 可以合并：如果最简单的 kernel 从一开始就让 `threadIdx.x` 对应连续 N 维，那么它已经具有较好的 B load/C store coalescing。课堂上保留一个故意错误的 mapping 版本，是为了隔离展示 coalescing，而不是暗示所有 naive GEMM 都天然 uncoalesced。

```text
one output per thread
        |
        v
warp-friendly global access
        |
        v
global -> shared reuse
        |
        v
1D shared -> register reuse
        |
        v
2D register outer product
        |
        v
fewer/wider movement instructions
        |
        v
bank-aware warp/lane mapping
        |
        v
architecture-specific parameter search
```

---

# 3. V0: Naive GEMM

## 3.1 Kernel 结构

```cpp
__global__ void gemm_v00_naive(
    const float* A,
    const float* B,
    float* C,
    int M,
    int N,
    int K) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;

    if (row >= M || col >= N) {
        return;
    }

    float acc = 0.0f;
    for (int k = 0; k < K; ++k) {
        acc = fmaf(A[row * K + k], B[k * N + col], acc);
    }
    C[row * N + col] = acc;
}
```

建议 launch：

```cpp
dim3 block(16, 16);
dim3 grid(ceil_div(N, 16), ceil_div(M, 16));
```

## 3.2 数据所在位置

| 数据 | 位置 |
|---|---|
| A、B、C | global memory，可能经过 L1/L2 |
| `acc` | register |
| block-level reuse | 未显式表达 |

## 3.3 访问分析

对固定 `k`，如果 `threadIdx.x` 对应 `col`：

- B load 在 warp 内通常访问连续列。
- C store 在 warp 内通常访问连续列。
- 同一输出行中的 lanes 读取相同的 global A address；就 coalescing 而言，这些地址通常只覆盖很少的 sectors，后续 reuse 可能由 cache 捕获。这里不是 shared-memory bank broadcast。

当前 launch 使用 `16 x 16` block。由于 CUDA 线程按 x-fastest 线性化，一个 warp 通常包含两个 16-thread rows，因此 A 是两组同地址访问，B/C 是两组规整的 16-element 访问，而不是整 warp恰好对应一行。

因此这一版的主要问题不是所有 global access 都 uncoalesced，而是 A/B 的算法级复用主要交给 cache 偶然捕获。

忽略 cache reuse 时：

\[
AI_{\text{code}}\approx\frac{2\ \text{FLOPs}}{8\ \text{bytes}}=0.25\ \text{FLOP/byte}
\]

## 3.4 预期 NCU 现象

- global load instruction 数多；
- Long Scoreboard 可能较高；
- FP32 pipeline 利用率低；
- occupancy 可能不低，但 eligible warps 和 issue rate 未必高；
- 实际 HBM bytes 受 L1/L2 reuse 影响，不一定等于代码级估算。

## 3.5 教学问题

> GEMM 明明有大量复用，为什么这个实现暴露给 memory hierarchy 的却是大量重复 load？

---

# 4. V1: Warp-Friendly Mapping

这一版不改变算法、block size 或每线程工作量，只改变 thread-to-output mapping。

## 4.1 Controlled Bad Mapping

可以故意让 `threadIdx.x` 对应 row：

```cpp
int row = blockIdx.y * blockDim.x + threadIdx.x;
int col = blockIdx.x * blockDim.y + threadIdx.y;
```

这样连续 lanes 通常以 leading-dimension stride 访问 A 和 C，产生 excessive sectors；固定 `k` 时的 B load 往往是同地址或分组同地址访问。

## 4.2 修正

恢复为：

```cpp
int row = blockIdx.y * blockDim.y + threadIdx.y;
int col = blockIdx.x * blockDim.x + threadIdx.x;
```

分析单位必须是一条 warp memory instruction 的 lane-address set，而不是笼统地说“矩阵按行访问”。

## 4.3 预期 NCU 变化

- actual sectors 更接近 ideal sectors；
- global excessive sectors 下降；
- 下游 L2/DRAM bytes 和 duration 可能下降，幅度需实测；
- 数学 FLOPs 和每线程输出数量不变。

## 4.4 Takeaway

> 先减少每条 warp global-memory instruction 所需的 excessive sectors，再通过 tiling、register reuse 或更少的动态 memory instructions 减少 request 总数。

---

# 5. V2: Shared-Memory Block Tiling

这一版只引入 block-level reuse。

## 5.1 Tile 形状

```text
BM = 32
BN = 32
BK = 32
TM = TN = 1
threads = 32 x 32 = 1024
```

1024 threads/block 不是最终推荐配置，但非常适合教学：

- 一个 block 对应一个 `32 x 32` C tile。
- 一个线程对应一个输出元素。
- 每个线程每轮各加载一个 A 和 B 元素。

## 5.2 Kernel 主循环

```cpp
__shared__ float As[32][32];
__shared__ float Bs[32][32];

float acc = 0.0f;

for (int k0 = 0; k0 < K; k0 += 32) {
    As[ty][tx] =
        row < M && k0 + tx < K
            ? A[row * K + k0 + tx]
            : 0.0f;

    Bs[ty][tx] =
        k0 + ty < K && col < N
            ? B[(k0 + ty) * N + col]
            : 0.0f;

    __syncthreads();

    #pragma unroll
    for (int k = 0; k < 32; ++k) {
        acc = fmaf(As[ty][k], Bs[k][tx], acc);
    }

    __syncthreads();
}
```

## 5.3 为什么需要两个 Barrier

第一个 barrier 保证完整 tile 已经写入 shared memory。

第二个 barrier 保证所有线程都完成当前 tile 的读取，之后才能覆盖同一块 shared buffer。

边界线程不能在 barrier 之前提前 return；无效的 K-tail 元素必须 zero-fill。

## 5.4 Arithmetic Intensity

一个 K tile 中：

\[
\text{FLOPs}=2\times32^3
\]

\[
\text{global bytes}=4\times(32^2+32^2)
\]

\[
AI_{\text{global-to-shared}}=8\ \text{FLOP/byte}
\]

## 5.5 为什么这仍不是高性能 Kernel

- 1024 threads/block 限制 residency 和调度灵活性。
- 每个线程只计算一个输出。
- 每个 FMA 前仍需要两个 shared-memory operands。
- shared load instruction 和 barrier overhead 较高。
- `32 x 32` tile 只是最容易讲清楚，不是普适最优配置。

## 5.6 预期 NCU 变化

- DRAM/L2 bytes per FLOP 下降；
- measured `AI_HBM` 上升；
- Long Scoreboard 可能下降；
- shared throughput、Barrier、Short Scoreboard 或 MIO Throttle 开始可见；
- FP32 utilization 上升；
- occupancy 可能下降，但性能仍明显提高。

## 5.7 Takeaway

> Shared memory 的首要收益是减少 global-hierarchy requests，而不只是提供一种低延迟 load。

---

# 6. V3: One-Dimensional Register Tiling

这一版让一个线程计算 M 方向上的多个输出，降低 shared-memory load/FMA 比例。

## 6.1 Tile 形状

```text
BM = 64
BN = 32
BK = 8
TM = 8
TN = 1

thread rows = BM / TM = 8
thread cols = BN = 32
threads = 8 x 32 = 256
```

## 6.2 Thread Ownership

```cpp
int tid = threadIdx.x;
int thread_row_group = tid / 32;  // 0..7
int thread_col = tid % 32;        // 0..31
int row_base = thread_row_group * 8;
```

每个线程计算：

```text
C[row_base + 0..7][thread_col]
```

## 6.3 数据布局

```cpp
__shared__ float As[64][8];
__shared__ float Bs[8][32];

float acc[8] = {};
```

每个 K step：

```cpp
float b = Bs[k][thread_col];

#pragma unroll
for (int i = 0; i < 8; ++i) {
    float a = As[row_base + i][k];
    acc[i] = fmaf(a, b, acc[i]);
}
```

一个 B shared load 进入 register 后服务 8 个 FMA。

## 6.4 Cooperative Loading

A tile 有 512 个 float，每线程加载两个；B tile 有 256 个 float，每线程加载一个。

教学版可以使用线性索引循环：

```cpp
for (int idx = tid; idx < BM * BK; idx += 256) {
    int local_m = idx / BK;
    int local_k = idx % BK;
    As[local_m][local_k] = predicated_A_load(...);
}

for (int idx = tid; idx < BK * BN; idx += 256) {
    int local_k = idx / BN;
    int local_n = idx % BN;
    Bs[local_k][local_n] = predicated_B_load(...);
}
```

## 6.5 Shared-Memory 行为

在一个 warp 的 shared-memory request 中：

- `Bs[k][thread_col]` 是连续 32 个 FP32。
- 对固定 i，`As[row_base+i][k]` 是同一 shared-memory location 的 read，可 broadcast。

这一版通常不需要 padding。

## 6.6 预期 NCU 变化

- shared loads/FMA 下降；
- 线程数从 1024 降为 256；
- barrier 之间的计算量增加；
- FP32 utilization 和 ILP 提高；
- registers/thread 增加；
- occupancy 可能变化，但不应作为唯一判断标准。

## 6.7 Takeaway

> Shared tiling 减少 global traffic；register tiling 开始减少 shared traffic。

---

# 7. V4: Two-Dimensional Register Tiling

对大尺寸、compute-intensive 的 SIMT SGEMM，二维 register outer product 是提高 A/B 双向 register reuse 和 ILP 的典型高性能结构；它不是所有矩阵形状上的数学必要条件，也不表示固定 `8 x 8` microtile 普遍最优。V3 的 1D tile 是教学递进，不是 NVIDIA 规定的必经阶段。

## 7.1 Tile 形状

```text
BM = 128
BN = 128
BK = 8
TM = 8
TN = 8

thread rows = BM / TM = 16
thread cols = BN / TN = 16
threads = 16 x 16 = 256
```

## 7.2 初始连续 Microtile Ownership

```cpp
int tr = threadIdx.x / 16;
int tc = threadIdx.x % 16;

int row_base = tr * 8;
int col_base = tc * 8;
```

每线程计算一个连续的 `8 x 8` C microtile。

## 7.3 Shared 和 Register Layout

```cpp
__shared__ float As[128][8];
__shared__ float Bs[8][128];

float acc[8][8] = {};
float reg_a[8];
float reg_b[8];
```

每个 K step 执行 thread-level outer product：

```cpp
#pragma unroll
for (int k = 0; k < BK; ++k) {
    #pragma unroll
    for (int i = 0; i < TM; ++i) {
        reg_a[i] = As[row_base + i][k];
    }

    #pragma unroll
    for (int j = 0; j < TN; ++j) {
        reg_b[j] = Bs[k][col_base + j];
    }

    #pragma unroll
    for (int i = 0; i < TM; ++i) {
        #pragma unroll
        for (int j = 0; j < TN; ++j) {
            acc[i][j] = fmaf(reg_a[i], reg_b[j], acc[i][j]);
        }
    }
}
```

每轮从 shared memory 读取 `TM + TN = 16` 个值，执行 `TM x TN = 64` 个 FMA。

按每线程请求的 shared operands 估算：

\[
AI_{\text{shared, requested}}
=
\frac{2TM\,TN}{4(TM+TN)}
\]

`TM=TN=8` 时为 `2 FLOP/byte`，相对 `1 x 1` 的 `0.25 FLOP/byte` 提高 8 倍。实际 shared service work 还受 broadcast、multicast、instruction width 和 bank conflict 影响。

## 7.4 CTA-Level Arithmetic Intensity

每个 K tile：

\[
\text{FLOPs}=2\times128\times128\times8
\]

\[
\text{global bytes}=4\times(128\times8+8\times128)
\]

\[
AI_{\text{global-to-shared}}=32\ \text{FLOP/byte}
\]

该数值忽略 C store、边界浪费和跨 block cache reuse。

## 7.5 新出现的代价

- `acc[8][8]` 表示 64 个同时存活的 FP32 accumulator values，通常造成至少约 64 个值的寄存器压力；实际 registers/thread 和 spill 以 ptxas/SASS/NCU 为准。
- 加上 A/B fragments、地址和临时变量，registers/thread 可能达到约 70 到 100。
- occupancy 通常下降，但更高 reuse 和 ILP 可能使性能继续上升。
- 若 compiler 无法静态展开或 register pressure 过高，数组可能 spill 到 local memory。
- 连续 `8 x 8` ownership 可能导致 B 的 shared-memory bank conflict。

## 7.6 为什么可能有 B Bank Conflict

以下是源码级 lane-address 预测；实际 request、指令宽度和 bank behavior 必须用目标 SASS 与 Source-page counters 确认。一个 warp 中，前 16 lanes 对应 `tr=0, tc=0..15`，后 16 lanes 对应 `tr=1, tc=0..15`。

固定 j 时：

```cpp
reg_b[j] = Bs[k][tc * 8 + j];
```

前半 warp 地址依次为：

```text
j, 8+j, 16+j, 24+j, ...
```

在 32-bank、4-byte bank width 的简化模型下，bank index 每次加 8，只覆盖少量 banks，可能形成多路 conflict。后半 warp 又重复相同地址集合。

这是一个重要教学节点：

> 提高 register reuse 的 thread ownership，不一定天然适合 shared-memory banks。

## 7.7 预期 NCU 变化

- FP32 instruction 和 pipeline utilization 大幅提高；
- global bytes/FLOP 下降；
- registers/thread 明显上升；
- occupancy 下降但性能仍可能上升；
- B shared loads 可能出现 excessive wavefronts；
- local-memory traffic 必须保持为零或接近零。

## 7.8 Takeaway

> 高性能 SIMT GEMM 的核心计算形态，是在 registers 中累加一个二维 output tile，并用 A/B register fragments 做 outer product。

## 7.9 A100 上的实测 Bank Conflict

以下结果是 course-specific measurement：`sc4` 的 A100 80GB PCIe、CC 8.0、CUDA 13、NCU 2025.3.1、`M=N=K=4096`。它们是指定 kernel SASS 和 profiler 版本的观测值，不是 CC 8.0 理论常数。NCU 对 V4 给出：

```text
shared load requests:       134,217,728
shared load wavefronts:     671,092,264
shared load bank-conflict metric: 268,438,694
wavefronts/request:                about 5.0
```

该结果显示大量 shared wavefront work，并报告非零 bank-conflict metric；Source page 同时显示大量 actual 相对 ideal 的 excessive shared wavefronts。这些指标结合 duration 支持连续 `8 x 8` ownership 在该 A100/SASS 上产生性能相关的 shared serialization。不能把 wavefronts/request 直接称为 N-way conflict degree，也不能把 `bank-conflict metric / wavefronts` 解释成“发生冲突的 wavefront 百分比”。

同一个 V4 还有 shared store conflict，来源主要是标量 cooperative loading 对 shared tile 的写入映射：

```text
shared store requests:       33,554,432
shared store wavefronts:     137,248,766
shared store bank-conflict metric: 103,763,772
wavefronts/request:                 about 4.1
```

因此后续两个优化需要用 V4/V5/V5b/V6 的 2x2 ablation 分开归因：

- V4 vs V5：隔离 vectorized cooperative-loading implementation 的累计影响；其中 global-load、shared-store 和 register effects 仍需 counters/SASS 分解。
- V4 vs V5b：在 scalar loading 下隔离 striped ownership。
- V5 vs V6：在 vectorized loading 下隔离 striped ownership。
- V5b vs V6：在 striped ownership 下隔离 vectorization。

---

# 8. V5: Vectorized Global Loads

这一版保持 CTA tile 和 compute ownership 不变，主要改变 cooperative movement 的 vector width；它可能同时改变 global loads、temporary registers、shared stores 和相应 SASS。

## 8.1 A Tile Loading

A tile 为 `[128][8]`，每行正好包含两个 `float4`：

```cpp
int a_local_row = threadIdx.x / 2;       // 0..127
int a_local_k4 = (threadIdx.x % 2) * 4;  // 0 or 4

float4 a4 = load_float4(
    &A[(block_m + a_local_row) * K + k0 + a_local_k4]);
```

每线程加载一个 A `float4`。

## 8.2 B Tile Loading

B tile 为 `[8][128]`，每行包含 32 个 `float4`：

```cpp
int b_local_k = threadIdx.x / 32;       // 0..7
int b_local_n4 = (threadIdx.x % 32) * 4;

float4 b4 = load_float4(
    &B[(k0 + b_local_k) * N + block_n + b_local_n4]);
```

每线程加载一个 B `float4`。

## 8.3 `float4` 真正优化了什么

可能减少：

- global load instructions；
- 地址计算 instructions；
- LSU issue pressure；
- cooperative loading 的指令开销。

它不一定减少 sectors 或 DRAM bytes。原本良好 coalesced 的标量 load 可能访问完全相同的 sectors。

> Vector width 和 warp-level coalescing 是不同问题。

## 8.4 对齐与边界

16-byte load 要求实际地址 16-byte 对齐。`cudaMalloc` 的基地址对齐并不保证每一行的偏移仍然对齐。

快速路径至少要求：

```text
A/B base address aligned to 16 bytes
K % 4 == 0 for row starts in A
N % 4 == 0 for row starts in B
tile offsets are multiples of 4
```

推荐保留两个路径：

- aligned/full-tile fast path 使用 `float4`；
- general path 使用 predicated scalar loads 和 zero-fill。

不能执行一个越界的 `float4` load 后再丢弃无效分量；load 本身已经非法。

## 8.5 预期 NCU 变化

- global load instruction 数下降；
- 地址计算整数指令下降；
- sectors 和 DRAM bytes 可能基本不变；
- 如果 V4 已受 shared conflict 或 FP32 限制，性能提升可能只有几个百分点。

## 8.6 Takeaway

> 先用 tiling 改变数据移动的数量级，再用 vectorization 降低执行这些搬运所需的指令成本。

---

# 9. V6: Bank-Aware Lane Ownership

这一版保持 `128 x 128 x 8` CTA tile、`8 x 8` 每线程输出和 256 threads 不变，只改变 thread 对 C 元素的 ownership。

目标是在不增加 padding 或复杂 swizzle 的情况下，使 shared loads 更适合 banks，同时保持 C stores coalesced。

## 9.1 Striped Ownership

```cpp
int tr = threadIdx.x / 16;  // 0..15
int tc = threadIdx.x % 16;  // 0..15
```

每个线程计算：

```text
row(i) = tr + i * 16
col(j) = tc + j * 16

i = 0..7
j = 0..7
```

每线程仍然拥有 64 个 C 元素，整个 block 仍覆盖完整 `128 x 128` tile，但元素从连续 microtile 改成 striped microtile。

## 9.2 Register Loads

```cpp
#pragma unroll
for (int k = 0; k < BK; ++k) {
    float reg_a[8];
    float reg_b[8];

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        reg_a[i] = As[tr + i * 16][k];
    }

    #pragma unroll
    for (int j = 0; j < 8; ++j) {
        reg_b[j] = Bs[k][tc + j * 16];
    }

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        #pragma unroll
        for (int j = 0; j < 8; ++j) {
            acc[i][j] = fmaf(reg_a[i], reg_b[j], acc[i][j]);
        }
    }
}
```

## 9.3 B Shared Access

固定 j 时：

```text
B column = tc + j * 16
```

一个 warp 的前 16 lanes 访问连续 16 个 FP32，后 16 lanes 访问相同的 16 个 shared-memory locations。这形成来自不同 banks 的多组 broadcast；按照 CUDA Best Practices Guide 的术语，这些 broadcast 可组合为 multicast，而不是同一 bank 中不同地址的 conflict。

## 9.4 A Shared Access

固定 i 时：

- 前 16 lanes 的 `tr` 相同，读取一个 A 地址；
- 后 16 lanes 读取另一个 A 地址；
- 表现为少量 broadcast；同一 request 中来自不同 banks 的多组 broadcast 可组合为 multicast。

## 9.5 C Store Coalescing

固定 `(i,j)` 执行 store 时：

- lanes 0..15 写同一行中的连续 16 个 float；
- lanes 16..31 写下一行中的连续 16 个 float。

因此虽然单线程的 8 个列不连续，每条 warp store instruction 仍然覆盖规整地址。

```cpp
#pragma unroll
for (int i = 0; i < 8; ++i) {
    int row = block_m + tr + i * 16;

    #pragma unroll
    for (int j = 0; j < 8; ++j) {
        int col = block_n + tc + j * 16;
        if (row < M && col < N) {
            C[row * N + col] = acc[i][j];
        }
    }
}
```

C store instruction 数较多，但对大 K 的 GEMM，epilogue 成本通常相对 mainloop 较小。若 epilogue 成为瓶颈，可进一步使用 shared-memory exchange 或另一种 warp tile mapping；这应作为 stretch goal，而不是混入本版。

## 9.6 为什么这里不需要 Padding

当前自然布局：

```cpp
__shared__ float As[128][8];
__shared__ float Bs[8][128];
```

已经满足：

- A compute loads 使用 broadcast/multicast；
- B compute loads 使用连续 banks 加 multicast；
- global A/B loading 保持规则。

特别是将 B 改成 `[8][129]`，并不能修复连续 microtile 中发生在同一 B row 内的 `tc * 8 + j` conflict。padding 改变 row stride，但该冲突来自同一行中的列间隔。

## 9.7 预期 NCU 变化

- 在目标 A100/SASS 的完整 tile 路径上，预计 shared excessive wavefronts 和 bank-conflict metric 显著下降；其他架构和编译结果需重新测量；
- Short Scoreboard 或 MIO Throttle 可能下降；
- FP32 issue rate提高；
- registers/thread 和 occupancy 基本不变；
- Barrier 或 Long Scoreboard 可能成为更明显的剩余瓶颈。

### A100 实测

V4 与 V6 的累计路线对比为：

下表来自另一轮独立 profile，因此累计 counter 与上文有小幅 run-to-run 差异；归因只比较同一轮 ablation 中的结果。

| Metric, `4096^3` | V4 continuous `8x8` | V6 bank-aware striped |
|---|---:|---:|
| Shared load bank conflicts | 268,438,491 | 14,854 |
| Shared load wavefronts | 671,091,675 | 402,668,909 |
| Shared store bank conflicts | 103,734,837 | 1,375,287 |
| Shared store wavefronts | 137,289,269 | 34,931,294 |
| Runtime | 14.65 ms | 12.53 ms |
| Throughput | 9.38 TFLOP/s | 10.97 TFLOP/s |

V6 相比 V4 同时改变了 vectorized cooperative loading 和 thread ownership，因此只能说明累计路线收益，不能把完整 17% 归因于 bank-aware assignment：

- shared load conflicts 几乎清零；
- shared load wavefronts 减少约 40%；
- shared store conflicts 也因 vectorized loading 基本清除；
- 累计性能提高约 17%；
- registers/thread 和报告的 occupancy 基本相同，因此收益不能由 occupancy 数值变化直接解释；eligible-warps 和 issue behavior 仍可能因依赖结构变化而改善。

NCU 的 SOL 和 scheduler 指标与瓶颈迁移的解释一致：

| Metric | V4 | V6 |
|---|---:|---:|
| L1/TEX throughput | 71.9% | 38.5% |
| Compute throughput | 64.0% | 74.8% |
| Eligible warps/scheduler | 0.92 | 1.32 |
| Issued warps/scheduler | 0.40 | 0.49 |
| No Eligible | 60.3% | 51.4% |

完整性能 ablation 为：

| Version | Loading | Ownership | TFLOP/s | 相对 pedantic cuBLAS |
|---|---|---|---:|---:|
| V4 | scalar | continuous | 9.38 | 65.1% |
| V5 | vectorized | continuous | 10.70 | 74.3% |
| V5b | scalar | striped | 10.24 | 71.1% |
| V6 | vectorized | striped | 10.97 | 76.1% |

因此 ownership 的隔离收益约为 V4→V5b 的 9%，或在 vectorized loading 下 V5→V6 的 2.5%；收益随其余路径的瓶颈而变化。

SOL 结果与“shared/L1TEX pressure 降低、更多 warps eligible、compute-side utilization 上升”一致；由于 V4→V6 是累计变化，这些指标本身不把收益唯一归因于 ownership 或 bank conflicts。`Compute Throughput` 是 constituent counters 的最高 `% peak`，不自动等于 useful FP32 FLOP/s 相对 FP32 roof。只有 SOL breakdown 确认 FP32 pipeline 为主导项，并将 GFLOP/s 与同一 clock basis 的 FP32 roof 对比后，才能说更接近 FP32 compute roof。

## 9.8 Takeaway

> Thread tile 不只是每线程计算多少输出，还规定 warp 如何访问 shared memory 和 global C。高性能 mapping 必须同时满足 register reuse、shared banks 和 global coalescing。

## 9.9 Thread Assignment 何时不够

thread assignment 能改变 lane 到 logical element 的对应关系，但不能改变被访问地址集合本身。

典型反例是固定 row-major shared tile 的列读取：

完整 Layout Lab 位于 `code/memory-layout/bank_conflict_demo.cu`：T0 coalesced copy、T1
naive transpose、T2 shared `[32][32]`、T3 padded `[32][33]`、T4 XOR-swizzled
`[32][32]`。在课程 A100、`4096 x 4096` 的一次测量中，T2 为 767 GB/s，
NCU SourceCounters 报告 16,252,928 个 excessive shared wavefronts（占
17,301,504 total 的 94%）；T3/T4 分别为 1446/1453 GB/s，且未触发该
uncoalesced-shared-access warning。这些是指定 build、GPU 和 NCU 版本的
course measurement，最终幻灯片数据仍应在固定运行条件下重测。

```cpp
__shared__ float tile[32][32];
float x = tile[lane][fixed_col];
```

32 个地址的 word offsets 为：

```text
fixed_col,
32 + fixed_col,
64 + fixed_col,
...
```

它们全部映射到同一个 bank。只对 lanes 做任意 permutation，地址集合仍然不变，因此仍然访问同一个 bank。此时需要改变以下至少一项：

- physical layout，例如 `[32][33]` padding；
- logical-to-physical swizzle；
- access instruction 的分解或调度；
- 数据所有权和后续算法组织，使一条指令不再读取该列地址集合。

因此应区分：

1. **Ownership-induced conflict**：V4 的 B fragment 就属于这一类，可以通过 striped ownership 修复。
2. **Layout-induced conflict**：固定 row-major tile 的 column gather 中，单纯重新编号 lanes 无法修复，需要改变 layout 或 access decomposition。
3. **Inherent width cost**：一条宽 shared-memory instruction 即使没有 bank conflict，也可能需要多个 wavefronts。不能用 `wavefronts > instructions` 定义冲突；应在同一 NCU 版本中查看 Source page 的 actual、ideal 和 excessive shared wavefronts，并结合 Shared Memory table 的 Bank Conflicts。

对 FP32 SIMT GEMM，thread assignment 经常可以解决 mainloop 的 A/B shared loads，但未必能同时让以下所有路径都最优：

- global A/B cooperative loads；
- shared stores；
- A/B shared fragment loads；
- final C stores。

成熟 GEMM 因此可能使用不同的 mainloop ownership 和 epilogue ownership，并通过 shared-memory exchange 在两者之间转换。CUTLASS 的独立 epilogue 正是在处理这类多目标约束。

---

# 10. V6 最终 Kernel 骨架

下面是最终强 baseline 的结构，而不是可直接编译的完整实现：

```cpp
template <bool Aligned>
__global__ void gemm_v06_simt_128x128x8(
    const float* __restrict__ A,
    const float* __restrict__ B,
    float* __restrict__ C,
    int M,
    int N,
    int K) {
    constexpr int BM = 128;
    constexpr int BN = 128;
    constexpr int BK = 8;
    constexpr int TM = 8;
    constexpr int TN = 8;

    __shared__ float As[BM][BK];
    __shared__ float Bs[BK][BN];

    int tid = threadIdx.x;
    int tr = tid / 16;
    int tc = tid % 16;

    int block_m = blockIdx.y * BM;
    int block_n = blockIdx.x * BN;

    float acc[TM][TN] = {};

    for (int k0 = 0; k0 < K; k0 += BK) {
        // Each thread loads one float4 from A and one float4 from B.
        // The general path performs predicated scalar loads and zero-fill.
        load_A_tile<Aligned>(A, As, M, K, block_m, k0, tid);
        load_B_tile<Aligned>(B, Bs, K, N, k0, block_n, tid);

        __syncthreads();

        #pragma unroll
        for (int k = 0; k < BK; ++k) {
            float reg_a[TM];
            float reg_b[TN];

            #pragma unroll
            for (int i = 0; i < TM; ++i) {
                reg_a[i] = As[tr + i * 16][k];
            }

            #pragma unroll
            for (int j = 0; j < TN; ++j) {
                reg_b[j] = Bs[k][tc + j * 16];
            }

            #pragma unroll
            for (int i = 0; i < TM; ++i) {
                #pragma unroll
                for (int j = 0; j < TN; ++j) {
                    acc[i][j] = fmaf(reg_a[i], reg_b[j], acc[i][j]);
                }
            }
        }

        __syncthreads();
    }

    #pragma unroll
    for (int i = 0; i < TM; ++i) {
        int row = block_m + tr + i * 16;

        #pragma unroll
        for (int j = 0; j < TN; ++j) {
            int col = block_n + tc + j * 16;
            if (row < M && col < N) {
                C[row * N + col] = acc[i][j];
            }
        }
    }
}
```

Launch：

```cpp
dim3 block(256);
dim3 grid(ceil_div(N, 128), ceil_div(M, 128));
```

最终实现中，`load_A_tile` 和 `load_B_tile` 是否保持为 helper，要根据编译后的 SASS 和寄存器分配决定。教学代码可以直接内联写在 kernel 中，以便逐版本 diff。

---

# 11. V7: Parameter Search and Shape Specialization

`128 x 128 x 8` 是合理的教学起点，不是所有 GPU、所有矩阵形状的通用最优解。

建议搜索：

```text
CTA tile:
    64x64, 128x64, 64x128, 128x128

BK:
    8, 16, 32

threads/CTA:
    128, 256

thread tile:
    4x4, 8x4, 4x8, 8x8
```

每个候选都必须检查：

- global sectors 是否接近 ideal；
- shared excessive wavefronts；
- registers/thread；
- spill loads/stores；
- shared memory/block；
- resident blocks/warps；
- eligible warps 和 issue rate；
- FP32 pipeline utilization；
- 完整 tile 与非整除尺寸的 duration。

不同形状适合不同 workload：

- 大方阵可使用较大 CTA tile 获取高 reuse。
- 小 M/N、大 K 可能没有足够 CTAs 填满 GPU。
- 矩形 GEMM 可能偏好 `128 x 64` 或 `64 x 128`。
- 大 tile 在边界上可能浪费大量线程和 FMA。

> 最终高性能版本应是一小组 shape-specialized kernels 加 dispatch，而不是一个参数对所有输入负责。

---

# 12. 为什么暂时不加入其他优化

## 12.1 Double Buffering

double buffering 的主要价值是重叠：

```text
load tile k+1
with
compute tile k
```

这已经是 two-stage software pipeline。只分配两块 shared buffer 但不重叠 load/compute，只会增加 shared-memory footprint并可能降低 occupancy，几乎没有价值。

因此本实践延后 double buffering。

## 12.2 `cp.async` / LDGSTS / TMA

这些机制优化 global-to-shared 搬运和流水线，本讲只保留同步 load-register-store 路径。后续可将 V6 作为 baseline，比较：

```text
LDG -> temporary registers -> STS
```

与异步直接 global-to-shared 路径。

## 12.3 Shared A Transpose

在 V6 的 striped mapping 中，`As[BM][BK]` compute access 已经主要是 broadcast/multicast。将 A 转置为 `[BK][BM]` 不一定减少 shared requests，反而会增加 cooperative store 和索引复杂度。

shared A transpose 在需要 vectorized shared fragment load 或另一种 warp tile layout 时可能有价值，应通过实际 SASS 和 shared wavefronts 决定，不应作为模板化必选项。

## 12.4 Shared Padding/Swizzle

padding 和 swizzle 应由具体 lane-address conflict 证明。V6 已通过 ownership 解决主要 conflict，额外 layout 变换可能只增加地址计算。

更复杂的 swizzle 适合后续 Tensor Core fragment、warp-level vector loads 或 async pipeline 课程。

## 12.5 Explicit Warp Tiling and Shared Epilogue

真正接近成熟 GEMM library 时，通常会明确划分：

```text
CTA tile -> warp tile -> thread tile
```

并使用独立 epilogue 将适合 mainloop 的 accumulator ownership 转换成适合 global store 的 striped ownership。CUTLASS 还会加入 bank-conflict-free layouts 和软件流水线。

这些是从“强教学 kernel”到“library-quality kernel”的下一步。若时间允许，可作为 stretch version V8，但不应掩盖 V0 到 V6 的主因果链。

---

# 13. Benchmark 和 Correctness Harness

所有版本必须共用同一个 harness。

## 13.1 CLI

```text
--kernel <v00|v01|...|v06>
--m <int>
--n <int>
--k <int>
--warmup <int>       default: 5
--iters <int>        default: 20
--seed <int>         default: 1
--verify / --no-verify
--profile            one target launch for NCU
--list-kernels
```

## 13.2 统一 Launcher

```cpp
using GemmLauncher = void (*)(
    const float* A,
    const float* B,
    float* C,
    int M,
    int N,
    int K,
    cudaStream_t stream);
```

每个版本使用唯一 kernel symbol，例如：

```cpp
extern "C" __global__ void gemm_v04_register_2d(...);
```

这可以让 NCU 精确过滤目标 kernel。

## 13.3 Correctness Cases

快速 smoke cases：

```text
1 x 1 x 1
3 x 5 x 7
16 x 16 x 16
31 x 33 x 29
127 x 193 x 61
257 x 263 x 269
```

其中尺寸顺序为 `M x N x K`。

性能和边界 cases：

```text
1024 x 1024 x 1024
2048 x 2048 x 2048
4096 x 4096 x 4096
4093 x 4099 x 4091
```

不能只验证方阵，否则 M/N/K 交换可能被掩盖。

## 13.4 Reference

小尺寸使用 CPU double accumulation。大尺寸使用 pedantic FP32 cuBLAS。

cuBLAS 必须禁止 TF32/Tensor Core fast mode，例如使用：

```cpp
cublasSetMathMode(handle, CUBLAS_PEDANTIC_MATH);
```

以及环境支持时的：

```cpp
CUBLAS_COMPUTE_32F_PEDANTIC
```

row-major reference 可通过：

\[
C^T=B^TA^T
\]

交换 A/B 和 M/N 参数调用 column-major cuBLAS，而无需真的转置数据。

## 13.5 Error Criterion

不要要求 bitwise equality。使用：

\[
|x-r|\leq\text{atol}+\text{rtol}|r|
\]

可从以下默认值开始：

```text
atol = 1e-4
rtol = 1e-3
```

同时报告：

- max absolute error；
- max relative error；
- max scaled error；
- mismatch count；
- first/worst mismatching index；
- NaN/Inf。

每次测试前将 C 填成 NaN，以发现未写输出和 grid coverage 错误。

## 13.6 Timing

只计 kernel，不包含 allocation、H2D/D2H 或 reference。

```cpp
cudaEventRecord(start, stream);
for (int i = 0; i < iters; ++i) {
    launch(..., stream);
}
cudaEventRecord(stop, stream);
cudaEventSynchronize(stop);
```

\[
\text{GFLOP/s}
=
\frac{2MNK}{\text{seconds}\times10^9}
\]

应至少报告：

```text
GPU model
compute capability
CUDA/driver version
kernel version and tile shape
M, N, K
average or median milliseconds
GFLOP/s
percentage of pedantic FP32 cuBLAS
correctness result
```

## 13.7 Profile Mode

`--profile` 模式只执行一次目标 kernel，不执行 cuBLAS reference 或 benchmark loop。NCU 再通过唯一 kernel 名和 `--launch-count 1` 双重过滤。

---

# 14. NCU 验证矩阵

| Version | 应解决的问题 | 主要观察 | 预期新瓶颈 |
|---|---|---|---|
| V0 | baseline | Long Scoreboard、global loads、FP32 utilization | global/cache traffic |
| V1 | sector efficiency | ideal/excessive sectors | reuse 不足 |
| V2 | global reuse | DRAM/L2 bytes/FLOP、AI | shared loads、barriers |
| V3 | 1D register reuse | shared loads/FMA、FP32 utilization | A/B 双向 reuse 不平衡 |
| V4 | 2D outer product | FFMA ratio、registers/thread | bank conflict、register pressure |
| V5 | movement instruction cost | LDG instruction count、integer address ops | shared conflict、barrier |
| V6 | shared bank efficiency | excessive wavefronts、Short Scoreboard | FP32、barrier、unhidden tile load |
| V7 | hardware-specific balance | duration、eligible warps、spill、all SOL units | architecture/problem dependent |

固定分析顺序：

1. Duration/GFLOP/s 是否改善？
2. 该版本想消除的 metric 是否真的改善？
3. FLOPs、bytes 和 correctness 是否保持可比？
4. 新的主要瓶颈是什么？
5. 该瓶颈是本讲继续处理，还是后续 pipeline 课程处理？

建议 section：

```bash
ncu \
  --kernel-name-base function \
  --kernel-name 'regex:^gemm_v06_simt_128x128x8$' \
  --launch-count 1 \
  --section SpeedOfLight \
  --section MemoryWorkloadAnalysis \
  --section ComputeWorkloadAnalysis \
  --section SchedulerStats \
  --section WarpStateStats \
  --section Occupancy \
  --section LaunchStats \
  --section SourceCounters \
  -o gemm_v06_4096 \
  ./build/gemm_bench --kernel v06 --m 4096 --n 4096 --k 4096 \
  --profile --no-verify
```

section 名和 metric 随 NCU 版本及架构变化，应以目标机器上的 `ncu --list-sections` 为准。

---

# 15. Correctness 和性能陷阱

1. **Barrier 前提前 return。** 边界 block 中所有线程仍必须参与 cooperative load 和 barrier。
2. **K tail 未 zero-fill。** 无效 shared 元素若保留上一轮内容，会产生静默数值错误。
3. **遗漏第二个 barrier。** 单 shared buffer 被下一轮覆盖时，其他线程可能仍在读取当前 tile。
4. **对越界地址执行 `float4` load。** 即使之后忽略无效分量，load 本身仍非法。
5. **实际地址未 16-byte 对齐。** 基指针对齐不代表每一行起点都对齐。
6. **Accumulator spill。** `acc[8][8]` 已占至少 64 registers，必须检查 `ptxas -v` 和 local-memory traffic。
7. **动态索引导致 local memory。** `BK/TM/TN` 应为编译期常量，内层循环应完全展开。
8. **只测试方阵或整除尺寸。** 很多 M/N 交换和 tail bugs 会被隐藏。
9. **把 NCU replay time 当 benchmark time。** 性能来自无 profiler 的 CUDA events；NCU 用来解释。
10. **拿 TF32 Tensor Core cuBLAS 作比较。** 必须使用 pedantic FP32 reference和 baseline。
11. **只报告最好一次。** 应预热并报告稳定统计量，同时说明 clock、power 和温度环境。
12. **反复使用同一小 buffer。** 可能得到不真实的热 L2 benchmark；需要明确这是 steady-state hot-cache 还是 cold/rotating-buffer 测试。

建议每个版本执行：

```bash
compute-sanitizer --tool memcheck \
  ./build/gemm_bench --kernel v04 --m 257 --n 263 --k 269 \
  --warmup 1 --iters 1
```

引入 shared-memory/synchronization 变化后再执行：

```bash
compute-sanitizer --tool racecheck \
  ./build/gemm_bench --kernel v04 --m 257 --n 263 --k 269 \
  --warmup 1 --iters 1
```

---

# 16. 推荐代码结构

```text
Makefile
code/
  README.md
  gemm/
    README.md
    gemm_bench.cu
  memory-layout/
    README.md
    bank_conflict_demo.cu
  scripts/
    profile-gemm.sh
    profile-memory-layout.sh
```

教学代码优先保证逐版 diff 清晰：

- 变量名和 launcher 接口保持稳定；
- V0/V1/V2/V3 可以独立阅读；
- V4/V5/V5b/V6 共用一个只有 `Vectorized`/`Striped` 两个布尔参数的 body，使两因素消融保持 tile 和控制流一致；
- 不在同一版本同时改 tile shape、mapping、vector width 和 shared layout；
- harness 不复制，每个版本走完全相同的验证与计时路径。

---

# 17. 实践课最终应形成的心智模型

```text
V0/V1:
    Make each warp request efficient.

V2:
    Reduce global requests through block-level reuse.

V3/V4:
    Reduce shared requests through register reuse and outer products.

V5:
    Reduce the instruction cost of data movement.

V6:
    Match lane ownership to banked shared memory and coalesced stores.

V7:
    Balance reuse, ILP, residency, and problem shape on the target GPU.
```

最终不是得到一串孤立技巧，而是得到一条层次化推理链：

```text
algorithmic reuse
-> CTA tile in shared memory
-> thread tile in registers
-> warp/lane mapping for physical memory systems
-> resource and occupancy balance
-> profiler-guided parameter selection
```

完成 V6 后，剩余的典型问题将是：

- tile load 与 compute 没有重叠；
- barrier 和 single-buffer mainloop 仍然暴露延迟；
- 大 accumulator tile 导致 occupancy 较低；
- mainloop ownership 与最高效 epilogue ownership可能不同。

这些问题自然导向下一阶段：double buffering、`cp.async`/LDGSTS、TMA、explicit warp tiling、shared epilogue 和 software pipelining。

---

# 参考资料

- [Simon Boehm: How to Optimize a CUDA Matmul Kernel for cuBLAS-like Performance](https://siboehm.com/articles/22/CUDA-MMM)
- [Simon Boehm: SGEMM_CUDA](https://github.com/siboehm/SGEMM_CUDA)
- [NVIDIA CUTLASS: Efficient GEMM in CUDA](https://docs.nvidia.com/cutlass/latest/media/docs/cpp/efficient_gemm.html)
- [NVIDIA CUDA C++ Best Practices Guide](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html)
- [NVIDIA: Efficient Matrix Transpose in CUDA C/C++](https://developer.nvidia.com/blog/efficient-matrix-transpose-cuda-cc/)
- [NVIDIA: Increase Performance with Vectorized Memory Access](https://developer.nvidia.com/blog/cuda-pro-tip-increase-performance-with-vectorized-memory-access/)
- [Amanzhol Salykov: Advanced Matrix Multiplication Optimization on NVIDIA GPUs](https://salykova.github.io/sgemm-gpu)
- [CUTLASS GEMM Performance Measurement Guidelines](https://docs.nvidia.com/cutlass/latest/media/docs/cpp/gemm_performance_measurement_methodology_guidelines.html)

# Session 2: Memory Hierarchy and Fast SIMT GEMM

**Weiming HPC Training Camp × LCPU AI Infra Seminars**

本讲用一个不依赖 Tensor Core 的 FP32 GEMM，建立从 workload、hardware 到 measurement 的完整推理链：

> Workload 决定值得复用的数据，hardware 决定数据能放在哪里，profiling 负责验证瓶颈是否真的迁移。

课程最终目标不是复刻 cuBLAS，而是让听众能够解释并实现：coalescing、shared-memory tiling、register tiling、bank-aware mapping、latency hiding，以及它们对应的硬件约束。

## 课程主结果

`code/gemm/gemm_bench.cu` 包含一条经过 A100 80GB PCIe 测试的完整演进路线：

| 版本 | 主要机制 | 4096³ 实测 |
|---|---|---:|
| V1 | 故意错误的 warp mapping（反例） | 0.43 TFLOP/s |
| V0 | coalesced naive | 2.11 TFLOP/s |
| V2 | shared-memory tiling | 3.95 TFLOP/s |
| V3 | 1D register tiling | 6.02 TFLOP/s |
| V4 | 2D register tiling | 9.38 TFLOP/s |
| V5 | 2D tiling + `float4` loading | 10.70 TFLOP/s |
| V5b | 2D tiling + bank-aware ownership | 10.24 TFLOP/s |
| V6 | vectorized + bank-aware | **10.97 TFLOP/s** |
| cuBLAS pedantic | FP32 CUDA Core baseline | **14.41 TFLOP/s** |

V6 在 4096³ 上稳定复现 pedantic FP32 cuBLAS 的 **76.1%–76.2%**。8192³ 曾观测到 **90.4%**，但 2026-07-28 在两张空闲 A100 上复验为 **80.7%–80.8%**；因此课程只采用 4096³ 的约 76% 作为 headline，不将 8192³ 的单次高值泛化为跨 shape 性能保证。

比较双方均使用严格 FP32：

- 自写 kernel：FP32 CUDA Core / FFMA；不使用 Tensor Core、`cp.async`/TMA、double buffering 或 software pipeline。
- cuBLAS：`CUBLAS_COMPUTE_32F_PEDANTIC` + `CUBLAS_PEDANTIC_MATH`。

完整测量边界、roofline 与 NCU 解释见 [A100 results](docs/results/a100-pcie80.md)。

## 三幕结构

1. **Act I — Preview**：从 GEMM 语义、data reuse 和 Roofline 看完整优化地图。
2. **Act II — Explain**：从 warp、SMSP、memory hierarchy、banked SRAM 和 register file 解释优化为何存在。
3. **Act III — Rebuild**：按 V0 → V6 重建 kernel，并用 correctness harness 与 NCU 验证瓶颈迁移。

详细讲义见 [seminar outline](docs/seminar-outline.md) 和 [Act III walkthrough](docs/act-iii-gemm-evolution.md)。

## Repository layout

```text
.
├── Makefile
├── code/
│   ├── README.md
│   ├── gemm/                  # V0–V6 + pedantic cuBLAS harness
│   ├── memory-layout/         # transpose/padding/XOR microbenchmark
│   └── scripts/               # reproducible NCU commands
├── docs/
│   ├── seminar-outline.md
│   ├── act-iii-gemm-evolution.md
│   ├── evidence-checklist.md
│   └── results/a100-pcie80.md
└── exercises/README.md
```

## Quick start

在 CUDA 13 / A100（SM80）环境中：

```bash
make CUDA_ARCH=80

./build/gemm_bench --kernel all --m 4096 --n 4096 --k 4096 \
  --warmup 3 --iters 10

./build/gemm_bench --kernel all --m 257 --n 263 --k 269 \
  --warmup 1 --iters 1
```

运行 shared-memory layout 实验：

```bash
./build/bank_conflict_demo --kernel all --m 4096 --n 4096 \
  --warmup 3 --iters 20
```

采集 NCU 报告：

```bash
code/scripts/profile-gemm.sh v06 4096 4096 4096
code/scripts/profile-memory-layout.sh t2 4096 4096
```

性能发布前请固定 GPU、clock、版本、GPU idle policy、warmup/iterations，并保留原始日志。单次课程机器结果不是架构常数。

## 课程验收标准

以 A100 80GB PCIe、4096³、pedantic FP32 cuBLAS 为基准：

| 等级 | 目标 |
|---|---:|
| Correct baseline | > 2 TFLOP/s |
| Basic tiled | > 3.5 TFLOP/s |
| Good SIMT | > 6 TFLOP/s |
| Strong SIMT | > 9 TFLOP/s |
| Final Act III | > 10.5 TFLOP/s and ≥ 70% cuBLAS |
| Stretch | ≥ 80% cuBLAS |

## Contributors

- @周宇轩
- @林若瑜

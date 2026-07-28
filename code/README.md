# Code labs

本目录只保留两个可独立运行、可验证、可 profile 的实验。所有 GEMM 版本共享同一个输入、correctness reference、计时方式和 pedantic FP32 cuBLAS baseline，避免把 harness 差异误认为 kernel 优化。

## 1. GEMM evolution

入口：[gemm/gemm_bench.cu](gemm/gemm_bench.cu)

| Kernel | 主要变化 | 教学目的 |
|---|---|---|
| `v01` | 故意让 lane 沿 M 维变化 | controlled bad mapping / coalescing 反例 |
| `v00` | lane 沿连续 N 维变化 | coalesced naive baseline |
| `v02` | `32×32×32` shared tile | CTA-level global reuse |
| `v03` | `64×32×8`, `8×1` thread tile | 1D register reuse |
| `v04` | `128×128×8`, `8×8` thread tile | 2D outer-product reuse |
| `v05` | `float4` cooperative loads | 更少、更宽的数据移动指令 |
| `v05b` | scalar loads + striped ownership | 单独观察 bank-aware mapping |
| `v06` | vectorized loads + striped ownership | 本讲最终 SIMT kernel |

`v01` 是反例而不是优化步骤。性能主线采用 `v00 → v02 → v03 → v04 → v05 → v06`；`v05b` 用于消融 vectorization 与 ownership 两个变量。

## 2. Memory-layout microbenchmark

入口：[memory-layout/bank_conflict_demo.cu](memory-layout/bank_conflict_demo.cu)

Canonical GEMM 不应为了讲 bank conflict 而凭空加入 padding。这个 transpose lab 用天然需要 shared transpose 的 workload 隔离展示：

| Kernel | 操作 | Shared layout |
|---|---|---|
| `t0` | coalesced copy baseline | none |
| `t1` | naive transpose | none |
| `t2` | shared transpose | `[32][32]` |
| `t3` | padded shared transpose | `[32][33]` |
| `t4` | XOR-swizzled shared transpose | `[32][32]` physical |

## Build and verify

```bash
make CUDA_ARCH=80
make correctness
```

`make correctness` 使用非方阵、非 tile 整除尺寸，专门覆盖边界 predicate。性能实验再单独使用 4096³ 或 8192³。

## Measurement discipline

- 不把 TF32 Tensor Core cuBLAS 与 FP32 CUDA Core kernel 比较。
- 一次 NCU invocation 只 profile 一个明确 kernel。
- `--profile` 只发射一次 kernel，避免把 replay 与 timing 混在一起。
- 对相邻版本的因果解释依赖受控消融与 counters，而不只看 runtime。
- 记录 GPU、CUDA/NCU、clock、build flags、shape、warmup、iterations 和 GPU idle policy。

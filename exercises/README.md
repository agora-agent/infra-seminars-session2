# Exercises

所有实验先做 correctness，再做 timing，最后做 NCU。不要用 profiler 中的 replayed duration 代替独立 timing。

## Lab 0 — Reproduce the harness

```bash
make CUDA_ARCH=80
make correctness
```

解释为什么 correctness case 使用 `257 × 263 × 269`，而不是只测 4096³。确认 cuBLAS reference 使用 pedantic FP32，而不是默认 TF32 Tensor Core 路径。

## Lab 1 — Warp mapping and coalescing

比较 `v01` 与 `v00`：

```bash
./build/gemm_bench --kernel v01 --m 4096 --n 4096 --k 4096
./build/gemm_bench --kernel v00 --m 4096 --n 4096 --k 4096
```

任务：画出一个 warp 的 `(row, col)`；预测 A/B load 与 C store 的地址；再用 global sectors 和 duration 验证。说明 `v01` 为什么是 controlled bad mapping，而不是优化路线中的起点。

## Lab 2 — Global-to-shared reuse

比较 `v00` 与 `v02`，计算两者在“代码请求”和“global-to-shared”两个边界上的 arithmetic intensity。解释：

- 为什么 shared tiling 减少重复 global load；
- single-buffer mainloop 为什么需要两个 `__syncthreads()`；
- 为什么 1024-thread V2 仍不是最终高性能形态。

## Lab 3 — Register microtiles

比较 `v02 → v03 → v04`。主问题：为什么从 1D `8×1` thread tile 到 2D `8×8` outer product 能让 4096³ 从 6.02 提升到 9.38 TFLOP/s？

记录 registers/thread、spill、occupancy、eligible warps、issue rate 与 FP32 pipeline utilization。说明“更高 occupancy”为什么不是唯一目标。

## Lab 4 — Vectorization and bank-aware ownership

做受控四点消融：

| Version | Loading | Ownership |
|---|---|---|
| V4 | scalar | continuous |
| V5 | vectorized | continuous |
| V5b | scalar | striped |
| V6 | vectorized | striped |

比较 shared actual/ideal/excessive wavefronts、L1/TEX throughput、eligible warps 与 runtime。不要把 V4→V6 的累计收益全部归因于 bank conflict。

## Lab 5 — Padding and XOR swizzle

```bash
./build/bank_conflict_demo --kernel all --m 4096 --n 4096 \
  --warmup 3 --iters 20
```

比较 `t2/t3/t4`，用地址到 bank 的映射解释 padding 与 XOR。然后回答：为什么最终 V6 GEMM 的自然布局不需要 padding？

## Lab 6 — Final acceptance

在 A100 80GB PCIe、4096³ 上，目标为：

- 所有 irregular correctness cases 通过；
- V6 ≥ 10.5 TFLOP/s；
- V6 ≥ pedantic FP32 cuBLAS 的 70%；
- no register spills；
- shared load conflicts approximately zero。

Stretch：尝试 double buffering/software pipeline，但必须保持原 V6 作为可比较 baseline，并报告新增复杂度与跨 shape 表现。

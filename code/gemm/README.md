# FP32 SIMT GEMM evolution

`gemm_bench.cu` 同时包含 V0–V6 kernel、统一 launcher、正确性检查、CUDA-event timing，以及 pedantic FP32 cuBLAS baseline。

## Run

```bash
../../build/gemm_bench --kernel all --m 4096 --n 4096 --k 4096 \
  --warmup 3 --iters 10
```

只发射一个 kernel 供 profiler 捕获：

```bash
../../build/gemm_bench --kernel v06 --m 4096 --n 4096 --k 4096 \
  --profile --no-verify
```

## Fixed scope

- Row-major FP32 A/B/C。
- `C = A × B`，即 `alpha=1, beta=0`。
- CUDA Core FFMA，不使用 Tensor Core/TF32。
- 单 buffer mainloop，不使用 `cp.async`、TMA、double buffering 或 software pipeline。
- 正确性 reference 与性能 baseline 都使用 `CUBLAS_COMPUTE_32F_PEDANTIC` 和 `CUBLAS_PEDANTIC_MATH`。

## Reading order

先读 `gemm_v00_naive` 和 `gemm_v01_bad_mapping`；再读独立的 V2/V3；最后读共用的 `gemm_128x128x8_body<Vectorized, Striped>`。后者用两个编译期布尔量形成 V4/V5/V5b/V6 的受控消融：

| Version | `Vectorized` | `Striped` |
|---|---:|---:|
| V4 | false | false |
| V5 | true | false |
| V5b | false | true |
| V6 | true | true |

详细推导见 [Act III walkthrough](../../docs/act-iii-gemm-evolution.md)。

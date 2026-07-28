# Shared-memory layout lab

这个实验把 global coalescing 与 shared-memory bank layout 分开观察。有效带宽按一次 input read 加一次 output write 计算：

```text
bandwidth_gbps = 2 * M * N * sizeof(float) / elapsed_time
```

```bash
../../build/bank_conflict_demo --kernel all --m 4096 --n 4096 \
  --warmup 3 --iters 20
```

A100 课程机器一次观测：

| Kernel | Effective bandwidth | NCU observation |
|---|---:|---|
| `t0` | 1301 GB/s | coalesced copy baseline |
| `t1` | 173 GB/s | strided global stores |
| `t2` | 767 GB/s | 94% shared wavefronts excessive |
| `t3` | 1446 GB/s | no uncoalesced-shared warning |
| `t4` | 1453 GB/s | no uncoalesced-shared warning |

这些数字是 CUDA 13 / NCU 2025.3.1 下的课程观测，不是 A100 常数。发布前应在最终 clock 与 GPU-idleness policy 下重测。

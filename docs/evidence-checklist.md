# CUDA Memory Hierarchy Seminar: Evidence Checklist

Use this checklist while turning the two seminar documents into slides. Every
quantitative statement should identify its evidence class and measurement
boundary.

## Evidence Labels

| Label | Meaning | Acceptable support |
|---|---|---|
| `[CUDA contract]` | Portable programming semantics used for correctness | CUDA C++ Programming Guide |
| `[architecture-scoped]` | Documented performance/resource model | Programming Guide compute-capability appendix, Best Practices Guide, architecture tuning guide |
| `[NCU model]` | Profiler metric or derived-analysis definition | Installed Nsight Compute version documentation and metric descriptions |
| `[A100 measured]` | Observation from the course test system | GPU, CC, CUDA/NCU version, dimensions, SASS/build flags, and run conditions |
| `[course design]` | Teaching sequence, analytical approximation, or custom optimization | Explicit assumptions plus experiment where applicable |

## Slide Review

| Topic | Required label | Review question | Primary official basis |
|---|---|---|---|
| Thread/block/warp semantics | `[CUDA contract]` | Does correctness rely only on documented execution and synchronization semantics? | CUDA C++ Programming Guide: Programming Model |
| Warp lane linearization | `[CUDA contract]` | Is x-fastest thread linearization used when drawing the `16 x 16` block? | CUDA C++ Programming Guide: Thread Hierarchy |
| Global coalescing | `[architecture-scoped]` | Is the 32-byte transaction/sector analysis limited to CC 6.0+ and separated from cache-line or DRAM-burst terminology? | CUDA C++ Best Practices Guide: Coalesced Access to Global Memory |
| Request/sector/wavefront | `[NCU model]` | Are these presented as tool/version-scoped metric concepts rather than CUDA semantics? | Nsight Compute Profiling Guide: Memory Chart and L1TEX wavefront model |
| A100 SMSP organization | `[architecture-scoped]` and `[NCU model]` | Is the four-partition model explicitly limited to GA100/A100? | Ampere Tuning Guide; Nsight Compute Profiling Guide |
| Warp issue and eligibility | `[NCU model]` | Are active, eligible, and issued warps kept distinct? | Nsight Compute Scheduler Statistics and Warp State Statistics |
| Long/Short Scoreboard | `[NCU model]` | Is the exact installed NCU version named, with `Wait` kept distinct? | Nsight Compute Warp State Statistics |
| Occupancy | `[architecture-scoped]` and `[NCU model]` | Are theoretical and achieved occupancy distinguished, and is occupancy not treated as a performance guarantee? | CUDA C++ Programming Guide: Occupancy; Nsight Compute Occupancy section |
| Shared scope and barriers | `[CUDA contract]` | Are both barriers in the single-buffer tiled GEMM justified by visibility and reuse hazards? | CUDA C++ Programming Guide: Shared Memory and Synchronization Functions |
| Shared banks | `[architecture-scoped]` | Are bank count/width claims limited to the documented target architecture? | CUDA C++ Programming Guide: Shared Memory; Best Practices Guide |
| Broadcast/multicast | `[architecture-scoped]` | Is shared read broadcast kept separate from global same-address loads, and are same-address non-atomic writes called undefined? | CUDA C++ Best Practices Guide: Shared Memory and Memory Banks |
| Bank-conflict counters | `[NCU model]` | Are actual/ideal/excessive wavefronts and raw metrics interpreted using the target NCU metric description rather than a universal formula? | Nsight Compute Profiling Guide and `ncu --query-metrics` descriptions |
| A100 L1/shared subsystem | `[architecture-scoped]` | Are 192 KB unified capacity, 164 KB maximum shared capacity, and discrete carveout options stated as A100 facts? | Ampere Tuning Guide: Unified Shared Memory/L1/Texture Cache |
| L2 block ordering | `[course design]` | Does the slide say locality probability rather than guaranteed CTA order or cache hit? | CUDA C++ Programming Guide block scheduling guarantees |
| Roofline | `[course design]` and `[NCU model]` | Does every AI use a named byte boundary, and is the shared roof identified as a pattern-specific course model? | Nsight Compute Roofline documentation; course equations |
| Register count and spill | `[A100 measured]` | Are registers/thread and local-memory traffic taken from ptxas/NCU instead of inferred solely from source arrays? | ptxas verbose output; Nsight Compute Launch/Memory sections |
| cuBLAS baseline | `[A100 measured]` | Is pedantic FP32 configured, and are dimensions, clock conditions, warmups, and iterations recorded? | cuBLAS documentation plus benchmark log |

## Experiment Review

| Experiment | Must hold constant | Correctness case | Required evidence |
|---|---|---|---|
| Coalescing microbenchmark | instruction work and useful bytes where possible | irregular length | actual/ideal sectors, downstream bytes, duration |
| V0 vs controlled bad mapping | matrix dimensions, block size, per-thread output | `257 x 263 x 269` | lane-address analysis, sectors, duration |
| V2 shared tiling | numerical semantics and benchmark harness | non-tile-divisible dimensions | dynamic global-load metric, L2/HBM bytes, barriers, duration |
| V4/V5/V5b/V6 ablation | CTA/thread tile and matrix dimensions | same irregular case | all four runtimes, SASS/registers, shared metrics |
| T0–T4 transpose lab | `32 x 8` launch shape and dimensions | `1027 x 1031` | effective bandwidth, sectors, actual/ideal/excessive shared wavefronts, metric descriptions |
| Fixed-condition final table | GPU id, clocks, build, data, warmups, iterations | full harness | raw log, median or stated aggregation, cuBLAS baseline |

## Measurement Record

Record this header with every course result:

```text
GPU model and device index:
Compute capability:
Driver / CUDA / nvcc / NCU versions:
Source revision and build command:
Kernel name and SASS identifier/report:
M, N, K or transpose dimensions:
Warmup and measured iterations:
Application clocks and observed SM/memory clocks:
GPU idle/exclusivity condition:
NCU sections/metrics and replay mode:
```

Do not promote a result to an architecture rule merely because it repeats on
one A100. Use `reports`, `is consistent with`, and `supports the interpretation`
for profiler evidence; reserve causal attribution for a controlled ablation.

# Optimized GEMM

This directory will contain the fully optimized GEMM kernel with:
- Thread microtiles (register-level data reuse)
- Bank conflict avoidance (padding/swizzle)
- Optimal tile sizes tuned for occupancy
- Warp-level coalesced memory access patterns

## TODO
- [ ] Implement register-tiled GEMM
- [ ] Add NCU profiling screenshots
- [ ] Benchmark against cuBLAS

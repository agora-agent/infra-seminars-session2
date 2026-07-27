# Exercises

## Exercise 1: Roofline Analysis
Compute the arithmetic intensity of the strawman GEMM and tiled GEMM.
How many bytes are loaded from global memory per FMA?

## Exercise 2: Bank Conflict Detection
Use NCU to identify bank conflicts in the tiled GEMM.
Apply padding to fix them and measure the improvement.

## Exercise 3: Occupancy Tuning
Experiment with different tile sizes and measure:
- Occupancy
- L2 hit rate
- Achieved bandwidth

## Exercise 4: Full Optimization
Starting from the tiled GEMM, apply all optimizations from Act II & III
to approach the Speed of Light.

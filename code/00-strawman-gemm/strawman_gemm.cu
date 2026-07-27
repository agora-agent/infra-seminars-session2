// Strawman GEMM: each thread computes one element of C
// This is the simplest (and slowest) implementation
#include <cuda_runtime.h>
#include <stdio.h>

__global__ void gemm_strawman(float *A, float *B, float *C, int M, int N, int K) {
    int row = blockIdx.y * blockDim.y + threadIdx.y;
    int col = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (row < M && col < N) {
        float sum = 0.0f;
        for (int k = 0; k < K; k++) {
            sum += A[row * K + k] * B[k * N + col];
        }
        C[row * N + col] = sum;
    }
}

// TODO: Add host code, timing, and comparison

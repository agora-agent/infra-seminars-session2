#include <cublas_v2.h>
#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t error = (call);                                                  \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "CUDA error at %s:%d: %s\n", __FILE__, __LINE__,    \
                   cudaGetErrorString(error));                                   \
      std::exit(1);                                                              \
    }                                                                            \
  } while (0)

#define CUBLAS_CHECK(call)                                                       \
  do {                                                                          \
    cublasStatus_t status = (call);                                               \
    if (status != CUBLAS_STATUS_SUCCESS) {                                       \
      std::fprintf(stderr, "cuBLAS error at %s:%d: %d\n", __FILE__, __LINE__,   \
                   static_cast<int>(status));                                    \
      std::exit(1);                                                              \
    }                                                                            \
  } while (0)

constexpr int ceil_div(int x, int y) { return (x + y - 1) / y; }

// V0: the useful naive baseline. CUDA linearizes threadIdx.x first, so nearby
// lanes vary along N and issue regular B loads and C stores.
extern "C" __global__ void gemm_v00_naive(const float* __restrict__ A,
                                            const float* __restrict__ B,
                                            float* __restrict__ C, int M, int N,
                                            int K) {
  int row = blockIdx.y * blockDim.y + threadIdx.y;
  int col = blockIdx.x * blockDim.x + threadIdx.x;
  if (row >= M || col >= N) return;

  float acc = 0.0f;
  for (int k = 0; k < K; ++k) {
    acc = fmaf(A[static_cast<size_t>(row) * K + k],
               B[static_cast<size_t>(k) * N + col], acc);
  }
  C[static_cast<size_t>(row) * N + col] = acc;
}

// V1: a controlled counterexample, not an optimization after V0. Swapping the
// row/column ownership makes nearby lanes walk the leading dimension.
extern "C" __global__ void gemm_v01_bad_mapping(
    const float* __restrict__ A, const float* __restrict__ B,
    float* __restrict__ C, int M, int N, int K) {
  int row = blockIdx.y * blockDim.x + threadIdx.x;
  int col = blockIdx.x * blockDim.y + threadIdx.y;
  if (row >= M || col >= N) return;

  float acc = 0.0f;
  for (int k = 0; k < K; ++k) {
    acc = fmaf(A[static_cast<size_t>(row) * K + k],
               B[static_cast<size_t>(k) * N + col], acc);
  }
  C[static_cast<size_t>(row) * N + col] = acc;
}

// V2: one output per thread, but A/B tiles are staged once per CTA. The 1024
// thread launch is intentionally simple enough to expose the cost of barriers
// and the need for register-level reuse in later versions.
extern "C" __global__ __launch_bounds__(1024)
void gemm_v02_shared_32(const float* __restrict__ A,
                        const float* __restrict__ B, float* __restrict__ C,
                        int M, int N, int K) {
  __shared__ float As[32][32];
  __shared__ float Bs[32][32];

  int tx = threadIdx.x;
  int ty = threadIdx.y;
  int row = blockIdx.y * 32 + ty;
  int col = blockIdx.x * 32 + tx;
  float acc = 0.0f;

  for (int k0 = 0; k0 < K; k0 += 32) {
    As[ty][tx] = row < M && k0 + tx < K
                     ? A[static_cast<size_t>(row) * K + k0 + tx]
                     : 0.0f;
    Bs[ty][tx] = k0 + ty < K && col < N
                     ? B[static_cast<size_t>(k0 + ty) * N + col]
                     : 0.0f;
    __syncthreads();

#pragma unroll
    for (int k = 0; k < 32; ++k) acc = fmaf(As[ty][k], Bs[k][tx], acc);
    __syncthreads();
  }

  if (row < M && col < N) C[static_cast<size_t>(row) * N + col] = acc;
}

// V3: each thread owns an 8x1 output strip. This is the first explicit
// shared-to-register reuse step.
extern "C" __global__ __launch_bounds__(256)
void gemm_v03_register_1d(const float* __restrict__ A,
                          const float* __restrict__ B, float* __restrict__ C,
                          int M, int N, int K) {
  constexpr int BM = 64, BN = 32, BK = 8, TM = 8;
  __shared__ float As[BM][BK];
  __shared__ float Bs[BK][BN];

  int tid = threadIdx.x;
  int tr = tid / BN;
  int tc = tid % BN;
  int block_m = blockIdx.y * BM;
  int block_n = blockIdx.x * BN;
  float acc[TM] = {};

  for (int k0 = 0; k0 < K; k0 += BK) {
    for (int idx = tid; idx < BM * BK; idx += 256) {
      int lm = idx / BK;
      int lk = idx % BK;
      int gm = block_m + lm;
      int gk = k0 + lk;
      As[lm][lk] = gm < M && gk < K
                       ? A[static_cast<size_t>(gm) * K + gk]
                       : 0.0f;
    }
    int lk = tid / BN;
    int ln = tid % BN;
    int gk = k0 + lk;
    int gn = block_n + ln;
    Bs[lk][ln] = gk < K && gn < N
                     ? B[static_cast<size_t>(gk) * N + gn]
                     : 0.0f;
    __syncthreads();

#pragma unroll
    for (int k = 0; k < BK; ++k) {
      float b = Bs[k][tc];
#pragma unroll
      for (int i = 0; i < TM; ++i) {
        acc[i] = fmaf(As[tr * TM + i][k], b, acc[i]);
      }
    }
    __syncthreads();
  }

#pragma unroll
  for (int i = 0; i < TM; ++i) {
    int row = block_m + tr * TM + i;
    int col = block_n + tc;
    if (row < M && col < N) C[static_cast<size_t>(row) * N + col] = acc[i];
  }
}

// V4/V5/V5b/V6 share one 128x128x8 implementation so that two independent
// choices can be ablated without changing the CTA or thread tile:
//   Vectorized: scalar cooperative loads vs float4 cooperative loads.
//   Striped:    contiguous 8x8 ownership vs bank-aware striped ownership.
template <bool Vectorized, bool Striped>
__device__ __forceinline__ void gemm_128x128x8_body(
    const float* __restrict__ A, const float* __restrict__ B,
    float* __restrict__ C, int M, int N, int K, float (&As)[128][8],
    float (&Bs)[8][128]) {
  constexpr int BK = 8, TM = 8, TN = 8;
  int tid = threadIdx.x;
  int tr = tid / 16;
  int tc = tid % 16;
  int block_m = blockIdx.y * 128;
  int block_n = blockIdx.x * 128;
  float acc[TM][TN] = {};

  for (int k0 = 0; k0 < K; k0 += BK) {
    int am = tid / 2;
    int ak4 = (tid % 2) * 4;
    int gm = block_m + am;
    int gk = k0 + ak4;

    if constexpr (Vectorized) {
      if (gm < M && gk + 3 < K && K % 4 == 0) {
        float4 value = *reinterpret_cast<const float4*>(
            &A[static_cast<size_t>(gm) * K + gk]);
        *reinterpret_cast<float4*>(&As[am][ak4]) = value;
      } else {
#pragma unroll
        for (int q = 0; q < 4; ++q) {
          As[am][ak4 + q] = gm < M && gk + q < K
                                ? A[static_cast<size_t>(gm) * K + gk + q]
                                : 0.0f;
        }
      }
    } else {
#pragma unroll
      for (int q = 0; q < 4; ++q) {
        As[am][ak4 + q] = gm < M && gk + q < K
                              ? A[static_cast<size_t>(gm) * K + gk + q]
                              : 0.0f;
      }
    }

    int bk = tid / 32;
    int bn4 = (tid % 32) * 4;
    gk = k0 + bk;
    int gn = block_n + bn4;
    if constexpr (Vectorized) {
      if (gk < K && gn + 3 < N && N % 4 == 0) {
        float4 value = *reinterpret_cast<const float4*>(
            &B[static_cast<size_t>(gk) * N + gn]);
        *reinterpret_cast<float4*>(&Bs[bk][bn4]) = value;
      } else {
#pragma unroll
        for (int q = 0; q < 4; ++q) {
          Bs[bk][bn4 + q] = gk < K && gn + q < N
                                ? B[static_cast<size_t>(gk) * N + gn + q]
                                : 0.0f;
        }
      }
    } else {
#pragma unroll
      for (int q = 0; q < 4; ++q) {
        Bs[bk][bn4 + q] = gk < K && gn + q < N
                              ? B[static_cast<size_t>(gk) * N + gn + q]
                              : 0.0f;
      }
    }
    __syncthreads();

#pragma unroll
    for (int k = 0; k < BK; ++k) {
      float reg_a[TM];
      float reg_b[TN];
#pragma unroll
      for (int i = 0; i < TM; ++i) {
        int lm = Striped ? tr + i * 16 : tr * TM + i;
        reg_a[i] = As[lm][k];
      }
#pragma unroll
      for (int j = 0; j < TN; ++j) {
        int ln = Striped ? tc + j * 16 : tc * TN + j;
        reg_b[j] = Bs[k][ln];
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
    int row = block_m + (Striped ? tr + i * 16 : tr * TM + i);
#pragma unroll
    for (int j = 0; j < TN; ++j) {
      int col = block_n + (Striped ? tc + j * 16 : tc * TN + j);
      if (row < M && col < N) C[static_cast<size_t>(row) * N + col] = acc[i][j];
    }
  }
}

extern "C" __global__ __launch_bounds__(256)
void gemm_v04_register_2d(const float* __restrict__ A,
                          const float* __restrict__ B, float* __restrict__ C,
                          int M, int N, int K) {
  __shared__ float As[128][8];
  __shared__ float Bs[8][128];
  gemm_128x128x8_body<false, false>(A, B, C, M, N, K, As, Bs);
}

extern "C" __global__ __launch_bounds__(256)
void gemm_v05_vectorized(const float* __restrict__ A,
                         const float* __restrict__ B, float* __restrict__ C,
                         int M, int N, int K) {
  __shared__ float As[128][8];
  __shared__ float Bs[8][128];
  gemm_128x128x8_body<true, false>(A, B, C, M, N, K, As, Bs);
}

extern "C" __global__ __launch_bounds__(256)
void gemm_v05b_bank_aware_scalar(const float* __restrict__ A,
                                 const float* __restrict__ B,
                                 float* __restrict__ C, int M, int N, int K) {
  __shared__ float As[128][8];
  __shared__ float Bs[8][128];
  gemm_128x128x8_body<false, true>(A, B, C, M, N, K, As, Bs);
}

extern "C" __global__ __launch_bounds__(256)
void gemm_v06_bank_aware(const float* __restrict__ A,
                         const float* __restrict__ B, float* __restrict__ C,
                         int M, int N, int K) {
  __shared__ float As[128][8];
  __shared__ float Bs[8][128];
  gemm_128x128x8_body<true, true>(A, B, C, M, N, K, As, Bs);
}

struct Options {
  std::string kernel = "all";
  int M = 1024;
  int N = 1024;
  int K = 1024;
  int warmup = 2;
  int iters = 5;
  bool verify = true;
  bool profile = false;
};

int parse_positive_int(const char* option, const char* value,
                       bool allow_zero = false) {
  char* end = nullptr;
  long parsed = std::strtol(value, &end, 10);
  long lower_bound = allow_zero ? 0 : 1;
  if (!value[0] || *end != '\0' || parsed < lower_bound ||
      parsed > 2147483647L) {
    std::fprintf(stderr, "Invalid value for %s: %s\n", option, value);
    std::exit(1);
  }
  return static_cast<int>(parsed);
}

using Launcher = void (*)(const float*, const float*, float*, int, int, int,
                          cudaStream_t);

void launch_v00(const float* A, const float* B, float* C, int M, int N, int K,
                cudaStream_t stream) {
  dim3 block(16, 16);
  dim3 grid(ceil_div(N, 16), ceil_div(M, 16));
  gemm_v00_naive<<<grid, block, 0, stream>>>(A, B, C, M, N, K);
}

void launch_v01(const float* A, const float* B, float* C, int M, int N, int K,
                cudaStream_t stream) {
  dim3 block(16, 16);
  dim3 grid(ceil_div(N, 16), ceil_div(M, 16));
  gemm_v01_bad_mapping<<<grid, block, 0, stream>>>(A, B, C, M, N, K);
}

void launch_v02(const float* A, const float* B, float* C, int M, int N, int K,
                cudaStream_t stream) {
  dim3 block(32, 32);
  dim3 grid(ceil_div(N, 32), ceil_div(M, 32));
  gemm_v02_shared_32<<<grid, block, 0, stream>>>(A, B, C, M, N, K);
}

void launch_v03(const float* A, const float* B, float* C, int M, int N, int K,
                cudaStream_t stream) {
  dim3 grid(ceil_div(N, 32), ceil_div(M, 64));
  gemm_v03_register_1d<<<grid, 256, 0, stream>>>(A, B, C, M, N, K);
}

void launch_v04(const float* A, const float* B, float* C, int M, int N, int K,
                cudaStream_t stream) {
  dim3 grid(ceil_div(N, 128), ceil_div(M, 128));
  gemm_v04_register_2d<<<grid, 256, 0, stream>>>(A, B, C, M, N, K);
}

void launch_v05(const float* A, const float* B, float* C, int M, int N, int K,
                cudaStream_t stream) {
  dim3 grid(ceil_div(N, 128), ceil_div(M, 128));
  gemm_v05_vectorized<<<grid, 256, 0, stream>>>(A, B, C, M, N, K);
}

void launch_v06(const float* A, const float* B, float* C, int M, int N, int K,
                cudaStream_t stream) {
  dim3 grid(ceil_div(N, 128), ceil_div(M, 128));
  gemm_v06_bank_aware<<<grid, 256, 0, stream>>>(A, B, C, M, N, K);
}

void launch_v05b(const float* A, const float* B, float* C, int M, int N,
                 int K, cudaStream_t stream) {
  dim3 grid(ceil_div(N, 128), ceil_div(M, 128));
  gemm_v05b_bank_aware_scalar<<<grid, 256, 0, stream>>>(A, B, C, M, N, K);
}

struct KernelSpec {
  const char* name;
  Launcher launch;
};

KernelSpec kernels[] = {{"v00", launch_v00}, {"v01", launch_v01},
                        {"v02", launch_v02}, {"v03", launch_v03},
                        {"v04", launch_v04}, {"v05", launch_v05},
                        {"v05b", launch_v05b},
                        {"v06", launch_v06}};

Options parse_options(int argc, char** argv) {
  Options o;
  for (int i = 1; i < argc; ++i) {
    auto value = [&](const char* option) {
      if (++i >= argc) {
        std::fprintf(stderr, "Missing value for %s\n", option);
        std::exit(1);
      }
      return argv[i];
    };
    if (!std::strcmp(argv[i], "--kernel")) o.kernel = value("--kernel");
    else if (!std::strcmp(argv[i], "--m"))
      o.M = parse_positive_int("--m", value("--m"));
    else if (!std::strcmp(argv[i], "--n"))
      o.N = parse_positive_int("--n", value("--n"));
    else if (!std::strcmp(argv[i], "--k"))
      o.K = parse_positive_int("--k", value("--k"));
    else if (!std::strcmp(argv[i], "--warmup"))
      o.warmup = parse_positive_int("--warmup", value("--warmup"), true);
    else if (!std::strcmp(argv[i], "--iters"))
      o.iters = parse_positive_int("--iters", value("--iters"));
    else if (!std::strcmp(argv[i], "--no-verify")) o.verify = false;
    else if (!std::strcmp(argv[i], "--profile")) o.profile = true;
    else {
      std::fprintf(stderr, "Unknown option: %s\n", argv[i]);
      std::exit(1);
    }
  }
  if (o.profile && o.kernel == "all") {
    std::fprintf(stderr, "--profile requires one explicit --kernel\n");
    std::exit(1);
  }
  return o;
}

bool selected(const Options& options, const char* name) {
  return options.kernel == "all" || options.kernel == name;
}

void make_cublas_reference(cublasHandle_t handle, const float* A,
                           const float* B, float* C, int M, int N, int K) {
  float alpha = 1.0f;
  float beta = 0.0f;
  CUBLAS_CHECK(cublasSetMathMode(handle, CUBLAS_PEDANTIC_MATH));
  CUBLAS_CHECK(cublasGemmEx(handle, CUBLAS_OP_N, CUBLAS_OP_N, N, M, K,
                            &alpha, B, CUDA_R_32F, N, A, CUDA_R_32F, K,
                            &beta, C, CUDA_R_32F, N,
                            CUBLAS_COMPUTE_32F_PEDANTIC,
                            CUBLAS_GEMM_DEFAULT));
}

bool verify_result(const std::vector<float>& got,
                   const std::vector<float>& reference) {
  constexpr float atol = 1e-3f;
  constexpr float rtol = 2e-3f;
  double max_abs = 0.0;
  double max_scaled = 0.0;
  size_t worst = 0;
  size_t mismatches = 0;
  for (size_t i = 0; i < got.size(); ++i) {
    double abs_error = std::abs(static_cast<double>(got[i]) - reference[i]);
    double limit = atol + rtol * std::abs(static_cast<double>(reference[i]));
    double scaled = abs_error / limit;
    if (!std::isfinite(got[i]) || scaled > 1.0) ++mismatches;
    if (scaled > max_scaled) {
      max_scaled = scaled;
      max_abs = abs_error;
      worst = i;
    }
  }
  std::printf(" verify=%s max_abs=%.3e max_scaled=%.3f worst=%zu",
              mismatches == 0 ? "PASS" : "FAIL", max_abs, max_scaled, worst);
  return mismatches == 0;
}

double benchmark_cublas(cublasHandle_t handle, const float* A, const float* B,
                        float* C, int M, int N, int K, int warmup, int iters) {
  for (int i = 0; i < warmup; ++i) make_cublas_reference(handle, A, B, C, M, N, K);
  CUDA_CHECK(cudaDeviceSynchronize());

  cudaEvent_t start, stop;
  CUDA_CHECK(cudaEventCreate(&start));
  CUDA_CHECK(cudaEventCreate(&stop));
  CUDA_CHECK(cudaEventRecord(start));
  for (int i = 0; i < iters; ++i) make_cublas_reference(handle, A, B, C, M, N, K);
  CUDA_CHECK(cudaEventRecord(stop));
  CUDA_CHECK(cudaEventSynchronize(stop));
  float elapsed_ms = 0.0f;
  CUDA_CHECK(cudaEventElapsedTime(&elapsed_ms, start, stop));
  CUDA_CHECK(cudaEventDestroy(start));
  CUDA_CHECK(cudaEventDestroy(stop));
  return 2.0 * M * N * K / ((elapsed_ms / iters) * 1.0e6);
}

int main(int argc, char** argv) {
  Options o = parse_options(argc, argv);
  bool matched = false;
  for (const KernelSpec& spec : kernels) {
    matched = matched || selected(o, spec.name);
  }
  if (!matched) {
    std::fprintf(stderr, "Unknown kernel: %s\n", o.kernel.c_str());
    return 1;
  }

  cudaDeviceProp prop{};
  CUDA_CHECK(cudaGetDeviceProperties(&prop, 0));
  std::printf("gpu=%s cc=%d.%d M=%d N=%d K=%d\n", prop.name, prop.major,
              prop.minor, o.M, o.N, o.K);
  std::printf("math=fp32_cuda_core cublas_compute=32f_pedantic "
              "cublas_math=pedantic\n");

  size_t a_count = static_cast<size_t>(o.M) * o.K;
  size_t b_count = static_cast<size_t>(o.K) * o.N;
  size_t c_count = static_cast<size_t>(o.M) * o.N;
  std::vector<float> h_A(a_count), h_B(b_count), h_C(c_count), h_ref;
  std::mt19937 rng(1);
  std::uniform_real_distribution<float> distribution(-0.5f, 0.5f);
  for (float& x : h_A) x = distribution(rng);
  for (float& x : h_B) x = distribution(rng);

  float *d_A, *d_B, *d_C, *d_ref = nullptr;
  CUDA_CHECK(cudaMalloc(&d_A, a_count * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&d_B, b_count * sizeof(float)));
  CUDA_CHECK(cudaMalloc(&d_C, c_count * sizeof(float)));
  CUDA_CHECK(cudaMemcpy(d_A, h_A.data(), a_count * sizeof(float),
                        cudaMemcpyHostToDevice));
  CUDA_CHECK(cudaMemcpy(d_B, h_B.data(), b_count * sizeof(float),
                        cudaMemcpyHostToDevice));

  cublasHandle_t handle;
  CUBLAS_CHECK(cublasCreate(&handle));
  if (o.verify) {
    CUDA_CHECK(cudaMalloc(&d_ref, c_count * sizeof(float)));
    make_cublas_reference(handle, d_A, d_B, d_ref, o.M, o.N, o.K);
    CUDA_CHECK(cudaDeviceSynchronize());
    h_ref.resize(c_count);
    CUDA_CHECK(cudaMemcpy(h_ref.data(), d_ref, c_count * sizeof(float),
                          cudaMemcpyDeviceToHost));
  }

  double cublas_gflops = 0.0;
  if (!o.profile) {
    if (!d_ref) CUDA_CHECK(cudaMalloc(&d_ref, c_count * sizeof(float)));
    cublas_gflops = benchmark_cublas(handle, d_A, d_B, d_ref, o.M, o.N, o.K,
                                     o.warmup, o.iters);
    std::printf("kernel=cublas_pedantic gflops=%.1f\n", cublas_gflops);
  }

  bool success = true;
  for (const KernelSpec& spec : kernels) {
    if (!selected(o, spec.name)) continue;

    if (o.profile) {
      spec.launch(d_A, d_B, d_C, o.M, o.N, o.K, nullptr);
      CUDA_CHECK(cudaGetLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      std::printf("kernel=%s profile_launch=done\n", spec.name);
      continue;
    }

    for (int i = 0; i < o.warmup; ++i)
      spec.launch(d_A, d_B, d_C, o.M, o.N, o.K, nullptr);
    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaDeviceSynchronize());

    cudaEvent_t start, stop;
    CUDA_CHECK(cudaEventCreate(&start));
    CUDA_CHECK(cudaEventCreate(&stop));
    CUDA_CHECK(cudaEventRecord(start));
    for (int i = 0; i < o.iters; ++i)
      spec.launch(d_A, d_B, d_C, o.M, o.N, o.K, nullptr);
    CUDA_CHECK(cudaEventRecord(stop));
    CUDA_CHECK(cudaEventSynchronize(stop));
    float elapsed_ms = 0.0f;
    CUDA_CHECK(cudaEventElapsedTime(&elapsed_ms, start, stop));
    float avg_ms = elapsed_ms / o.iters;
    double gflops = 2.0 * o.M * o.N * o.K / (avg_ms * 1.0e6);
    std::printf("kernel=%s avg_ms=%.4f gflops=%.1f cublas_pct=%.1f", spec.name,
                avg_ms, gflops, 100.0 * gflops / cublas_gflops);

    if (o.verify) {
      CUDA_CHECK(cudaMemcpy(h_C.data(), d_C, c_count * sizeof(float),
                            cudaMemcpyDeviceToHost));
      success &= verify_result(h_C, h_ref);
    }
    std::printf("\n");
    CUDA_CHECK(cudaEventDestroy(start));
    CUDA_CHECK(cudaEventDestroy(stop));
  }

  if (d_ref) CUDA_CHECK(cudaFree(d_ref));
  CUDA_CHECK(cudaFree(d_C));
  CUDA_CHECK(cudaFree(d_B));
  CUDA_CHECK(cudaFree(d_A));
  CUBLAS_CHECK(cublasDestroy(handle));
  return success ? 0 : 2;
}

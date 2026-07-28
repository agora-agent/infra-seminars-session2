#include <cuda_runtime.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <vector>

#define CUDA_CHECK(call)                                                        \
  do {                                                                          \
    cudaError_t error = (call);                                                  \
    if (error != cudaSuccess) {                                                  \
      std::fprintf(stderr, "%s:%d: CUDA error: %s\n", __FILE__, __LINE__,      \
                   cudaGetErrorString(error));                                   \
      std::exit(1);                                                              \
    }                                                                            \
  } while (0)

constexpr int kTile = 32;
constexpr int kBlockRows = 8;

// T0/T1 separate global-store coalescing from all shared-memory effects.
extern "C" __global__ void transpose_t0_copy(const float* input, float* output,
                                               int rows, int cols) {
  int col = blockIdx.x * kTile + threadIdx.x;
  int row = blockIdx.y * kTile + threadIdx.y;

#pragma unroll
  for (int j = 0; j < kTile; j += kBlockRows) {
    if (row + j < rows && col < cols) {
      output[static_cast<size_t>(row + j) * cols + col] =
          input[static_cast<size_t>(row + j) * cols + col];
    }
  }
}

extern "C" __global__ void transpose_t1_naive(const float* input,
                                                float* output, int rows,
                                                int cols) {
  int col = blockIdx.x * kTile + threadIdx.x;
  int row = blockIdx.y * kTile + threadIdx.y;

#pragma unroll
  for (int j = 0; j < kTile; j += kBlockRows) {
    if (row + j < rows && col < cols) {
      output[static_cast<size_t>(col) * rows + row + j] =
          input[static_cast<size_t>(row + j) * cols + col];
    }
  }
}

// T2 and T3 execute the same logical transpose. Only the physical shared row
// stride changes, making this a controlled padding experiment.
template <int Stride>
__device__ __forceinline__ void transpose_shared_body(const float* input,
                                                       float* output, int rows,
                                                       int cols) {
  __shared__ float tile[kTile][Stride];

  int input_col = blockIdx.x * kTile + threadIdx.x;
  int input_row = blockIdx.y * kTile + threadIdx.y;

#pragma unroll
  for (int j = 0; j < kTile; j += kBlockRows) {
    if (input_row + j < rows && input_col < cols) {
      tile[threadIdx.y + j][threadIdx.x] =
          input[static_cast<size_t>(input_row + j) * cols + input_col];
    }
  }
  __syncthreads();

  int output_col = blockIdx.y * kTile + threadIdx.x;
  int output_row = blockIdx.x * kTile + threadIdx.y;

#pragma unroll
  for (int j = 0; j < kTile; j += kBlockRows) {
    if (output_row + j < cols && output_col < rows) {
      output[static_cast<size_t>(output_row + j) * rows + output_col] =
          tile[threadIdx.x][threadIdx.y + j];
    }
  }
}

extern "C" __global__ void transpose_t2_shared(const float* input,
                                                 float* output, int rows,
                                                 int cols) {
  transpose_shared_body<32>(input, output, rows, cols);
}

extern "C" __global__ void transpose_t3_padded(const float* input,
                                                 float* output, int rows,
                                                 int cols) {
  transpose_shared_body<33>(input, output, rows, cols);
}

// T4 keeps a 32x32 allocation but permutes the physical column with row XOR.
// The load and store sides apply inverse logical-to-physical mappings.
extern "C" __global__ void transpose_t4_xor(const float* input, float* output,
                                              int rows, int cols) {
  __shared__ float tile[kTile][kTile];

  int input_col = blockIdx.x * kTile + threadIdx.x;
  int input_row = blockIdx.y * kTile + threadIdx.y;

#pragma unroll
  for (int j = 0; j < kTile; j += kBlockRows) {
    int logical_row = threadIdx.y + j;
    if (input_row + j < rows && input_col < cols) {
      tile[logical_row][threadIdx.x ^ logical_row] =
          input[static_cast<size_t>(input_row + j) * cols + input_col];
    }
  }
  __syncthreads();

  int output_col = blockIdx.y * kTile + threadIdx.x;
  int output_row = blockIdx.x * kTile + threadIdx.y;

#pragma unroll
  for (int j = 0; j < kTile; j += kBlockRows) {
    int logical_col = threadIdx.y + j;
    if (output_row + j < cols && output_col < rows) {
      output[static_cast<size_t>(output_row + j) * rows + output_col] =
          tile[threadIdx.x][logical_col ^ threadIdx.x];
    }
  }
}

using Launcher = void (*)(const float*, float*, int, int, cudaStream_t);

void launch_t0(const float* input, float* output, int rows, int cols,
               cudaStream_t stream) {
  dim3 block(kTile, kBlockRows);
  dim3 grid((cols + kTile - 1) / kTile, (rows + kTile - 1) / kTile);
  transpose_t0_copy<<<grid, block, 0, stream>>>(input, output, rows, cols);
}

void launch_t1(const float* input, float* output, int rows, int cols,
               cudaStream_t stream) {
  dim3 block(kTile, kBlockRows);
  dim3 grid((cols + kTile - 1) / kTile, (rows + kTile - 1) / kTile);
  transpose_t1_naive<<<grid, block, 0, stream>>>(input, output, rows, cols);
}

void launch_t2(const float* input, float* output, int rows, int cols,
               cudaStream_t stream) {
  dim3 block(kTile, kBlockRows);
  dim3 grid((cols + kTile - 1) / kTile, (rows + kTile - 1) / kTile);
  transpose_t2_shared<<<grid, block, 0, stream>>>(input, output, rows, cols);
}

void launch_t3(const float* input, float* output, int rows, int cols,
               cudaStream_t stream) {
  dim3 block(kTile, kBlockRows);
  dim3 grid((cols + kTile - 1) / kTile, (rows + kTile - 1) / kTile);
  transpose_t3_padded<<<grid, block, 0, stream>>>(input, output, rows, cols);
}

void launch_t4(const float* input, float* output, int rows, int cols,
               cudaStream_t stream) {
  dim3 block(kTile, kBlockRows);
  dim3 grid((cols + kTile - 1) / kTile, (rows + kTile - 1) / kTile);
  transpose_t4_xor<<<grid, block, 0, stream>>>(input, output, rows, cols);
}

struct KernelSpec {
  const char* name;
  Launcher launch;
  bool transpose;
};

constexpr KernelSpec kKernels[] = {
    {"t0", launch_t0, false}, {"t1", launch_t1, true},
    {"t2", launch_t2, true},  {"t3", launch_t3, true},
    {"t4", launch_t4, true},
};

struct Options {
  const char* kernel = "all";
  int rows = 4096;
  int cols = 4096;
  int warmup = 2;
  int iterations = 10;
  bool verify = true;
  bool profile = false;
};

int parse_int(const char* option, const char* value) {
  char* end = nullptr;
  long result = std::strtol(value, &end, 10);
  if (!value[0] || *end != '\0' || result < 0 || result > 2147483647L) {
    std::fprintf(stderr, "Invalid value for %s: %s\n", option, value);
    std::exit(1);
  }
  return static_cast<int>(result);
}

Options parse_options(int argc, char** argv) {
  Options options;
  for (int i = 1; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--no-verify")) {
      options.verify = false;
    } else if (!std::strcmp(argv[i], "--profile")) {
      options.profile = true;
    } else if (i + 1 < argc && !std::strcmp(argv[i], "--kernel")) {
      options.kernel = argv[++i];
    } else if (i + 1 < argc && !std::strcmp(argv[i], "--m")) {
      options.rows = parse_int("--m", argv[++i]);
    } else if (i + 1 < argc && !std::strcmp(argv[i], "--n")) {
      options.cols = parse_int("--n", argv[++i]);
    } else if (i + 1 < argc && !std::strcmp(argv[i], "--warmup")) {
      options.warmup = parse_int("--warmup", argv[++i]);
    } else if (i + 1 < argc && !std::strcmp(argv[i], "--iters")) {
      options.iterations = parse_int("--iters", argv[++i]);
    } else {
      std::fprintf(stderr, "Unknown or incomplete option: %s\n", argv[i]);
      std::exit(1);
    }
  }

  if (options.rows <= 0 || options.cols <= 0 || options.iterations <= 0) {
    std::fprintf(stderr, "--m, --n, and --iters must be positive\n");
    std::exit(1);
  }
  if (options.profile && !std::strcmp(options.kernel, "all")) {
    std::fprintf(stderr, "--profile requires one explicit --kernel\n");
    std::exit(1);
  }
  return options;
}

bool selected(const Options& options, const char* name) {
  return !std::strcmp(options.kernel, "all") ||
         !std::strcmp(options.kernel, name);
}

int main(int argc, char** argv) {
  Options options = parse_options(argc, argv);
  bool matched = false;
  for (const KernelSpec& kernel : kKernels) {
    matched = matched || selected(options, kernel.name);
  }
  if (!matched) {
    std::fprintf(stderr, "Unknown kernel: %s\n", options.kernel);
    return 1;
  }

  cudaDeviceProp properties{};
  CUDA_CHECK(cudaGetDeviceProperties(&properties, 0));
  std::printf("gpu=%s cc=%d.%d M=%d N=%d\n", properties.name,
              properties.major, properties.minor, options.rows, options.cols);

  size_t elements = static_cast<size_t>(options.rows) * options.cols;
  size_t bytes = elements * sizeof(float);
  std::vector<float> host_input(elements);
  std::vector<float> copy_reference;
  std::vector<float> transpose_reference;
  std::vector<float> host_output(elements);

  std::mt19937 random(1);
  std::uniform_int_distribution<int> distribution(-1024, 1024);
  for (float& value : host_input) {
    value = static_cast<float>(distribution(random));
  }

  if (options.verify) {
    copy_reference = host_input;
    transpose_reference.resize(elements);
    for (int row = 0; row < options.rows; ++row) {
      for (int col = 0; col < options.cols; ++col) {
        transpose_reference[static_cast<size_t>(col) * options.rows + row] =
            host_input[static_cast<size_t>(row) * options.cols + col];
      }
    }
  }

  float* device_input = nullptr;
  float* device_output = nullptr;
  CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&device_input), bytes));
  CUDA_CHECK(cudaMalloc(reinterpret_cast<void**>(&device_output), bytes));
  CUDA_CHECK(cudaMemcpy(device_input, host_input.data(), bytes,
                        cudaMemcpyHostToDevice));

  cudaEvent_t start;
  cudaEvent_t stop;
  CUDA_CHECK(cudaEventCreate(&start));
  CUDA_CHECK(cudaEventCreate(&stop));

  int failures = 0;
  for (const KernelSpec& kernel : kKernels) {
    if (!selected(options, kernel.name)) {
      continue;
    }

    if (options.profile) {
      kernel.launch(device_input, device_output, options.rows, options.cols, 0);
      CUDA_CHECK(cudaGetLastError());
      CUDA_CHECK(cudaDeviceSynchronize());
      std::printf("kernel=%s profile_launch=done\n", kernel.name);
    } else {
      for (int i = 0; i < options.warmup; ++i) {
        kernel.launch(device_input, device_output, options.rows, options.cols,
                      0);
      }
      CUDA_CHECK(cudaGetLastError());
      CUDA_CHECK(cudaDeviceSynchronize());

      CUDA_CHECK(cudaEventRecord(start));
      for (int i = 0; i < options.iterations; ++i) {
        kernel.launch(device_input, device_output, options.rows, options.cols,
                      0);
      }
      CUDA_CHECK(cudaEventRecord(stop));
      CUDA_CHECK(cudaEventSynchronize(stop));

      float elapsed_ms = 0.0f;
      CUDA_CHECK(cudaEventElapsedTime(&elapsed_ms, start, stop));
      float average_ms = elapsed_ms / options.iterations;
      double bandwidth_gbps = 2.0 * static_cast<double>(bytes) /
                              (average_ms * 1.0e6);
      std::printf("kernel=%s avg_ms=%.4f bandwidth_gbps=%.2f", kernel.name,
                  average_ms, bandwidth_gbps);

      if (options.verify) {
        CUDA_CHECK(cudaMemcpy(host_output.data(), device_output, bytes,
                              cudaMemcpyDeviceToHost));
        const std::vector<float>& reference =
            kernel.transpose ? transpose_reference : copy_reference;
        size_t mismatches = 0;
        size_t first_mismatch = 0;
        for (size_t i = 0; i < elements; ++i) {
          if (host_output[i] != reference[i]) {
            if (mismatches == 0) {
              first_mismatch = i;
            }
            ++mismatches;
          }
        }
        if (mismatches == 0) {
          std::printf(" verify=PASS\n");
        } else {
          std::printf(" verify=FAIL mismatches=%zu first_index=%zu expected=%g "
                      "actual=%g\n",
                      mismatches, first_mismatch, reference[first_mismatch],
                      host_output[first_mismatch]);
          ++failures;
        }
      } else {
        std::printf(" verify=SKIP\n");
      }
    }
  }

  CUDA_CHECK(cudaEventDestroy(stop));
  CUDA_CHECK(cudaEventDestroy(start));
  CUDA_CHECK(cudaFree(device_output));
  CUDA_CHECK(cudaFree(device_input));
  return failures == 0 ? 0 : 2;
}

NVCC ?= nvcc
CUDA_ARCH ?= 80
BUILD_DIR ?= build

NVCCFLAGS := -O3 --generate-line-info -std=c++17 -arch=sm_$(CUDA_ARCH) -Xptxas=-v

.PHONY: all clean correctness

all: $(BUILD_DIR)/gemm_bench $(BUILD_DIR)/bank_conflict_demo

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/gemm_bench: code/gemm/gemm_bench.cu | $(BUILD_DIR)
	$(NVCC) $(NVCCFLAGS) $< -lcublas -o $@

$(BUILD_DIR)/bank_conflict_demo: code/memory-layout/bank_conflict_demo.cu | $(BUILD_DIR)
	$(NVCC) $(NVCCFLAGS) $< -o $@

correctness: all
	$(BUILD_DIR)/gemm_bench --kernel all --m 257 --n 263 --k 269 --warmup 1 --iters 1
	$(BUILD_DIR)/bank_conflict_demo --kernel all --m 1027 --n 1031 --warmup 1 --iters 1

clean:
	rm -rf $(BUILD_DIR)

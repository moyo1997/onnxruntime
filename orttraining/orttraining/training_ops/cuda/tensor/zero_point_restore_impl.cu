// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#include "orttraining/training_ops/cuda/tensor/zero_point_restore_impl.h"
#include "core/providers/cuda/cu_inc/bitmask.cuh"
#include <cub/cub.cuh>

namespace onnxruntime {
namespace cuda {

template <typename T>

void GetZeroPointRestoreTempStorageBytesImpl(cudaStream_t stream,
                                             size_t& temp_storage_bytes,
                                             int total_element_count) {
  cub::DeviceScan::InclusiveSum(
      static_cast<void*>(nullptr),  // input, when NULL, the required allocation size is written to temp_storage_bytes and no work is done.
      temp_storage_bytes,           // input or output
      static_cast<T*>(nullptr),     // input
      static_cast<T*>(nullptr),     // output
      total_element_count,          // input
      stream);
}

void CalculateInputOffsetForEachOutputImpl(cudaStream_t stream,
                                           void* d_temp_storage,
                                           size_t& temp_storage_bytes,
                                           int* restored_output_mask,
                                           int* output_idx_to_input_idx_map_buffer,
                                           int total_element_count) {
  cub::DeviceScan::InclusiveSum(
      d_temp_storage,                      // input, when NULL, the required allocation size is written to temp_storage_bytes and no work is done.
      temp_storage_bytes,                  // input or output
      restored_output_mask,                // input
      output_idx_to_input_idx_map_buffer,  // output
      total_element_count,                 // input
      stream);
}

constexpr int kBlockSize = 256;
constexpr int kNumUnroll = 4;

__global__ void FillOutputFromMaskKernel(const CUDA_LONG N,
                                         const fast_divmod fdm_bits_per_element,
                                         const BitmaskElementType* mask_data,
                                         int* restored_output_mask) {
  CUDA_LONG idx = blockDim.x * blockIdx.x + threadIdx.x;

  int masks[kNumUnroll];
  if (idx < N) {
    int bitmask_idx, bitmask_shift;
    fdm_bits_per_element.divmod(idx, bitmask_idx, bitmask_shift);
    BitmaskElementType shifted_mask = mask_data[bitmask_idx] >> bitmask_shift;
#pragma unroll
    for (int i = 0; i < kNumUnroll; i++) {
      masks[i] = static_cast<int>((shifted_mask & (1 << i)) == 1);
    }
  }

#pragma unroll
  for (int i = 0; i < kNumUnroll; ++i) {
    CUDA_LONG li = idx + i;
    if (li < N) {
      restored_output_mask[li] = masks[i];
    }
  }
}

void FillOutputFromMaskImpl(cudaStream_t stream,
                            const int64_t total_element_count,
                            const BitmaskElementType* mask_data,
                            int* restored_output_mask) {
  const int blocksPerGrid = static_cast<int>(CeilDiv(total_element_count, kBlockSize * kNumUnroll));
  fast_divmod fdm_bits_per_element(kNumBitsPerBitmaskElement);
  FillOutputFromMaskKernel<<<blocksPerGrid, kBlockSize, 0, stream>>>(
      static_cast<CUDA_LONG>(total_element_count), fdm_bits_per_element, mask_data, restored_output_mask);
}

template <typename T>
__global__ void RestoreFromMaskKernel(const CUDA_LONG N,
                                      const int step_size,
                                      const int steps_per_thread,
                                      const fast_divmod fdm_bits_per_element,
                                      const float zero_point_value,
                                      const T* input_data,
                                      const int* output_idx_to_input_idx_map_buffer,
                                      T* output_data) {
  CUDA_LONG idx = blockDim.x * blockIdx.x + threadIdx.x;

  for (int i = 0; i < steps_per_thread; ++i) {
    CUDA_LONG id = idx * kNumUnroll + i * step_size;

    int maps[kNumUnroll + 1];
    if (id < N) {
      if (id == 0) {
        maps[0] = 0;
      } else {
        maps[0] = output_idx_to_input_idx_map_buffer[id];
      }

#pragma unroll
      for (int i = 1; i < kNumUnroll + 1; ++i) {
        maps[i] = output_idx_to_input_idx_map_buffer[id + i];
      }
    }

#pragma unroll
    for (int i = 0; i < kNumUnroll; ++i) {
      CUDA_LONG li = id + i;
      if (li < N) {
        int map_value = maps[i] - maps[i - 1];
        output_data[li] = map_value == 1 ? input_data[map_value] : static_cast<T>(zero_point_value);
      }
    }
  }
}

template <typename T>
void RestoreFromMaskImpl(const cudaDeviceProp& prop,
                         cudaStream_t stream,
                         const int64_t total_element_count,
                         const float zero_point_value,
                         const T* input_data,
                         const int* output_idx_to_input_idx_map_buffer,
                         T* output_data) {
  const int blocks_per_sm = prop.maxThreadsPerMultiProcessor / kBlockSize;
  const int grid_size =
      std::min(prop.multiProcessorCount * blocks_per_sm,
               static_cast<int>(CeilDiv(total_element_count, kBlockSize * kNumUnroll)));

  const int step_size = kBlockSize * grid_size * kNumUnroll;
  const int steps_per_thread = static_cast<int>(CeilDiv(total_element_count, step_size));
  fast_divmod fdm_bits_per_element(kNumBitsPerBitmaskElement);

  RestoreFromMaskKernel<T><<<grid_size, kBlockSize, 0, stream>>>(
      static_cast<CUDA_LONG>(total_element_count),
      step_size,
      steps_per_thread,
      fdm_bits_per_element,
      zero_point_value,
      input_data,
      output_idx_to_input_idx_map_buffer,
      output_data);
}

#define SPECIALIZED_RESTORE_FROM_MASK_IMPL(T)                                         \
  template void RestoreFromMaskImpl<T>(const cudaDeviceProp& prop,                    \
                                       cudaStream_t stream,                           \
                                       const int64_t total_element_count,             \
                                       const float zero_point_value,                  \
                                       const T* input_data,                           \
                                       const int* output_idx_to_input_idx_map_buffer, \
                                       T* output_data);

SPECIALIZED_RESTORE_FROM_MASK_IMPL(float)
SPECIALIZED_RESTORE_FROM_MASK_IMPL(double)
SPECIALIZED_RESTORE_FROM_MASK_IMPL(half)
SPECIALIZED_RESTORE_FROM_MASK_IMPL(BFloat16)

#undef SPECIALIZED_RESTORE_FROM_MASK_IMPL

}  // namespace cuda
}  // namespace onnxruntime
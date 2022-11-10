/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/* Modifications Copyright (c) Microsoft. */

#include "beam_search_topk.h"

#include <cub/cub.cuh>

#include "reduce_kernel_utils.h"
#include "core/providers/cuda/shared_inc/cuda_utils.h"

namespace onnxruntime {
namespace contrib {
namespace cuda {

// kernel to compute the top k on last axis for tensor with shape: [batch, beam_size, parts_of_vocab, vacab_part_size]
// Its grid is [batch * beam_size, parts_of_vocab]
template <typename T, int max_k, int thread_block_size>
__global__ void BeamSearchOnlineTopKStage1Kernel(
    const T* input,
    int32_t k,
    int32_t vocab_size,
    int32_t vocab_part_size,
    T* output_values,
    int32_t* output_token) {
  TopK<T, max_k> top_k_thread;

  // initialize top_k
  for (int32_t i = 0; i < max_k; ++i) {
    top_k_thread.key[i] = -1;
    top_k_thread.value[i] = NumericLimits<T>::Min();
  }

  int batch_beam = blockIdx.x;
  int voc_part_id = blockIdx.y;

  int token_id_base = voc_part_id * vocab_part_size;
  const T* input_block = input + batch_beam * vocab_size;
  // voc_part_size
  for (int i = threadIdx.x + token_id_base; i < vocab_part_size + token_id_base; i += blockDim.x) {
    if (i < vocab_size) {
      top_k_thread.insert(input_block[i], i);
    }
  }

  // reduce in thread block
  typedef cub::BlockReduce<TopK<T, max_k>, thread_block_size> BlockReduce;
  __shared__ typename BlockReduce::TempStorage temp_storage;

  TopK<T, max_k> top_k_block = BlockReduce(temp_storage).Reduce(top_k_thread, reduce_topk_op<T, max_k>);
  __syncthreads();

  output_values += batch_beam * gridDim.y * k + voc_part_id * k;
  output_token += batch_beam * gridDim.y * k + voc_part_id * k;
  if (threadIdx.x == 0) {
    for (int i = 0; i < k; i++) {
      output_values[i] = top_k_block.value[i];
      output_token[i] = top_k_block.key[i];
    }
  }
}

template <typename T, int max_k, int thread_block_size>
__global__ void BeamSearchOnlineTopKStage2Kernel(
    const T* input_values,
    const int32_t* input_indices,
    int32_t K,
    int32_t vocab_size,
    int32_t parts_per_beam,
    T* output_values,
    int32_t* output_indices) {
  const int vector_id = blockIdx.x;
  const int thread_id = threadIdx.x;

  extern __shared__ char buf_s_[];  // intermediate result
  T* buf_value = reinterpret_cast<T*>(buf_s_);
  int32_t* buf_indices = reinterpret_cast<int32_t*>(buf_s_ + max_k * parts_per_beam * sizeof(int32_t));

  typedef cub::BlockReduce<TopK<T, max_k>, thread_block_size> BlockReduce;
  __shared__ typename BlockReduce::TempStorage temp_storage;

  input_values += vector_id * K * parts_per_beam;
  input_indices += vector_id * K * parts_per_beam;

  TopK<T, max_k> partial;
  for (int i = 0; i < max_k; ++i) {
    partial.key[i] = -1;
    partial.value[i] = NumericLimits<T>::Min();
  }

  // load and unpack into registers through smem
  for (int idx = thread_id; idx < K * parts_per_beam; idx += thread_block_size) {
    buf_value[idx] = input_values[idx];
    buf_indices[idx] = input_indices[idx];
  }
  __syncthreads();

  if (thread_id < parts_per_beam) {
    T* b_v = buf_value + thread_id * K;
    int32_t* b_i = buf_indices + thread_id * K;
    for (int i = 0; i < K; i++) {
      partial.insert(b_v[i], b_i[i]);
    }
  }

  TopK<T, max_k> total = BlockReduce(temp_storage).Reduce(partial, reduce_topk_op<T, max_k>);

  if (thread_id == 0) {
    output_values += vector_id * K;
    output_indices += vector_id * K;

    for (int i = 0; i < K; ++i) {
      if (i < K) {
        output_values[i] = total.value[i];
        output_indices[i] = total.key[i];
      }
    }
  }
}

template <typename T, int max_k>
void LaunchBeamSearchOnlineTopKStage2Kernel(
    const T* topk_values_tmp,
    const int32_t* topk_indices_tmp,
    int32_t batch_size,
    int32_t num_beams,
    int32_t vocab_size,
    int32_t parts_per_beam,
    int32_t K,
    T* output_values,
    int32_t* output_indices,
    cudaStream_t stream) {
  ORT_ENFORCE(parts_per_beam <= 128, "Parts per beam should not be greater than 128");

  int smem_stage2_size = parts_per_beam * max_k * 2 * sizeof(int32_t);

  if (parts_per_beam <= 32) {
    BeamSearchOnlineTopKStage2Kernel<T, max_k, 32><<<batch_size * num_beams, 32, smem_stage2_size, stream>>>(
        topk_values_tmp, topk_indices_tmp, K, vocab_size, parts_per_beam, output_values, output_indices);
    return;
  }

  if (parts_per_beam <= 64) {
    BeamSearchOnlineTopKStage2Kernel<T, max_k, 64><<<batch_size * num_beams, 64, smem_stage2_size, stream>>>(
        topk_values_tmp, topk_indices_tmp, K, vocab_size, parts_per_beam, output_values, output_indices);
    return;
  }

  BeamSearchOnlineTopKStage2Kernel<T, max_k, 128><<<batch_size * num_beams, 128, smem_stage2_size, stream>>>(
      topk_values_tmp, topk_indices_tmp, K, vocab_size, parts_per_beam, output_values, output_indices);
  return;
}

template <typename T, int max_k>
void TopKLauncherMaxK(
    const T* input,
    int batch_size,
    int num_beams,
    int vocab_size,
    int K,
    T* output_values,
    int32_t* output_indices,
    T* output_values_tmp,
    int32_t* output_indices_tmp,
    cudaStream_t stream) {
  constexpr int THREAD_BLOCK_SIZE = (max_k < 16) ? (max_k < 8) ? 256 : 128 : 64;

  int voc_parts = 4;
  if (batch_size * num_beams < 256) {
    // volta has 80 SMs, so we aim for three waves
    voc_parts = (240 + batch_size * num_beams - 1) / (batch_size * num_beams);
    voc_parts = std::min(128, voc_parts);  // we implment up to 128
  }

  dim3 grid(batch_size * num_beams, voc_parts);
  cudaFuncSetAttribute(BeamSearchOnlineTopKStage1Kernel<T, max_k, THREAD_BLOCK_SIZE>,
                       cudaFuncAttributePreferredSharedMemoryCarveout,
                       cudaSharedmemCarveoutMaxL1);
  BeamSearchOnlineTopKStage1Kernel<T, max_k, THREAD_BLOCK_SIZE>
      <<<grid, THREAD_BLOCK_SIZE, 0, stream>>>(input, K, vocab_size, (vocab_size + voc_parts - 1) / voc_parts, output_values_tmp, output_indices_tmp);

  LaunchBeamSearchOnlineTopKStage2Kernel<T, max_k>(
      output_values_tmp,
      output_indices_tmp,
      batch_size,
      num_beams,
      vocab_size,
      voc_parts,
      K,
      output_values,
      output_indices,
      stream);
}

template <typename T>
void LaunchTopK(
    const T* input,
    int batch_size,
    int num_beams,
    int vocab_size,
    int K,
    T* output_values,
    int32_t* output_indices,
    T* output_values_tmp,
    int32_t* output_indices_tmp,
    cudaStream_t stream) {
  ORT_ENFORCE(K <= 64, "Online TopK doesn't support K > 64");
  if (K <= 4) {
    return TopKLauncherMaxK<T, 4>(input, batch_size, num_beams, vocab_size, K, output_values, output_indices, output_values_tmp, output_indices_tmp, stream);
  } else if (K <= 8) {
    return TopKLauncherMaxK<T, 8>(input, batch_size, num_beams, vocab_size, K, output_values, output_indices, output_values_tmp, output_indices_tmp, stream);
  } else if (K <= 16) {
    return TopKLauncherMaxK<T, 16>(input, batch_size, num_beams, vocab_size, K, output_values, output_indices, output_values_tmp, output_indices_tmp, stream);
  } else if (K <= 32) {
    return TopKLauncherMaxK<T, 32>(input, batch_size, num_beams, vocab_size, K, output_values, output_indices, output_values_tmp, output_indices_tmp, stream);
  } else {
    return TopKLauncherMaxK<T, 64>(input, batch_size, num_beams, vocab_size, K, output_values, output_indices, output_values_tmp, output_indices_tmp, stream);
  }
}

template void LaunchTopK(const float* input,
                         int batch_size,
                         int num_beams,
                         int vocab_size,
                         int K,
                         float* output_values,
                         int32_t* output_indices,
                         float* output_values_tmp,
                         int32_t* output_indices_tmp,
                         cudaStream_t stream);

template void LaunchTopK(const half* input,
                         int batch_size,
                         int num_beams,
                         int vocab_size,
                         int K,
                         half* output_values,
                         int32_t* output_indices,
                         half* output_values_tmp,
                         int32_t* output_indices_tmp,
                         cudaStream_t stream);

}  // namespace cuda
}  // namespace contrib
}  // namespace onnxruntime

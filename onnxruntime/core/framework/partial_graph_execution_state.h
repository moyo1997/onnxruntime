//// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once

#ifdef ENABLE_TRAINING
#include "core/common/common.h"
#include "core/framework/ort_value.h"
#include "core/framework/iexecutor.h"

namespace onnxruntime {

typedef std::unordered_map<std::string, OrtValue> OrtValueCache;
typedef std::shared_ptr<OrtValueCache> OrtValueCachePtr;
class ExecutionContext;
class DeviceStreamColloection;

struct PartialGraphExecutionState {
 public:
  PartialGraphExecutionState() : execution_context_(nullptr){
  }

  ~PartialGraphExecutionState() = default;

  void SetProgramCounterStart(size_t start) { program_counter_start_ = start; }
  void SetProgramCounterEnd(size_t end) { program_counter_end_ = end; }

  struct ProgramRegion {
    size_t node_start;
    size_t node_end;

    std::vector<std::pair<size_t, size_t> > stream_pc_range;
  };

  size_t GetProgramCounterStart() { return program_counter_start_; }
  size_t GetProgramCounterEnd() { return program_counter_end_; }

  ProgramRegion& GetProgramRegions(const SessionState& session_state);

  ExecutionContext& GetExecutionContext(const std::vector<int>& feed_mlvalue_idxs, const std::vector<OrtValue>& feeds,
                                      const std::vector<int>& fetch_mlvalue_idxs, std::vector<OrtValue>& fetches,
                                      const std::unordered_map<size_t, IExecutor::CustomAllocator>& fetch_allocators,
                                      const SessionState& session_state,
                                      const logging::Logger& sess_logger,
                                      const DeviceStreamColloection& device_streams_map,
                                      const bool& terminate_flag); 

 private:
  std::unique_ptr<ExecutionContext> execution_context_;
  size_t program_counter_start_{0};
  size_t program_counter_end_{0};

  std::vector<ProgramRegion> program_regions_;
};
}  // namespace onnxruntime
#endif

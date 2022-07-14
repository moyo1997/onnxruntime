// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#pragma once

#include <thread>
#include <future>

#include "core/common/common.h"
#include "core/common/logging/logging.h"
#include "core/framework/framework_common.h"
#include "core/session/inference_session.h"

namespace onnxruntime {
#ifdef ENABLE_TRAINING
struct PartialGraphExecutionState;
typedef std::unordered_map<std::string, OrtValue> OrtValueCache;
typedef std::shared_ptr<OrtValueCache> OrtValueCachePtr;
#endif

namespace training {

class TrainingAgent {
 public:
  explicit TrainingAgent(InferenceSession& session,
                         const std::vector<std::string>& fw_feed_names,
                         const std::vector<OrtDevice>& fw_outputs_device_info,
                         const std::vector<std::string>& bw_fetches_names,
                         const std::vector<OrtDevice>& bw_outputs_device_info);
  ~TrainingAgent();
  // For ORTModule.forward()
  common::Status RunForward(const std::vector<OrtValue>& feeds, std::vector<OrtValue>& fetches,
                            PartialGraphExecutionState& state, const OrtValueCachePtr& cache) ORT_MUST_USE_RESULT;

  // For ORTModule.backward()
  common::Status RunBackward(const std::vector<OrtValue>& feeds, std::vector<OrtValue>& fetches,
                             PartialGraphExecutionState& state) ORT_MUST_USE_RESULT;

  common::Status RunCore(const std::vector<OrtValue>& feeds, std::vector<OrtValue>& fetches,
                         PartialGraphExecutionState& state, FeedsFetchesManager& feeds_fetches_manager,
                         const OrtValueCachePtr& cache)
      ORT_MUST_USE_RESULT;

  void CreateAndInitializeFeedsFetchesManager(const SessionState& session_state,
                                              const std::vector<std::string>& feed_names,
                                              const std::vector<std::string>& fetches_names,
                                              const std::vector<OrtDevice>& outputs_device_info,
                                              std::unique_ptr<FeedsFetchesManager>& feeds_fetches_manager);

 private:
  // TrainingAgent runs on a InferenceSession under the hood
  InferenceSession& inference_session_;
  std::unique_ptr<FeedsFetchesManager> fw_feeds_fetches_manager_;
  std::unique_ptr<FeedsFetchesManager> bw_feeds_fetches_manager_;
  size_t fw_program_counter_end_;
  size_t bw_program_counter_end_;
};

}  // namespace training
}  // namespace onnxruntime

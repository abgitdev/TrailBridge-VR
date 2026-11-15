// SPDX-License-Identifier: MIT
#pragma once
#include <atomic>
#include <cstdint>

namespace basalt {
// All producers perform one opt-in check. No clocks, allocation, formatting,
// I/O, or trace synchronization is executed when it is false.
extern std::atomic<bool> gFrameTraceEnabled;
inline bool frameTraceEnabled() { return gFrameTraceEnabled.load(std::memory_order_relaxed); }
enum class TraceKind { Wait, Begin, End, Locate, Tracking, Submit, Gpu, Consumed, Acquire, Release, Event, Flush };
struct TraceEye {
    uint64_t swapchain = 0;
    uint32_t image = 0, slice = 0;
    int32_t width = 0, height = 0;
};
struct TraceRecord {
    TraceKind kind = TraceKind::Event;
    uint64_t frame = 0, control = 0;
    uint64_t lossEpoch = 0; // internal continuity marker; not a CSV column
    int64_t trackingExpires[3]{}; // internal freshness deadlines
    int64_t time = 0, waitEnter = 0, budgetWait = 0, waitExit = 0, predicted = 0;
    int64_t begin = 0, endEnter = 0, endExit = 0, display = 0, result = 0;
    uint32_t layers = 0, projections = 0, quads = 0, others = 0;
    bool haveViews = false, ready = false;
    TraceEye eyes[2]{};
    int64_t head = -1, headAge = -1, left = -1, leftAge = -1, right = -1, rightAge = -1;
    int64_t gpu = -1, consume = -1;
    char text[64]{};
};
int64_t frameTraceNow(); // QPC, same clock as XrTime, converted to microseconds
void frameTraceStart(); // instance lifecycle only; opens file and starts writer
void frameTraceStop();
void frameTraceFlush(); // lifecycle only; waits for writer, never a frame hook
void frameTracePush(const TraceRecord& record); // bounded, nonblocking, may lose
void frameTraceEvent(const char* text, uint64_t identity = 0);
void frameTraceTracking(const TraceRecord& record);
}

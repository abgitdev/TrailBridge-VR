// SPDX-License-Identifier: MIT
#include "frame_trace.hpp"
#include <windows.h>
#include <cstdio>
#include <cstring>
#include <map>
#include <new>
#include <string>
#include <vector>

namespace basalt {
std::atomic<bool> gFrameTraceEnabled{false};
namespace {
constexpr size_t kCapacity = 4096;
struct alignas(64) Slot {
    std::atomic<uint64_t> sequence{0};
    TraceRecord record;
};
Slot* gRing = nullptr; // allocated once, only after explicit opt-in
std::atomic<uint64_t> gWrite{0};
uint64_t gRead = 0; // sole consumer owns this counter
std::atomic<uint64_t> gLost{0};
std::atomic<bool> gStop{false};
HANDLE gFile = INVALID_HANDLE_VALUE, gThread = nullptr, gWake = nullptr, gFlushed = nullptr;
HANDLE gReady = nullptr;
wchar_t* gPath = nullptr;
DWORD gPathLength = 0;
bool gWriteFailed = false;

// One complete line per synchronous WriteFile. A killed writer can leave a
// partial final line on some filesystems; readers discard that unterminated
// tail. All preceding lines are independently parseable (no stdio buffer).
void line(const std::string& value) {
    if (gWriteFailed) return;
    const std::string bytes = value + "\n";
    DWORD written = 0;
    if (!WriteFile(gFile, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) ||
        written != bytes.size()) {
        gWriteFailed = true;
        std::fprintf(stderr, "Basalt OpenXR: frame trace write failed; recording disabled\n");
        gFrameTraceEnabled.store(false);
    }
}
void row(const char* type, const TraceRecord& r, const std::string& text = "") {
    std::string s = type;
    auto n = [&](auto v) { s += ','; s += std::to_string(v); };
    n(r.frame); n(r.time); s += ',' + text;
    n(r.waitEnter); n(r.budgetWait); n(r.waitExit); n(r.predicted);
    n(r.begin); n(r.endEnter); n(r.endExit); n(r.display); n(r.result);
    n(r.layers); n(r.projections); n(r.quads); n(r.others); n(r.haveViews); n(r.ready);
    for (const auto& e : r.eyes) { n(e.swapchain); n(e.image); n(e.slice); n(e.width); n(e.height); }
    n(r.head); n(r.headAge); n(r.left); n(r.leftAge); n(r.right); n(r.rightAge);
    n(r.gpu); n(r.consume); n(r.control);
    line(s);
}
bool pop(TraceRecord& r) {
    Slot& slot = gRing[gRead % kCapacity];
    if (slot.sequence.load(std::memory_order_acquire) != gRead + 1) return false;
    r = slot.record;
    slot.sequence.store(gRead + kCapacity, std::memory_order_release);
    ++gRead;
    return true;
}
bool tryPush(const TraceRecord& r) {
    uint64_t position = gWrite.load(std::memory_order_relaxed);
    // A bounded MPSC reservation. No producer waits for either the writer or
    // another producer's copy, even if that thread is descheduled mid-record.
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
        Slot& slot = gRing[position % kCapacity];
        const int64_t difference = static_cast<int64_t>(slot.sequence.load(std::memory_order_acquire) - position);
        if (difference == 0) {
            if (gWrite.compare_exchange_weak(position, position + 1, std::memory_order_relaxed)) {
                slot.record = r;
                slot.record.lossEpoch = gLost.load(std::memory_order_relaxed);
                slot.sequence.store(position + 1, std::memory_order_release);
                return true;
            }
        } else if (difference < 0) return false; // full
        else position = gWrite.load(std::memory_order_relaxed);
    }
    return false;
}
struct Delivery {
    TraceRecord submission;
    int64_t sent = 0, consumed = 0;
    std::vector<TraceRecord> acquisitions;
};
struct WriterFile {
    ~WriterFile() {
        if (gFile != INVALID_HANDLE_VALUE) CloseHandle(gFile);
        gFile = INVALID_HANDLE_VALUE;
    }
};
bool openTraceFile() {
    const bool absolutePath = gPathLength >= 3 && gPath[1] == L':' &&
        (gPath[2] == L'\\' || gPath[2] == L'/');
    gFile = absolutePath ? CreateFileW(gPath, FILE_APPEND_DATA | GENERIC_READ,
        FILE_SHARE_READ, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr) : INVALID_HANDLE_VALUE;
    if (gFile == INVALID_HANDLE_VALUE) {
        std::fprintf(stderr, "Basalt OpenXR: cannot open frame trace; tracing disabled\n"); return false;
    }
    LARGE_INTEGER size{}; GetFileSizeEx(gFile, &size);
    if (size.QuadPart == 0) {
        const int64_t before = frameTraceNow();
        FILETIME wall{}; GetSystemTimeAsFileTime(&wall);
        const int64_t clock = before + (frameTraceNow() - before) / 2;
        const uint64_t ticks = (uint64_t(wall.dwHighDateTime) << 32) | wall.dwLowDateTime;
        line("# trailbridge_frame_trace_version=1");
        line("# clock_monotonic_us=" + std::to_string(clock));
        line("# clock_utc_unix_us=" + std::to_string(ticks / 10 - 11644473600000000ULL));
        line("# missing_timestamp=0; unknown_duration_or_state=-1; incomplete_frame has no successful EndFrame");
        line("# pose_ages=age since runtime packet arrival at xrLocateViews; Quest and runtime clocks are different domains");
        line("# gpu_fence_wait=waiter fence duration; consume_wait=fence completion to exact FrameConsumed ACK; timings overlap");
        line("# stale_image_event=source image reacquired before exact FrameConsumed ACK; candidate only; actual concurrent Metal reads are not observable");
        line("type,frame,timestamp,text,wait_enter,budget_wait,wait_exit,predicted_display,begin,end_enter,end_exit,end_display_time,end_result,layer_count,projection_layers,quad_layers,other_layers,haveFrameViews,controlFrameReady,left_swapchain,left_image,left_slice,left_width,left_height,right_swapchain,right_image,right_slice,right_width,right_height,head_tracked,head_age,left_active,left_age,right_active,right_age,gpu_fence_wait,consume_wait,control_frame");
    }
    return !gWriteFailed;
}
DWORD WINAPI writer(LPVOID) try {
    WriterFile fileLifetime;
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
    if (!openTraceFile()) { SetEvent(gReady); return 0; }
    gFrameTraceEnabled.store(true);
    SetEvent(gReady);
    std::map<uint64_t, TraceRecord> frames;
    std::map<int64_t, TraceRecord> poses;
    std::map<uint64_t, Delivery> deliveries;
    int64_t tracking[3] = {-1, -1, -1};
    int64_t trackingExpires[3]{};
    const char* trackingNames[] = {"head", "left_controller", "right_controller"};
    uint64_t reportedLost = 0;
    uint64_t lossEpoch = 0;
    auto emit = [&](TraceRecord r) {
        auto p = poses.find(r.predicted);
        if (p != poses.end()) {
            r.head = p->second.head; r.headAge = p->second.headAge;
            r.left = p->second.left; r.leftAge = p->second.leftAge;
            r.right = p->second.right; r.rightAge = p->second.rightAge;
        }
        r.time = r.waitEnter;
        if (!r.endExit) r.result = -1;
        row("frame", r, r.endExit ? "" : "incomplete_frame");
    };
    auto expireTracking = [&](int64_t time) {
        for (size_t i = 0; i < 3; ++i) {
            if (tracking[i] == 1 && trackingExpires[i] && time >= trackingExpires[i]) {
                TraceRecord event; event.time = trackingExpires[i];
                row("event", event, std::string(trackingNames[i]) + "_tracking_invalid");
                tracking[i] = 0;
            }
        }
    };
    auto reportLoss = [&]() {
        const uint64_t lost = gLost.load();
        if (lost != reportedLost) {
            TraceRecord loss; loss.time = frameTraceNow(); loss.frame = lost;
            row("event", loss, "writer_lost_records_total"); reportedLost = lost;
        }
    };
    for (;;) {
        WaitForSingleObject(gWake, 1000);
        TraceRecord r;
        while (pop(r)) {
            if (r.lossEpoch != lossEpoch) {
                // A lost ACK/release must never become a guessed stale-image
                // accusation. Start a new continuity interval.
                deliveries.clear(); poses.clear();
                for (size_t i = 0; i < 3; ++i) { tracking[i] = -1; trackingExpires[i] = 0; }
                lossEpoch = r.lossEpoch;
            }
            if (r.kind == TraceKind::Wait) {
                frames[r.frame] = r;
            } else if (r.kind == TraceKind::Begin) {
                if (r.control) {
                    auto old = frames.find(r.control);
                    if (old != frames.end()) { emit(old->second); frames.erase(old); }
                    TraceRecord event; event.frame = r.control; event.time = r.time;
                    row("event", event, "frame_discarded");
                }
                frames[r.frame].begin = r.time;
            } else if (r.kind == TraceKind::End) {
                auto& f = frames[r.frame];
                r.waitEnter = f.waitEnter; r.budgetWait = f.budgetWait;
                r.waitExit = f.waitExit; r.predicted = f.predicted; r.begin = f.begin;
                r.gpu = f.gpu; r.consume = f.consume; r.control = f.control;
                emit(r); frames.erase(r.frame);
            } else if (r.kind == TraceKind::Locate) {
                poses[r.display] = r;
                expireTracking(r.time);
            } else if (r.kind == TraceKind::Tracking) {
                expireTracking(r.time);
                const int64_t values[] = {r.head, r.left, r.right};
                for (size_t i = 0; i < 3; ++i) {
                    const int64_t active = values[i] && r.time < r.trackingExpires[i];
                    if (tracking[i] != active && (tracking[i] != -1 || active == 0))
                        row("event", r, std::string(trackingNames[i]) + (active ? "_tracking_valid" : "_tracking_invalid"));
                    tracking[i] = active; trackingExpires[i] = r.trackingExpires[i];
                }
            } else if (r.kind == TraceKind::Submit) {
                deliveries[r.control] = Delivery{r, 0, 0, {}};
                auto f = frames.find(r.frame);
                if (f != frames.end()) f->second.control = r.control;
            } else if (r.kind == TraceKind::Gpu || r.kind == TraceKind::Consumed) {
                auto d = deliveries.find(r.control);
                if (d != deliveries.end()) {
                    r.frame = d->second.submission.frame;
                    if (r.kind == TraceKind::Gpu) {
                        d->second.sent = r.time;
                    } else {
                        r.consume = d->second.sent ? r.time - d->second.sent : -1;
                    }
                    auto f = frames.find(r.frame);
                    if (f != frames.end()) {
                        if (r.gpu >= 0) f->second.gpu = r.gpu;
                        if (r.consume >= 0) f->second.consume = r.consume;
                    } else row("late", r);
                    if (r.kind == TraceKind::Consumed) {
                        d->second.consumed = r.time;
                        for (const auto& acquire : d->second.acquisitions)
                            if (acquire.time < r.time)
                                row("event", acquire, "stale_image_reacquired_before_consumed");
                        d->second.acquisitions.clear();
                    }
                } else row("late", r, "unmatched_control_frame");
            } else if (r.kind == TraceKind::Acquire) {
                for (auto& d : deliveries) {
                    for (const auto& e : d.second.submission.eyes) {
                        if (e.swapchain == r.eyes[0].swapchain && e.image == r.eyes[0].image &&
                            d.second.submission.time <= r.time &&
                            (!d.second.consumed || r.time < d.second.consumed)) {
                            r.frame = d.second.submission.frame; r.control = d.first;
                            // Await the timestamp of the exact ACK. Producers
                            // can be preempted between observation and enqueue:
                            // ring arrival order alone cannot prove a hazard.
                            if (d.second.consumed)
                                row("event", r, "stale_image_reacquired_before_consumed");
                            else if (d.second.acquisitions.size() < kCapacity)
                                d.second.acquisitions.push_back(r);
                            else ++gLost;
                            break;
                        }
                    }
                }
            } else if (r.kind == TraceKind::Event) {
                row("event", r, r.text);
                if (std::strcmp(r.text, "control_disconnected") == 0 ||
                    std::strcmp(r.text, "receiver_failed") == 0) {
                    for (const auto& d : deliveries)
                        for (const auto& acquire : d.second.acquisitions)
                            row("event", acquire, "stale_image_reacquired_before_consumed");
                    for (auto& d : deliveries) {
                        d.second.acquisitions.clear();
                        if (!d.second.consumed) d.second.consumed = r.time;
                    }
                }
            } else if (r.kind == TraceKind::Flush) {
                expireTracking(r.time);
                for (const auto& f : frames) emit(f.second);
                for (const auto& d : deliveries)
                    for (const auto& acquire : d.second.acquisitions)
                        row("event", acquire, "stale_image_reacquired_before_consumed");
                frames.clear(); poses.clear(); deliveries.clear();
                reportLoss();
                FlushFileBuffers(gFile); SetEvent(gFlushed);
            }
            // Diagnostic memory is bounded even after invalid app call order
            // or dropped records. Missing metadata is explicit, never guessed.
            if (frames.size() > kCapacity) { emit(frames.begin()->second); frames.erase(frames.begin()); }
            if (poses.size() > kCapacity) poses.erase(poses.begin());
            // Retain completed identities for reordered producer observations.
            if (deliveries.size() > kCapacity) deliveries.erase(deliveries.begin());
        }
        reportLoss();
        FlushFileBuffers(gFile);
        if (gStop.load()) break;
    }
    return 0;
} catch (...) {
    gFrameTraceEnabled.store(false);
    std::fprintf(stderr, "Basalt OpenXR: frame trace writer failed; tracing disabled\n");
    SetEvent(gReady);
    SetEvent(gFlushed);
    return 0;
}
}
int64_t frameTraceNow() {
    LARGE_INTEGER c{}, f{};
    if (!QueryPerformanceCounter(&c) || !QueryPerformanceFrequency(&f) || f.QuadPart <= 0)
        return static_cast<int64_t>(GetTickCount64()) * 1000;
    return c.QuadPart / f.QuadPart * 1000000 + c.QuadPart % f.QuadPart * 1000000 / f.QuadPart;
}
void frameTracePush(const TraceRecord& r) {
    if (!tryPush(r)) gLost.fetch_add(1, std::memory_order_relaxed);
}
void frameTraceEvent(const char* text, uint64_t identity) {
    TraceRecord r; r.time = frameTraceNow(); r.frame = identity;
    std::strncpy(r.text, text, sizeof(r.text) - 1); frameTracePush(r);
}
void frameTraceTracking(const TraceRecord& r) { frameTracePush(r); }
void frameTraceStart() try {
    if (gThread) return;
    DWORD length = GetEnvironmentVariableW(L"BASALT_FRAME_TRACE", nullptr, 0);
    if (!length) return;
    gWriteFailed = false; gStop = false; gLost = 0;
    gRead = 0; gWrite = 0;
    gPath = length <= 32768 ? new (std::nothrow) wchar_t[length] : nullptr;
    gRing = new (std::nothrow) Slot[kCapacity];
    if (!gRing || !gPath) {
        std::fprintf(stderr, "Basalt OpenXR: cannot allocate frame trace ring; tracing disabled\n");
        delete[] gPath; gPath = nullptr; delete[] gRing; gRing = nullptr; return;
    }
    gPathLength = GetEnvironmentVariableW(L"BASALT_FRAME_TRACE", gPath, length);
    if (!gPathLength || gPathLength >= length) {
        delete[] gPath; gPath = nullptr; delete[] gRing; gRing = nullptr; return;
    }
    for (uint64_t i = 0; i < kCapacity; ++i) gRing[i].sequence.store(i, std::memory_order_relaxed);
    gWake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    gFlushed = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    gReady = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    gThread = gWake && gFlushed && gReady ? CreateThread(nullptr, 0, writer, nullptr, 0, nullptr) : nullptr;
    if (gThread) {
        HANDLE initialized[] = {gReady, gThread};
        WaitForMultipleObjects(2, initialized, FALSE, INFINITE);
    }
    if (!gThread || !frameTraceEnabled()) {
        if (!gThread) std::fprintf(stderr, "Basalt OpenXR: cannot start frame trace writer; tracing disabled\n");
        if (gThread) { WaitForSingleObject(gThread, INFINITE); CloseHandle(gThread); gThread = nullptr; }
        if (gWake) CloseHandle(gWake);
        if (gFlushed) CloseHandle(gFlushed);
        if (gReady) CloseHandle(gReady);
        delete[] gRing; gRing = nullptr;
        delete[] gPath; gPath = nullptr;
    }
} catch (...) {
    gFrameTraceEnabled.store(false);
    delete[] gRing; gRing = nullptr;
    delete[] gPath; gPath = nullptr;
    std::fprintf(stderr, "Basalt OpenXR: frame trace initialization failed; tracing disabled\n");
}
void frameTraceFlush() {
    if (!gThread || WaitForSingleObject(gThread, 0) == WAIT_OBJECT_0) return;
    // Lifecycle is allowed to wait. Ensure the flush marker itself is not lost.
    TraceRecord r; r.kind = TraceKind::Flush; r.time = frameTraceNow();
    while (!tryPush(r)) {
        if (WaitForSingleObject(gThread, 0) == WAIT_OBJECT_0) return;
        SetEvent(gWake); Sleep(1);
    }
    SetEvent(gWake);
    HANDLE completion[] = {gFlushed, gThread};
    WaitForMultipleObjects(2, completion, FALSE, INFINITE);
}
void frameTraceStop() {
    if (!gThread) return;
    gFrameTraceEnabled.store(false); frameTraceFlush(); gStop = true; SetEvent(gWake);
    WaitForSingleObject(gThread, INFINITE);
    CloseHandle(gThread); CloseHandle(gWake); CloseHandle(gFlushed); CloseHandle(gReady);
    delete[] gRing; gRing = nullptr;
    delete[] gPath; gPath = nullptr;
    gThread = nullptr; gFile = INVALID_HANDLE_VALUE;
}
}

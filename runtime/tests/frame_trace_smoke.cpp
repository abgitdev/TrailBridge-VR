// SPDX-License-Identifier: MIT
// Exercise the real frame lifecycle/trace writer without D3D or a headset.
// Only graphics/control queries are stand-ins; no game prefix is involved.
#include "runtime.hpp"
#include "control.hpp"
#include "frame_trace.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {
const auto session = reinterpret_cast<XrSession>(uintptr_t(1));
const auto instance = reinterpret_cast<XrInstance>(uintptr_t(2));
void require(bool value, const char* message) {
    if (!value) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); }
}
std::vector<std::string> split(const std::string& line) {
    std::vector<std::string> result;
    std::istringstream stream(line);
    std::string cell;
    while (std::getline(stream, cell, ',')) result.push_back(cell);
    return result;
}
void frames() {
    using namespace basalt;
    initializeSessionLifecycle(instance, session);
    XrSessionBeginInfo start{}; start.type = XR_TYPE_SESSION_BEGIN_INFO;
    start.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    require(beginSession(session, &start) == XR_SUCCESS, "begin session");
    XrCompositionLayerProjectionView eyes[2]{};
    for (auto& eye : eyes) {
        eye.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW;
        eye.pose.orientation.w = 1;
        eye.fov = {-.7f, .7f, .7f, -.7f};
        eye.subImage.swapchain = reinterpret_cast<XrSwapchain>(uintptr_t(4));
        eye.subImage.imageRect.extent = {64, 64};
    }
    XrCompositionLayerProjection projection{}; projection.type = XR_TYPE_COMPOSITION_LAYER_PROJECTION;
    projection.viewCount = 2; projection.views = eyes;
    XrCompositionLayerQuad quad{}; quad.type = XR_TYPE_COMPOSITION_LAYER_QUAD;
    quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    quad.subImage = eyes[0].subImage;
    const XrCompositionLayerBaseHeader* layers[] = {
        reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection),
        reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quad)};
    for (int i = 0; i < 6; ++i) {
        XrFrameState state{}; state.type = XR_TYPE_FRAME_STATE;
        require(waitFrame(session, nullptr, &state) == XR_SUCCESS, "wait frame");
        require(beginFrame(session, nullptr) == XR_SUCCESS, "begin frame");
        XrFrameEndInfo end{}; end.type = XR_TYPE_FRAME_END_INFO;
        end.displayTime = state.predictedDisplayTime;
        end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
        end.layers = layers;
        end.layerCount = i == 0 || i == 4 ? 0 : i == 3 ? 2 : 1;
        if (i == 2) end.layers = &layers[1];
        if (i == 5) {
            XrCompositionLayerBaseHeader unknown{}; unknown.type = XR_TYPE_UNKNOWN;
            const auto* bad = &unknown;
            end.layers = &bad;
            require(endFrame(session, &end) == XR_ERROR_LAYER_INVALID, "unsupported layer result unchanged");
            end.layers = layers;
        }
        require(endFrame(session, &end) == XR_SUCCESS, "end frame");
    }
    invalidateSessionLifecycle(session);
}
}
// Test doubles only for dependencies of frame.cpp, not its pacing/state code.
namespace basalt {
bool isValidSession(XrSession value) { return value == session; }
bool isValidInstance(XrInstance value) { return value == instance; }
bool isDisplayRefreshRateExtensionEnabled(XrInstance) { return false; }
bool isSpaceForSession(XrSpace, XrSession) { return true; }
bool sessionHasReferenceSpace(XrSession, XrReferenceSpaceType) { return false; }
bool isPoseWellFormed(const XrPosef&) { return true; }
bool getSwapchainSubmitState(XrSwapchain, XrSession* s, uint32_t* w, uint32_t* h,
                            uint32_t* a, bool* released, uint32_t* index) {
    *s = session; *w = *h = 64; *a = 1; *released = true; *index = 2; return true;
}
uint64_t locatedViewsQuestTimestamp(XrSession, XrTime) { return 0; }
bool controlActive(XrSession) { return false; }
XrDuration controlConfiguredDisplayPeriod() { return 1'000'000; }
bool controlWaitForFrameBudget(XrSession) { return true; }
void controlNotePredictedDisplayTime(XrSession, XrTime) {}
void controlFrameReady(int64_t, uint64_t, const ControlFrameView*, uint32_t, uint64_t) {}
}
int main(int argc, char** argv) {
    using namespace basalt;
    if (argc == 2 && std::strcmp(argv[1], "--kill-writer") == 0) {
        frameTraceStart();
        for (;;) { frameTraceEvent("kill_probe"); Sleep(1); }
    }
    require(argc == 2, "trace path argument");
    DeleteFileA(argv[1]);
    SetEnvironmentVariableA("BASALT_FRAME_TRACE", nullptr);
    frameTraceStart(); frames(); frameTraceStop();
    const int64_t offStart = frameTraceNow();
    for (unsigned i = 0; i < 100000; ++i) {
        if (frameTraceEnabled()) frameTraceEvent("benchmark");
    }
    const int64_t offMicros = frameTraceNow() - offStart;
    require(GetFileAttributesA(argv[1]) == INVALID_FILE_ATTRIBUTES, "off produces no file");
    SetEnvironmentVariableA("BASALT_FRAME_TRACE", "Q:\\missing-directory\\trace.csv");
    frameTraceStart();
    require(!frameTraceEnabled(), "bad path disables tracing");
    SetEnvironmentVariableA("BASALT_FRAME_TRACE", argv[1]);
    frameTraceStart();
    require(frameTraceEnabled(), "on starts writer");
    frames();
    TraceRecord r;
    r.kind = TraceKind::Release; r.time = frameTraceNow(); r.eyes[0] = {4, 2, 0, 64, 64}; frameTracePush(r);
    r.kind = TraceKind::Submit; r.frame = 3; r.control = 1; frameTracePush(r);
    r.kind = TraceKind::Gpu; r.gpu = 42; r.time = frameTraceNow(); frameTracePush(r);
    r.kind = TraceKind::Acquire; frameTracePush(r);
    r.kind = TraceKind::Consumed; r.time += 100; r.gpu = -1; frameTracePush(r);
    r.kind = TraceKind::Acquire; frameTracePush(r); // consumed: must NOT be stale
    // An ACK can be observed earlier but enqueued later than acquisition.
    // Conversely an earlier acquire can reach the ring after its ACK.
    const int64_t baseTime = frameTraceNow() + 1000;
    r.kind = TraceKind::Submit; r.control = 2; r.time = baseTime; frameTracePush(r);
    r.kind = TraceKind::Acquire; r.time = baseTime + 200; frameTracePush(r);
    r.kind = TraceKind::Consumed; r.time = baseTime + 100; frameTracePush(r);
    r.kind = TraceKind::Acquire; r.time = baseTime + 50; frameTracePush(r);
    // Only transitions become events, including the 500 ms freshness expiry.
    TraceRecord tracking; tracking.kind = TraceKind::Tracking;
    tracking.time = baseTime; tracking.head = tracking.left = tracking.right = 1;
    for (auto& expiry : tracking.trackingExpires) expiry = baseTime + 500000;
    frameTracePush(tracking); frameTracePush(tracking);
    tracking.head = 0; tracking.time += 10; frameTracePush(tracking); frameTracePush(tracking);
    tracking.head = 1; tracking.time += 10; frameTracePush(tracking);
    TraceRecord locate; locate.kind = TraceKind::Locate; locate.time = baseTime + 600000; frameTracePush(locate);
    frameTraceFlush();
    const int64_t onStart = frameTraceNow();
    for (unsigned i = 0; i < 1000; ++i) {
        if (frameTraceEnabled()) frameTraceEvent("benchmark");
    }
    const int64_t onMicros = frameTraceNow() - onStart;
    frameTraceFlush(); frameTraceStop();
    std::ifstream file(argv[1]);
    std::string line;
    unsigned count = 0, stale = 0, late = 0, invalidHead = 0, validHead = 0, otherLayer = 0;
    bool header = false, version = false, clock = false;
    const unsigned total[] = {0, 1, 1, 2, 0, 1};
    const unsigned projections[] = {0, 1, 0, 1, 0, 1};
    const unsigned quads[] = {0, 0, 1, 1, 0, 0};
    while (std::getline(file, line)) {
        if (line == "# trailbridge_frame_trace_version=1") version = true;
        if (line.find("# clock_utc_unix_us=") == 0) clock = true;
        if (line.find("type,frame,") == 0) { require(split(line).size() == 38, "column count"); header = true; }
        if (line.find("frame,") == 0) {
            auto c = split(line);
            require(c.size() == 38 && count < 6, "whole frame row");
            require(std::stoul(c[13]) == total[count] && std::stoul(c[14]) == projections[count] &&
                    std::stoul(c[15]) == quads[count] && c[16] == "0", "layer classification");
            require(std::stoi(c[17]) == (projections[count] != 0) && c[17] == c[18], "delivered views and ready");
            ++count;
        }
        if (line.find("stale_image_reacquired_before_consumed") != std::string::npos) ++stale;
        if (line.find("late,") == 0) ++late;
        if (line.find(",head_tracking_invalid,") != std::string::npos) ++invalidHead;
        if (line.find(",head_tracking_valid,") != std::string::npos) ++validHead;
        if (line.find(",end_frame_failed,") != std::string::npos) {
            auto c = split(line);
            if (c[16] == "1" && std::stoi(c[12]) == XR_ERROR_LAYER_INVALID) ++otherLayer;
        }
    }
    require(version && clock && header && count == 6, "header and expected frames");
    require(stale == 2 && late == 3, "exact image/ACK timestamps and late rows");
    require(invalidHead == 2 && validHead == 1, "tracking transitions and freshness expiry");
    require(otherLayer == 1, "unsupported layers classified without changing validation");
    std::printf("Synthetic Wine producer: disabled %.3f ns/check; enabled %.3f us/record (not real-frame overhead)\n",
        offMicros * 1000.0 / 100000, onMicros / 1000.0);
    const std::string overflowPath = std::string(argv[1]) + ".overflow.csv";
    DeleteFileA(overflowPath.c_str());
    SetEnvironmentVariableA("BASALT_FRAME_TRACE", overflowPath.c_str());
    frameTraceStart();
    for (unsigned i = 0; i < 100000; ++i) frameTraceEvent("overflow_probe");
    frameTraceStop();
    std::ifstream overflow(overflowPath);
    bool lossReported = false;
    while (std::getline(overflow, line)) {
        if (!line.empty() && line[0] != '#') require(split(line).size() == 38, "overflow keeps whole rows");
        if (line.find(",writer_lost_records_total,") != std::string::npos)
            lossReported = std::stoull(split(line)[1]) > 0;
    }
    require(lossReported, "full ring counts and reports lost records without blocking");
    const std::string killPath = std::string(argv[1]) + ".kill.csv";
    DeleteFileA(killPath.c_str());
    SetEnvironmentVariableA("BASALT_FRAME_TRACE", killPath.c_str());
    wchar_t executable[32768]{};
    require(GetModuleFileNameW(nullptr, executable, 32768) != 0, "own smoke executable path");
    std::wstring command = L"\"";
    command += executable; command += L"\" --kill-writer";
    STARTUPINFOW startup{}; startup.cb = sizeof(startup);
    PROCESS_INFORMATION child{};
    require(CreateProcessW(executable, command.data(), nullptr, nullptr, FALSE,
        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &child), "start isolated trace kill probe");
    bool sawRows = false;
    for (unsigned i = 0; i < 1000; ++i) {
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        if (GetFileAttributesExA(killPath.c_str(), GetFileExInfoStandard, &attributes) &&
            attributes.nFileSizeLow > 4096) { sawRows = true; break; }
        Sleep(10);
    }
    TerminateProcess(child.hProcess, 99);
    WaitForSingleObject(child.hProcess, INFINITE);
    CloseHandle(child.hThread); CloseHandle(child.hProcess);
    require(sawRows, "kill probe wrote rows before termination");
    std::ifstream killed(killPath, std::ios::binary);
    killed.seekg(-1, std::ios::end);
    char finalByte = 0; killed.get(finalByte);
    require(finalByte == '\n', "killed writer left a whole final line");
    killed.clear(); killed.seekg(0);
    while (std::getline(killed, line))
        if (!line.empty() && line[0] != '#') require(split(line).size() == 38, "killed trace remains parseable");
    std::puts("PASS: full-ring loss accounting and abruptly killed trace writer");
    std::puts("PASS: opt-in frame trace lifecycle, layers, late waits and image identity");
}

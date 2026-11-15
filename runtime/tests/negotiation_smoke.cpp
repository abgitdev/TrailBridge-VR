#include <windows.h>

#define XR_USE_PLATFORM_WIN32
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <openxr/openxr_loader_negotiation.h>

#include <cstdint>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <initializer_list>

#include "../pe/controller_pose.hpp"

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        ++failures;
    }
}

bool vectorNear(const XrVector3f& a, const XrVector3f& b) {
    return std::fabs(a.x - b.x) < 0.00001f &&
        std::fabs(a.y - b.y) < 0.00001f && std::fabs(a.z - b.z) < 0.00001f;
}

bool poseNear(const XrPosef& a, const XrPosef& b) {
    const float dot = a.orientation.x * b.orientation.x +
        a.orientation.y * b.orientation.y + a.orientation.z * b.orientation.z +
        a.orientation.w * b.orientation.w;
    return vectorNear(a.position, b.position) && std::fabs(std::fabs(dot) - 1.0f) < 0.00001f;
}

void checkControllerPoses() {
    using namespace basalt;
    check(parseTouchGripPitch(nullptr) == 0.0f && parseTouchGripPitch("") == 0.0f,
          "missing grip override is off");
    check(parseTouchGripPitch("+15") == 15.0f && parseTouchGripPitch("-43.5") == -43.5f &&
              parseTouchGripPitch("180") == 180.0f && parseTouchGripPitch("-180") == -180.0f,
          "grip override accepts signed degrees within bounds");
    for (const char* invalid : {"nan", "inf", "-inf", "1e999", "181", "-181",
                               "15deg", "15 20", "--15", "garbage"}) {
        check(parseTouchGripPitch(invalid) == 0.0f, "invalid grip override is off");
    }

    constexpr float s = 0.7071067811865475f;
    // A world yaw makes an incorrectly pre-multiplied local pitch observable.
    const XrPosef source{{0.0f, s, 0.0f, s}, {0.2f, 1.1f, -0.6f}};
    const XrPosef identity = identityPose();
    for (uint32_t hand = 0; hand < 2; ++hand) {
        const XrPosef grip = touchActionPoseInLocal(source, hand, false, 0.0f, identity);
        check(poseNear(grip, source), "default grip preserves the OpenComposite raw-pose source");

        const XrPosef aim = touchActionPoseInLocal(source, hand, true, 0.0f, identity);
        const float side = hand == 0 ? 1.0f : -1.0f;
        const XrPosef expectedOffset{
            {-0.366501227f, 0.0f, 0.0f, 0.930417568f},
            {side * 0.014694f, -0.025988699f, -0.073315846f}};
        check(poseNear(poseCompose(poseInvert(grip), aim), expectedOffset),
              "estimated aim is -43 degrees with mirrored position relative to corrected grip");
        check(vectorNear(aim.position,
                         {0.126684154f, 1.074011301f, -0.6f - side * 0.014694f}),
              "aim origin offset rotates with the controller in world space");
        check(vectorNear(quaternionRotate(aim.orientation, {0.0f, 0.0f, -1.0f}),
                         {-0.731353702f, -0.681998360f, 0.0f}),
              "aim forward follows the estimated pointing ray rather than grip forward");

        const XrPosef overridden = touchActionPoseInLocal(source, hand, false, 15.0f, identity);
        check(vectorNear(overridden.position, source.position) &&
                  vectorNear(quaternionRotate(overridden.orientation, {0.0f, 0.0f, -1.0f}),
                             {-0.965925826f, 0.258819045f, 0.0f}),
              "grip override is a local pitch on both hands and preserves the origin");
        check(poseNear(touchActionPoseInLocal(source, hand, true, 15.0f, identity), aim),
              "grip compatibility experiment leaves the estimated aim ray unchanged");

        const XrPosef appOffset{{0.0f, 0.0f, s, s}, {0.0f, 0.0f, -0.1f}};
        const XrPosef appAim = touchActionPoseInLocal(source, hand, true, 0.0f, appOffset);
        check(vectorNear(appAim.position,
                         {aim.position.x - 0.073135370f, aim.position.y - 0.068199836f,
                          aim.position.z}) &&
                  vectorNear(quaternionRotate(appAim.orientation, {1.0f, 0.0f, 0.0f}),
                             {-0.681998360f, 0.731353702f, 0.0f}),
              "application position and rotation offsets follow the selected aim pose");
        check(poseNear(touchActionPoseInLocal(source, hand, false, 0.0f, appOffset),
                       poseCompose(source, appOffset)),
              "default grip preserves existing application offsets");

        const XrPosef baseOffset{{s, 0.0f, 0.0f, s}, {0.1f, 0.2f, 0.3f}};
        const XrPosef actionBase = touchActionPoseInLocal(source, hand, true, 0.0f, baseOffset);
        const XrPosef head{{0.0f, 0.0f, 0.0f, 1.0f}, {-0.3f, 1.6f, 0.8f}};
        check(poseNear(poseCompose(actionBase, poseCompose(poseInvert(actionBase), head)), head),
              "an aim action base with offsets round-trips head/view poses");
    }
    std::puts("PASS: controller pose math, grip preservation and override validation");
}

// xrLocateViews holds eye poses relative to a LOCAL-family base through a
// tracking gap and re-expresses them when a recenter changed LOCAL-from-Quest.
void checkHeldViewRebase() {
    using namespace basalt;
    constexpr float s = 0.7071067811865475f;
    const XrPosef eyeInQuest{{0.0f, s, 0.0f, s}, {0.4f, 1.6f, -0.3f}};
    const XrPosef previousLocalFromQuest{{0.0f, 0.5f, 0.0f, 0.866025404f}, {-0.25f, 0.0f, 0.5f}};
    const XrPosef localFromQuest{{0.0f, -s, 0.0f, s}, {0.3f, 0.0f, -0.1f}};
    // A rotated, offset base makes a missing or misordered conjugation observable.
    const XrPosef basePose{{s, 0.0f, 0.0f, s}, {0.1f, 0.2f, 0.3f}};
    const XrPosef held = poseCompose(
        poseInvert(basePose), poseCompose(previousLocalFromQuest, eyeInQuest));
    const XrPosef expected = poseCompose(
        poseInvert(basePose), poseCompose(localFromQuest, eyeInQuest));
    check(poseNear(poseCompose(baseFromPreviousBase(
                                   basePose, previousLocalFromQuest, localFromQuest),
                               held),
                   expected),
          "held eye pose follows a recentered LOCAL into an offset base");
    check(poseNear(poseCompose(baseFromPreviousBase(
                                   basePose, localFromQuest, previousLocalFromQuest),
                               expected),
                   held),
          "held eye pose follows a locate from before the recenter back");
    check(!poseNear(poseCompose(poseCompose(localFromQuest, poseInvert(previousLocalFromQuest)),
                                held),
                    expected),
          "the base offset makes an unconjugated rebase observable");
    check(poseNear(baseFromPreviousBase(basePose, localFromQuest, localFromQuest),
                   identityPose()),
          "an unchanged LOCAL definition keeps held eye poses");
    std::puts("PASS: held eye poses rebase across a LOCAL recenter");
}

XrNegotiateLoaderInfo validLoaderInfo() {
    XrNegotiateLoaderInfo info{};
    info.structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;
    info.structVersion = XR_LOADER_INFO_STRUCT_VERSION;
    info.structSize = sizeof(info);
    info.minInterfaceVersion = 1;
    info.maxInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
    info.minApiVersion = XR_MAKE_VERSION(1, 0, 0);
    info.maxApiVersion = XR_MAKE_VERSION(1, 0x3ff, 0xfff);
    return info;
}

XrNegotiateRuntimeRequest validRuntimeRequest() {
    XrNegotiateRuntimeRequest request{};
    request.structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;
    request.structVersion = XR_RUNTIME_INFO_STRUCT_VERSION;
    request.structSize = sizeof(request);
    return request;
}

// XR_KHR_win32_convert_performance_counter_time: the runtime's XrTime is the
// QueryPerformanceCounter value in nanoseconds, so conversion is exact scaling.
void checkPerformanceCounterConversion(PFN_xrGetInstanceProcAddr getInstanceProcAddr,
                                       PFN_xrCreateInstance create,
                                       PFN_xrDestroyInstance destroy,
                                       XrInstanceCreateInfo createInfo) {
    const char* enabled[] = {XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME};
    createInfo.enabledExtensionCount = 1;
    createInfo.enabledExtensionNames = enabled;
    XrInstance instance = XR_NULL_HANDLE;
    check(create(&createInfo, &instance) == XR_SUCCESS && instance != XR_NULL_HANDLE,
          "an instance enables the clock-conversion extension");
    PFN_xrVoidFunction toTimeVoid = nullptr;
    PFN_xrVoidFunction toCounterVoid = nullptr;
    check(getInstanceProcAddr(instance, "xrConvertWin32PerformanceCounterToTimeKHR", &toTimeVoid) ==
                  XR_SUCCESS && toTimeVoid != nullptr &&
              getInstanceProcAddr(instance, "xrConvertTimeToWin32PerformanceCounterKHR",
                                  &toCounterVoid) == XR_SUCCESS && toCounterVoid != nullptr,
          "GIPA exposes both clock conversions once enabled");
    if (toTimeVoid == nullptr || toCounterVoid == nullptr) {
        destroy(instance);
        return;
    }
    auto toTime = reinterpret_cast<PFN_xrConvertWin32PerformanceCounterToTimeKHR>(toTimeVoid);
    auto toCounter = reinterpret_cast<PFN_xrConvertTimeToWin32PerformanceCounterKHR>(toCounterVoid);

    LARGE_INTEGER frequency{};
    LARGE_INTEGER now{};
    check(QueryPerformanceFrequency(&frequency) && frequency.QuadPart > 0 &&
              QueryPerformanceCounter(&now) && now.QuadPart > 0,
          "the performance counter works");
    const int64_t expected = now.QuadPart / frequency.QuadPart * 1'000'000'000 +
        now.QuadPart % frequency.QuadPart * 1'000'000'000 / frequency.QuadPart;
    XrTime time = 0;
    check(toTime(instance, &now, &time) == XR_SUCCESS && time == expected,
          "a counter converts to QueryPerformanceCounter in nanoseconds, the runtime clock");
    LARGE_INTEGER back{};
    check(toCounter(instance, time, &back) == XR_SUCCESS && back.QuadPart <= now.QuadPart &&
              now.QuadPart - back.QuadPart <= 1,
          "a converted time converts back to its counter");
    LARGE_INTEGER later{};
    QueryPerformanceCounter(&later);
    XrTime laterTime = 0;
    check(toTime(instance, &later, &laterTime) == XR_SUCCESS && laterTime >= time,
          "converted times follow the counter");

    LARGE_INTEGER invalid{};
    XrTime unchanged = 0;
    check(toTime(instance, &invalid, &unchanged) == XR_ERROR_TIME_INVALID,
          "a zero counter is not a time");
    invalid.QuadPart = -1;
    check(toTime(instance, &invalid, &unchanged) == XR_ERROR_TIME_INVALID,
          "a negative counter is not a time");
    check(toCounter(instance, 0, &back) == XR_ERROR_TIME_INVALID &&
              toCounter(instance, -1, &back) == XR_ERROR_TIME_INVALID,
          "times at or before zero are invalid");
    if (frequency.QuadPart < 1'000'000'000) {
        invalid.QuadPart = INT64_MAX;
        check(toTime(instance, &invalid, &unchanged) == XR_ERROR_TIME_INVALID,
              "a counter beyond the XrTime range is rejected");
    }
    check(toTime(instance, nullptr, &time) == XR_ERROR_VALIDATION_FAILURE &&
              toTime(instance, &now, nullptr) == XR_ERROR_VALIDATION_FAILURE &&
              toCounter(instance, time, nullptr) == XR_ERROR_VALIDATION_FAILURE,
          "clock conversions validate their pointers");

    check(destroy(instance) == XR_SUCCESS, "the clock-conversion instance is destroyed");
    check(toTime(instance, &now, &time) == XR_ERROR_HANDLE_INVALID &&
              toCounter(instance, expected, &back) == XR_ERROR_HANDLE_INVALID,
          "clock conversions reject a destroyed instance");

    // A later instance that did not enable the extension cannot use it.
    createInfo.enabledExtensionCount = 0;
    createInfo.enabledExtensionNames = nullptr;
    XrInstance plain = XR_NULL_HANDLE;
    check(create(&createInfo, &plain) == XR_SUCCESS, "an instance without the extension is created");
    check(toTime(plain, &now, &time) == XR_ERROR_FUNCTION_UNSUPPORTED,
          "a clock conversion on an instance without the extension is unsupported");
    check(destroy(plain) == XR_SUCCESS, "the instance without the extension is destroyed");
    std::printf("Performance counter frequency: %lld Hz\n",
                static_cast<long long>(frequency.QuadPart));
}

// XR_FB_display_refresh_rate: its functions reach only an instance that
// enabled it, and they need a session, which plain Wine cannot create, so
// here they only reject a null session. d3d11_runtime_smoke checks the rates.
void checkDisplayRefreshRateGating(PFN_xrGetInstanceProcAddr getInstanceProcAddr,
                                   PFN_xrCreateInstance create,
                                   PFN_xrDestroyInstance destroy,
                                   XrInstanceCreateInfo createInfo) {
    const char* names[] = {"xrEnumerateDisplayRefreshRatesFB", "xrGetDisplayRefreshRateFB",
                           "xrRequestDisplayRefreshRateFB"};
    const char* enabled[] = {XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME};
    createInfo.enabledExtensionCount = 1;
    createInfo.enabledExtensionNames = enabled;
    XrInstance instance = XR_NULL_HANDLE;
    check(create(&createInfo, &instance) == XR_SUCCESS && instance != XR_NULL_HANDLE,
          "an instance enables the display refresh rate extension");
    PFN_xrVoidFunction functions[3]{};
    bool exposed = true;
    for (int index = 0; index < 3; ++index) {
        exposed = exposed &&
            getInstanceProcAddr(instance, names[index], &functions[index]) == XR_SUCCESS &&
            functions[index] != nullptr;
    }
    check(exposed, "GIPA exposes the three refresh rate functions once enabled");
    if (exposed) {
        auto enumerateRates = reinterpret_cast<PFN_xrEnumerateDisplayRefreshRatesFB>(functions[0]);
        auto getRate = reinterpret_cast<PFN_xrGetDisplayRefreshRateFB>(functions[1]);
        auto requestRate = reinterpret_cast<PFN_xrRequestDisplayRefreshRateFB>(functions[2]);
        uint32_t count = 0;
        float rate = 0.0f;
        check(enumerateRates(XR_NULL_HANDLE, 0, &count, nullptr) == XR_ERROR_HANDLE_INVALID &&
                  getRate(XR_NULL_HANDLE, &rate) == XR_ERROR_HANDLE_INVALID &&
                  requestRate(XR_NULL_HANDLE, 72.0f) == XR_ERROR_HANDLE_INVALID,
              "refresh rate functions reject a null session");
    }
    check(destroy(instance) == XR_SUCCESS, "the refresh rate instance is destroyed");

    createInfo.enabledExtensionCount = 0;
    createInfo.enabledExtensionNames = nullptr;
    XrInstance plain = XR_NULL_HANDLE;
    check(create(&createInfo, &plain) == XR_SUCCESS, "an instance without refresh rate is created");
    bool hidden = true;
    for (const char* name : names) {
        PFN_xrVoidFunction function = nullptr;
        hidden = hidden &&
            getInstanceProcAddr(plain, name, &function) == XR_ERROR_FUNCTION_UNSUPPORTED &&
            function == nullptr;
    }
    check(hidden, "GIPA hides the refresh rate functions from an instance without the extension");
    check(destroy(plain) == XR_SUCCESS, "the instance without refresh rate is destroyed");
}

}  // namespace

int main(int argc, char** argv) {
    checkControllerPoses();
    checkHeldViewRebase();
    const char* dllPath = argc > 1 ? argv[1] : "basalt_openxr.dll";
    HMODULE runtime = LoadLibraryA(dllPath);
    check(runtime != nullptr, "LoadLibraryA loads basalt_openxr.dll");
    if (runtime == nullptr) {
        std::fprintf(stderr, "Windows error: %lu\n", GetLastError());
        return 1;
    }

    FARPROC negotiateAddress = GetProcAddress(runtime, "xrNegotiateLoaderRuntimeInterface");
    PFN_xrNegotiateLoaderRuntimeInterface negotiate = nullptr;
    static_assert(sizeof(negotiate) == sizeof(negotiateAddress));
    std::memcpy(&negotiate, &negotiateAddress, sizeof(negotiate));
    check(negotiate != nullptr, "runtime exports unmangled negotiation entry point");
    if (negotiate == nullptr) {
        FreeLibrary(runtime);
        return 1;
    }

    auto loaderInfo = validLoaderInfo();
    auto runtimeRequest = validRuntimeRequest();
    check(negotiate(&loaderInfo, &runtimeRequest) == XR_SUCCESS, "valid negotiation succeeds");
    check(runtimeRequest.runtimeInterfaceVersion == 1, "runtime selects interface version 1");
    check(XR_VERSION_MAJOR(runtimeRequest.runtimeApiVersion) == 1 &&
              XR_VERSION_MINOR(runtimeRequest.runtimeApiVersion) == 0,
          "runtime selects OpenXR 1.0");
    check(runtimeRequest.getInstanceProcAddr != nullptr, "runtime supplies xrGetInstanceProcAddr");

    check(negotiate(nullptr, &runtimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "null loader info is rejected");
    check(negotiate(&loaderInfo, nullptr) == XR_ERROR_INITIALIZATION_FAILED,
          "null runtime request is rejected");

    auto badLoaderInfo = validLoaderInfo();
    badLoaderInfo.structType = XR_LOADER_INTERFACE_STRUCT_UNINTIALIZED;
    auto scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad loader struct type is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.structVersion += 1;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad loader struct version is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.structSize -= 1;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad loader struct size is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minInterfaceVersion = 2;
    badLoaderInfo.maxInterfaceVersion = 2;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "incompatible loader interface is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minInterfaceVersion = 1;
    badLoaderInfo.maxInterfaceVersion = 0;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "reversed interface range is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minApiVersion = XR_MAKE_VERSION(2, 0, 0);
    badLoaderInfo.maxApiVersion = XR_MAKE_VERSION(2, 0, 0);
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "incompatible API range is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minApiVersion = XR_MAKE_VERSION(1, 1, 0);
    badLoaderInfo.maxApiVersion = XR_MAKE_VERSION(1, 0, 0);
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "reversed API range is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minApiVersion = XR_MAKE_VERSION(1, 0, 999);
    badLoaderInfo.maxApiVersion = XR_MAKE_VERSION(1, 0, 999);
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_SUCCESS,
          "API negotiation ignores patch-only differences");

    auto badRuntimeRequest = validRuntimeRequest();
    badRuntimeRequest.structSize -= 1;
    check(negotiate(&loaderInfo, &badRuntimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad runtime request struct is rejected");

    badRuntimeRequest = validRuntimeRequest();
    badRuntimeRequest.structType = XR_LOADER_INTERFACE_STRUCT_UNINTIALIZED;
    check(negotiate(&loaderInfo, &badRuntimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad runtime request type is rejected");

    badRuntimeRequest = validRuntimeRequest();
    badRuntimeRequest.structVersion += 1;
    check(negotiate(&loaderInfo, &badRuntimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad runtime request version is rejected");

    PFN_xrVoidFunction cleared = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(XR_NULL_HANDLE, nullptr, &cleared) ==
              XR_ERROR_VALIDATION_FAILURE && cleared == nullptr,
          "GIPA rejects a null name and clears output");
    check(runtimeRequest.getInstanceProcAddr(XR_NULL_HANDLE, "xrCreateInstance", nullptr) ==
              XR_ERROR_VALIDATION_FAILURE,
          "GIPA rejects a null output pointer");

    PFN_xrVoidFunction unknown = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrDefinitelyNotBasalt", &unknown) == XR_ERROR_HANDLE_INVALID,
          "non-global null-instance lookup is rejected");
    check(unknown == nullptr, "unknown function pointer is cleared");

    PFN_xrVoidFunction instanceOnly = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrDestroyInstance", &instanceOnly) == XR_ERROR_HANDLE_INVALID &&
              instanceOnly == nullptr,
          "instance command requires a valid instance");

    PFN_xrVoidFunction enumerateVoid = nullptr;
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties", &enumerateVoid) == XR_SUCCESS &&
              enumerateVoid != nullptr,
          "GIPA exposes extension enumeration");
    auto enumerate = reinterpret_cast<PFN_xrEnumerateInstanceExtensionProperties>(enumerateVoid);
    // The clock conversion and the display refresh rate are always
    // advertised; D3D11 only where DXMT supplies a device, which this
    // plain-Wine smoke expects to be hidden.
    uint32_t extensionCount = UINT32_MAX;
    check(enumerate(nullptr, 0, &extensionCount, nullptr) == XR_SUCCESS &&
              extensionCount >= 2 && extensionCount <= 3,
          "runtime advertises two or three extensions");
    XrExtensionProperties advertised[3]{};
    advertised[0].type = XR_TYPE_EXTENSION_PROPERTIES;
    advertised[1].type = XR_TYPE_EXTENSION_PROPERTIES;
    advertised[2].type = XR_TYPE_EXTENSION_PROPERTIES;
    const uint32_t capacity = extensionCount <= 3 ? extensionCount : 3;
    uint32_t written = 0;
    bool foundCounterTime = false;
    bool foundRefreshRate = false;
    bool foundD3D11 = false;
    if (enumerate(nullptr, capacity, &written, advertised) == XR_SUCCESS) {
        for (uint32_t index = 0; index < written && index < 3; ++index) {
            const XrExtensionProperties& extension = advertised[index];
            foundCounterTime = foundCounterTime ||
                (std::strcmp(extension.extensionName,
                             XR_KHR_WIN32_CONVERT_PERFORMANCE_COUNTER_TIME_EXTENSION_NAME) == 0 &&
                 extension.extensionVersion ==
                     XR_KHR_win32_convert_performance_counter_time_SPEC_VERSION);
            foundRefreshRate = foundRefreshRate ||
                (std::strcmp(extension.extensionName,
                             XR_FB_DISPLAY_REFRESH_RATE_EXTENSION_NAME) == 0 &&
                 extension.extensionVersion == XR_FB_display_refresh_rate_SPEC_VERSION);
            foundD3D11 = foundD3D11 ||
                std::strcmp(extension.extensionName, "XR_KHR_D3D11_enable") == 0;
        }
    }
    check(foundCounterTime, "runtime advertises XR_KHR_win32_convert_performance_counter_time v1");
    check(foundRefreshRate, "runtime advertises XR_FB_display_refresh_rate v1");
    check(!foundD3D11, "plain Wine hides XR_KHR_D3D11_enable");
    XrExtensionProperties untyped[3]{};
    check(enumerate(nullptr, capacity, &written, untyped) == XR_ERROR_VALIDATION_FAILURE,
          "extension enumeration validates the output structure type");
    check(enumerate("missing-layer", 0, &extensionCount, nullptr) == XR_ERROR_API_LAYER_NOT_PRESENT,
          "extension enumeration rejects an unknown API layer");
    check(enumerate(nullptr, 1, &extensionCount, nullptr) == XR_ERROR_VALIDATION_FAILURE,
          "extension enumeration validates its output buffer");

    PFN_xrVoidFunction layersVoid = nullptr;
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrEnumerateApiLayerProperties", &layersVoid) == XR_SUCCESS &&
              layersVoid != nullptr,
          "GIPA exposes API-layer enumeration");
    auto enumerateLayers = reinterpret_cast<PFN_xrEnumerateApiLayerProperties>(layersVoid);
    uint32_t layerCount = UINT32_MAX;
    check(enumerateLayers(0, &layerCount, nullptr) == XR_SUCCESS && layerCount == 0,
          "runtime advertises zero API layers");

    PFN_xrVoidFunction createVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(XR_NULL_HANDLE, "xrCreateInstance", &createVoid);
    auto create = reinterpret_cast<PFN_xrCreateInstance>(createVoid);
    XrInstanceCreateInfo createInfo{};
    createInfo.type = XR_TYPE_INSTANCE_CREATE_INFO;
    createInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    std::strncpy(createInfo.applicationInfo.applicationName, "Basalt direct smoke",
                 XR_MAX_APPLICATION_NAME_SIZE - 1);
    XrInstance instance = XR_NULL_HANDLE;
    check(create(&createInfo, &instance) == XR_SUCCESS && instance != XR_NULL_HANDLE,
          "direct xrCreateInstance succeeds");

    XrInstance secondInstance = XR_NULL_HANDLE;
    check(create(&createInfo, &secondInstance) == XR_ERROR_LIMIT_REACHED &&
              secondInstance == XR_NULL_HANDLE,
          "runtime bounds simultaneous live instances");

    PFN_xrVoidFunction unknownWithInstance = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(
              instance, "xrDefinitelyNotBasalt", &unknownWithInstance) == XR_ERROR_FUNCTION_UNSUPPORTED &&
              unknownWithInstance == nullptr,
          "unknown function with a valid instance is unsupported");
    for (const char* conversion : {"xrConvertWin32PerformanceCounterToTimeKHR",
                                   "xrConvertTimeToWin32PerformanceCounterKHR"}) {
        PFN_xrVoidFunction notEnabled = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
        check(runtimeRequest.getInstanceProcAddr(instance, conversion, &notEnabled) ==
                  XR_ERROR_FUNCTION_UNSUPPORTED && notEnabled == nullptr,
              "clock conversions need their extension enabled");
    }

    PFN_xrVoidFunction getSystemVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrGetSystem", &getSystemVoid);
    auto getSystem = reinterpret_cast<PFN_xrGetSystem>(getSystemVoid);
    XrSystemGetInfo systemInfo{};
    systemInfo.type = XR_TYPE_SYSTEM_GET_INFO;
    systemInfo.formFactor = XR_FORM_FACTOR_HANDHELD_DISPLAY;
    XrSystemId systemId = 99;
    check(getSystem(instance, &systemInfo, &systemId) == XR_ERROR_FORM_FACTOR_UNSUPPORTED &&
              systemId == XR_NULL_SYSTEM_ID,
          "system discovery rejects unsupported form factors and clears output");
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    check(getSystem(instance, &systemInfo, &systemId) == XR_SUCCESS && systemId != XR_NULL_SYSTEM_ID,
          "direct HMD system discovery succeeds");

    PFN_xrVoidFunction systemPropertiesVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrGetSystemProperties", &systemPropertiesVoid);
    auto getSystemProperties = reinterpret_cast<PFN_xrGetSystemProperties>(systemPropertiesVoid);
    XrSystemProperties badSystemProperties{};
    badSystemProperties.type = XR_TYPE_UNKNOWN;
    check(getSystemProperties(instance, systemId, &badSystemProperties) == XR_ERROR_VALIDATION_FAILURE,
          "system properties validate the output structure type");
    badSystemProperties.type = XR_TYPE_SYSTEM_PROPERTIES;
    check(getSystemProperties(instance, systemId + 1, &badSystemProperties) == XR_ERROR_SYSTEM_INVALID,
          "system properties reject an unknown system ID");

    PFN_xrVoidFunction viewConfigurationsVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrEnumerateViewConfigurations", &viewConfigurationsVoid);
    auto enumerateViewConfigurations =
        reinterpret_cast<PFN_xrEnumerateViewConfigurations>(viewConfigurationsVoid);
    uint32_t viewConfigurationCount = 0;
    check(enumerateViewConfigurations(instance, systemId + 1, 0,
                                      &viewConfigurationCount, nullptr) == XR_ERROR_SYSTEM_INVALID,
          "view configuration enumeration rejects an unknown system ID");

    PFN_xrVoidFunction viewsVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrEnumerateViewConfigurationViews", &viewsVoid);
    auto enumerateViews = reinterpret_cast<PFN_xrEnumerateViewConfigurationViews>(viewsVoid);
    uint32_t viewCount = 0;
    check(enumerateViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_MONO,
                         0, &viewCount, nullptr) == XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED,
          "view enumeration rejects unsupported view types");
    XrViewConfigurationView shortViews[1]{};
    shortViews[0].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    check(enumerateViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                         1, &viewCount, shortViews) == XR_ERROR_SIZE_INSUFFICIENT && viewCount == 2,
          "stereo view enumeration reports an undersized output array");
    XrViewConfigurationView directViews[2]{};
    directViews[0].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    directViews[1].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    directViews[0].next = reinterpret_cast<void*>(static_cast<uintptr_t>(1));
    directViews[1].next = reinterpret_cast<void*>(static_cast<uintptr_t>(2));
    check(enumerateViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                         2, &viewCount, directViews) == XR_SUCCESS && viewCount == 2 &&
              directViews[0].next == reinterpret_cast<void*>(static_cast<uintptr_t>(1)) &&
              directViews[1].next == reinterpret_cast<void*>(static_cast<uintptr_t>(2)),
          "stereo view enumeration preserves caller-owned header fields");

    PFN_xrVoidFunction propertiesVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrGetInstanceProperties", &propertiesVoid);
    auto getProperties = reinterpret_cast<PFN_xrGetInstanceProperties>(propertiesVoid);
    XrInstanceProperties properties{};
    properties.type = XR_TYPE_INSTANCE_PROPERTIES;
    properties.next = reinterpret_cast<void*>(static_cast<uintptr_t>(1));
    check(getProperties(instance, &properties) == XR_SUCCESS, "direct xrGetInstanceProperties succeeds");
    check(std::strncmp(properties.runtimeName, "BasaltVR", 8) == 0,
          "runtime properties identify BasaltVR");
    check(properties.type == XR_TYPE_INSTANCE_PROPERTIES &&
              properties.next == reinterpret_cast<void*>(static_cast<uintptr_t>(1)),
          "runtime properties preserve caller-owned header fields");

    PFN_xrVoidFunction destroyVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrDestroyInstance", &destroyVoid);
    auto destroy = reinterpret_cast<PFN_xrDestroyInstance>(destroyVoid);
    check(destroy(instance) == XR_SUCCESS, "direct xrDestroyInstance succeeds");
    check(destroy(instance) == XR_ERROR_HANDLE_INVALID, "double destroy rejects a stale handle");
    check(getProperties(instance, &properties) == XR_ERROR_HANDLE_INVALID,
          "properties reject a destroyed handle");
    check(destroy(reinterpret_cast<XrInstance>(static_cast<uintptr_t>(0x1234))) == XR_ERROR_HANDLE_INVALID,
          "destroy rejects a forged handle without dereferencing it");

    XrInstance replacement = XR_NULL_HANDLE;
    check(create(&createInfo, &replacement) == XR_SUCCESS && replacement != XR_NULL_HANDLE,
          "instance can be recreated after destroy");
    check(destroy(instance) == XR_ERROR_HANDLE_INVALID,
          "an old handle cannot target a newly created instance");
    systemId = XR_NULL_SYSTEM_ID;
    check(getSystem(instance, &systemInfo, &systemId) == XR_ERROR_HANDLE_INVALID,
          "system discovery rejects a stale instance handle");
    check(destroy(replacement) == XR_SUCCESS, "replacement instance is destroyed");

    for (uint32_t cycle = 0; cycle < 128; ++cycle) {
        XrInstance cycledInstance = XR_NULL_HANDLE;
        if (create(&createInfo, &cycledInstance) != XR_SUCCESS ||
            destroy(cycledInstance) != XR_SUCCESS) {
            check(false, "instance handle generation survives repeated create/destroy cycles");
            break;
        }
    }

    checkPerformanceCounterConversion(runtimeRequest.getInstanceProcAddr, create, destroy, createInfo);
    checkDisplayRefreshRateGating(runtimeRequest.getInstanceProcAddr, create, destroy, createInfo);

    FreeLibrary(runtime);
    if (failures != 0) {
        std::fprintf(stderr, "%d negotiation smoke check(s) failed\n", failures);
        return 1;
    }
    std::puts("PASS: BasaltVR runtime negotiation and direct lifecycle");
    return 0;
}

#pragma once

#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdlib>

#include "pose_math.hpp"

namespace basalt {

inline XrQuaternionf controllerPitch(float degrees) {
    constexpr float kHalfRadiansPerDegree = 3.14159265358979323846f / 360.0f;
    const float halfAngle = degrees * kHalfRadiansPerDegree;
    return {std::sin(halfAngle), 0.0f, 0.0f, std::cos(halfAngle)};
}

// A process-local compatibility experiment, not a new controller calibration.
// Missing, malformed, non-finite and out-of-range values leave grip unchanged.
inline float parseTouchGripPitch(const char* value) {
    if (value == nullptr || *value == '\0') {
        return 0.0f;
    }
    char* end = nullptr;
    errno = 0;
    const float degrees = std::strtof(value, &end);
    return end != value && *end == '\0' && errno != ERANGE &&
            std::isfinite(degrees) && std::fabs(degrees) <= 180.0f
        ? degrees : 0.0f;
}

inline XrPosef estimatedTouchAimFromAlvrGrip(uint32_t hand) {
    // ALVR 20.14.1 interaction.rs sends native OpenXR grip * this correction
    // on Quest 2/3. Keep the corrected grip as our default grip convention.
    const float side = hand == 0 ? 1.0f : -1.0f;
    const XrPosef nativeGripFromAlvrGrip{
        controllerPitch(-15.0f), {-side * 0.005f, -0.005f, 0.0f}};

    // OpenComposite openxr, OculusInteractionProfile.cpp: Quest 2 SteamVR
    // openxr_grip and tip components (T * Rx). These are published model
    // values, NOT a measured Quest 3/Touch Plus aim calibration.
    const XrPosef rawFromNativeGrip{
        controllerPitch(20.6f), {side * 0.007f, -0.00182941f, 0.1019482f}};
    const XrPosef rawFromAim{
        controllerPitch(-37.4f), {side * 0.016694f, -0.02522f, 0.024687f}};
    return poseCompose(poseInvert(nativeGripFromAlvrGrip),
        poseCompose(poseInvert(rawFromNativeGrip), rawFromAim));
}

inline XrPosef touchActionPoseInLocal(
    const XrPosef& alvrGripInLocal,
    uint32_t hand,
    bool aim,
    float gripPitchDegrees,
    const XrPosef& poseInActionSpace) {
    static const XrPosef aimFromAlvrGrip[2] = {
        estimatedTouchAimFromAlvrGrip(0), estimatedTouchAimFromAlvrGrip(1)};
    const XrPosef sourceFromAction = aim
        ? aimFromAlvrGrip[hand == 0 ? 0 : 1]
        : XrPosef{controllerPitch(gripPitchDegrees), {0.0f, 0.0f, 0.0f}};
    // The grip-only override deliberately leaves the estimated physical aim
    // ray alone. Application offsets are always applied in the chosen pose.
    return poseCompose(poseCompose(alvrGripInLocal, sourceFromAction), poseInActionSpace);
}

}  // namespace basalt

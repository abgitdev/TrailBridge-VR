#pragma once

#include <cmath>
#include <cstdint>

namespace basalt {

constexpr int64_t kDefaultDisplayPeriod = 13'888'889;

// The control file carries integer millihertz, avoiding locale-dependent
// floating-point text. One millihertz is the smallest representable rate.
inline int64_t displayPeriodFromMillihertz(double millihertz) {
    if (!std::isfinite(millihertz) || millihertz < 1 || millihertz > 240'000 ||
        std::floor(millihertz) != millihertz) {
        return kDefaultDisplayPeriod;
    }
    return static_cast<int64_t>(std::llround(1'000'000'000'000.0 / millihertz));
}

}  // namespace basalt

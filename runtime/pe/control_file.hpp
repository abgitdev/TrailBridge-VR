#pragma once

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "basalt_control_protocol.h"
#include "frame_period.hpp"

namespace basalt {

struct ControlFileSettings {
    uint16_t port = 0;
    char token[BASALT_CONTROL_TOKEN_LENGTH + 1]{};
    uint32_t width = 0;
    uint32_t height = 0;
    int64_t displayPeriod = kDefaultDisplayPeriod;
    bool invalidRefreshRate = false;
};

// Pure parser shared with the timer probe. Both old two/four-field files and
// the optional fifth field are accepted. Bad rates must not break the socket
// handoff: retain 72 Hz and let the caller log the fallback once.
inline bool parseControlFile(const char* contents, ControlFileSettings* settings) {
    *settings = {};
    unsigned int port = 0, width = 0, height = 0;
    char token[64]{}, rate[64]{}, extra = '\0';
    const int count = std::sscanf(contents, "%u %63s %u %u %63s %c",
                                  &port, token, &width, &height, rate, &extra);
    if ((count != 2 && count != 4 && count != 5) ||
        port == 0 || port > 65535 ||
        std::strlen(token) != BASALT_CONTROL_TOKEN_LENGTH) {
        return false;
    }
    settings->port = static_cast<uint16_t>(port);
    std::memcpy(settings->token, token, sizeof(settings->token));
    if (count >= 4) {
        settings->width = width;
        settings->height = height;
    }
    if (count == 5) {
        char* end = nullptr;
        const double millihertz = std::strtod(rate, &end);
        settings->invalidRefreshRate = end == rate || *end != '\0' ||
            !std::isfinite(millihertz) || millihertz < 1 || millihertz > 240'000 ||
            std::floor(millihertz) != millihertz;
        if (!settings->invalidRefreshRate) {
            settings->displayPeriod = displayPeriodFromMillihertz(millihertz);
        }
    }
    return true;
}

}  // namespace basalt

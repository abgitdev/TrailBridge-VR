#ifdef _WIN32
#include <windows.h>
#endif

#include "../pe/control_file.hpp"

#include <algorithm>
#include <cstdio>
#include <limits>
#include <string>

#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

namespace {

#ifdef _WIN32
constexpr int kIntervals = 144;
#endif

#ifdef _WIN32
double elapsedSeconds(const LARGE_INTEGER& start, const LARGE_INTEGER& end,
                      const LARGE_INTEGER& frequency) {
    return static_cast<double>(end.QuadPart - start.QuadPart) /
           static_cast<double>(frequency.QuadPart);
}

#endif

bool checkPeriodsAndControlFiles() {
    struct PeriodCase { double millihertz; int64_t expected; };
    const PeriodCase cases[] = {
        {72'000, 13'888'889}, {90'000, 11'111'111}, {120'000, 8'333'333},
        {80'000, 12'500'000}, {240'000, 4'166'667}, {1, 1'000'000'000'000},
        {0, 13'888'889}, {-1, 13'888'889}, {240'001, 13'888'889},
        {std::numeric_limits<double>::infinity(), 13'888'889},
        {std::numeric_limits<double>::quiet_NaN(), 13'888'889},
    };
    for (const auto& test : cases) {
        if (basalt::displayPeriodFromMillihertz(test.millihertz) != test.expected) {
            std::fprintf(stderr, "FAIL: display period for %g mHz\n", test.millihertz);
            return false;
        }
    }
    const std::string base = "4321 " + std::string(32, 'a');
    const std::string sized = base + " 1152 1216";
    basalt::ControlFileSettings settings;
    for (const auto& line : {base, sized}) {
        if (!basalt::parseControlFile(line.c_str(), &settings) ||
            settings.displayPeriod != 13'888'889 || settings.invalidRefreshRate) {
            std::fprintf(stderr, "FAIL: legacy control file\n");
            return false;
        }
    }
    for (const auto& test : {cases[0], cases[1], cases[2]}) {
        const auto rate = std::to_string(static_cast<int>(test.millihertz));
        for (const auto& prefix : {sized + " ", sized + std::string(128 - sized.size(), ' ')}) {
            const std::string line = prefix + rate + "\n";
            if (!basalt::parseControlFile(line.c_str(), &settings) ||
                settings.displayPeriod != test.expected || settings.invalidRefreshRate ||
                settings.width != 1152 || settings.height != 1216) {
                std::fprintf(stderr, "FAIL: negotiated control file\n");
                return false;
            }
            if (prefix.size() == 128) {
                // Exact pre-change DLL parser and read limit. This must keep
                // accepting a new streamer file without seeing a fifth field.
                const std::string legacyRead = line.substr(0, 127);
                unsigned int port = 0, width = 0, height = 0;
                char token[64]{}, extra = 0;
                if (std::sscanf(legacyRead.c_str(), "%u %63s %u %u %c",
                                &port, token, &width, &height, &extra) != 4 ||
                    port != 4321 || width != 1152 || height != 1216) {
                    std::fprintf(stderr, "FAIL: old DLL + new control file\n");
                    return false;
                }
            }
        }
    }
    for (const char* invalid : {"nan", "inf", "-inf", "0", "-1", "240001", "abc", "90000x", "0.1"}) {
        const std::string line = sized + " " + invalid;
        if (!basalt::parseControlFile(line.c_str(), &settings) ||
            settings.displayPeriod != 13'888'889 || !settings.invalidRefreshRate) {
            std::fprintf(stderr, "FAIL: invalid control-file refresh rate\n");
            return false;
        }
    }
    if (!basalt::parseControlFile((base + " 0 0 90000").c_str(), &settings) ||
        settings.width != 0 || settings.height != 0 || settings.displayPeriod != 11'111'111 ||
        basalt::parseControlFile((sized + " 90000 extra").c_str(), &settings)) {
        std::fprintf(stderr, "FAIL: optional dimensions / extra fields\n");
        return false;
    }
    std::printf("PASS: 11 period cases; legacy, negotiated, invalid and old-DLL control files\n");
    return true;
}

}  // namespace

int main() {
    if (!checkPeriodsAndControlFiles()) { return 1; }
#ifdef _WIN32
    LARGE_INTEGER frequency{};
    LARGE_INTEGER started{};
    LARGE_INTEGER ended{};
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) {
        std::fprintf(stderr, "FAIL: QueryPerformanceFrequency\n");
        return 1;
    }

    QueryPerformanceCounter(&started);
    for (int index = 0; index < kIntervals; ++index) {
        Sleep(14);
    }
    QueryPerformanceCounter(&ended);
    const double sleepSeconds = elapsedSeconds(started, ended, frequency);

    HANDLE timer = CreateWaitableTimerExW(
        nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (timer == nullptr) {
        timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
    }
    if (timer == nullptr) {
        std::fprintf(stderr, "FAIL: CreateWaitableTimer\n");
        return 1;
    }

    for (const int refreshRate : {72, 90, 120}) {
        const int64_t period = basalt::displayPeriodFromMillihertz(refreshRate * 1000);
        QueryPerformanceCounter(&started);
        for (int index = 0; index < kIntervals; ++index) {
            LARGE_INTEGER due{};
            LARGE_INTEGER now{};
            QueryPerformanceCounter(&now);
            const LONGLONG target = started.QuadPart +
                static_cast<LONGLONG>((static_cast<double>(index) + 1) *
                    static_cast<double>(period) * static_cast<double>(frequency.QuadPart) / 1e9);
            const LONGLONG remainingTicks = target - now.QuadPart;
            if (remainingTicks <= 0) {
                continue;
            }
            const LONGLONG remaining100ns =
                (remainingTicks * 10'000'000) / frequency.QuadPart;
            due.QuadPart = -std::max<LONGLONG>(1, remaining100ns);
            if (!SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE) ||
                WaitForSingleObject(timer, 1000) != WAIT_OBJECT_0) {
                CloseHandle(timer);
                std::fprintf(stderr, "FAIL: waitable timer interval\n");
                return 1;
            }
        }
        QueryPerformanceCounter(&ended);
        const double timerSeconds = elapsedSeconds(started, ended, frequency);

        const double sleepHz = static_cast<double>(kIntervals) / sleepSeconds;
        const double timerHz = static_cast<double>(kIntervals) / timerSeconds;
        std::printf("Sleep(14): %.2f Hz; absolute waitable %d Hz: %.2f Hz\n",
                    sleepHz, refreshRate, timerHz);
        if (timerHz < refreshRate * 0.94 || timerHz > refreshRate * 1.06) {
            CloseHandle(timer);
            std::fprintf(stderr, "FAIL: waitable timer did not hold the %d Hz cadence\n", refreshRate);
            return 1;
        }
    }
    CloseHandle(timer);
    std::printf("PASS: waitable timer supports 72/90/120 Hz OpenXR cadences\n");
#endif
    return 0;
}

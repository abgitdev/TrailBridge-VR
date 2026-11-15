import Foundation
import BasaltCore

/// A problem the live dashboard can explain, with a suggestion the user can
/// act on for the next session.
public struct StreamHealthIssue: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case headsetSilent
        case lowFrameRate
        case highLatency
        case thermalPressure
        case lowPowerMode
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let title: String
    public let detail: String
}

/// Turns the recent dashboard samples and Mac power state into issues,
/// most severe first. Rules look at medians of the latest reports so one
/// slow frame or a reconnect blip does not raise a warning.
public enum StreamHealthAdvisor {
    /// Latest reports per series that each rule considers.
    public static let window = 8
    /// Reports required before a rate or latency rule can fire.
    public static let minimumReports = 5
    /// Silence after which a previously reporting headset is flagged.
    public static let silenceThreshold: TimeInterval = 6

    public static func evaluate(
        samples: [StreamMetricSample],
        settings: StreamLaunchSettings,
        thermalState: ProcessInfo.ThermalState = .nominal,
        lowPowerMode: Bool = false,
        headsetDisconnected: Bool = false,
        now: Date = Date()
    ) -> [StreamHealthIssue] {
        if headsetDisconnected {
            return [StreamHealthIssue(
                kind: .headsetSilent,
                title: L10n.string(.healthDisconnectedTitle),
                detail: L10n.string(.healthDisconnectedDetail))]
        }
        var issues = [StreamHealthIssue]()
        let fpsReports = samples.filter { $0.fps != nil }

        if let last = fpsReports.last,
           now.timeIntervalSince(last.date) > silenceThreshold {
            issues.append(StreamHealthIssue(
                kind: .headsetSilent,
                title: L10n.string(.healthSilentTitle),
                detail: L10n.string(.healthSilentDetail, Int64(now.timeIntervalSince(last.date)))
                    + (settings.connection == .wired
                        ? L10n.string(.healthSilentUSB)
                        : L10n.string(.healthSilentWiFi))))
        } else if let observed = median(of: fpsReports.suffix(window).compactMap(\.fps)),
                  settings.fps > 0,
                  observed < Double(settings.fps) * StreamMetricSummary.lowFrameRateFraction {
            issues.append(StreamHealthIssue(
                kind: .lowFrameRate,
                title: L10n.string(.healthLowFramesTitle),
                detail: L10n.string(.healthLowFramesDetail, observed, Int64(settings.fps))
                    + frameRateSuggestion(for: settings)))
        }

        let latencies = samples.compactMap(\.latencyMilliseconds).suffix(window)
        if let observed = median(of: Array(latencies)),
           observed > latencyBudget(for: settings.latency) {
            let sent = median(of: Array(samples.compactMap(\.sentFPS).suffix(window)))
            issues.append(StreamHealthIssue(
                kind: .highLatency,
                title: L10n.string(.healthLatencyTitle),
                detail: L10n.string(.healthLatencyDetail, observed)
                    + latencySuggestion(for: settings, sentFPS: sent)))
        }

        if thermalState == .serious || thermalState == .critical {
            issues.append(StreamHealthIssue(
                kind: .thermalPressure,
                title: L10n.string(.healthThermalTitle),
                detail: L10n.string(.healthThermalDetail)))
        }

        if lowPowerMode {
            issues.append(StreamHealthIssue(
                kind: .lowPowerMode,
                title: L10n.string(.healthLowPowerTitle),
                detail: L10n.string(.healthLowPowerDetail)))
        }
        return issues
    }

    /// Median latency above which a preset is flagged. Measured Quest 3
    /// pipelines run about 47–58 ms (docs/STREAMER.md), so these leave room
    /// for normal variance and only catch clearly degraded sessions.
    public static func latencyBudget(for preset: StreamLatencyPreset) -> Double {
        switch preset {
        case .balanced: return 90
        case .low: return 80
        case .ultra: return 75
        }
    }

    /// Frames per second a game may fall short of the target before latency
    /// is blamed on the game rather than the link. A game that holds the
    /// target still varies by about half a frame per two-second report.
    static let gameFrameTolerance = 1.0

    private static func frameRateSuggestion(
        for settings: StreamLaunchSettings, suggestingBitrate: Bool = true
    ) -> String {
        if settings.resolution == .quality {
            return L10n.string(.healthTryBalanced)
        }
        if settings.fps > 72 {
            return L10n.string(.healthTry72)
        }
        if suggestingBitrate, settings.connection == .wifi, settings.megabits > 60 {
            return L10n.string(.healthTryBitrateOrUSB)
        }
        if settings.resolution == .balanced {
            return L10n.string(.healthTryPerformance)
        }
        return L10n.string(.healthCloseApps)
    }

    /// Input-to-display latency includes the game's own frame time. When the
    /// Mac itself sends fewer frames than the target, the game is behind and
    /// a lighter setting helps; only otherwise is the delay after the Mac.
    private static func latencySuggestion(
        for settings: StreamLaunchSettings, sentFPS: Double?
    ) -> String {
        guard settings.connection == .wifi else {
            return L10n.string(.healthTryBitrateOrResolution)
        }
        if let sentFPS, settings.fps > 0,
           sentFPS < Double(settings.fps) - gameFrameTolerance {
            return L10n.string(.healthGameLatency, sentFPS, Int64(settings.fps))
                + frameRateSuggestion(for: settings, suggestingBitrate: false)
        }
        return L10n.string(.healthWiFiLatency)
    }

    static func median(of values: [Double]) -> Double? {
        guard values.count >= minimumReports else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

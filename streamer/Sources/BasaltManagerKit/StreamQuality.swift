import Foundation
import Darwin
import BasaltCore

public enum StreamQualityPreset: String, Codable, CaseIterable, Sendable {
    case performance, balanced, quality, high, maximum, custom

    public static let presets = allCases.filter { $0 != .custom }
    public var label: String { rawValue.capitalized }
    public var codec: VideoCodec { .hevc }

    public var resolution: ResolutionSelection? {
        switch self {
        case .performance: return .performance
        case .balanced: return .balanced
        case .quality: return .quality
        case .high: return .high
        case .maximum: return .maximum
        case .custom: return nil
        }
    }

    public var megabits: Int {
        switch self {
        case .performance: return 30
        case .balanced: return 50
        case .quality: return 80
        case .high, .maximum: return 80
        case .custom: return 0
        }
    }

    public var antiAliasing: HeadsetFilterLevel {
        [.quality, .high, .maximum].contains(self) ? .quality : .off
    }

    public func matches(_ settings: StreamLaunchSettings) -> Bool {
        resolution != nil && settings.codec == codec && settings.resolution == resolution
            && settings.megabits == megabits && settings.questSupersampling == antiAliasing
            && settings.fps == 72 && settings.latency == .low && settings.questSharpening == .off
    }
}

public struct StreamQualityRecommendation: Equatable, Sendable {
    public let preset: StreamQualityPreset
    public let isTested: Bool
    public var evidence: String { isTested ? "tested" : "estimate — not tested yet" }

    /// Pure mapping. Unknown hardware conservatively uses Balanced.
    public static func recommend(brand: String, memoryBytes: UInt64) -> Self {
        let chip = brand.lowercased()
        let gb = memoryBytes / (1024 * 1024 * 1024)
        guard let range = chip.range(of: #"apple m[0-9]+"#, options: .regularExpression),
              let generation = Int(chip[range].dropFirst("apple m".count)) else {
            return Self(preset: .balanced, isTested: false)
        }
        if gb < 16 { return Self(preset: .balanced, isTested: false) }
        if generation >= 5 || chip.contains("ultra") {
            return Self(preset: .maximum, isTested: false)
        }
        if chip.contains("pro") || chip.contains("max") {
            return Self(preset: .high, isTested: false)
        }
        if generation == 4 && gb >= 24 {
            return Self(preset: .quality, isTested: true)
        }
        return Self(preset: .balanced, isTested: false)
    }

    public static func currentMac() -> Self {
        var size = 0
        var brand = ""
        if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
            var bytes = [CChar](repeating: 0, count: size)
            if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 {
                brand = String(cString: bytes)
            }
        }
        var memory: UInt64 = 0
        var memorySize = MemoryLayout<UInt64>.size
        _ = sysctlbyname("hw.memsize", &memory, &memorySize, nil, 0)
        return recommend(brand: brand, memoryBytes: memory)
    }

    public var settings: StreamLaunchSettings {
        var settings = StreamLaunchSettings()
        settings.selectQuality(preset)
        return settings
    }
}

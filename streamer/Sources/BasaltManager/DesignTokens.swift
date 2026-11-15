import SwiftUI
import AppKit

enum TB {
    private static func color(
        _ name: String, _ dark: UInt32, _ light: UInt32,
        alpha: Double = 1, lightAlpha: Double? = nil,
        hcDark: UInt32? = nil, hcLight: UInt32? = nil,
        hcDarkAlpha: Double? = nil, hcLightAlpha: Double? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("TrailBridge.\(name)")) { appearance in
            let hex: UInt32
            let opacity: Double
            switch appearance.bestMatch(from: [
                .darkAqua, .aqua, .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua
            ]) {
            case .accessibilityHighContrastDarkAqua:
                hex = hcDark ?? dark
                opacity = hcDarkAlpha ?? alpha
            case .accessibilityHighContrastAqua:
                hex = hcLight ?? light
                opacity = hcLightAlpha ?? lightAlpha ?? alpha
            case .darkAqua:
                hex = dark
                opacity = alpha
            default:
                hex = light
                opacity = lightAlpha ?? alpha
            }
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255, alpha: opacity)
        })
    }

    static let windowBackground = color("windowBackground", 0x1E1D21, 0xF5F2EE)
    static let sidebarBase = color("sidebarBase", 0x1A1618, 0xEEE8E2)
    static let sidebarEmber = color("sidebarEmber", 0x8A3A16, 0xF7C9A8)
    static let sidebarPlum = color("sidebarPlum", 0x3B2C47, 0xDCD3E6)
    static let sidebarVeil = color("sidebarVeil", 0x241F21, 0xEEE8E2, alpha: 0.80, lightAlpha: 0.70)
    static let hairline = color("hairline", 0xFFFFFF, 0x000000, alpha: 0.07, lightAlpha: 0.09,
                                hcDarkAlpha: 0.22, hcLightAlpha: 0.30)
    static let cardBackground = color("cardBackground", 0x2A292E, 0xFFFFFF)
    static let cardBorder = color("cardBorder", 0xFFFFFF, 0x000000, alpha: 0.08, lightAlpha: 0.09,
                                  hcDarkAlpha: 0.24, hcLightAlpha: 0.32)
    static let sunkenBackground = color("sunkenBackground", 0x19181B, 0xFAF8F5)
    static let settingsStripFill = color("settingsStripFill", 0xFFFFFF, 0x000000, alpha: 0.04, lightAlpha: 0.03)
    static let textPrimary = color("textPrimary", 0xF4F1EC, 0x1F1B18, hcDark: 0xFFFFFF, hcLight: 0x000000)
    static let textSecondary = color("textSecondary", 0xABA59D, 0x67605A,
                                     hcDark: 0xD0C9C0, hcLight: 0x4A443E)
    static let textTertiary = color("textTertiary", 0xDDD7CF, 0x3A3530)
    static let navText = color("navText", 0xEAE5DE, 0x2A2521)
    static let navSelectedText = color("navSelectedText", 0xFFF6EE, 0x1F1B18)
    static let iconIdle = color("iconIdle", 0xC9C1B7, 0x5C554F)
    static let selectionFill = color("selectionFill", 0xFF781F, 0xFF781F, alpha: 0.22, lightAlpha: 0.18,
                                     hcDarkAlpha: 0.34, hcLightAlpha: 0.28)
    static let quietFill = color("quietFill", 0xFFFFFF, 0x000000, alpha: 0.06, lightAlpha: 0.05,
                                 hcDarkAlpha: 0.12, hcLightAlpha: 0.10)
    static let quietBorder = color("quietBorder", 0xFFFFFF, 0x000000, alpha: 0.14,
                                   hcDarkAlpha: 0.30, hcLightAlpha: 0.40)
    static let lava = color("lava", 0xFF781F, 0xFF781F)
    static let onLava = color("onLava", 0x1A0D05, 0x1A0D05)
    static let lavaRim = color("lavaRim", 0xFFBE78, 0xFFBE78, alpha: 0.55)
    static let lavaText = color("lavaText", 0xFF8A3D, 0xB04A06, hcDark: 0xFFA060, hcLight: 0x8F3A00)
    /// Fill of system form controls (selected segment, switch, slider). The
    /// system draws white on it: 4.6:1 against white text, and at least 3:1
    /// against both card backgrounds. Plain lava gives 2.7:1.
    static let controlTint = color("controlTint", 0xCB4A0C, 0xCB4A0C)
    static let lavaGlow = color("lavaGlow", 0xFF6414, 0xFF6414, alpha: 0.28, lightAlpha: 0.18)
    static let live = color("live", 0xFF4A2B, 0xFF4A2B)
    static let onLive = color("onLive", 0x1A0905, 0x1A0905)
    static let liveText = color("liveText", 0xFF8467, 0xA82B16)
    static let liveDot = color("liveDot", 0xFF5A3C, 0xD9381E)
    static let liveCardFill = color("liveCardFill", 0xFF4A2B, 0xFF4A2B, alpha: 0.14, lightAlpha: 0.10)
    static let liveCardBorder = color("liveCardBorder", 0xFF5A3C, 0xD63C1E, alpha: 0.50, lightAlpha: 0.45)
    static let emberBorder = color("emberBorder", 0xFF6E28, 0xE0601C, alpha: 0.55, lightAlpha: 0.60)
    static let heroBackground = color("heroBackground", 0x2A1C17, 0x2A1C17)
    static let heroIdleBackground = color("heroIdleBackground", 0x232126, 0x232126)
    static let heroFailedBackground = color("heroFailedBackground", 0x2A1717, 0x2A1717)
    static let heroHills = color("heroHills", 0x4A1E10, 0x4A1E10)
    static let heroSun = color("heroSun", 0xFF8A3D, 0xFF8A3D)
    static let successText = color("successText", 0x86E5AB, 0x17703F)
    static let successFill = color("successFill", 0x4ADE80, 0x22A05A, alpha: 0.12)
    static let warningText = color("warningText", 0xFFC07A, 0x8A5000)
    static let warningFill = color("warningFill", 0xFFAA3C, 0xFFAA3C, alpha: 0.16, lightAlpha: 0.20)
    static let dangerText = color("dangerText", 0xFF8A7A, 0xB42318)
    static let dangerFill = color("dangerFill", 0xFF503C, 0xDC3228, alpha: 0.14, lightAlpha: 0.10)
    // Light value: 5.0:1 on the sidebar's ember spot, where 0xA9480A gave 3.8:1.
    static let link = color("link", 0xFFB37A, 0x8F3A00)
    static let stopFill = color("stopFill", 0xF4F1EC, 0x1F1B18)
    static let onStop = color("onStop", 0x1A1414, 0xF4F1EC)
    static let stopSquare = color("stopSquare", 0xE23A1E, 0xE23A1E)
    static let artPlaceholder = color("artPlaceholder", 0x2B2724, 0xE9E3DC)
    static let artChecker = color("artChecker", 0xFFFFFF, 0x000000, alpha: 0.04)
    static let activeShadow = color("activeShadow", 0xFF5014, 0xFF5014, alpha: 0.14)
    static let heroShadow = color("heroShadow", 0xFF5014, 0xFF5014, alpha: 0.16)

    enum Typography {
        static let heroTitle = Font.system(size: 32, weight: .heavy)
        static let metricValue = Font.system(size: 34, weight: .bold).monospacedDigit()
        static let heroTimer = Font.system(size: 20, weight: .bold).monospacedDigit()
        static let sectionTitle = Font.system(size: 17, weight: .bold)
        static let pageTitle = Font.system(size: 15, weight: .bold)
        static let cardTitle = Font.system(size: 15, weight: .bold)
        static let primaryButton = Font.system(size: 14, weight: .bold)
        static let heroButton = Font.system(size: 16, weight: .bold)
        static let panelTitle = Font.system(size: 13.5, weight: .bold)
        static let body = Font.system(size: 13)
        static let meta = Font.system(size: 12)
        static let caption = Font.system(size: 11.5)
        static let chip = Font.system(size: 11.5, weight: .medium)
        static let statusChip = Font.system(size: 11.5, weight: .semibold)
        static let groupLabel = Font.system(size: 11, weight: .semibold)

        static func navRow(selected: Bool) -> Font {
            .system(size: 13.5, weight: selected ? .semibold : .regular)
        }

        static func stateLabel(size: CGFloat) -> Font {
            .system(size: size, weight: .semibold, design: .monospaced)
        }
    }

    enum Spacing {
        static let contentHorizontal: CGFloat = 28
        static let contentVertical: CGFloat = 22
        static let streamHorizontal: CGFloat = 24
        static let streamVertical: CGFloat = 18
        static let grid: CGFloat = 20
        static let stream: CGFloat = 12
        static let cardTop: CGFloat = 12
        static let cardSides: CGFloat = 14
        static let cardInner: CGFloat = 8
        static let heroVertical: CGFloat = 18
        static let heroHorizontal: CGFloat = 22
        static let sidebarCardVertical: CGFloat = 10
        static let sidebarCardHorizontal: CGFloat = 12
        static let navHorizontal: CGFloat = 10
        static let navGap: CGFloat = 10
        static let chipHorizontal: CGFloat = 7
        static let chipVertical: CGFloat = 2
    }

    enum Radius {
        static let card: CGFloat = 14
        static let hero: CGFloat = 18
        static let sidebarCard: CGFloat = 12
        static let navRow: CGFloat = 8
        static let primaryButton: CGFloat = 9
        static let quietButton: CGFloat = 8
        static let panelButton: CGFloat = 7
        static let heroButton: CGFloat = 12
        static let chip: CGFloat = 6
        static let liveSmall: CGFloat = 4
        static let liveRegular: CGFloat = 5
    }

    enum Size {
        static let sidebarIdeal: CGFloat = 232
        static let navRow: CGFloat = 32
        static let navIcon: CGFloat = 18
        static let primaryButton: CGFloat = 34
        static let quietButton: CGFloat = 30
        static let panelButton: CGFloat = 26
        static let heroButton: CGFloat = 48
        static let iconButton: CGFloat = 34
        static let replayButton: CGFloat = 28
        static let checkerCell: CGFloat = 16
    }
}

extension Color {
    static let basaltLava = TB.lava
    static let basaltSlate = TB.cardBackground
}

extension View {
    func tbHeroTitle() -> some View {
        font(TB.Typography.heroTitle).tracking(-0.3)
    }

    func tbMetricValue() -> some View {
        font(TB.Typography.metricValue).tracking(-0.6)
    }
}

/// The app-wide light/dark choice from Settings. `system` follows macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    /// Applied to `NSApp.appearance`, so every window and menu follows it.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

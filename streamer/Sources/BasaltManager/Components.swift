import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

/// "1 game", "2 games": a count with a regular English plural.
func plural(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// Short presentation helper; AppKit callers can use L10n directly.
func L(_ key: L10nKey, _ args: CVarArg...) -> String {
    L10n.string(key, arguments: args)
}

// MARK: - Session presentation

extension SessionState {
    var tint: Color {
        switch self {
        case .stopped: return TB.textSecondary
        case .starting: return TB.warningText
        case .streaming: return TB.liveText
        case .utility: return TB.lavaText
        case .failed: return TB.dangerText
        }
    }

    var eyebrow: String {
        switch self {
        case .stopped: return L(.sessionReady)
        case .starting: return L(.sessionConnectingState)
        case .streaming: return L(.sessionLiveState)
        case .utility: return L(.sessionRunning)
        case .failed: return L(.sessionFailedState)
        }
    }

    var shortTitle: String {
        switch self {
        case .stopped: return L(.sessionIdle)
        case .starting: return L(.sessionConnecting)
        case .streaming: return L(.sessionStreaming)
        case .utility: return L(.sessionWindowsRunning)
        case .failed: return L(.sessionFailed)
        }
    }

    var shortDetail: String {
        switch self {
        case .stopped: return L(.sessionNotRunning)
        case .starting: return L(.sessionPreparing)
        case .streaming(let profile): return profile
        case .utility(let name): return name
        case .failed(let message): return message
        }
    }
}

extension StreamConnectionMode {
    var shortLabel: String { self == .wired ? L(.connectionUSB) : L(.connectionWiFi) }
    var symbol: String { self == .wired ? "cable.connector" : "wifi" }
}

extension StreamLatencyPreset {
    var title: String {
        switch self {
        case .balanced: return L(.latencyBalanced)
        case .low: return L(.latencyLow)
        case .ultra: return L(.latencyUltra)
        }
    }
}

// MARK: - Surfaces

struct CardStyle: ViewModifier {
    var padding: CGFloat
    var cornerRadius: CGFloat = TB.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(TB.cardBackground, in: shape)
            .overlay(shape.strokeBorder(TB.cardBorder))
    }
}

extension View {
    /// Confirms clearing Recent Sessions; shared by Stream and Settings.
    func clearSessionHistoryDialog(
        isPresented: Binding<Bool>, model: BasaltAppModel
    ) -> some View {
        confirmationDialog(L(.historyClearQuestion), isPresented: isPresented) {
            Button(L(.historyClear), role: .destructive) { model.clearSessionHistory() }
        } message: {
            Text(L(.historyClearDetail))
        }
    }

    func cardStyle(padding: CGFloat = 16, cornerRadius: CGFloat = TB.Radius.card) -> some View {
        modifier(CardStyle(padding: padding, cornerRadius: cornerRadius))
    }

    /// Grouped-form footers otherwise inherit the primary label color and
    /// trailing alignment on recent macOS releases.
    func formFooterStyle() -> some View {
        font(.footnote)
            .foregroundStyle(TB.textSecondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Chip: View {
    enum Kind {
        case neutral, success, unverified, progress, warning, failed, live

        static var verified: Self { .success }

        fileprivate static func legacy(text: String, tint: Color) -> Self {
            if text == "LIVE" { return .live }
            if tint == .green || tint == TB.successText { return .success }
            if tint == .red || tint == TB.dangerText { return .failed }
            if tint == .orange || tint == .yellow || tint == TB.warningText { return .warning }
            return .neutral
        }

        fileprivate var foreground: Color {
            switch self {
            case .neutral: return TB.textTertiary
            case .success: return TB.successText
            case .unverified: return TB.textSecondary
            case .progress, .warning: return TB.warningText
            case .failed: return TB.dangerText
            case .live: return TB.onLive
            }
        }

        fileprivate var fill: Color {
            switch self {
            case .neutral: return TB.quietFill
            case .success: return TB.successFill
            case .unverified: return .clear
            case .progress, .warning: return TB.warningFill
            case .failed: return TB.dangerFill
            case .live: return TB.live
            }
        }
    }

    let text: String
    var systemImage: String?
    var tint: Color = .secondary
    var kind: Kind?

    var body: some View {
        let kind = kind ?? .legacy(text: text, tint: tint)
        if kind == .live {
            LiveBadge()
        } else {
            HStack(spacing: 4) {
                if kind == .success {
                    PixelIcon(glyph: .check, size: 8, color: kind.foreground)
                } else if kind == .progress {
                    PixelIcon(glyph: .dot, size: 6, color: kind.foreground).tbBlink()
                } else if kind == .neutral, let systemImage {
                    Image(systemName: systemImage).imageScale(.small).accessibilityHidden(true)
                }
                Text(text).lineLimit(1).help(text)
            }
            .font(kind == .neutral ? TB.Typography.chip : TB.Typography.statusChip)
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, TB.Spacing.chipHorizontal)
            .padding(.vertical, TB.Spacing.chipVertical)
            .background(kind.fill, in: RoundedRectangle(cornerRadius: TB.Radius.chip))
            .overlay {
                if kind == .unverified {
                    RoundedRectangle(cornerRadius: TB.Radius.chip)
                        .strokeBorder(TB.textSecondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
            }
        }
    }
}

/// An opaque backing keeps semantic chip colors legible over arbitrary artwork.
struct ArtworkChip: View {
    let text: String
    var systemImage: String?
    var tint: Color = TB.textTertiary
    var kind: Chip.Kind?

    var body: some View {
        if (kind ?? .legacy(text: text, tint: tint)) == .live {
            LiveBadge()
        } else {
            Chip(text: text, systemImage: systemImage, tint: tint, kind: kind)
                .background(TB.cardBackground, in: RoundedRectangle(cornerRadius: TB.Radius.chip))
        }
    }
}

struct CountBadge: View {
    let count: Int
    var selected = false

    var body: some View {
        Text(count.formatted(.number.locale(L10n.language.locale)))
            .font(TB.Typography.statusChip.monospacedDigit())
            .foregroundStyle(selected ? TB.navSelectedText : TB.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(selected ? TB.quietBorder : TB.quietFill, in: Capsule())
    }
}

/// Marks the Diagnostics sidebar row while any game records. The row reads
/// the reason as its accessibility value.
struct RecordingBadge: View {
    var body: some View {
        PixelIcon(glyph: .dot, size: 6, color: TB.warningText)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(TB.warningFill, in: Capsule())
    }
}

struct LiveBadge: View {
    var small = false

    var body: some View {
        HStack(spacing: 4) {
            PixelIcon(glyph: .dot, size: small ? 6 : 8, color: TB.onLive).tbBlink()
            StateLabel(L(.chipLive))
        }
        .foregroundStyle(TB.onLive)
        .padding(.horizontal, small ? 6 : 8)
        .padding(.vertical, small ? 1 : 3)
        .background(TB.live, in: RoundedRectangle(cornerRadius: small ? TB.Radius.liveSmall : TB.Radius.liveRegular))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(.sessionStreaming))
    }
}

struct StateLabel: View {
    let text: String
    var size: CGFloat

    init(_ text: String, size: CGFloat = 11) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text.uppercased(with: L10n.language.locale))
            .font(TB.Typography.stateLabel(size: size))
            .tracking(size * 0.06)
    }
}

struct SymbolTile: View {
    let symbol: String
    var tint: Color = .basaltLava
    var size: CGFloat = 32

    private var tokenTint: Color {
        if tint == .green || tint == TB.successText { return TB.successText }
        if tint == .red || tint == TB.dangerText { return TB.dangerText }
        if tint == .yellow || tint == .orange || tint == TB.warningText { return TB.warningText }
        if tint == .secondary || tint == TB.iconIdle { return TB.iconIdle }
        return TB.lavaText
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tokenTint)
            .frame(width: size, height: size)
            .background(TB.quietFill,
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        PixelIcon(glyph: .dot, size: 8, color: color).tbBlink(pulsing)
    }
}

private struct TBGlassCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let tint: Color
    let fill: Color
    let border: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(TB.cardBackground).overlay(shape.fill(fill))
                } else if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular.tint(tint.opacity(0.25)), in: shape)
                } else {
                    shape.fill(TB.cardBackground).overlay(shape.fill(fill))
                }
            }
            .overlay(shape.strokeBorder(border, lineWidth: contrast == .increased ? 2 : 1))
    }
}

extension View {
    func tbGlassCard(
        tint: Color = .clear, fill: Color = TB.cardBackground,
        border: Color = TB.cardBorder, cornerRadius: CGFloat = TB.Radius.card
    ) -> some View {
        modifier(TBGlassCard(tint: tint, fill: fill, border: border, cornerRadius: cornerRadius))
    }
}

struct TBPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var emphasized = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TB.Typography.primaryButton)
            .foregroundStyle(TB.onLava)
            .padding(.horizontal, 14)
            .frame(height: TB.Size.primaryButton)
            .background(TB.lava, in: RoundedRectangle(cornerRadius: TB.Radius.primaryButton))
            .overlay(RoundedRectangle(cornerRadius: TB.Radius.primaryButton).strokeBorder(TB.lavaRim))
            .shadow(color: emphasized ? TB.lavaGlow : .clear, radius: 7, y: 4)
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.85 : 1)
    }
}

struct TBHeroPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TB.Typography.heroButton)
            .foregroundStyle(TB.onLava)
            .padding(.horizontal, 22)
            .frame(height: TB.Size.heroButton)
            .background(TB.lava, in: RoundedRectangle(cornerRadius: TB.Radius.heroButton))
            .overlay(RoundedRectangle(cornerRadius: TB.Radius.heroButton).strokeBorder(TB.lavaRim))
            .shadow(color: TB.lavaGlow, radius: 7, y: 4)
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.85 : 1)
    }
}

struct TBReplayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: TB.Size.replayButton, height: TB.Size.replayButton)
            .background(TB.lava.opacity(0.16), in: RoundedRectangle(cornerRadius: TB.Radius.quietButton))
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
    }
}

struct TBQuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let radius = compact ? TB.Radius.panelButton : TB.Radius.quietButton
        configuration.label
            .font(TB.Typography.body)
            .foregroundStyle(TB.textPrimary)
            .padding(.horizontal, compact ? 10 : 12)
            .frame(height: compact ? TB.Size.panelButton : TB.Size.quietButton)
            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(TB.quietBorder))
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
    }
}

/// A small bordered button with `Chip` metrics, so it lines up with chips in one row.
struct TBChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: TB.Radius.chip)
        configuration.label
            .font(TB.Typography.statusChip)
            .foregroundStyle(TB.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, TB.Spacing.chipHorizontal + 1)
            .padding(.vertical, TB.Spacing.chipVertical)
            .background(TB.quietFill, in: shape)
            .overlay(shape.strokeBorder(TB.quietBorder))
            .contentShape(shape)
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
    }
}

struct TBOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TB.Typography.body.weight(.semibold))
            .foregroundStyle(TB.lavaText)
            .padding(.horizontal, 12)
            .frame(height: TB.Size.quietButton)
            .overlay(RoundedRectangle(cornerRadius: TB.Radius.quietButton).strokeBorder(TB.emberBorder))
            .contentShape(RoundedRectangle(cornerRadius: TB.Radius.quietButton))
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
    }
}

struct TBHeroStopButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: compact ? 8 : 10) {
            Rectangle().fill(TB.stopSquare)
                .frame(width: compact ? 8 : 12, height: compact ? 8 : 12).accessibilityHidden(true)
            configuration.label.labelStyle(.titleOnly)
        }
        .font(compact ? TB.Typography.primaryButton : TB.Typography.heroButton)
        .foregroundStyle(TB.onStop)
        .padding(.horizontal, compact ? 14 : 22)
        .frame(height: compact ? TB.Size.primaryButton : TB.Size.heroButton)
        .background(TB.stopFill, in: RoundedRectangle(cornerRadius: compact ? TB.Radius.primaryButton : TB.Radius.heroButton))
        .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.85 : 1)
    }
}

struct TBIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let accessibilityLabel: String
    var compact = false
    var foreground: Color = TB.lavaText

    func makeBody(configuration: Configuration) -> some View {
        let size = compact ? TB.Size.replayButton : TB.Size.iconButton
        let radius = compact ? TB.Radius.quietButton : TB.Radius.primaryButton
        configuration.label
            .labelStyle(.iconOnly)
            .font(TB.Typography.body.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(TB.quietBorder))
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
            .accessibilityLabel(accessibilityLabel)
    }
}

/// Keep work visible without motion when the system requests it.
struct TBProgressIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var text: String? = nil

    init(_ text: String? = nil) { self.text = text }

    var body: some View {
        HStack(spacing: 8) {
            if reduceMotion {
                PixelIcon(glyph: .dot, size: 8, color: TB.warningText)
            } else {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
            if let text { Text(text) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? L(.commonWorking))
    }
}

struct ProgressRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let progress: Double
    var tint: Color = .basaltLava
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: progress)
    }
}

/// The environments or game profiles whose file cannot be read: what they
/// are called, why they cannot be used, and a way to remove each.
struct DamagedItemsSection: View {
    enum Kind { case environments, games }

    let kind: Kind
    let items: [DamagedItem]
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(L(kind == .environments ? .damagedEnvironmentsTitle : .damagedGamesTitle),
                         count: items.count)
            Text(L(kind == .environments ? .damagedEnvironmentNote : .damagedGameNote))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(items) { item in
                    if item.id != items.first?.id { TBRowDivider() }
                    DamagedItemRow(item: item, kind: kind, model: model)
                }
            }
            .cardStyle(padding: 0)
        }
    }
}

private struct DamagedItemRow: View {
    let item: DamagedItem
    let kind: DamagedItemsSection.Kind
    @ObservedObject var model: BasaltAppModel
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                PixelIcon(glyph: .warning, size: 18, color: TB.warningText).accessibilityHidden(true)
                Text(item.name).font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2).help(item.name)
                Chip(text: L(.damagedChip), kind: .warning)
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([item.file])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(TBIconButtonStyle(accessibilityLabel: L(.libraryShowInFinder), compact: true))
                .help(L(.libraryShowInFinder))
                Button(L(.damagedRemove), role: .destructive) { confirmingRemoval = true }
                    .buttonStyle(TBQuietButtonStyle(compact: true))
                    .disabled(model.sessionState.isActive || model.isBusy || model.isImportingGameFolder)
            }
            DisclosureGroup(L(.commonDetails)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.reason.detail).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    PathText(path: item.file.path)
                }
                .padding(.top, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .confirmationDialog(L(.damagedRemoveQuestion, item.name), isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button(L(.damagedRemoveConfirm), role: .destructive) {
                Task { await model.removeDamaged(item) }
            }
            Button(L(.commonCancel), role: .cancel) {}
        } message: {
            Text(L(kind == .environments ? .damagedRemoveEnvironmentWarning : .damagedRemoveGameWarning))
        }
    }
}

/// A home-relative, middle-truncated path that still exposes the full value.
struct PathText: View {
    let path: String

    var body: some View {
        Text((path as NSString).abbreviatingWithTildeInPath)
            .font(.caption.monospaced())
            // A token, not `.secondary`: inside a secondary-styled parent the
            // hierarchical style would halve the opacity again.
            .foregroundStyle(TB.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(path)
    }
}

struct SectionTitle<Accessory: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        let countText: String? = count.map { $0.formatted(.number.locale(L10n.language.locale)) }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(TB.Typography.sectionTitle).foregroundStyle(TB.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(countText ?? "")
            if let countText {
                // Read as the heading's value above.
                Text(countText)
                    .font(TB.Typography.body.monospacedDigit())
                    .foregroundStyle(TB.textSecondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 12)
            accessory
        }
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(_ title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Shared sheet chrome: an icon header, scrollable form content, and a
/// bottom action bar.
struct SheetScaffold<Content: View, Actions: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var tint: Color = .basaltLava
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    private var sectionGlyph: PixelGlyph? {
        switch symbol {
        case "gamecontroller", "plus.app", "doc.text": .library
        case "shippingbox", "square.on.square": .bottles
        case "slider.horizontal.3", "gearshape": .settings
        case "checklist": .setup
        case "visionpro": .headset
        case "antenna.radiowaves.left.and.right": .stream
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    if let sectionGlyph {
                        PixelIcon(glyph: sectionGlyph, size: 24, color: TB.lavaText)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(TB.lavaText)
                    }
                }
                .frame(width: 38, height: 38)
                .background(TB.lava.opacity(0.16), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(TB.Typography.cardTitle)
                        .lineLimit(2).help(title)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(TB.textSecondary)
                            .lineLimit(2).help(subtitle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            TBRowDivider()

            content.frame(maxWidth: .infinity, maxHeight: .infinity)

            TBRowDivider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                FlowLayout(spacing: 10, lineSpacing: 8) { actions }
            }
            .buttonStyle(TBQuietButtonStyle())
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(TB.Typography.body)
        .foregroundStyle(TB.textPrimary)
        .tint(TB.controlTint)
        .background(TB.windowBackground)
        // Sheets are hosted in their own windows; repeat the root's Reduce Motion rule.
        .tbReducedMotion()
    }
}

/// Wraps children onto new lines when they no longer fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, maxWidth), height: nil))
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: widest, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, maxWidth), height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Pages beside a scroll bar

/// Lays a page's scroll content out at the width left beside a scroll bar's
/// strip, whether the bar is shown or not. A page that follows the bar has
/// one height with it and another without: a grid fits one more column, or
/// its tiles grow with their width, and the page is taller without the bar.
/// A window between those two heights shows and hides the bar without end,
/// and AppKit ends the app for a layout that never settles.
private struct LegacyScrollerLayout: ViewModifier {
    /// The scroll view's own width, measured outside it.
    let width: CGFloat
    @State private var scrollerStrip = LegacyScrollerLayout.legacyScrollerWidth

    /// What a scroll bar that takes its own strip (a mouse, or "Show scroll
    /// bars: Always") cuts off the page's width; nothing for overlay bars.
    private static var legacyScrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    func body(content: Content) -> some View {
        content
            .frame(width: max(0, width - scrollerStrip))
            .frame(maxWidth: .infinity, alignment: .leading)
            .onReceive(NotificationCenter.default.publisher(
                for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
                scrollerStrip = Self.legacyScrollerWidth
            }
    }
}

extension View {
    /// For the content of a vertical `ScrollView` whose height depends on its
    /// width. `width` is the scroll view's width from a `GeometryReader`
    /// around it, which the scroll bar does not change.
    func layoutBesideLegacyScroller(width: CGFloat) -> some View {
        modifier(LegacyScrollerLayout(width: width))
    }
}

// MARK: - Management pages

/// Shared readable column for Steam, environments and headset setup.
struct TBManagementPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TB.Spacing.contentVertical) { content }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, TB.Spacing.contentHorizontal)
                .padding(.vertical, TB.Spacing.contentVertical)
        }
        .font(TB.Typography.body)
        .foregroundStyle(TB.textPrimary)
        .background(TB.windowBackground)
    }
}

struct TBRowDivider: View {
    var body: some View {
        Rectangle().fill(TB.hairline).frame(height: 1).accessibilityHidden(true)
    }
}

struct TBPixelTile: View {
    let glyph: PixelGlyph
    var color: Color = TB.lavaText
    var size: CGFloat = 40

    var body: some View {
        PixelIcon(glyph: glyph, size: 24, color: color)
            .frame(width: size, height: size)
            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }
}

struct TBArtworkThumbnail: View {
    let url: URL?
    var glyph: PixelGlyph = .bottles
    /// A game executable whose icon stands in when there is no artwork.
    var iconExecutable: URL?

    var body: some View {
        ZStack {
            TB.artPlaceholder
            if let url {
                ArtworkImage(url: url).id(url)
            } else if let iconExecutable {
                ExecutableIconArt(executable: iconExecutable, inset: 4) {
                    PixelIcon(glyph: glyph, size: 24, color: TB.textSecondary)
                }
                .id(iconExecutable)
            } else {
                Path { path in
                    let cell = TB.Size.checkerCell
                    for row in 0..<3 {
                        for column in 0..<6 where (row + column).isMultiple(of: 2) {
                            path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                                width: cell, height: cell))
                        }
                    }
                }
                .fill(TB.artChecker, style: FillStyle(antialiased: false))
                PixelIcon(glyph: glyph, size: 24, color: TB.textSecondary)
            }
        }
        .frame(width: 92, height: 43)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Clipping hides a poster-shaped cover that fills this frame; it
        // would still catch the mouse outside the thumbnail without this.
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
}

/// Icons read from game executables, kept in memory for the app's lifetime.
/// A file without a usable icon is remembered too, so it is parsed once.
private enum ExecutableIconCache {
    /// Immutable after creation, so handing it across actors is safe.
    final class Entry: @unchecked Sendable {
        let image: NSImage?
        let backing: IconBacking?
        init(image: NSImage?, backing: IconBacking?) {
            self.image = image
            self.backing = backing
        }
    }

    static let entries = NSCache<NSString, Entry>()

    static func load(_ executable: URL) -> Entry {
        let data = ExecutableIcon.imageData(fromExecutableAt: executable)
        guard let data, let image = NSImage(data: data) else {
            return Entry(image: nil, backing: nil)
        }
        return Entry(image: image, backing: ExecutableIcon.backing(forImageData: data))
    }
}

/// The icon inside a Windows game's executable, centred on the usual art
/// background. An icon that could vanish into it sits on a rounded plate, as
/// an app icon would: light behind dark icons, dark behind light ones, so it
/// shows in either theme. Shows `placeholder` until the icon loads, or if
/// there is none.
struct ExecutableIconArt<Placeholder: View>: View {
    let executable: URL
    var inset: CGFloat = 10
    let placeholder: Placeholder
    @State private var entry: ExecutableIconCache.Entry?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Fixed, not themed: the plate answers the icon, not the window.
    private static var lightPlate: Color { Color(red: 0.914, green: 0.890, blue: 0.863) }
    private static var darkPlate: Color { Color(red: 0.169, green: 0.153, blue: 0.141) }

    init(executable: URL, inset: CGFloat = 10,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.executable = executable
        self.inset = inset
        self.placeholder = placeholder()
        _entry = State(initialValue: ExecutableIconCache.entries.object(
            forKey: executable.path as NSString))
    }

    var body: some View {
        ZStack {
            if let image = entry?.image {
                TB.artPlaceholder
                GeometryReader { geometry in
                    let side = max(0, min(geometry.size.width, geometry.size.height) - 2 * inset)
                    let plate: Color? = switch entry?.backing {
                    case .light: Self.lightPlate
                    case .dark: Self.darkPlate
                    case nil: nil
                    }
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(plate == nil ? 0 : side * 0.08)
                        .frame(width: side, height: side)
                        .background {
                            if let plate {
                                RoundedRectangle(cornerRadius: side * 0.2, style: .continuous)
                                    .fill(plate)
                            }
                        }
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
                .transition(reduceMotion ? .identity : .opacity)
            } else {
                placeholder
            }
        }
        .task {
            guard entry == nil else { return }
            let executable = executable
            let loaded = await Task.detached(priority: .utility) {
                ExecutableIconCache.load(executable)
            }.value
            ExecutableIconCache.entries.setObject(loaded, forKey: executable.path as NSString)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { entry = loaded }
        }
    }
}

/// A short sheet that fits the minimum window; long instructions scroll.
struct TBManagementSheet<Content: View, Actions: View>: View {
    let glyph: PixelGlyph
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TBPixelTile(glyph: glyph)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(TB.Typography.sectionTitle)
                        .lineLimit(2).help(title).accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                            .lineLimit(2).help(subtitle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            TBRowDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            TBRowDivider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                FlowLayout(spacing: 10, lineSpacing: 8) { actions }
            }
            .buttonStyle(TBQuietButtonStyle())
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .font(TB.Typography.body)
        .foregroundStyle(TB.textPrimary)
        .background(TB.windowBackground)
        .tbReducedMotion()
    }
}

private struct TBReducedMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
    }
}

extension View {
    func tbReducedMotion() -> some View { modifier(TBReducedMotion()) }
}

// MARK: - File panels

@MainActor
enum FilePanels {
    static func chooseFile(
        title: String, message: String? = nil, extensions: [String],
        startingAt directory: URL? = nil
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.allowedContentTypes = extensions.compactMap {
            UTType(filenameExtension: $0)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(
        title: String, message: String? = nil, startingAt directory: URL? = nil,
        canCreate: Bool = false
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let message { panel.message = message }
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Asks where to save an export. `baseName` gets a local timestamp and
    /// `fileExtension`, e.g. "BasaltVR-session-2026-10-09-2130.log".
    static func saveFile(title: String, baseName: String, fileExtension: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        panel.nameFieldStringValue = "\(baseName)-\(stamp.string(from: Date())).\(fileExtension)"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Grouped settings forms

extension View {
    func tbFormFooterStyle() -> some View {
        font(TB.Typography.meta)
            .foregroundStyle(TB.textSecondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Native grouped forms keep their scrolling and control semantics.
    func tbGroupedForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .font(TB.Typography.body)
            .foregroundStyle(TB.textPrimary)
            .tint(TB.controlTint)
            .background(TB.windowBackground)
    }
}

/// Opaque backing plus a hairline makes a form header read like other cards.
struct TBFormHeader<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 14)
    }
}

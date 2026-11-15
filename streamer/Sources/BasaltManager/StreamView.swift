import SwiftUI
import AppKit
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

extension BasaltAppModel {
    /// Profiles whose bottle has both the DXMT handoff and OpenXR runtime.
    var launchableProfiles: [LaunchProfile] {
        profiles.filter { profile in
            bottles.contains {
                $0.name == profile.bottleName && $0.isReadyForVR
            }
        }
    }

    /// The profile Play launches: the preferred one while it is launchable,
    /// otherwise the first launchable profile.
    var selectedLaunchProfileName: String? {
        let launchable = launchableProfiles
        if let preferredProfileName,
           launchable.contains(where: { $0.name == preferredProfileName }) {
            return preferredProfileName
        }
        return launchable.first?.name
    }

    /// The session's profile, or the profile Play launches.
    var displayedProfileName: String? {
        sessionState.profileName ?? selectedLaunchProfileName
    }

    var displayedStreamSettings: StreamLaunchSettings {
        displayedProfileName.map(streamSettings(for:)) ?? settings
    }
}

struct StreamDashboardView: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 2 * TB.Spacing.streamHorizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: TB.Spacing.stream) {
                    SessionHero(model: model)
                    SessionSettingsCard(model: model)
                    RecordingReminder(model: model)

                    if let message = model.steamUpdateMessage {
                        HStack(spacing: 12) {
                            TBProgressIndicator().controlSize(.small)
                            Text(message).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(L(.streamStartAnyway)) { model.startDespiteSteamUpdate = true }
                                .buttonStyle(TBQuietButtonStyle())
                                .fixedSize()
                        }
                        .streamWarningStyle()
                    }

                    StreamHealthBanner(model: model, console: model.console)
                    MetricTiles(console: model.console, settings: model.displayedStreamSettings)

                    if contentWidth >= 760 {
                        HStack(alignment: .top, spacing: TB.Spacing.stream) {
                            SessionLogCard(model: model, console: model.console)
                                .frame(width: (contentWidth - TB.Spacing.stream) * 1.1 / 2.1)
                            RecentSessionsCard(model: model)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        SessionLogCard(model: model, console: model.console)
                        RecentSessionsCard(model: model)
                    }
                }
                .padding(.vertical, TB.Spacing.streamVertical)
                .padding(.horizontal, TB.Spacing.streamHorizontal)
                // The metric tiles fit one more column without the scroll bar.
                .layoutBesideLegacyScroller(width: geometry.size.width)
            }
            .tourScrollsToTarget(on: .stream)
        }
        .background(TB.windowBackground)
        .foregroundStyle(TB.textPrimary)
        .navigationTitle(L(.sidebarStream))
        .navigationSubtitle(model.sessionState.shortTitle)
    }
}

// MARK: - Session hero

private struct SessionHero: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.learning) private var learning

    private var state: SessionState { model.sessionState }
    private var launchable: [LaunchProfile] { model.launchableProfiles }
    private var selectedProfile: String? { model.selectedLaunchProfileName }

    private var stateColor: Color {
        switch state {
        case .stopped, .utility: TB.lavaText
        case .starting: TB.warningText
        case .streaming: TB.liveText
        case .failed: TB.dangerText
        }
    }

    private var background: Color {
        switch state {
        case .starting, .streaming: TB.heroBackground
        case .stopped, .utility: TB.heroIdleBackground
        case .failed: TB.heroFailedBackground
        }
    }

    private var hasEmberBorder: Bool {
        switch state {
        case .starting, .streaming: true
        case .stopped, .utility, .failed: false
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TB.Radius.hero, style: .continuous)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                heroText.frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                primaryControls.fixedSize()
            }
            VStack(alignment: .leading, spacing: 16) {
                heroText
                primaryControls
            }
        }
        .id(state.eyebrow)
        .transition(reduceMotion ? .identity : .opacity)
        .padding(.vertical, TB.Spacing.heroVertical)
        .padding(.horizontal, TB.Spacing.heroHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { background.overlay(alignment: .bottomTrailing) { HeroSunset() } }
        .clipShape(shape)
        .overlay(shape.strokeBorder(hasEmberBorder ? TB.emberBorder : TB.cardBorder,
                                    lineWidth: contrast == .increased ? 2 : 1))
        .overlay {
            if state.isStreaming {
                shape.stroke(TB.lava.opacity(0.08), lineWidth: 4).padding(-2)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: state.isStreaming ? TB.heroShadow : .clear, radius: 20, y: 10)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state)
        // Deliberate: the hero is dark in both themes, so the TB tokens inside
        // it (text, chips, Stop) must resolve their dark-theme values.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L(.streamHeroLabel))
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                // The dot and the label together are what a learning step
                // calls the state; same spacing as the row around them.
                HStack(spacing: 8) {
                    PixelIcon(glyph: .dot, size: 12,
                              color: state.isStreaming ? TB.liveDot : stateColor)
                        .tbBlink(state.isActive)
                    StateLabel(state.eyebrow, size: 20)
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                        .help(state.eyebrow)
                }
                .tourTarget(.streamStatus)
                if state.isStreaming {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(at: context.date))
                            .font(TB.Typography.heroTimer)
                            .foregroundStyle(TB.textPrimary)
                            // Polled when focused instead of announced every second.
                            .accessibilityAddTraits(.updatesFrequently)
                            .accessibilityLabel(L(.streamTimerLabel))
                            .accessibilityValue(elapsed(at: context.date))
                    }
                    .fixedSize()
                    .padding(.leading, 6)
                }
            }
            Text(title)
                .tbHeroTitle()
                .foregroundStyle(TB.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
                .accessibilityAddTraits(.isHeader)
            Group {
                if case .starting = state {
                    LatestLogLine(console: model.console)
                } else {
                    Text(subtitle).help(subtitle)
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(TB.textTertiary)
            .lineLimit(3)
            .textSelection(.enabled)
            if let learning {
                if case .failed(let message) = state {
                    HowToFixButton(learning: learning, message: message)
                } else if state.isStreaming {
                    CantSeeGameLink(learning: learning, liveSessionStart: model.streamingStartedAt)
                } else if state == .stopped {
                    ReturnReminderLine(
                        learning: learning,
                        playOffered: !launchable.isEmpty && !model.isImportingGameFolder)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func elapsed(at date: Date) -> String {
        guard let start = model.streamingStartedAt else { return L(.streamNoValue) }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return L(.sessionElapsed, Int64(seconds / 3600), Int64(seconds / 60 % 60), Int64(seconds % 60))
    }

    private var title: String {
        switch state {
        case .stopped: launchable.isEmpty ? L(.streamNoGames) : L(.streamReady)
        case .starting(let profile), .streaming(let profile): profile
        case .utility(let name): name
        case .failed: L(.sessionFailed)
        }
    }

    private var subtitle: String {
        switch state {
        case .stopped: launchable.isEmpty ? L(.streamNoGamesDetail) : L(.streamReadyDetail)
        case .starting: L(.streamPreparing)
        case .streaming:
            model.displayedStreamSettings.connection == .wired ? L(.streamOverUSB) : L(.streamOverWiFi)
        case .utility: L(.streamUtilityDetail)
        case .failed(let message): message
        }
    }

    @ViewBuilder private var primaryControls: some View {
        if state.isActive {
            HStack(spacing: 10) {
                if case .starting = state {
                    TBProgressIndicator().controlSize(.small).accessibilityLabel(L(.sessionConnecting))
                }
                Button(L(.commonStop), role: .destructive) { model.stop() }
                    .buttonStyle(TBHeroStopButtonStyle())
                    .help(L(.streamStopHelp))
            }
        } else if launchable.isEmpty {
            Button { model.selection = .library } label: {
                HStack(spacing: 10) {
                    PixelIcon(glyph: .library, size: 18, color: TB.onLava)
                    Text(L(.streamOpenLibrary))
                }
            }
            .buttonStyle(TBHeroPrimaryButtonStyle())
        } else {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(.streamGame))
                        .font(.system(size: 11))
                        .foregroundStyle(TB.textTertiary)
                        .accessibilityHidden(true) // the picker below carries the same name
                    Picker(L(.streamGame), selection: Binding(
                        get: { selectedProfile ?? "" },
                        set: { model.preferredProfileName = $0 })) {
                        ForEach(launchable, id: \.name) { profile in
                            Text(model.gameTitle(forProfile: profile.name)).tag(profile.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200, height: 34)
                    .controlSize(.large)
                    .help(selectedProfile.map(model.gameTitle(forProfile:)) ?? L(.streamGame))
                }
                Button {
                    guard let selectedProfile else { return }
                    Task { await model.launch(profileName: selectedProfile) }
                } label: {
                    HStack(spacing: 10) {
                        PixelIcon(glyph: .play, size: 12, color: TB.onLava)
                        Text(L(.libraryPlay))
                    }
                }
                .buttonStyle(TBHeroPrimaryButtonStyle())
                .disabled(model.isImportingGameFolder)
                .tourTarget(.streamPlay, onAccent: true)
            }
        }
    }
}

/// "How to fix" under a launch failure Learning knows. Hidden while the quick
/// path's own strip shows that advice: the button would do nothing then.
/// Observes the controller here, so the hero itself does not depend on it.
private struct HowToFixButton: View {
    @ObservedObject var learning: LearningController
    let message: String

    var body: some View {
        if !learning.tourShowsFailure, let advice = learning.advice(for: message) {
            Button(L(.learningHowToFix)) { learning.showAdvice(advice) }
                .buttonStyle(TBQuietButtonStyle(compact: true))
                .tourTarget(.topic(.streamHowToFix))
                .padding(.top, 6)
        }
    }
}

/// After a long break, one line where Play is: "Been a while? I'll show how
/// to start VR". Used or closed, it stays away until the next such break.
/// Observes the controller here, so the hero itself does not depend on it.
private struct ReturnReminderLine: View {
    @ObservedObject var learning: LearningController
    let playOffered: Bool

    var body: some View {
        if learning.returnReminderDue(playOffered: playOffered) {
            HStack(spacing: 8) {
                Text(LearningReturnReminder.text)
                    .foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(LearningReturnReminder.showTitle) { learning.useReturnReminder() }
                    .buttonStyle(TBQuietButtonStyle(compact: true))
                Button { learning.dismissReturnReminder() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TB.textSecondary)
                .help(LearningReturnReminder.closeTitle)
                .accessibilityLabel(LearningReturnReminder.closeTitle)
            }
            .font(.system(size: 13))
            .padding(.top, 6)
        }
    }
}

/// After the quick path completes: "Can't see the game?" with the same tips,
/// for the rest of that session. A plain button with fixed text: it starts no
/// timer and watches neither the session nor its samples, and it goes when
/// the hero leaves the live state.
private struct CantSeeGameLink: View {
    @ObservedObject var learning: LearningController
    let liveSessionStart: Date?

    var body: some View {
        if QuickPathFollowUp.showsCantSeeGame(
            completedSessionStart: learning.completedSessionStart, liveSessionStart: liveSessionStart) {
            let help = QuickPathHelp.cantSeeGame()
            TourHelpButton(title: help.title, help: TourHint.Help(tips: help.tips), compact: true)
                .padding(.top, 6)
        }
    }
}

/// While connecting, observe the console here rather than refreshing the hero.
private struct LatestLogLine: View {
    @ObservedObject var console: SessionConsole

    var body: some View {
        let line = console.latestLine ?? L(.streamPreparing)
        Text(line).help(line).accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Effective launch settings

private struct SessionSettingsCard: View {
    @ObservedObject var model: BasaltAppModel
    @State private var editingProfileSettings: ProfileSettingsSelection?
    @State private var showingTechnicalDetails = false

    private var settings: StreamLaunchSettings { model.displayedStreamSettings }
    private var active: Bool { model.sessionState.isActive }
    private var hasOverride: Bool {
        model.displayedProfileName.map { model.profileSettings[$0] != nil } ?? false
    }
    private var title: String { active ? L(.streamSessionSettings) : L(.streamNextSettings) }
    private var scopeHelp: String { hasOverride ? L(.streamPerGameHelp) : L(.streamGlobalHelp) }
    private var footer: String { active ? L(.streamChangesNextLaunch) : L(.streamUsedNextLaunch) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    headerLabels.fixedSize()
                    Spacer(minLength: 0)
                    settingsMenu
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(TB.Typography.panelTitle).accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        scopePlaque
                        Chip(text: L(.streamSaved), kind: .success)
                        Spacer(minLength: 0)
                        settingsMenu
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 10, alignment: .leading)],
                      alignment: .leading, spacing: 12) {
                SettingValue(title: L(.streamQuality), value: presetTitle)
                SettingValue(title: L(.streamFrames), value: L(.streamFPS, Int64(settings.fps)))
                SettingValue(title: L(.streamBitrate), value: L(.streamMbps, Int64(settings.megabits)))
                SettingValue(title: L(.streamResolution), value: dimensions)
                SettingValue(title: L(.streamConnection), value: settings.connection.shortLabel)
                SettingValue(title: L(.streamLatency), value: settings.latency.title)
                SettingValue(title: L(.streamAudio), value: settings.gameAudioChoice.label ?? L(.streamNoAudio))
            }
            Rectangle().fill(TB.hairline).frame(height: 1).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    technicalDetails.frame(minWidth: 280)
                    Spacer(minLength: 0)
                    footerNote.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 8) {
                    technicalDetails
                    footerNote
                }
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .cardStyle(padding: 0)
        .sheet(item: $editingProfileSettings) { selection in
            PerGameSettingsSheet(profileName: selection.name, model: model)
        }
    }

    private var headerLabels: some View {
        HStack(spacing: 12) {
            Text(title).font(TB.Typography.panelTitle).accessibilityAddTraits(.isHeader)
            scopePlaque
            Chip(text: L(.streamSaved), kind: .success)
        }
    }

    private var scopePlaque: some View {
        Text(hasOverride ? L(.libraryPerGame) : L(.libraryGlobal))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(TB.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: TB.Radius.quietButton))
            .overlay(RoundedRectangle(cornerRadius: TB.Radius.quietButton).strokeBorder(TB.quietBorder))
            .help(scopeHelp)
            .accessibilityHint(scopeHelp)
    }

    private var settingsMenu: some View {
        Menu {
            if let selectedProfile = model.selectedLaunchProfileName {
                Button(L(.streamProfileSettings, model.gameTitle(forProfile: selectedProfile))) {
                    editingProfileSettings = ProfileSettingsSelection(name: selectedProfile)
                }
            }
            Button(L(.streamGlobalSettings)) { model.selection = .settings }
        } label: {
            Text(L(.streamAdjust))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(TB.lavaText)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .overlay(RoundedRectangle(cornerRadius: TB.Radius.quietButton).strokeBorder(TB.emberBorder))
                .opacity(active ? 0.5 : 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(active)
        .help(L(.streamChangesNextLaunch))
        .tourTarget(.chapter(.streamAdjust))
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showingTechnicalDetails) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)],
                      alignment: .leading, spacing: 10) {
                SettingValue(title: L(.streamCodec), value: settings.codec.label)
                SettingValue(title: L(.streamSharpening), value: filterTitle(settings.questSharpening))
                SettingValue(title: L(.streamAntiAliasing), value: filterTitle(settings.questSupersampling))
            }
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L(.streamTechnicalDetails))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TB.textTertiary)
                Text(L(.streamTechnicalSubtitle))
                    .font(TB.Typography.caption)
                    .foregroundStyle(TB.textSecondary)
            }
        }
    }

    private var footerNote: some View {
        Text(footer)
            .font(TB.Typography.meta)
            .foregroundStyle(TB.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var dimensions: String {
        let resolution = settings.resolution.perEyeResolution
        return L(.commonDimensions, String(resolution.width), String(resolution.height))
    }

    private var presetTitle: String {
        switch settings.qualityPreset {
        case .performance: L(.libraryPresetPerformance)
        case .balanced: L(.libraryPresetBalanced)
        case .quality: L(.libraryPresetQuality)
        case .high: L(.libraryPresetHigh)
        case .maximum: L(.libraryPresetMaximum)
        case .custom: L(.libraryPresetCustom)
        }
    }

    private func filterTitle(_ filter: HeadsetFilterLevel) -> String {
        switch filter {
        case .off: L(.streamFilterOff)
        case .normal: L(.streamFilterNormal)
        case .quality: L(.streamFilterQuality)
        }
    }
}

private struct ProfileSettingsSelection: Identifiable {
    var id: String { name }
    let name: String
}

private struct SettingValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(TB.Typography.caption).foregroundStyle(TB.textSecondary)
            Text(value)
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .foregroundStyle(TB.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Metrics

/// Observe the console itself so only the tiles re-render per sample.
private struct MetricTiles: View {
    @ObservedObject var console: SessionConsole
    let settings: StreamLaunchSettings

    var body: some View {
        let samples = console.recentSamples
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: TB.Spacing.stream)],
                  spacing: TB.Spacing.stream) {
            MetricTile(title: L(.streamHeadsetFrames), unit: L(.streamUnitFPS),
                       samples: samples.compactMap(\.fps), reference: Double(settings.fps),
                       referenceText: L(.streamTarget, Int64(settings.fps)))
            MetricTile(title: L(.streamBitrate), unit: L(.streamUnitMbps),
                       samples: samples.compactMap(\.megabits), reference: Double(settings.megabits),
                       referenceText: L(.streamLimit, Int64(settings.megabits)))
            MetricTile(title: L(.streamLatency), unit: L(.streamUnitMilliseconds),
                       samples: samples.compactMap(\.latencyMilliseconds), reference: 0,
                       referenceText: L(.streamInputToDisplay))
        }
    }
}

private struct MetricTile: View {
    let title: String
    let unit: String
    let samples: [Double]
    let reference: Double
    let referenceText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    metricTitle.fixedSize()
                    Spacer(minLength: 0)
                    metricReference.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    metricTitle
                    metricReference
                }
            }
            .frame(minHeight: 30, alignment: .top)
            HStack(alignment: .bottom, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(samples.last.map { L(.streamIntegerValue, $0) } ?? L(.streamNoValue))
                        .tbMetricValue()
                    Text(unit).font(TB.Typography.body).foregroundStyle(TB.textSecondary)
                }
                .fixedSize()
                // Without samples this is "— fps"; the summary below already says "No samples yet".
                .accessibilityHidden(samples.isEmpty)
                PixelSparkline(samples: samples, reference: reference)
            }
            Text(summary)
                .font(TB.Typography.caption.monospacedDigit())
                .foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardStyle(padding: 0)
        .accessibilityElement(children: .combine)
        // New samples arrive about once a second; poll rather than announce.
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var metricTitle: some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(TB.textTertiary)
    }

    private var metricReference: some View {
        Text(referenceText).font(TB.Typography.meta.monospacedDigit()).foregroundStyle(TB.textSecondary)
    }

    private var summary: String {
        let statistics = MetricStatistics(samples)
        guard let average = statistics.average,
              let low = statistics.minimum, let high = statistics.maximum else {
            return L(.streamNoSamples)
        }
        return L(.streamMetricSummary, average, low, high)
    }
}

// MARK: - Log

private struct SessionLogCard: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var console: SessionConsole

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    title.fixedSize()
                    Spacer(minLength: 0)
                    HStack(spacing: 6) { logActions }.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    HStack(spacing: 6) { logActions }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            Rectangle().fill(TB.hairline).frame(height: 1).accessibilityHidden(true)
            SessionLogView(text: console.log.isEmpty ? L(.streamLogPlaceholder) : console.log)
                .frame(height: 220)
                .background(TB.sunkenBackground)
                .accessibilityLabel(L(.streamLog))
        }
        .cardStyle(padding: 0)
        .clipShape(RoundedRectangle(cornerRadius: TB.Radius.card))
    }

    private var title: some View {
        Text(L(.streamLog)).font(TB.Typography.panelTitle).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private var logActions: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(exportedLog, forType: .string)
        } label: {
            Text(L(.menuCopy)).font(.system(size: 12))
        }
        .buttonStyle(TBQuietButtonStyle(compact: true))
        .help(L(.streamCopyLogHelp))
        .disabled(console.log.isEmpty)
        Menu {
            Button(L(.streamSaveLog)) { saveLog() }.disabled(console.log.isEmpty)
            Button(L(.streamExportMetrics)) { saveMetrics() }.disabled(console.samples.isEmpty)
        } label: {
            Text(L(.streamSave))
                .font(.system(size: 12))
                .foregroundStyle(TB.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: TB.Size.panelButton)
                .background(TB.quietFill, in: RoundedRectangle(cornerRadius: TB.Radius.panelButton))
                .overlay(RoundedRectangle(cornerRadius: TB.Radius.panelButton).strokeBorder(TB.quietBorder))
                .opacity(console.log.isEmpty && console.samples.isEmpty ? 0.5 : 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L(.streamSaveHelp))
        .disabled(console.log.isEmpty && console.samples.isEmpty)
        Button(L(.streamClear)) { model.clearLog() }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(TB.textTertiary)
            .padding(.horizontal, 6)
            .frame(height: TB.Size.panelButton)
            .help(L(.streamClearLogHelp))
            // Two "Clear" buttons share this screen; say which one, and keep
            // the visible word working for Voice Control.
            .accessibilityLabel(L(.streamClearLogLabel))
            .accessibilityInputLabels([L(.streamClear), L(.streamClearLogLabel)])
            .disabled(console.log.isEmpty || model.sessionState.isActive)
    }

    private func saveLog() {
        guard let url = FilePanels.saveFile(
            title: L(.streamSaveLogTitle), baseName: L(.streamLogFileBaseName), fileExtension: "log")
        else { return }
        model.export(exportedLog, to: url)
    }

    /// What Copy and Save hand out. The log on screen is the person's own;
    /// a copy gets pasted into public issues, so names, paths, addresses and
    /// serials are replaced the same way as in the diagnostic report.
    private var exportedLog: String {
        console.exportedLog(redactedWith: DiagnosticRedactor(
            dataFolder: model.dataRoot.path, appFolder: model.repoRoot.path))
    }

    private func saveMetrics() {
        guard let url = FilePanels.saveFile(
            title: L(.streamExportMetricsTitle), baseName: L(.streamMetricsFileBaseName), fileExtension: "csv")
        else { return }
        model.export(StreamMetricCSV.render(console.samples), to: url)
    }
}

/// A fixed-size AppKit text container avoids SwiftUI repeatedly measuring the
/// full selectable log inside two nested scroll views as telemetry arrives.
/// The diagnostic report sheet reuses it for its preview.
struct SessionLogView: NSViewRepresentable {
    let text: String
    /// Keep the newest output in view while the reader is at the end.
    var followsTail = true

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    final class Coordinator {
        /// The text last handed to the view, so updates can append.
        var shown = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let shown = context.coordinator.shown
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage, text != shown else { return }
        let wasAtBottom = shown.isEmpty
            || scrollView.contentView.bounds.maxY >= textView.bounds.maxY - 24
        if !shown.isEmpty, text.utf8.starts(with: shown.utf8) {
            // Output only grows between trims; appending avoids replacing
            // and relaying out the whole log for every chunk.
            let added = Substring(text.utf8.dropFirst(shown.utf8.count))
            storage.append(NSAttributedString(string: String(added), attributes: [
                .font: textView.font as Any,
                .foregroundColor: textView.textColor ?? .labelColor,
            ]))
        } else {
            textView.string = text
        }
        context.coordinator.shown = text
        if followsTail, wasAtBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}

// MARK: - Health

private struct StreamWarningStyle: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        content
            .font(TB.Typography.body)
            .foregroundStyle(TB.warningText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background {
                shape.fill(TB.cardBackground).overlay(shape.fill(TB.warningFill))
            }
            .overlay(shape.strokeBorder(TB.warningText.opacity(contrast == .increased ? 1 : 0.3),
                                        lineWidth: contrast == .increased ? 2 : 1))
    }
}

private extension View {
    func streamWarningStyle() -> some View { modifier(StreamWarningStyle()) }
}

/// One line while any game records diagnostics, so the switch is not forgotten.
private struct RecordingReminder: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        let names = model.recordingProfileNames
        if !names.isEmpty {
            let text = L(.recordingReminder, names.joined(separator: ", "))
            HStack(spacing: 12) {
                PixelIcon(glyph: .dot, size: 8, color: TB.warningText)
                Text(text).lineLimit(2).help(text)
                Spacer(minLength: 0)
                Button(L(.recordingOpen)) { model.selection = .diagnostics }
                    .buttonStyle(TBQuietButtonStyle(compact: true))
                    .fixedSize()
            }
            .streamWarningStyle()
        }
    }
}

/// A timer detects a silent headset even when no new samples arrive.
private struct StreamHealthBanner: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var console: SessionConsole

    var body: some View {
        if case .streaming = model.sessionState {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let issues = StreamHealthAdvisor.evaluate(
                    samples: console.recentSamples,
                    settings: model.displayedStreamSettings,
                    thermalState: ProcessInfo.processInfo.thermalState,
                    lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                    headsetDisconnected: console.headsetDisconnected,
                    now: context.date)
                if !issues.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(issues) { issue in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: issue.kind.symbol)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(issue.title).font(TB.Typography.body.weight(.semibold))
                                    Text(issue.detail)
                                        .foregroundStyle(TB.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .streamWarningStyle()
                }
            }
        }
    }
}

private extension StreamHealthIssue.Kind {
    var symbol: String {
        switch self {
        case .headsetSilent: return "wifi.exclamationmark"
        case .lowFrameRate: return "speedometer"
        case .highLatency: return "timer"
        case .thermalPressure: return "thermometer.high"
        case .lowPowerMode: return "battery.25"
        }
    }
}

// MARK: - History

private struct RecentSessionsCard: View {
    @ObservedObject var model: BasaltAppModel
    @State private var confirmingClear = false

    private static let visibleCount = 6

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L(.streamRecentSessions))
                    .font(TB.Typography.panelTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(L(.streamClear)) { confirmingClear = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(TB.textTertiary)
                    .frame(height: TB.Size.panelButton)
                    .help(L(.streamClearHistoryHelp))
                    .accessibilityLabel(L(.streamClearHistoryLabel))
                    .accessibilityInputLabels([L(.streamClear), L(.streamClearHistoryLabel)])
                    .disabled(model.sessionHistory.isEmpty)
            }
            .padding(.leading, 14)
            .padding(.trailing, 12)
            .padding(.vertical, 9)
            Rectangle().fill(TB.hairline).frame(height: 1).accessibilityHidden(true)
            if model.sessionHistory.isEmpty {
                Text(L(.streamHistoryEmpty))
                    .font(TB.Typography.body)
                    .foregroundStyle(TB.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                let visible = Array(model.sessionHistory.prefix(Self.visibleCount))
                ForEach(visible) { record in
                    SessionHistoryRow(record: record, model: model)
                    if record.id != visible.last?.id {
                        Rectangle().fill(TB.hairline).frame(height: 1).accessibilityHidden(true)
                    }
                }
            }
        }
        .cardStyle(padding: 0)
        .clearSessionHistoryDialog(isPresented: $confirmingClear, model: model)
        .tourTarget(.chapter(.streamRecentSessions))
    }
}

private struct SessionHistoryRow: View {
    let record: SessionRecord
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        HStack(spacing: 10) {
            outcomeGlyph
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { profileName; outcomeChips }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        profileName
                        FlowLayout(spacing: 6) { outcomeChips }
                    }
                }
                HStack(spacing: 8) {
                    Text(subtitle)
                        .foregroundStyle(TB.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(subtitle)
                    Spacer(minLength: 0)
                    if let stats {
                        Text(stats)
                            .monospacedDigit()
                            .foregroundStyle(TB.textTertiary)
                            .fixedSize()
                    }
                }
                .font(TB.Typography.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Name, outcome, chips, date and stats read as one row; Replay stays separate.
            .accessibilityElement(children: .combine)
            Button {
                Task { await model.launch(profileName: record.profileName) }
            } label: {
                PixelIcon(glyph: .play, size: 8, color: TB.lavaText)
            }
            .buttonStyle(TBReplayButtonStyle())
            // Names the game, so six "Play again" buttons stay distinguishable.
            .accessibilityLabel(L(.streamReplayHelp, title))
            .help(canReplay ? L(.streamReplayHelp, title) : L(.streamCannotReplay))
            .disabled(!canReplay)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }

    /// The game's name as the Library shows it, not the profile's file
    /// name; a profile removed since keeps its own name.
    private var title: String { model.gameTitle(forProfile: record.profileName) }

    private var profileName: some View {
        Text(title)
            .font(TB.Typography.body.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .help(title)
            .accessibilityValue(outcomeLabel)
    }

    @ViewBuilder private var outcomeChips: some View {
        if let share = record.metrics.lowFrameRateShare, share >= 0.1 {
            Chip(text: L(.streamBelowTarget, Int64((share * 100).rounded())), kind: .warning)
        }
        if record.outcome == .failed {
            Chip(text: L(.streamFailureChip), kind: .failed)
        }
    }

    @ViewBuilder private var outcomeGlyph: some View {
        switch record.outcome {
        case .ended: PixelIcon(glyph: .check, size: 8, color: TB.successText)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                .foregroundStyle(TB.dangerText).frame(width: 8).accessibilityHidden(true)
        case .stopped, nil: PixelIcon(glyph: .dot, size: 8, color: TB.textSecondary)
        }
    }

    private var canReplay: Bool {
        !model.sessionState.isActive && !model.isImportingGameFolder
            && model.launchableProfiles.contains { $0.name == record.profileName }
    }

    private var outcomeLabel: String {
        switch record.outcome {
        case .ended: L(.streamOutcomeEnded)
        case .failed: L(.streamFailureChip)
        case .stopped: L(.streamOutcomeStopped)
        case nil: L(.streamOutcomeUnknown)
        }
    }

    private var subtitle: String {
        let date = DateFormatter()
        date.locale = L10n.language.locale
        date.dateFormat = L(.streamHistoryDateFormat)
        date.shortMonthSymbols = L(.streamHistoryMonths).components(separatedBy: "|")
        var parts = [date.string(from: record.startedAt)]
        if let duration = record.streamingDuration {
            parts.append(formattedDuration(duration))
        }
        if record.outcome == .failed {
            parts.append(record.failureReason ?? L(.streamUnknownError))
        } else {
            parts.append(record.settings.connection.shortLabel)
        }
        return parts.joined(separator: " · ")
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int64(duration))
        if seconds >= 3600 {
            return L(.streamDurationHoursMinutes, seconds / 3600, seconds / 60 % 60)
        }
        if seconds >= 60 {
            return L(.streamDurationMinutesSeconds, seconds / 60, seconds % 60)
        }
        return L(.streamDurationSeconds, seconds)
    }

    private var stats: String? {
        var parts = [String]()
        if let fps = record.metrics.fps.average {
            parts.append(L(.streamHistoryFPS, fps))
        }
        if let latency = record.metrics.latencyMilliseconds.average {
            parts.append(L(.streamHistoryLatency, latency))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

import SwiftUI
import AppKit
import BasaltCore
import BasaltManagerKit

struct SettingsView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var confirmingClearHistory = false
    @State private var showingUninstall = false

    var body: some View {
        Form {
            Section {
                TBFormHeader {
                    HStack(spacing: 12) {
                        TBPixelTile(glyph: .settings, size: 38)
                        Text(L(.settingsGlobalTitle)).font(TB.Typography.cardTitle)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(L(.settingsGlobalHelp)).foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.profileSettings.isEmpty {
                        let names = model.profileSettings.keys.map(model.gameTitle(forProfile:)).sorted().joined(separator: ", ")
                        let text = L(.settingsOverrideNames,
                                     L10n.plural(.settingsOverrideCount, model.profileSettings.count), names)
                        Text(text).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                            .lineLimit(2).help(text).accessibilityLabel(text)
                    }
                }
            }
            .listRowBackground(TB.cardBackground)

            Section {
                Picker(L(.settingsLanguage), selection: $model.language) {
                    ForEach(AppLanguage.available, id: \.self) { language in
                        Text(language.isReviewed ? language.nativeName
                             : L(.settingsUnreviewedLanguage, language.nativeName,
                                 L(.settingsTranslationNotReviewed)))
                            .tag(language)
                    }
                }
            } header: {
                Text(L(.settingsLanguage))
            } footer: {
                Text(L(.settingsLanguageImmediate)).tbFormFooterStyle()
            }
            .listRowBackground(TB.cardBackground)

            Section {
                Picker(L(.settingsAppearance), selection: $model.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(L(appearance.titleKey)).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(L(.settingsAppearance))
            }
            .listRowBackground(TB.cardBackground)

            Section {
                StreamSettingsFields(settings: $model.settings, audioDevices: model.audioDevices,
                                     recommendation: model.qualityRecommendation, tourMarks: true)
            } footer: {
                Button(L(.settingsRestoreDefaults)) { model.settings = defaultStreamSettings }
                    .buttonStyle(TBQuietButtonStyle(compact: true))
                    .disabled(model.settings == defaultStreamSettings)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(TB.cardBackground)

            Section(L(.settingsStorage)) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.settingsDataFolder))
                    PathText(path: model.dataRoot.path)
                    dataFolderStatus
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([model.dataRoot])
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(TBIconButtonStyle(accessibilityLabel: L(.libraryShowInFinder), compact: true))
                        .help(L(.libraryShowInFinder))
                        // Finder would be asked about a folder that is not there.
                        .disabled(model.dataFolderState != .ready)
                        Button(L(.settingsChangeFolder)) { DataFolderChooser.choose(for: model) }
                            .buttonStyle(TBQuietButtonStyle(compact: true))
                            .disabled(model.sessionState.isActive)
                        if model.dataFolderState != .ready {
                            DataFolderRecoveryButtons(model: model, offersChooser: false)
                        }
                    }
                }
                // On appear and after a change; never on the main thread.
                .task(id: model.dataRoot) { await model.refreshDataFolderVolume() }
                LabeledContent(L(.settingsContents)) {
                    Text(L(.settingsContentsValue, L10n.plural(.settingsBottleCount, model.bottles.count),
                           L10n.plural(.settingsProfileCount, model.profiles.count)))
                        .foregroundStyle(TB.textSecondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L(.settingsRepository))
                    PathText(path: model.repoRoot.path)
                }
            }
            .listRowBackground(TB.cardBackground)

            Section(L(.settingsSafety)) {
                Label(L(.settingsDiscoveredBottles,
                        L10n.plural(.environmentCount, model.discoveredBottles.count)), systemImage: "shippingbox")
                Label(L10n.plural(.settingsSteamGameCount, model.steamGames.filter { !$0.isTool }.count),
                      systemImage: "gamecontroller")
                Label(L(.settingsReadOnly), systemImage: "lock.shield")
                Label(L(.settingsOpenComposite), systemImage: "doc.badge.gearshape")
            }
            .listRowBackground(TB.cardBackground)

            Section {
                LabeledContent(L(.diagnosticsTitle)) {
                    Button(L(.settingsCreateReport)) { model.showingDiagnostics = true }
                        .buttonStyle(TBQuietButtonStyle(compact: true))
                }
                .tourTarget(.topic(.settingsCreateReport))
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.settingsHistory))
                    HStack(spacing: 10) {
                        Text(L10n.plural(.settingsSessionCount, model.sessionHistory.count))
                            .foregroundStyle(TB.textSecondary)
                        Spacer(minLength: 0)
                        Button(L(.settingsClearHistory)) { confirmingClearHistory = true }
                            .buttonStyle(TBQuietButtonStyle(compact: true))
                            .disabled(model.sessionHistory.isEmpty)
                    }
                }
            } header: {
                Text(L(.settingsDiagnostics))
            } footer: {
                Text(L(.settingsDiagnosticsHelp, Int64(SessionHistoryStore.defaultLimit)))
                    .tbFormFooterStyle()
            }
            .listRowBackground(TB.cardBackground)

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.uninstallHelp)).foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L(.uninstallButton)) { showingUninstall = true }
                        .buttonStyle(TBQuietButtonStyle(compact: true))
                        .disabled(model.sessionState.isActive)
                }
            } header: {
                Text(L(.uninstallSection))
            }
            .listRowBackground(TB.cardBackground)
        }
        .tbGroupedForm()
        .sheet(isPresented: $showingUninstall) { UninstallSheet(model: model) }
        .tourScrollsToTarget(on: .settings)
        .navigationTitle(L(.sidebarSettings))
        .clearSessionHistoryDialog(isPresented: $confirmingClearHistory, model: model)
        .dataFolderNetworkQuestion(model: model)
    }

    /// Under the path: the disk and its free space, or why the folder
    /// cannot be used right now.
    @ViewBuilder private var dataFolderStatus: some View {
        switch model.dataFolderState {
        case .ready:
            if let volume = model.dataFolderVolume {
                Text(volume.summary).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
        case .checking:
            Text(L(.dataFolderChecking)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
        case .problem(let problem):
            Text(L(.dataFolderUnavailableTitle)).font(TB.Typography.meta).foregroundStyle(TB.warningText)
            Text(problem.message).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var defaultStreamSettings: StreamLaunchSettings {
        var defaults = model.qualityRecommendation.settings
        defaults.applyAudioDefault(devices: model.audioDevices)
        return defaults
    }
}

// MARK: - Removing the app

/// Lists what removing the app deletes, group by group with sizes, and what
/// stays, then removes it all after one more confirmation. The BasaltVR
/// folder in Application Support may belong to the original BasaltVR app,
/// so it has its own box, unticked, with its path.
private struct UninstallSheet: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AppFootprint.Item]?
    @State private var basaltVRFolder: AppFootprint.BasaltVRFolder?
    @State private var includesBasaltVRFolder = false
    @State private var confirming = false
    @State private var removing = false
    @State private var failure: String?

    var body: some View {
        TBManagementSheet(glyph: .settings, title: L(.uninstallTitle),
                          subtitle: L(.uninstallSubtitle)) {
            VStack(alignment: .leading, spacing: 12) {
                if let items {
                    ForEach(AppFootprint.Group.allCases, id: \.self) { group in
                        row(L(title(for: group)), size(AppFootprint.totalBytes(items, in: group),
                                                       present: items.contains { $0.group == group }))
                    }
                    row(L(.uninstallPermissions), "")
                    row(L(.uninstallApplication), "")
                    if let basaltVRFolder {
                        Toggle(isOn: $includesBasaltVRFolder) {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L(.uninstallBasaltVRFolder))
                                    Text(basaltVRFolder.url.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(TB.textSecondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 12)
                                Text(Self.format(basaltVRFolder.bytes))
                                    .foregroundStyle(TB.textSecondary).monospacedDigit()
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(removing)
                    }
                    Text(L(.uninstallTotal, Self.format(totalBytes(items))))
                        .font(TB.Typography.cardTitle)
                } else {
                    TBProgressIndicator(L(.uninstallCounting)).foregroundStyle(TB.textSecondary)
                }
                Text(L(.uninstallKeeps)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure {
                    Text(failure).font(TB.Typography.meta).foregroundStyle(TB.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } actions: {
            if removing {
                TBProgressIndicator(L(.uninstallRemoving)).foregroundStyle(TB.textSecondary)
            }
            Spacer(minLength: 0)
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(removing)
            Button(L(.uninstallConfirm)) { confirming = true }
                .buttonStyle(TBPrimaryButtonStyle())
                .disabled(items == nil || removing || model.sessionState.isActive)
        }
        .frame(width: 560, height: basaltVRFolder == nil ? 500 : 570)
        .interactiveDismissDisabled(removing)
        .task { await count() }
        .confirmationDialog(L(.uninstallQuestion), isPresented: $confirming) {
            Button(L(.uninstallConfirm), role: .destructive) {
                removing = true
                failure = nil
                Task {
                    failure = await model.removeAppCompletely(
                        includingBasaltVRFolder: includesBasaltVRFolder && basaltVRFolder != nil)
                    removing = false
                    await count()
                }
            }
            Button(L(.commonCancel), role: .cancel) {}
        }
    }

    private func count() async {
        let footprint = await model.appFootprint()
        items = footprint.items
        basaltVRFolder = footprint.basaltVRFolder
    }

    /// What the button deletes as the box stands now.
    private func totalBytes(_ items: [AppFootprint.Item]) -> Int64 {
        AppFootprint.totalBytes(items)
            + (includesBasaltVRFolder ? basaltVRFolder?.bytes ?? 0 : 0)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(TB.textSecondary).monospacedDigit()
        }
    }

    private func title(for group: AppFootprint.Group) -> L10nKey {
        switch group {
        case .games: .uninstallGroupGames
        case .settings: .uninstallGroupSettings
        case .systemCaches: .uninstallGroupCaches
        case .crashReports: .uninstallGroupCrashReports
        case .temporaryFiles: .uninstallGroupTemporary
        }
    }

    private func size(_ bytes: Int64, present: Bool) -> String {
        present ? Self.format(bytes) : L(.uninstallNone)
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Data folder

/// The folder panel for the data folder, from Settings and from the page
/// shown while the folder cannot be used.
@MainActor
enum DataFolderChooser {
    static func choose(for model: BasaltAppModel) {
        guard let url = FilePanels.chooseFolder(
            title: L(.settingsChooseFolder),
            // A folder that is missing or does not answer would hold the panel up.
            startingAt: model.dataFolderState == .ready ? model.dataRoot : nil,
            canCreate: true) else { return }
        Task { await model.changeDataRoot(to: url) }
    }
}

/// The ways out while the data folder is checked or cannot be used.
struct DataFolderRecoveryButtons: View {
    @ObservedObject var model: BasaltAppModel
    var offersChooser = true

    var body: some View {
        if case .problem = model.dataFolderState {
            Button(L(.dataFolderRetry)) { Task { await model.checkDataFolder() } }
                .buttonStyle(TBQuietButtonStyle(compact: true))
        }
        if offersChooser {
            Button(L(.dataFolderChooseOther)) { DataFolderChooser.choose(for: model) }
                .buttonStyle(TBQuietButtonStyle(compact: true))
        }
        Button(L(.dataFolderUseDefault)) { Task { await model.useStandardDataFolder() } }
            .buttonStyle(TBQuietButtonStyle(compact: true))
    }
}

/// Stands in for every page but Settings while the data folder is being
/// checked or cannot be used, so no page reads it or creates anything in
/// place of a disk that is not connected.
struct DataFolderGateView: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        // A scroll view and a title like every other page: without them the
        // window took the sidebar's scroll view for the page's own and laid
        // the sidebar out shifted up, its session card gone.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    if case .problem(let problem) = model.dataFolderState {
                        PixelIcon(glyph: .warning, size: 18, color: TB.warningText).accessibilityHidden(true)
                        Text(L(.dataFolderUnavailableTitle)).font(TB.Typography.cardTitle)
                            .accessibilityAddTraits(.isHeader)
                        PathText(path: model.dataRoot.path)
                        Text(problem.message)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TBProgressIndicator(L(.dataFolderChecking))
                        PathText(path: model.dataRoot.path)
                    }
                    HStack(spacing: 8) { DataFolderRecoveryButtons(model: model) }
                        .padding(.top, 4)
                }
                .frame(maxWidth: 460)
                .padding(24)
                // Centred in the page, as before.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(TB.windowBackground)
        .navigationTitle(L(.settingsDataFolder))
        .dataFolderNetworkQuestion(model: model)
    }
}

/// Stands in for every page while the settings file cannot be read: names
/// the file and offers to show it or to set it aside and start fresh.
struct SettingsFileGateView: View {
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        // A scroll view and a title like every other page; see
        // `DataFolderGateView`.
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 12) {
                    if let problem = model.settingsFileProblem {
                        PixelIcon(glyph: .warning, size: 18, color: TB.warningText).accessibilityHidden(true)
                        Text(L(.settingsFileProblemTitle)).font(TB.Typography.cardTitle)
                            .accessibilityAddTraits(.isHeader)
                        PathText(path: problem.file.path)
                        Text(L(.settingsFileProblemMessage))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup(L(.commonDetails)) {
                            Text(problem.detail).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                        HStack(spacing: 8) {
                            Button(L(.libraryShowInFinder)) {
                                NSWorkspace.shared.activateFileViewerSelecting([problem.file])
                            }
                            .buttonStyle(TBQuietButtonStyle(compact: true))
                            Button(L(.settingsFileSetAside)) { model.setSettingsFileAside() }
                                .buttonStyle(TBQuietButtonStyle(compact: true))
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: 460)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .background(TB.windowBackground)
        .navigationTitle(L(.sidebarSettings))
    }
}

extension View {
    /// Asks once before the data goes to network storage.
    func dataFolderNetworkQuestion(model: BasaltAppModel) -> some View {
        alert(L(.settingsDataFolder), isPresented: Binding(
            get: { model.askingAboutNetworkDataFolder },
            set: { model.askingAboutNetworkDataFolder = $0 }
        )) {
            Button(L(.dataFolderContinue)) { Task { await model.confirmNetworkDataFolder() } }
            Button(L(.commonCancel), role: .cancel) {}
        } message: {
            Text(L(.dataFolderNetworkWarning))
        }
    }
}

/// Stream controls as grouped-form rows, shared by Settings and the
/// per-game sheet.
struct StreamSettingsFields: View {
    @Binding var settings: StreamLaunchSettings
    let audioDevices: [GameAudioDevice]
    let recommendation: StreamQualityRecommendation
    /// The rows a learning step can point at are marked. Only the Settings
    /// page sets this: the per-game sheet has its own steps and is never
    /// pointed into.
    var tourMarks = false
    @Environment(\.openURL) private var openURL
    @State private var advanced = false
    @FocusState private var focusedPreset: StreamQualityPreset?

    /// Refresh rates Quest headsets offer; a stored custom value stays listed.
    private static let frameRates = [60, 72, 80, 90, 120]
    /// Up to the highest bitrate whose stream the selected codec keeps
    /// decodable (HEVC 240, H.264 300). Above 200 Mbps suits a USB cable or a
    /// strong 6 GHz link; Wi-Fi feedback still lowers the target on trouble.
    private var bitrateRange: ClosedRange<Double> {
        10.0...Double(settings.codec.maximumMegabits)
    }

    var body: some View {
        Picker(selection: $settings.connection) {
            ForEach(StreamConnectionMode.allCases, id: \.self) {
                Text($0.shortLabel).tag($0)
            }
        } label: {
            LabelWithHelp(title: L(.streamConnection), badge: .connection)
        }
        .pickerStyle(.segmented)
        .tourTarget(tourMarks ? .chapter(.settingsConnection) : nil)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(L(.streamQuality)).font(TB.Typography.panelTitle)
                    .accessibilityAddTraits(.isHeader)
                LearningHelpBadgeButton(badge: .quality)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(StreamQualityPreset.allCases, id: \.self) { preset in
                    presetCard(preset)
                }
            }
            // FlowLayout aligns tops, so every item here uses chip metrics
            // (11.5 pt text, 2 pt vertical padding) to share one height.
            FlowLayout(spacing: 8) {
                HStack(spacing: 5) {
                    PixelIcon(glyph: .dot, size: 6, color: TB.lavaText).accessibilityHidden(true)
                    Text(L(.settingsRecommended, StreamSettingsPresentation.preset(recommendation.preset)))
                }
                .font(TB.Typography.caption).foregroundStyle(TB.textSecondary)
                .padding(.vertical, TB.Spacing.chipVertical)
                Chip(text: recommendation.isTested ? L(.settingsTested) : L(.settingsUntested),
                     kind: recommendation.isTested ? .success : .unverified)
                // The outline is on the button; a form scrolls only to a
                // row, so the row below carries the id.
                Button(L(.settingsUseRecommended)) { settings.selectQuality(recommendation.preset) }
                    .buttonStyle(TBChipButtonStyle())
                    .tourTarget(tourMarks ? .chapter(.settingsUseRecommended) : nil, scrolls: false)
            }
        }
        .padding(.vertical, 4)
        .tourScrollAnchor(tourMarks ? .chapter(.settingsUseRecommended) : nil)

        // Custom has no preset values to show, so its controls are always open.
        DisclosureGroup(L(.settingsAdvanced), isExpanded: Binding(
            get: { advanced || settings.qualityPreset == .custom },
            set: { advanced = $0 })) {
            Picker(L(.streamCodec), selection: $settings.codec) {
                ForEach(VideoCodec.allCases, id: \.self) {
                    Text($0 == .h264 ? L(.settingsH264) : L(.settingsHEVC)).tag($0)
                }
            }
            Picker(L(.streamSharpening), selection: $settings.questSharpening) {
                ForEach(HeadsetFilterLevel.allCases, id: \.self) {
                    Text(StreamSettingsPresentation.filter($0)).tag($0)
                }
            }
            Picker(L(.settingsFrameRate), selection: $settings.fps) {
                ForEach(Array(Set(Self.frameRates + [settings.fps])).sorted(), id: \.self) {
                    Text(L(.streamFPS, Int64($0))).tag($0)
                }
            }
            Picker(L(.streamResolution), selection: $settings.resolution) {
                ForEach(ResolutionSelection.allCases, id: \.self) {
                    Text(StreamSettingsPresentation.resolution($0)).tag($0)
                }
            }
            if settings.resolution.perEyeResolution.width > ResolutionSelection.maximum.perEyeResolution.width {
                Text(L(.settingsResolutionLargeHelp)).tbFormFooterStyle()
            }
            LabeledContent(L(.streamBitrate)) {
                HStack(spacing: 10) {
                    Slider(value: bitrate, in: bitrateRange)
                        .frame(minWidth: 100)
                        .accessibilityLabel(L(.streamBitrate))
                        .accessibilityValue(L(.streamMbps, Int64(settings.megabits)))
                    Text(L(.streamMbps, Int64(settings.megabits)))
                        .monospacedDigit().fixedSize()
                }
            }
            Picker(L(.settingsEncoderMode), selection: $settings.encoderMode) {
                ForEach(EncoderRateMode.allCases, id: \.self) {
                    Text(StreamSettingsPresentation.encoderMode($0)).tag($0)
                }
            }
            Text(L(.settingsEncoderModeHelp, StreamSettingsPresentation.encoderMode(
                settings.usesLowLatencyRateControl ? .lowLatency : .moreFrames))).tbFormFooterStyle()
            Picker(L(.streamAntiAliasing), selection: $settings.questSupersampling) {
                ForEach(HeadsetFilterLevel.allCases, id: \.self) {
                    Text(StreamSettingsPresentation.filter($0)).tag($0)
                }
            }
            Text(L(.settingsFiltersHelp)).tbFormFooterStyle()
        }

        audioPicker
            .tourTarget(tourMarks ? .topic(.settingsGameAudio) : nil)
            .onAppear { settings.applyAudioDefault(devices: audioDevices) }
            .onChange(of: audioDevices) { _, devices in
                settings.applyAudioDefault(devices: devices)
            }
        switch settings.gameAudioChoice {
        case .mac: Text(L(.settingsMacAudioHelp)).tbFormFooterStyle()
        case .device: Text(L(.settingsAudioRouting)).tbFormFooterStyle()
        case .off: EmptyView()
        }
        if !GameAudioSource.macAudioSupported {
            Text(L(.settingsMacAudioUnsupported)).tbFormFooterStyle()
        }
        // BlackHole stays a choice for when the Mac's own audio does not work.
        if !hasBlackHole {
            LabeledContent("BlackHole") {
                HStack {
                    Text(L(.environmentNotInstalled)).foregroundStyle(TB.textSecondary)
                    Button(L(.settingsGetBlackHole)) { openURL(BlackHoleSetup.downloadURL) }
                        .buttonStyle(TBQuietButtonStyle(compact: true))
                }
            }
            Text(L(.settingsAudioInstallation)).tbFormFooterStyle()
        }

        Toggle(L(.settingsGamePriority), isOn: $settings.gamePriorityHigh)
        Text(L(.settingsGamePriorityHelp)).tbFormFooterStyle()
    }

    private func presetCard(_ preset: StreamQualityPreset) -> some View {
        let selected = settings.qualityPreset == preset
        let recommended = preset == recommendation.preset
        let shape = RoundedRectangle(cornerRadius: 9)
        return Button { settings.selectQuality(preset) } label: {
            let name = StreamSettingsPresentation.preset(preset)
            let summary = preset.resolution.map { resolution in
                L(.settingsPresetSummary,
                  L(.commonDimensions, String(resolution.perEyeResolution.width),
                    String(resolution.perEyeResolution.height)), Int64(preset.megabits))
            } ?? L(.settingsCustomHelp)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(name).font(TB.Typography.body.weight(.semibold)).lineLimit(1).help(name)
                    // The same lava dot marks the recommendation line under the grid.
                    if recommended {
                        PixelIcon(glyph: .dot, size: 6, color: TB.lavaText)
                            .help(L(.settingsRecommendedShort))
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    if selected { PixelIcon(glyph: .check, size: 8, color: TB.lavaText) }
                }
                Text(summary).font(TB.Typography.caption).foregroundStyle(TB.textSecondary)
                    .lineLimit(1).minimumScaleFactor(0.85).help(summary)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? TB.selectionFill : TB.cardBackground, in: shape)
            .overlay(shape.strokeBorder(selected ? TB.lavaText : TB.cardBorder))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
        .focused($focusedPreset, equals: preset)
        .focusEffectDisabled()
        .overlay {
            if focusedPreset == preset && !selected {
                shape.strokeBorder(TB.textSecondary, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .onKeyPress(.return) { settings.selectQuality(preset); return .handled }
        .onKeyPress(.space) { settings.selectQuality(preset); return .handled }
        .accessibilityAddTraits(selected ? .isSelected : [])
        // The lava dot is a state, not usage advice: read it as the value,
        // which VoiceOver speaks at once (hints come late or not at all).
        .accessibilityValue(recommended ? L(.settingsRecommendedShort) : "")
    }

    private var hasBlackHole: Bool {
        audioDevices.contains { $0.name.localizedCaseInsensitiveContains("BlackHole") }
    }

    /// The Mac's own audio, BlackHole devices and Off. Other inputs, such
    /// as microphones, are not offered; one chosen earlier stays listed.
    private var audioPicker: some View {
        Picker(selection: $settings.gameAudioChoice) {
            // Always tagged, so a stored choice of the Mac's own audio
            // matches a row even on a macOS that cannot capture it.
            Text(GameAudioSource.macAudioSupported ? L(.settingsMacAudio)
                 : L(.settingsAudioUnavailable, L(.settingsMacAudio)))
                .tag(GameAudioChoice.mac)
            ForEach(audioDevices.filter { isLoopback($0.name) || isSelectedDevice($0.name) },
                    id: \.id) { device in
                Text(L(.settingsAudioDevice, device.name, Int64(device.sampleRate)))
                    .tag(GameAudioChoice.device(device.name))
            }
            if case .device(let name) = settings.gameAudioChoice,
               !audioDevices.contains(where: { $0.name == name }) {
                Text(L(.settingsAudioUnavailable, name)).tag(GameAudioChoice.device(name))
            }
            Text(L(.streamFilterOff)).tag(GameAudioChoice.off)
        } label: {
            LabelWithHelp(title: L(.settingsGameAudio), badge: .gameAudio)
        }
    }

    private func isLoopback(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("BlackHole")
    }

    private func isSelectedDevice(_ name: String) -> Bool {
        settings.gameAudioChoice == .device(name)
    }

    /// Snaps to 5 Mbps without the tick marks a stepped slider would draw.
    private var bitrate: Binding<Double> {
        Binding(
            get: { Double(settings.megabits) },
            set: { settings.megabits = Int(($0 / 5).rounded()) * 5 })
    }
}

/// Labels at the presentation boundary leave persisted values and Kit tests unchanged.
private enum StreamSettingsPresentation {
    static func preset(_ value: StreamQualityPreset) -> String {
        switch value {
        case .performance: L(.libraryPresetPerformance)
        case .balanced: L(.libraryPresetBalanced)
        case .quality: L(.libraryPresetQuality)
        case .high: L(.libraryPresetHigh)
        case .maximum: L(.libraryPresetMaximum)
        case .custom: L(.libraryPresetCustom)
        }
    }

    static func filter(_ value: HeadsetFilterLevel) -> String {
        switch value {
        case .off: L(.streamFilterOff)
        case .normal: L(.streamFilterNormal)
        case .quality: L(.streamFilterQuality)
        }
    }

    static func encoderMode(_ value: EncoderRateMode) -> String {
        switch value {
        case .auto: L(.encoderModeAuto)
        case .lowLatency: L(.encoderModeLowLatency)
        case .moreFrames: L(.encoderModeMoreFrames)
        }
    }

    static func resolution(_ value: ResolutionSelection) -> String {
        let key: L10nKey
        switch value {
        case .performance: key = .libraryPresetPerformance
        case .balanced: key = .libraryPresetBalanced
        case .quality: key = .libraryPresetQuality
        case .high: key = .libraryPresetHigh
        case .maximum: key = .libraryPresetMaximum
        case .questNative: key = .resolutionQuestNative
        case .questNative125: key = .resolutionQuestNative125
        case .questNative150: key = .resolutionQuestNative150
        }
        return L(.settingsResolutionValue, L(key),
                 L(.commonDimensions, String(value.perEyeResolution.width), String(value.perEyeResolution.height)))
    }
}

private extension AppAppearance {
    var titleKey: L10nKey {
        switch self {
        case .system: .settingsAppearanceSystem
        case .light: .settingsAppearanceLight
        case .dark: .settingsAppearanceDark
        }
    }
}

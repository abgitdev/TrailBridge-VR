import SwiftUI
import BasaltManagerKit

struct SetupView: View {
    @ObservedObject var model: BasaltAppModel

    private var required: [SetupCheck] { model.setupChecks.filter(\.required) }
    private var optional: [SetupCheck] { model.setupChecks.filter { !$0.required } }
    private var readyCount: Int { model.setupChecks.filter { $0.status == .ready }.count }
    private var ready: Bool { !model.setupChecks.isEmpty && model.missingRequiredSetupCount == 0 }
    private var progressText: String { L(.setupProgress, Int64(readyCount), Int64(model.setupChecks.count)) }

    var body: some View {
        TBManagementPage {
            summary
            checklist(required, title: L(.setupRequired), footer: L(.setupRequiredHelp))
            checklist(optional, title: L(.setupOptional), footer: L(.setupOptionalHelp))
        }
        .tourScrollsToTarget(on: .setup)
        .tint(TB.lava)
        .navigationTitle(L(.sidebarSetup))
        .navigationSubtitle(progressText)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TBPixelTile(glyph: .setup, color: ready ? TB.successText : TB.lavaText)
                Text(ready ? L(.setupReady) : L10n.plural(.setupStepsLeft, model.missingRequiredSetupCount))
                    .font(TB.Typography.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                ForEach(model.setupChecks) { check in
                    Rectangle()
                        .fill(check.status == .ready ? (ready ? TB.successText : TB.lava) : TB.hairline)
                        .frame(width: 10, height: 10)
                }
                Text(progressText).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(progressText)
            Text(guidance).foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if ready {
                // The Library is where a game is added; the Steam wizard and
                // the folder import make and prepare the environment themselves.
                Button(L(.streamOpenLibrary)) { model.selection = .library }
                    .buttonStyle(TBPrimaryButtonStyle())
            } else if let next = required.first(where: { $0.status != .ready && $0.action != nil }) {
                Button(actionTitle(next)) { Task { await model.installDependency(for: next) } }
                    .buttonStyle(TBPrimaryButtonStyle())
                    .disabled(model.isBusy || (next.offersWineDownload && model.wineInstall.isRunning))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
        .tourTarget(.chapter(.setupSummary))
    }

    private var guidance: String {
        if ready {
            return model.bottles.contains(where: \.isReadyForVR)
                ? L(.setupReadyGuidance) : L(.setupBottleGuidance)
        }
        return L(.setupMissingGuidance)
    }

    private func checklist(_ checks: [SetupCheck], title: String, footer: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title)
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    if check.id != checks.first?.id { TBRowDivider() }
                    row(for: check)
                }
            }
            .cardStyle(padding: 0)
            Text(footer).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(for check: SetupCheck) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title(check)).font(TB.Typography.panelTitle)
                    .lineLimit(1).help(title(check))
                Spacer(minLength: 0)
                Chip(text: statusTitle(check), kind: check.status == .ready ? .success
                     : check.status == .unavailable ? .failed
                     : check.required || check.id == "gstreamer" ? .warning : .neutral)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        PathText(path: title(check))
                        if check.id == "audio", check.status == .ready,
                           check.detail.hasSuffix(" is available") {
                            PathText(path: String(check.detail.dropLast(" is available".count)))
                        }
                        if check.detail.hasPrefix("/") {
                            PathText(path: check.detail)
                        } else {
                            Text(technicalDetail(check)).textSelection(.enabled)
                        }
                        if check.id == "audio" {
                            Text(GameAudioSource.macAudioSupported ? L(.settingsMacAudioHelp)
                                 : check.status == .ready ? L(.settingsAudioRouting)
                                 : L(.settingsAudioInstallation))
                        }
                    }
                    .padding(.top, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(explanation(check)).lineLimit(1).help(explanation(check))
                        Spacer(minLength: 0)
                        Text(L(.commonDetails)).fixedSize()
                    }
                }
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                if check.offersWineDownload, model.wineInstall.isRunning {
                    Button(L(.commonCancel)) { model.cancelWineDownload() }
                        .buttonStyle(TBQuietButtonStyle(compact: true))
                } else if check.status != .ready, check.action != nil {
                    Button(actionTitle(check)) { Task { await model.installDependency(for: check) } }
                        .buttonStyle(TBQuietButtonStyle(compact: true)).disabled(model.isBusy)
                }
            }
            if check.offersWineDownload { wineInstallStatus }
            if check.id == "rosetta", check.status == .actionNeeded { rosettaInstructions }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title(check))
    }

    /// The Wine download while it runs, and why it failed when it did.
    @ViewBuilder private var wineInstallStatus: some View {
        switch model.wineInstall {
        case .idle:
            EmptyView()
        case .downloading(let received, let total):
            let size = total ?? PinnedWine.archiveBytes
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(min(received, size)), total: Double(max(size, 1)))
                Text(received == 0 ? L(.wineDownloadStarting)
                     : L(.wineDownloadProgress, byteCount(received), byteCount(size)))
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
        case .verifying:
            TBProgressIndicator(L(.wineDownloadVerifying))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
        case .unpacking:
            TBProgressIndicator(L(.wineDownloadUnpacking))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
        case .failed(let reason):
            Text(reason).font(TB.Typography.meta).foregroundStyle(TB.dangerText)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    /// What to do in Terminal; the app never installs Rosetta itself.
    private var rosettaInstructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(.setupRosettaInstall, L(.menuRefresh)))
                .fixedSize(horizontal: false, vertical: true)
            Text(Rosetta.installCommand).font(.caption.monospaced()).textSelection(.enabled)
        }
        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
    }

    private func byteCount(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(model.language.locale))
    }

    private func title(_ check: SetupCheck) -> String {
        switch check.id {
        case "mac": L(.setupMac)
        case "rosetta": L(.setupRosetta)
        case "wine": L(.setupEngine)
        case "gstreamer": L(.setupGStreamer)
        case "runtime": L(.setupRuntime)
        case "dxmt": L(.setupGraphics)
        case "screen": L(.setupScreen)
        case "adb": L(.setupADB)
        case "audio": L(.setupAudio)
        default: check.title
        }
    }

    private func explanation(_ check: SetupCheck) -> String {
        switch check.id {
        case "mac": L(.setupMacHelp)
        case "rosetta": L(.setupRosettaHelp)
        case "wine": L(.setupEngineHelp)
        case "gstreamer": L(.setupGStreamerHelp)
        case "runtime": L(.setupRuntimeHelp)
        case "dxmt": L(.setupGraphicsHelp)
        case "screen": L(.setupScreenHelp)
        case "adb": L(.setupADBHelp)
        case "audio": L(.setupAudioHelp)
        default: check.detail
        }
    }

    private func technicalDetail(_ check: SetupCheck) -> String {
        switch check.id {
        case "mac": check.status == .ready ? L(.setupMacHelp) : L(.setupMacUnsupported)
        // What to do when it is missing is on the row itself.
        case "rosetta": check.status == .ready ? L(.setupRosettaInstalled) : L(.setupRosettaHelp)
        case "wine":
            check.status == .ready ? L(.setupEngineAvailable)
                : check.offersWineDownload ? L(.setupEngineNotDownloaded, PinnedWine.download.version)
                : L(.setupEngineBuild)
        case "gstreamer":
            if check.status != .ready {
                L(.setupGStreamerInstall, L(.menuRefresh))
            } else if let version = model.setupGStreamerVersion {
                L(.setupGStreamerVersion, version)
            } else {
                L(.setupGStreamerInstalled)
            }
        case "runtime": L(.setupRuntimeBuild)
        case "dxmt": L(.setupGraphicsBuild)
        case "screen": check.status == .ready ? L(.setupScreenGranted) : L(.setupScreenPrivacy)
        case "adb": L(.setupADBHelp)
        case "audio":
            GameAudioSource.macAudioSupported ? L(.setupMacAudioAvailable)
                : check.status == .ready ? L(.setupAudioAvailable) : L(.environmentNotInstalled)
        default: check.detail
        }
    }

    private func actionTitle(_ check: SetupCheck) -> String {
        switch check.id {
        case "screen": L(.setupAllow)
        case "adb": L(.headsetGetTools)
        case "audio": L(.settingsGetBlackHole)
        case "rosetta": model.rosettaCommandCopied ? L(.diagnosticsCopied) : L(.setupRosettaCopy)
        case "wine" where check.offersWineDownload:
            if case .failed = model.wineInstall { L(.dataFolderRetry) } else { model.wineDownloadTitle }
        case "gstreamer": L(.setupGStreamerPackage)
        case "wine", "runtime", "dxmt": L(.setupBuildHelp)
        default: check.action ?? ""
        }
    }

    private func statusTitle(_ check: SetupCheck) -> String {
        switch check.status {
        case .ready: L(.setupCheckReady)
        case .actionNeeded where check.id == "gstreamer": L(.setupGStreamerMissing)
        case .actionNeeded: check.required ? L(.setupCheckNeeded) : L(.setupCheckOptional)
        case .unavailable: L(.setupCheckUnavailable)
        }
    }

}

/// Says what the Wine download is, how large, where it comes from and
/// where it goes, before anything is downloaded.
struct WineDownloadSheet: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TBManagementSheet(glyph: .setup,
                          title: L(.wineDownloadTitle, PinnedWine.download.version)) {
            Text(L(.wineDownloadExplanation))
            Text(L(.wineDownloadSize, PinnedWine.archiveSizeText, PinnedWine.unpackedSizeText))
            Link(L(.wineDownloadRelease, PinnedWine.download.version),
                 destination: PinnedWine.releasePage)
                .foregroundStyle(TB.link)
            VStack(alignment: .leading, spacing: 8) {
                Text(L(.wineDownloadFolder))
                PathText(path: model.dataRoot.path)
                // The folder is chosen where it always is, with its checks.
                Button(L(.wineDownloadOtherFolder)) {
                    dismiss()
                    model.selection = .settings
                }
                .buttonStyle(TBQuietButtonStyle(compact: true))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 14)
            PinnedDownloadMetadata(download: PinnedWine.download)
        } actions: {
            Spacer(minLength: 0)
            Button(L(.commonCancel)) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L(.headsetDownloadInstall)) {
                dismiss()
                model.startWineDownload()
            }
            .buttonStyle(TBPrimaryButtonStyle())
        }
        .frame(width: 640, height: 560)
    }
}

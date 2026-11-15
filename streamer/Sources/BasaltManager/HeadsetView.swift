import SwiftUI
import BasaltCore
import BasaltManagerKit

struct HeadsetView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var confirmingTrustReset = false

    var body: some View {
        TBManagementPage {
            statusCard
            // Only when the download is the fix: not before the first
            // answer, and not for an error of another kind.
            if model.headsetTools == .missing {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(L(.headsetUSBTools))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L(.headsetToolsExplanation))
                        Button(L(.headsetGetTools)) { model.headsetConfirmation = .platformTools }
                            .buttonStyle(TBPrimaryButtonStyle()).disabled(model.headsetProgress != nil)
                            .tourTarget(.chapter(.headsetGetTools), onAccent: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 14)
                }
            }
            if model.headsetStatus.connection != .connected {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(L(.headsetConnect))
                    VStack(spacing: 0) {
                        if model.headsetStatus.connection != .unauthorized {
                            setupStep(1, text: L(.headsetDeveloperMode))
                            TBRowDivider()
                            setupStep(2, text: L(.headsetDataCable))
                            TBRowDivider()
                        }
                        setupStep(3, text: L(.headsetAllowDebugging))
                    }
                    .cardStyle(padding: 0)
                }
            }
            if model.headsetStatus.connection == .connected {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(L(.headsetClient))
                    VStack(alignment: .leading, spacing: 12) {
                        if model.headsetStatus.clientVersion != PinnedHeadsetDownload.testedALVR.version {
                            Text(L(.headsetInstallExplanation, PinnedHeadsetDownload.testedALVR.version))
                            Button(L(.headsetInstall)) { model.headsetConfirmation = .client }
                                .buttonStyle(TBPrimaryButtonStyle()).disabled(model.headsetProgress != nil)
                                .tourTarget(.chapter(.headsetInstall), onAccent: true)
                        }
                        if model.headsetStatus.clientInstalled {
                            Text(L(.headsetOpenClient))
                            Text(L(.headsetWiFiGuidance))
                                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 14)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(L(.headsetTrusted), count: model.trustedHeadsets.count)
                Text(L(.headsetTrustExplanation)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                VStack(spacing: 0) {
                    if model.trustedHeadsetsUnreadable {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 10) {
                                PixelIcon(glyph: .warning, size: 18, color: TB.warningText)
                                    .accessibilityHidden(true)
                                Text(L(.headsetTrustUnreadable, HeadsetTrustStore.fileName))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Button(L(.headsetTrustReset)) { confirmingTrustReset = true }
                                .buttonStyle(TBQuietButtonStyle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    } else if model.trustedHeadsets.isEmpty {
                        Text(L(.headsetNoTrusted)).foregroundStyle(TB.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(model.trustedHeadsets, id: \.self) { name in
                        if name != model.trustedHeadsets.first { TBRowDivider() }
                        HStack(spacing: 12) {
                            TBPixelTile(glyph: .headset, color: TB.iconIdle, size: 34)
                            Text(name).font(.system(size: 13.5, weight: .semibold))
                                .lineLimit(2).help(name)
                            Spacer(minLength: 0)
                            Button(L(.headsetForget), role: .destructive) { model.setHeadsetTrusted(name, trusted: false) }
                                .buttonStyle(TBQuietButtonStyle())
                                .accessibilityLabel(L(.headsetForgetNamed, name))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
                .cardStyle(padding: 0)
                Text(L(.headsetForgetFootnote)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
        }
        .confirmationDialog(L(.headsetTrustResetQuestion), isPresented: $confirmingTrustReset,
                            titleVisibility: .visible) {
            Button(L(.headsetTrustResetConfirm), role: .destructive) { model.resetTrustedHeadsets() }
            Button(L(.commonCancel), role: .cancel) {}
        } message: {
            Text(L(.headsetTrustResetWarning))
        }
        .tourScrollsToTarget(on: .headset)
        .navigationTitle(L(.sidebarHeadset))
        .navigationSubtitle(statusTitle)
        .task(id: model.dataRoot) {
            while !Task.isCancelled {
                await model.refreshHeadset()
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                TBPixelTile(glyph: .headset,
                            color: model.headsetStatus.connection == .connected ? TB.successText : TB.iconIdle,
                            size: 48)
                VStack(alignment: .leading, spacing: 8) {
                    Text(statusTitle).font(.system(size: 22, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Chip(text: model.headsetStatus.connection == .connected ? L(.headsetUSBConnected) : L(.headsetUSBDisconnected),
                         kind: model.headsetStatus.connection == .connected ? .success : .neutral)
                }
                Spacer(minLength: 0)
            }
            if model.headsetStatus.connection == .connected {
                if model.headsetStatus.clientInstalled {
                    let version = model.headsetStatus.clientVersion ?? L(.headsetUnknownVersion)
                    Text(version == PinnedHeadsetDownload.testedALVR.version
                         ? L(.headsetClientInstalled, version)
                         : L(.headsetClientVersion, version, PinnedHeadsetDownload.testedALVR.version))
                        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                } else {
                    Chip(text: L(.headsetClientMissing), kind: .warning)
                }
                if let name = model.headsetStatus.model {
                    DisclosureGroup(L(.commonDetails)) {
                        Text(name).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                            .textSelection(.enabled).padding(.top, 4)
                    }
                }
            }
            // Missing tools are not an error: the tools block below says
            // what to do, and the wrapper's own text would only confuse.
            if let error = model.headsetScanError, model.headsetTools != .missing { errorMessage(error) }
            if let error = model.headsetError { errorMessage(error) }
            if let progress = model.headsetProgress {
                TBProgressIndicator(progressText(progress)).foregroundStyle(TB.warningText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 14)
        .tourTarget(.chapter(.headsetStatus))
    }

    private func errorMessage(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Chip(text: L(.commonError), kind: .failed)
            Text(L(.headsetErrorGuidance)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            DisclosureGroup(L(.commonDetails)) {
                Text(error).foregroundStyle(TB.dangerText).textSelection(.enabled)
            }
        }
    }

    private func setupStep(_ number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PixelNumberTile(number: number)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(.headsetNumberedStep, Int64(number), text))
    }

    private var statusTitle: String {
        switch model.headsetTools {
        // Nothing was asked yet: the status is a placeholder.
        case .checking: return L(.learningChecking)
        case .missing: return L(.headsetToolsNeeded)
        case .failed, .ready:
            switch model.headsetStatus.connection {
            // The first question failed, and not for want of the tools.
            case .noTools: return L(.learningCheckFailed)
            case .none: return L(.headsetNotConnected)
            case .unauthorized: return L(.headsetApprovalNeeded)
            case .connected: return L(.headsetConnected)
            }
        }
    }

    // Model diagnostics remain untouched; translate its known progress messages at the UI boundary.
    private func progressText(_ value: String) -> String {
        switch value {
        case "Downloading Platform Tools from Google…": L(.headsetDownloadingTools)
        case "Downloading tested ALVR client…": L(.headsetDownloadingClient)
        case "Verified download. Preparing USB tools…": L(.headsetPreparingTools)
        case "Verified download. Installing ALVR on headset…": L(.headsetInstallingClient)
        default: value
        }
    }
}

private struct PixelNumberTile: View {
    let number: Int

    private var bitmap: PixelBitmap {
        switch number {
        case 1: PixelBitmap(["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."])
        case 2: PixelBitmap([".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"])
        default: PixelBitmap(["####.", "....#", "....#", ".###.", "....#", "....#", "####."])
        }
    }

    var body: some View {
        bitmap.path(in: CGRect(x: 0, y: 0, width: 10, height: 14))
            .fill(TB.lavaText, style: FillStyle(antialiased: false))
            .frame(width: 10, height: 14)
            .frame(width: 32, height: 32)
            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

enum HeadsetConfirmation: String, Identifiable {
    case platformTools, client, replaceClient
    var id: String { rawValue }
}

struct HeadsetRequestSheet: View {
    let request: HeadsetRequest
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TBManagementSheet(glyph: .headset, title: L(.headsetRequestTitle, request.hostname)) {
            Text(L(.headsetRequestExplanation))
            Text(L(.headsetRequestAddress, request.ip))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle(padding: 14)
        } actions: {
            Spacer(minLength: 0)
            Button(L(.headsetDeny)) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(L(.headsetAllow)) {
                model.setHeadsetTrusted(request.hostname, trusted: true)
                dismiss()
            }.buttonStyle(TBPrimaryButtonStyle())
        }
        .frame(width: 520, height: 320)
    }
}

struct HeadsetDownloadSheet: View {
    let confirmation: HeadsetConfirmation
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TBManagementSheet(glyph: .headset, title: title) {
            if confirmation == .platformTools {
                Text(L(.headsetToolsDownloadExplanation, PinnedHeadsetDownload.platformTools.version))
                Link(L(.headsetGoogleTerms), destination: PinnedHeadsetDownload.googleTerms)
                    .foregroundStyle(TB.link)
            } else if confirmation == .client {
                Text(L(.headsetClientDownloadExplanation, PinnedHeadsetDownload.testedALVR.version))
                Link(L(.headsetALVRRelease), destination: URL(string: "https://github.com/alvr-org/ALVR/releases/tag/v20.14.1")!)
                    .foregroundStyle(TB.link)
            } else {
                Text(L(.headsetReplaceWarning))
                DisclosureGroup(L(.commonDetails)) {
                    Text(model.headsetReplacementReason).font(TB.Typography.meta)
                        .foregroundStyle(TB.textSecondary).textSelection(.enabled).padding(.top, 4)
                }
            }
            PinnedDownloadMetadata(download: download)
        } actions: {
            Spacer(minLength: 0)
            Button(L(.commonCancel)) { dismiss() }.keyboardShortcut(.cancelAction)
            Button(confirmation == .replaceClient ? L(.headsetReplaceAction)
                   : confirmation == .platformTools ? L(.headsetAgreeDownload) : L(.headsetDownloadInstall)) {
                dismiss()
                Task { await model.performHeadsetSetup(confirmation) }
            }.buttonStyle(TBPrimaryButtonStyle())
        }
        .frame(width: 640, height: 480)
    }

    private var download: PinnedHeadsetDownload {
        confirmation == .platformTools ? .platformTools : .testedALVR
    }

    private var title: String {
        switch confirmation {
        case .platformTools: L(.headsetToolsDownloadTitle)
        case .client: L(.headsetClientDownloadTitle)
        case .replaceClient: L(.headsetReplaceTitle)
        }
    }
}

/// The file, its address and its checksum, for a download sheet.
struct PinnedDownloadMetadata: View {
    let download: PinnedHeadsetDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(.headsetDownloadFile, download.url.lastPathComponent))
                .font(TB.Typography.meta).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(L(.headsetDownloadSource)).font(TB.Typography.meta)
            Link(destination: download.url) {
                Text(download.url.absoluteString)
                    .lineLimit(2).truncationMode(.middle).help(download.url.absoluteString)
            }
            .foregroundStyle(TB.link)
            Text(L(download.digest == .sha256 ? .headsetDownloadSHA256 : .headsetDownloadSHA1,
                   download.checksum))
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }
}

extension BasaltAppModel {
    var headsetTrustStore: HeadsetTrustStore {
        HeadsetTrustStore(dataRoot: dataRoot)
    }

    /// The Headset page's polling has had an answer in this data folder.
    var headsetChecked: Bool { headsetCheckedRoot == dataRoot }

    /// The USB tools, by the rule the "Headset" chapter and the Setup check
    /// share.
    var headsetTools: HeadsetTools {
        HeadsetTools(checked: headsetChecked, connection: headsetStatus.connection,
                     scanError: headsetScanError)
    }

    func refreshHeadset() async {
        guard headsetProgress == nil else { return }
        let root = dataRoot
        let result = await Task.detached { Result { try HeadsetSetup(dataRoot: root).inspect() } }.value
        guard root == dataRoot, !Task.isCancelled else { return }
        switch result {
        case .success(let status): headsetStatus = status; headsetScanError = nil
        case .failure(let error):
            // The tools live in the data folder: when its disk has left,
            // the window says that instead of an error of the USB tools.
            if await dataFolderHasGone() { return }
            headsetScanError = error.localizedDescription
        }
        // The first answer, good or bad, ends "Checking…".
        if headsetCheckedRoot != root { headsetCheckedRoot = root }
        do {
            trustedHeadsets = try headsetTrustStore.load()
            if trustedHeadsetsUnreadable { trustedHeadsetsUnreadable = false }
        } catch is HeadsetTrustStore.Unreadable {
            // Not a failure of the USB tools: the list's own block says it.
            if !trustedHeadsets.isEmpty { trustedHeadsets = [] }
            if !trustedHeadsetsUnreadable { trustedHeadsetsUnreadable = true }
        } catch { headsetScanError = error.localizedDescription }
    }

    func setHeadsetTrusted(_ name: String, trusted: Bool) {
        do {
            try headsetTrustStore.setTrusted(name, trusted: trusted)
            trustedHeadsets = try headsetTrustStore.load()
            headsetRequests.removeAll { $0.hostname == name }
        } catch let error as HeadsetTrustStore.Unreadable {
            trustedHeadsetsUnreadable = true
            alertMessage = L10n.string(.headsetTrustUnreadable, error.file.lastPathComponent)
        } catch { present(error) }
    }

    /// Replaces a list of trusted headsets that cannot be read with an
    /// empty one; every headset then asks for approval again.
    func resetTrustedHeadsets() {
        do {
            try headsetTrustStore.reset()
            trustedHeadsets = []
            trustedHeadsetsUnreadable = false
        } catch { present(error) }
    }

    func performHeadsetSetup(_ action: HeadsetConfirmation) async {
        guard headsetProgress == nil else { return }
        let root = dataRoot
        let setup = HeadsetSetup(dataRoot: root)
        headsetError = nil
        headsetProgress = action == .platformTools ? "Downloading Platform Tools from Google…" : "Downloading tested ALVR client…"
        defer { headsetProgress = nil }
        do {
            if action == .platformTools {
                let directory = try HeadsetSetup.directory("Tools", in: root)
                let zip = try await HeadsetSetup.download(.platformTools, into: directory)
                headsetProgress = "Verified download. Preparing USB tools…"
                try await Task.detached { try setup.installPlatformTools(zip: zip) }.value
            } else {
                // Capture and keep the selected USB serial across the operation.
                let selectedSerial = action == .replaceClient ? headsetInstallSerial : headsetStatus.serial
                guard let serial = selectedSerial else { throw BasaltError("Connect and authorize your headset first.") }
                headsetInstallSerial = serial
                let directory = try HeadsetSetup.directory("Downloads/ALVR", in: root)
                let apk: URL
                if action == .replaceClient { apk = directory.appendingPathComponent(PinnedHeadsetDownload.testedALVR.url.lastPathComponent) }
                else { apk = try await HeadsetSetup.download(.testedALVR, into: directory) }
                headsetProgress = "Verified download. Installing ALVR on headset…"
                try await Task.detached {
                    try setup.installClient(apk: apk, serial: serial, replacingOldClient: action == .replaceClient)
                }.value
            }
            headsetProgress = nil
            await refreshHeadset()
            await refresh()
        } catch let error as HeadsetInstallError {
            headsetReplacementReason = error.localizedDescription
            headsetConfirmation = .replaceClient
        } catch { headsetError = error.localizedDescription }
    }
}

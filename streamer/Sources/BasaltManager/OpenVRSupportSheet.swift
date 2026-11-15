import SwiftUI
import BasaltBottleKit
import BasaltManagerKit

struct OpenVRSupportSheet: View {
    let profile: LaunchProfile
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var targets = [URL]()
    @State private var selected: URL?
    @State private var artifact: OpenCompositeArtifact?
    @State private var error: String?
    @State private var isBusy = false
    @State private var confirmingDownload = false
    @State private var architecture: OpenCompositeArchitecture?
    @State private var installed = false
    @State private var details = false
    @State private var inspectedTargets = false

    private var locked: Bool { isBusy || model.sessionState.isActive }
    private var status: String {
        if !inspectedTargets { return L(.openVRNotChecked) }
        if error != nil { return L(.openVRUnavailable) }
        if targets.isEmpty { return L(.openVRNotNeeded) }
        if selected == nil { return L(.openVRSelectDLL) }
        return installed ? L(.environmentInstalled) : L(.environmentNotInstalled)
    }

    var body: some View {
        SheetScaffold(symbol: "puzzlepiece.extension", title: L(.openVRTitle), subtitle: model.gameTitle(forProfile: profile.name)) {
            Form {
                Section {
                    HStack {
                        Chip(text: isBusy ? L(.openVRProgress) : status,
                             kind: isBusy ? .progress : error != nil ? .failed
                             : !inspectedTargets ? .unverified : installed ? .success : selected == nil && !targets.isEmpty ? .warning : .neutral)
                        Spacer(minLength: 8)
                        LearningHelpBadgeButton(badge: .openVR)
                    }
                    Toggle(isOn: Binding(get: { installed }, set: { enabled in
                        if enabled {
                            if let artifact { install(artifact) }
                            else { confirmingDownload = true }
                        } else { uninstall() }
                    })) {
                        Text(L(.openVRTitle)).font(TB.Typography.cardTitle)
                        Text(installed ? L(.openVROn) : L(.streamFilterOff)).foregroundStyle(TB.textSecondary)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .padding(.vertical, 8)
                    .disabled(locked || selected == nil || (!installed && architecture == nil))
                    Text(L(.openVRExplanation))
                        .tbFormFooterStyle()
                    // Steam started by the app keeps the switch locked, and
                    // closing its window only hides it: say so and offer Stop.
                    if model.sessionState.isActive && !isBusy {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(L(.openVRLockedWhileRunning))
                                .foregroundStyle(TB.warningText)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button(L(.commonStop)) { model.stop() }
                                .buttonStyle(TBQuietButtonStyle(compact: true))
                                .fixedSize()
                        }
                    }
                    if targets.count > 1, let selected {
                        Text(L(.openVRSelected, relativePath(selected)))
                            .tbFormFooterStyle()
                    }
                    if targets.isEmpty && error == nil {
                        Text(L(.openVRNoDLL))
                            .tbFormFooterStyle()
                    }
                }
                DisclosureGroup(L(.commonDetails), isExpanded: $details) {
                    LabeledContent(L(.openVRStatus), value: status)
                    if !targets.isEmpty {
                        Picker(L(.openVRGameDLL), selection: $selected) {
                            Text(L(.openVRChooseDLL)).tag(URL?.none)
                            ForEach(targets, id: \.self) { target in
                                Text(relativePath(target)).tag(URL?.some(target))
                            }
                        }
                        .disabled(locked)
                        if targets.count > 1 {
                            Text(L(.openVRMultipleDLLs))
                                .tbFormFooterStyle()
                        }
                        if let selected {
                            PathText(path: relativePath(selected))
                        }
                        if let architecture {
                            LabeledContent(L(.openVRArchitecture), value: architecture.rawValue)
                        }
                    }
                    if selected != nil {
                        FlowLayout(spacing: 8) {
                            Button(L(.openVRDownloadOfficial)) { confirmingDownload = true }
                                .disabled(architecture == nil || locked)
                            Button(L(.openVRChooseFile)) { chooseFile() }
                                .disabled(architecture == nil || locked)
                        }
                        .buttonStyle(TBQuietButtonStyle(compact: true))
                        if let artifact {
                            LabeledContent(L(.openVRFileSize), value:
                                artifact.size.formatted(.byteCount(style: .file).locale(L10n.language.locale)))
                            Text(L(.openVRChecksum, artifact.sha256))
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(L(.openVRMatches))
                                .tbFormFooterStyle()
                            if installed {
                                Button(L(.openVRReplaceDLL)) { install(artifact) }
                                    .disabled(locked)
                            }
                        }
                        Text(L(.openVRRestore))
                            .tbFormFooterStyle()
                    }
                }
                if let error {
                    DisclosureGroup(L(.commonDetails)) {
                        Text(error).foregroundStyle(TB.dangerText).textSelection(.enabled)
                    }
                }
            }
            .tbGroupedForm()
        } actions: {
            Spacer()
            Button(L(.sheetDone)) { dismiss() }
                .keyboardShortcut(.cancelAction).buttonStyle(TBPrimaryButtonStyle()).disabled(isBusy)
        }
        .frame(width: 700, height: 560)
        .interactiveDismissDisabled(isBusy)
        .onAppear { refresh() }
        .onChange(of: selected) { _, _ in
            artifact = nil
            inspectSelection()
        }
        .sheet(isPresented: $confirmingDownload) { downloadConfirmation }
    }

    private var downloadConfirmation: some View {
        SheetScaffold(symbol: "arrow.down.circle", title: L(.openVRDownloadTitle)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L(.openVROfficialOnly))
                    if let architecture {
                        PathText(path: OpenCompositeDownload.officialURL(for: architecture).absoluteString)
                            .textSelection(.enabled)
                        Text(L(.openVRDownloadHelp, architecture.rawValue))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
            }
        } actions: {
            Button(L(.commonCancel)) { confirmingDownload = false }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(L(.openVRDownloadEnable)) { download() }
                .buttonStyle(TBPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
        .frame(width: 660, height: 380)
    }

    private func relativePath(_ url: URL) -> String {
        guard let bottle = model.bottles.first(where: { $0.name == profile.bottleName }) else {
            return url.lastPathComponent
        }
        let prefix = URL(fileURLWithPath: bottle.prefixPath).standardizedFileURL.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func refresh() {
        defer { inspectedTargets = true }
        do {
            targets = try model.manager.openVRTargets(profileName: profile.name)
            if let selected, !targets.contains(selected) { self.selected = nil }
            if selected == nil {
                selected = targets.first(where: {
                    (try? model.manager.isOpenComposite(at: $0)) == true
                }) ?? targets.first
            }
            error = nil
            inspectSelection()
        } catch { self.error = error.localizedDescription }
    }

    private func inspectSelection() {
        architecture = nil
        installed = false
        error = nil
        guard let selected else { return }
        do {
            installed = try model.manager.isOpenComposite(at: selected)
            architecture = try OpenCompositeArchitecture.dllArchitecture(in: Data(contentsOf: selected))
        } catch { self.error = error.localizedDescription }
    }

    private func chooseFile() {
        guard let file = FilePanels.chooseFile(
            title: L(.openVRChooseFileTitle), extensions: ["dll"]) else { return }
        do {
            let bytes = try Data(contentsOf: file)
            guard try OpenCompositeArchitecture.dllArchitecture(in: bytes) == architecture else {
                throw BottleToolError(L(.openVRArchitectureMismatch))
            }
            artifact = OpenCompositeArtifact(file: file, data: bytes)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func download() {
        guard let architecture else { return }
        confirmingDownload = false
        isBusy = true
        error = nil
        Task { @MainActor in
            defer { isBusy = false }
            do {
                artifact = try await OpenCompositeDownload.download(
                    architecture: architecture, dataRoot: model.dataRoot)
                if let artifact, let selected {
                    _ = try model.manager.installOpenComposite(
                        profileName: profile.name, artifact: artifact.file, targetDLL: selected)
                    refresh()
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func install(_ artifact: OpenCompositeArtifact) {
        guard let selected, !locked else { return }
        do {
            _ = try model.manager.installOpenComposite(
                profileName: profile.name, artifact: artifact.file, targetDLL: selected)
            refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func uninstall() {
        guard let selected, !locked else { return }
        do {
            try model.manager.uninstallOpenComposite(profileName: profile.name, targetDLL: selected)
            artifact = nil
            refresh()
        } catch { self.error = error.localizedDescription }
    }
}

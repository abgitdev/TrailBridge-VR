import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

struct PerGameSettingsSheet: View {
    let profileName: String
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: StreamLaunchSettings

    init(profileName: String, model: BasaltAppModel) {
        self.profileName = profileName
        self.model = model
        _settings = State(initialValue: model.streamSettings(for: profileName))
    }

    private var hasOverride: Bool { model.profileSettings[profileName] != nil }

    var body: some View {
        SheetScaffold(
            symbol: "slider.horizontal.3", title: L(.sheetPerGameTitle, model.gameTitle(forProfile: profileName)),
            subtitle: hasOverride ? L(.sheetOwnSettings) : L(.sheetGlobalSettings)
        ) {
            Form {
                Section {
                    TBFormHeader {
                        Text(hasOverride ? L(.sheetOwnSettings) : L(.sheetGlobalSettings))
                            .font(TB.Typography.cardTitle)
                            .accessibilityAddTraits(.isHeader)
                        Text(hasOverride ? L(.sheetOverrideHelp) : L(.sheetGlobalHelp))
                            .foregroundStyle(TB.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    StreamSettingsFields(settings: $settings, audioDevices: model.audioDevices,
                                         recommendation: model.qualityRecommendation)
                }
            }
            .tbGroupedForm()
        } actions: {
            Button(L(.sheetUseGlobal)) {
                model.resetStreamSettings(for: profileName)
                dismiss()
            }
            .disabled(!hasOverride)
            Spacer()
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L(.sheetSave)) {
                model.saveStreamSettings(settings, for: profileName)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(TBPrimaryButtonStyle())
        }
        .frame(width: 660, height: 560)
    }
}

struct ProfileEditorSheet: View {
    let profile: LaunchProfile
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: LaunchSource
    @State private var executable: String
    @State private var workingDirectory: String
    @State private var gameRoot: String
    @State private var arguments: String
    @State private var environment: String
    @State private var confirmingDelete = false
    @State private var showingOpenVR = false

    init(profile: LaunchProfile, model: BasaltAppModel) {
        self.profile = profile
        self.model = model
        _source = State(initialValue: profile.source)
        _executable = State(initialValue: profile.executable)
        _workingDirectory = State(initialValue: profile.workingDirectory ?? "")
        _gameRoot = State(initialValue: profile.gameRoot ?? "")
        _arguments = State(initialValue: profile.arguments.joined(separator: "\n"))
        _environment = State(initialValue: profile.environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        SheetScaffold(
            symbol: "doc.text",
            title: L(.sheetProfileTitle),
            subtitle: L(.sheetIdentity, profile.name, profile.bottleName)
        ) {
            Form {
                Section {
                    Picker(L(.sheetSource), selection: $source) {
                        ForEach(LaunchSource.allCases, id: \.self) {
                            Text(sourceTitle($0)).tag($0)
                        }
                    }
                    StackedField(title: L(.sheetExecutable), text: $executable,
                                 prompt: L(.sheetExecutableExample))
                    StackedField(title: L(.sheetWorkingDirectory), text: $workingDirectory,
                                 prompt: L(.sheetOptionalFolder))
                    StackedField(title: L(.sheetGameFolder), text: $gameRoot,
                                 prompt: L(.sheetGameFolderExample))
                }

                Section {
                    TextEditor(text: $arguments)
                        .accessibilityLabel(L(.sheetArguments))
                        .font(.body.monospaced())
                        .frame(minHeight: 60)
                } header: {
                    Text(L(.sheetArguments))
                } footer: {
                    Text(L(.sheetArgumentsHelp))
                        .tbFormFooterStyle()
                }

                Section {
                    TextEditor(text: $environment)
                        .accessibilityLabel(L(.sheetEnvironment))
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                } header: {
                    Text(L(.sheetEnvironment))
                } footer: {
                    Text(L(.sheetEnvironmentHelp))
                        .tbFormFooterStyle()
                }

                Section(L(.openVRTitle)) {
                    Button(L(.sheetManageOpenVR)) { showingOpenVR = true }
                    if gameRoot != (profile.gameRoot ?? "") {
                        Text(L(.sheetSaveGameFolder))
                            .tbFormFooterStyle()
                    }
                }
            }
            .tbGroupedForm()
        } actions: {
            Button(L(.sheetDeleteProfileMenu), role: .destructive) { confirmingDelete = true }
            Spacer()
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L(.sheetSave)) { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(TBPrimaryButtonStyle())
                .disabled(executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .frame(width: 660, height: 560)
        .sheet(isPresented: $showingOpenVR) {
            OpenVRSupportSheet(profile: profile, model: model)
        }
        .confirmationDialog(
            L(.sheetDeleteProfileQuestion, model.gameTitle(forProfile: profile.name)), isPresented: $confirmingDelete,
            titleVisibility: .visible) {
                Button(L(.sheetDeleteProfile), role: .destructive) {
                    Task { await model.deleteProfile(profile.name); dismiss() }
                }
                Button(L(.commonCancel), role: .cancel) {}
            } message: {
                Text(L(.sheetDeleteProfileHelp))
            }
    }

    private func sourceTitle(_ source: LaunchSource) -> String {
        switch source {
        case .direct: L(.libraryDirect)
        case .steam: L(.commonSteam)
        case .bsmanager: L(.commonBSManager)
        case .itch: L(.commonItch)
        }
    }

    private func save() {
        var values = [String: String]()
        for line in environment.components(separatedBy: .newlines) {
            guard let split = line.firstIndex(of: "="), split != line.startIndex else { continue }
            values[String(line[..<split])] = String(line[line.index(after: split)...])
        }
        // Start from the profile itself, so fields this sheet does not edit,
        // such as the title of a game added from a folder, are kept.
        var updated = profile
        updated.source = source
        updated.executable = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.arguments = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
        updated.workingDirectory = workingDirectory.isEmpty ? nil : workingDirectory
        updated.environment = values
        updated.gameRoot = gameRoot.isEmpty ? nil : gameRoot
        Task { await model.updateProfile(updated); dismiss() }
    }
}

struct ImportBottleSheet: View {
    let bottle: DiscoveredBottle
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isCopying = false

    init(bottle: DiscoveredBottle, model: BasaltAppModel) {
        self.bottle = bottle
        self.model = model
        let lowered = bottle.name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        _name = State(initialValue: String((lowered.isEmpty ? "imported-bottle" : lowered).prefix(56)))
    }

    var body: some View {
        SheetScaffold(
            symbol: "square.on.square",
            title: L(.sheetCopyTitle),
            subtitle: L(.sheetIdentity, bottle.name, bottle.origin.label)
        ) {
            Form {
                Section {
                    TextField(L(.sheetCopyName), text: $name)
                    LabeledContent(L(.sheetSource)) { PathText(path: bottle.prefix.path) }
                }
                Section {
                    Label(L(.sheetCopyOriginal), systemImage: "lock.shield")
                    Label(L(.sheetCopyAPFS), systemImage: "internaldrive")
                    Label(L(.sheetCopyPrepare), systemImage: "wrench.and.screwdriver")
                }
                .foregroundStyle(TB.textSecondary)
                if isCopying {
                    Chip(text: L(.sheetCopyProgress), kind: .progress)
                }
            }
            .tbGroupedForm()
            .disabled(isCopying)
        } actions: {
            Spacer()
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isCopying)
            Button(isCopying ? L(.sheetCopying) : L(.sheetCopyAction)) {
                let destination = name
                isCopying = true
                Task {
                    if await model.importBottle(bottle, as: destination) {
                        dismiss()
                    } else {
                        isCopying = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(TBPrimaryButtonStyle())
            .disabled(name.isEmpty || isCopying)
        }
        .frame(width: 620, height: 440)
        .interactiveDismissDisabled(isCopying)
    }
}

struct BSManagerInstallerSheet: View {
    let installer: URL
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottle = ""

    var body: some View {
        SheetScaffold(
            symbol: "arrow.down.circle",
            title: L(.sheetBSInstallTitle),
            subtitle: L(.sheetBSInstallHelp)
        ) {
            Form {
                Section {
                    LabeledContent(L(.sheetInstaller)) {
                        Text(installer.lastPathComponent).font(.callout.monospaced())
                    }
                    BottlePicker(selection: $selectedBottle, bottles: model.bottles)
                } footer: {
                    Text(L(.sheetBSIsolation))
                        .tbFormFooterStyle()
                }
            }
            .tbGroupedForm()
        } actions: {
            Spacer()
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L(.sheetRunInstaller)) {
                guard let bottle = model.bottles.first(where: {
                    $0.name == selectedBottle
                }) else { return }
                model.runBSManagerInstaller(installer, in: bottle)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(TBPrimaryButtonStyle())
            .disabled(selectedBottle.isEmpty)
        }
        .frame(width: 580, height: 360)
        .onAppear {
            if selectedBottle.isEmpty {
                selectedBottle = model.bsManagerInstallations.first?.bottleName
                    ?? (model.bottles.count == 1 ? model.bottles[0].name : "")
            }
        }
    }
}

struct BSManagerBottleSheet: View {
    let instance: BSManagerInstance
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottle = ""

    var body: some View {
        SheetScaffold(
            symbol: "wand.and.stars",
            title: L(.sheetBSProfileTitle),
            subtitle: L(.libraryBeatSaberVersion, instance.name)
        ) {
            if model.bottles.isEmpty {
                ContentUnavailableView(
                    L(.sheetNoBottle),
                    systemImage: "shippingbox",
                    description: Text(L(.sheetBSNoBottleHelp)))
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        BottlePicker(selection: $selectedBottle, bottles: model.bottles)
                    } footer: {
                        Text(L(.sheetBSBottleHelp))
                            .tbFormFooterStyle()
                    }
                }
                .tbGroupedForm()
            }
        } actions: {
            Spacer()
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(L(.libraryCreateProfile)) {
                guard let bottle = model.bottles.first(where: {
                    $0.name == selectedBottle
                }) else { return }
                Task {
                    await model.createBSManagerProfile(for: instance, in: bottle)
                    dismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(TBPrimaryButtonStyle())
            .disabled(selectedBottle.isEmpty)
        }
        .frame(width: 580, height: 360)
        .onAppear {
            if selectedBottle.isEmpty {
                selectedBottle = instance.bottleName
                    ?? (model.bottles.count == 1 ? model.bottles[0].name : "")
            }
        }
    }
}

/// Creates a launch profile for a Windows game Basalt does not find on its
/// own: GOG, itch.io, or anything installed with a plain installer.
struct AddGameSheet: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBottle = ""
    @State private var executable: URL?
    @State private var name = ""
    @State private var source = LaunchSource.direct
    @State private var arguments = ""
    @State private var isAdding = false

    private var bottle: ManagedBottle? {
        model.bottles.first { $0.name == selectedBottle }
    }

    private var prefix: URL? {
        bottle.map { URL(fileURLWithPath: $0.prefixPath, isDirectory: true) }
    }

    /// The chosen exe is not on the chosen bottle's C: drive.
    private var isOutsideBottle: Bool {
        guard let executable, let prefix else { return false }
        return !ManualGame.isInstalled(executable, inPrefix: prefix)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SheetScaffold(
            symbol: "plus.app",
            title: L(.libraryAddGame),
            subtitle: L(.sheetAddHelp)
        ) {
            if model.bottles.isEmpty {
                ContentUnavailableView(
                    L(.sheetNoBottle),
                    systemImage: "shippingbox",
                    description: Text(L(.sheetAddNoBottleHelp)))
                    .frame(maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        BottlePicker(selection: $selectedBottle, bottles: model.bottles)
                        LabeledContent(L(.streamGame)) {
                            HStack(spacing: 8) {
                                if let executable {
                                    PathText(path: executable.path)
                                }
                                Button(L(.sheetChooseGame)) { chooseGame() }
                                    .disabled(bottle == nil)
                            }
                        }
                        if isOutsideBottle {
                            Label(L(.sheetOutsideBottle, selectedBottle),
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(TB.dangerText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } footer: {
                        Text(L(.sheetChooseExeHelp))
                            .tbFormFooterStyle()
                    }

                    Section {
                        TextField(L(.sheetGameName), text: $name, prompt: Text(L(.sheetGameNamePrompt)))
                        Picker(L(.sheetSource), selection: $source) {
                            Text(L(.libraryDirect)).tag(LaunchSource.direct)
                            Text(L(.commonItch)).tag(LaunchSource.itch)
                        }
                        TextField(L(.sheetArguments), text: $arguments, prompt: Text(L(.sheetOptional)))
                            .font(.body.monospaced())
                    } footer: {
                        Text(L(.sheetSpaceArguments))
                            .tbFormFooterStyle()
                    }

                    Section {
                        Label(L(.sheetOpenVRHelp),
                              systemImage: "info.circle")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(TB.textSecondary)
                }
                .tbGroupedForm()
                .disabled(isAdding)
                .overlay(alignment: .bottomLeading) {
                    if isAdding {
                        Chip(text: L(.sheetAdding), kind: .progress).padding(20)
                    }
                }
            }
        } actions: {
            Spacer()
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isAdding)
            Button(L(.libraryAddGame)) { add() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(TBPrimaryButtonStyle())
                .disabled(bottle == nil || executable == nil || isOutsideBottle
                          || trimmedName.isEmpty || isAdding)
        }
        .frame(width: 660, height: 560)
        .interactiveDismissDisabled(isAdding)
        .onAppear {
            if selectedBottle.isEmpty, model.bottles.count == 1 {
                selectedBottle = model.bottles[0].name
            }
        }
    }

    private func chooseGame() {
        guard let prefix, let url = FilePanels.chooseFile(
            title: L(.sheetChooseExeTitle),
            message: L(.sheetChooseExeHelp),
            extensions: ["exe"],
            startingAt: prefix.appendingPathComponent("drive_c", isDirectory: true))
        else { return }
        executable = url
        name = ManualGame.suggestedName(for: url)
        source = ManualGame.inferredSource(for: url)
    }

    private func add() {
        guard let bottle, let executable else { return }
        isAdding = true
        Task {
            if await model.createGameProfile(
                named: trimmedName, executable: executable, source: source,
                arguments: ManualGame.arguments(from: arguments), in: bottle) {
                dismiss()
            } else {
                isAdding = false
            }
        }
    }
}

/// A full-width monospaced field under its label, for long Windows and host
/// paths that an inline form field would truncate.
private struct StackedField: View {
    let title: String
    @Binding var text: String
    var prompt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
        }
        .padding(.vertical, 2)
    }
}

private struct BottlePicker: View {
    @Binding var selection: String
    let bottles: [ManagedBottle]

    var body: some View {
        Picker(L(.sheetBottle), selection: $selection) {
            Text(L(.sheetSelectBottle)).tag("")
            ForEach(bottles, id: \.name) { bottle in
                Text(bottle.name).tag(bottle.name)
            }
        }
    }
}

// MARK: - Diagnostics

/// Shows exactly what a bug report contains before it is copied or saved.
/// The report is a snapshot taken when the sheet opens; nothing is sent.
struct DiagnosticReportSheet: View {
    let model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeLog = true
    @State private var report: DiagnosticReport?
    @State private var markdown = ""
    @State private var copied = false
    @State private var errorMessage: String?

    /// The folders this app run uses, which may not be the ones it was
    /// started with when the person chose another data folder.
    private var redactor: DiagnosticRedactor {
        DiagnosticRedactor(dataFolder: model.dataRoot.path, appFolder: model.repoRoot.path)
    }
    private static let bugReportURL = URL(
        string: "https://github.com/abgitdev/TrailBridge-VR/issues/new?template=bug_report.yml")!

    var body: some View {
        SheetScaffold(
            symbol: "stethoscope", title: L(.diagnosticsTitle),
            subtitle: L(.diagnosticsSubtitle)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if copied { Chip(text: L(.diagnosticsCopied), kind: .success) }
                if errorMessage != nil { Chip(text: L(.commonError), kind: .failed) }
                Toggle(L(.diagnosticsIncludeLog), isOn: $includeLog)
                SessionLogView(text: markdown, followsTail: false)
                    .accessibilityLabel(L(.diagnosticsReportPreview))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TB.sunkenBackground, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(TB.hairline))
                Text(L(.diagnosticsRedaction))
                    .tbFormFooterStyle()
            }
            .padding(20)
        } actions: {
            Button(L(.diagnosticsBugForm)) { NSWorkspace.shared.open(Self.bugReportURL) }
                .help(L(.diagnosticsBugFormHelp))
            Spacer()
            Menu {
                Button(L(.diagnosticsMarkdown)) { save(asJSON: false) }
                Button(L(.diagnosticsJSON)) { save(asJSON: true) }
            } label: {
                Text(L(.sheetSave))
                    .font(TB.Typography.body).foregroundStyle(TB.textPrimary)
                    .padding(.horizontal, 12).frame(height: TB.Size.quietButton)
                    .background(TB.quietFill, in: RoundedRectangle(cornerRadius: TB.Radius.quietButton))
                    .overlay(RoundedRectangle(cornerRadius: TB.Radius.quietButton).strokeBorder(TB.quietBorder))
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .disabled(report == nil)
            Button(copied ? L(.diagnosticsCopied) : L(.diagnosticsCopy)) {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(markdown, forType: .string)
            }
            .disabled(report == nil)
            Button(L(.sheetDone)) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(TBPrimaryButtonStyle())
        }
        .frame(width: 800, height: 560)
        .onAppear(perform: rebuild)
        .onChange(of: includeLog) { rebuild() }
        .alert(L(.appName), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L(.commonOK)) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func rebuild() {
        let snapshot = model.makeDiagnosticReport(includeLog: includeLog)
        report = snapshot
        markdown = snapshot.markdown(redactedWith: redactor)
        copied = false
    }

    private func save(asJSON: Bool) {
        guard let report, let url = FilePanels.saveFile(
            title: L(.diagnosticsSaveTitle), baseName: "BasaltVR-diagnostics",
            fileExtension: asJSON ? "json" : "md") else { return }
        do {
            let text = asJSON ? try report.json(redactedWith: redactor) : markdown
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = L(.diagnosticsSaveFailure, url.lastPathComponent, error.localizedDescription)
        }
    }
}

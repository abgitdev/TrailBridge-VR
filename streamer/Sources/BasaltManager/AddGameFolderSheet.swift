import SwiftUI
import BasaltBottleKit
import BasaltManagerKit

/// Library → + → Add Game from Folder…: a Windows game in a folder anywhere
/// on the Mac becomes the game of a new environment of its own. The sheet
/// reads the folder without changing it and collects the choices; the model
/// runs the import, so its steps and outcome outlive a rebuilt window.
struct AddGameFolderSheet: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var scanState = FolderScanState.idle
    @State private var scanID = UUID()
    @State private var executableID: String?
    @State private var showsOtherExecutables = false
    @State private var title = ""
    @State private var arguments = ""
    @State private var environment = ""
    /// The user typed the environment's name, so the title no longer sets it.
    @State private var environmentEdited = false

    var body: some View {
        TBManagementSheet(glyph: .library, title: L(.folderImportTitle),
                          subtitle: L(.folderImportSubtitle)) {
            if let state = model.folderImport {
                FolderImportProgressView(state: state)
            } else {
                form
            }
        } actions: {
            if let state = model.folderImport {
                importActions(state)
            } else {
                formActions
            }
        }
        .frame(width: 660, height: 580)
        .interactiveDismissDisabled(model.isImportingGameFolder)
        .onAppear { model.folderImportSheetPresented = true }
        .onDisappear {
            model.folderImportSheetPresented = false
            model.clearGameFolderImport()
        }
        .onChange(of: model.folderImport?.outcome) { _, outcome in
            // The result is read out, so VoiceOver users need not look for it.
            if outcome != nil, let message = model.folderImport?.outcomeMessage {
                AccessibilityNotification.Announcement(message).post()
            }
        }
        .onChange(of: title) { _, newTitle in
            guard !environmentEdited, case .scanned(let result) = scanState else { return }
            environment = GameFolderScan.environmentName(for: newTitle, taken: taken(result))
        }
    }

    // MARK: Form

    @ViewBuilder private var form: some View {
        folderCard
        if case .scanned(let result) = scanState, result.scan.refusal == nil {
            executableSection(result.scan)
            detailsCard(result)
        }
        if let blocker = model.gameFolderImportBlocker {
            VStack(alignment: .leading, spacing: 8) {
                // With no Wine yet, the way out is one button in Setup.
                FolderNotice(text: blocker == .needsSetup && model.wineDownloadOffered
                             ? model.wineDownloadGuidance : blocker.message(environment: environment),
                             kind: .warning)
                if blocker == .needsSetup {
                    Button(L(.wizardOpenSetup)) {
                        model.selection = .setup
                        dismiss()
                    }
                    .buttonStyle(TBQuietButtonStyle(compact: true))
                }
            }
        }
    }

    private var folderCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(L(.folderImportFolder))
                    .font(TB.Typography.panelTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button(L(.folderImportChooseFolder)) { chooseFolder() }
                    .buttonStyle(TBQuietButtonStyle(compact: true))
            }
            if let folder { PathText(path: folder.path) }
            switch scanState {
            case .idle:
                Text(L(.folderImportPanelMessage))
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .scanning:
                TBProgressIndicator(L(.folderImportScanning)).foregroundStyle(TB.textSecondary)
            case .failed(let message):
                FolderNotice(text: message, kind: .problem)
            case .scanned(let result):
                Text(L(.folderImportSize, byteText(result.scan.inventory.totalBytes)))
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                if let refusal = result.scan.refusal {
                    FolderNotice(text: refusal.message, kind: .problem)
                }
                ForEach(Array(result.scan.hints.enumerated()), id: \.offset) { _, hint in
                    FolderNotice(text: hint.message, kind: hint == .openVR ? .info : .warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    /// The probable games as choices; launchers, installers and helpers
    /// wait under "Other .exe files", opened when nothing looks like the game.
    private func executableSection(_ scan: GameFolderScan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(.folderImportExecutable))
                .font(TB.Typography.panelTitle)
                .accessibilityAddTraits(.isHeader)
            if scan.gameExecutables.isEmpty {
                FolderNotice(text: L(.folderImportSelectExecutable), kind: .warning)
            } else {
                executableList(scan.gameExecutables)
            }
            if !scan.otherExecutables.isEmpty {
                DisclosureGroup(isExpanded: $showsOtherExecutables) {
                    executableList(scan.otherExecutables).padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Text(L(.folderImportOtherExecutables))
                        CountBadge(count: scan.otherExecutables.count)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(L(.folderImportExecutableHelp))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func executableList(_ executables: [GameFolderExecutable]) -> some View {
        VStack(spacing: 0) {
            ForEach(executables) { executable in
                if executable.id != executables.first?.id { TBRowDivider() }
                ExecutableRow(executable: executable, isSelected: executable.id == executableID) {
                    executableID = executable.id
                }
            }
        }
        .cardStyle(padding: 0)
    }

    private func detailsCard(_ result: FolderScanResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            FolderField(title: L(.folderImportGameTitle)) {
                TextField(L(.folderImportGameTitle), text: $title)
            }
            FolderField(title: L(.folderImportArguments), help: L(.folderImportArgumentsHelp)) {
                TextField(L(.folderImportArguments), text: $arguments, prompt: Text(L(.sheetOptional)))
                    .font(.body.monospaced())
            }
            FolderField(title: L(.folderImportEnvironment), help: L(.folderImportEnvironmentHelp),
                        problem: environmentProblem(result)?.message(for: environment)) {
                TextField(L(.folderImportEnvironment), text: environmentBinding)
                    .font(.body.monospaced())
            }
            Text(L(.folderImportDestination, result.scan.destinationFolderName))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                .textSelection(.enabled)
            FolderNotice(text: result.space.message, kind: result.space.isEnough ? .disk : .problem)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    @ViewBuilder private var formActions: some View {
        Spacer(minLength: 0)
        Button(L(.commonCancel)) { dismiss() }
            .keyboardShortcut(.cancelAction)
        Button(L(.folderImportAdd)) { add() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(TBPrimaryButtonStyle())
            .disabled(readyToAdd == nil)
    }

    // MARK: Import

    /// Cancel works only while the copy runs: creating and preparing the
    /// environment cannot stop, so the button waits disabled until then.
    /// Back keeps the choices for another try.
    @ViewBuilder private func importActions(_ state: GameFolderImport) -> some View {
        if state.isRunning {
            if state.isCancelling {
                TBProgressIndicator(L(.folderImportCancelling)).foregroundStyle(TB.textSecondary)
            }
            Spacer(minLength: 0)
            Button(L(.folderImportCancelCopy)) { model.cancelGameFolderImport() }
                .disabled(state.step != .copy || state.isCancelling)
        } else {
            if state.outcome != .added {
                Button(L(.commonBack)) { back() }
            }
            Spacer(minLength: 0)
            Button(state.outcome == .added ? L(.sheetDone) : L(.commonClose)) {
                model.clearGameFolderImport()
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(TBPrimaryButtonStyle())
        }
    }

    // MARK: Actions

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Typing a name stops the title from choosing it.
    private var environmentBinding: Binding<String> {
        Binding(get: { environment }, set: { value in
            guard value != environment else { return }
            environment = value
            environmentEdited = true
        })
    }

    /// The scan and the executable Add starts with, or nil while anything is
    /// missing or wrong.
    private var readyToAdd: (scan: GameFolderScan, executable: GameFolderExecutable)? {
        guard case .scanned(let result) = scanState, result.scan.refusal == nil,
              result.space.isEnough, model.gameFolderImportBlocker == nil,
              environmentProblem(result) == nil, !trimmedTitle.isEmpty,
              let executable = result.scan.executables.first(where: { $0.id == executableID })
        else { return nil }
        return (result.scan, executable)
    }

    private func add() {
        guard let ready = readyToAdd else { return }
        let gameTitle = trimmedTitle
        let gameArguments = ManualGame.arguments(from: arguments)
        let environmentName = environment
        Task {
            await model.importGameFolder(
                ready.scan, executable: ready.executable, title: gameTitle,
                arguments: gameArguments, environment: environmentName)
        }
    }

    /// Back to the form after a failure or a cancellation, with the choices
    /// kept. The folder is read again, since it or the free space may have
    /// changed meanwhile.
    private func back() {
        model.clearGameFolderImport()
        if let folder { scan(folder, keepingChoices: true) }
    }

    private func chooseFolder() {
        guard let url = FilePanels.chooseFolder(
            title: L(.folderImportPanelTitle), message: L(.folderImportPanelMessage)) else { return }
        folder = url
        scan(url, keepingChoices: false)
    }

    /// Reads the folder off the main actor; a later choice wins over a scan
    /// that is still running.
    private func scan(_ url: URL, keepingChoices: Bool) {
        let id = UUID()
        scanID = id
        scanState = .scanning
        let manager = model.manager
        Task {
            let result = await Task.detached { FolderScanResult.read(url, manager: manager) }.value
            guard scanID == id else { return }
            switch result {
            case .success(let scanned):
                apply(scanned, keepingChoices: keepingChoices)
            case .failure(let error):
                scanState = .failed(GameFolderRefusal(error: error)?.message
                    ?? L(.folderImportFailed, error.localizedDescription))
            }
        }
    }

    /// A new folder starts from its own suggestions; after Back the choices
    /// stay as long as the folder still has the chosen executable.
    private func apply(_ result: FolderScanResult, keepingChoices: Bool) {
        let scan = result.scan
        let keepsExecutable = keepingChoices && scan.executables.contains { $0.id == executableID }
        let chosen = keepsExecutable ? executableID : scan.suggestedExecutable?.id
        let gameTitle = keepingChoices ? title : scan.suggestedTitle
        let namedByUser = keepingChoices && environmentEdited
        executableID = chosen
        showsOtherExecutables = scan.suggestedExecutable == nil
            || scan.otherExecutables.contains { $0.id == chosen }
        if !keepingChoices {
            title = gameTitle
            arguments = ""
            environmentEdited = false
        }
        if !namedByUser {
            environment = GameFolderScan.environmentName(for: gameTitle, taken: taken(result))
        }
        scanState = .scanned(result)
    }

    private func taken(_ result: FolderScanResult) -> [String] {
        result.environmentFolders + model.gameFolderImportReservedNames
    }

    private func environmentProblem(_ result: FolderScanResult) -> GameFolderEnvironmentNameProblem? {
        GameFolderScan.environmentNameProblem(environment, taken: taken(result))
    }

    private func byteText(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.language.locale))
    }
}

// MARK: - Scan

/// A scanned folder with what the form checks against it.
private struct FolderScanResult: Sendable {
    let scan: GameFolderScan
    /// Room on the data disk, by the rule the copy checks again.
    let space: GameFolderSpaceVerdict
    /// Every entry in Bottles, so a new environment's name stays free.
    let environmentFolders: [String]

    /// Blocking and read-only: the folder, the data disk and Bottles.
    static func read(_ url: URL, manager: BottleManager) -> Result<FolderScanResult, Error> {
        Result {
            let inventory = try manager.inventoryGameFolder(url)
            return FolderScanResult(
                scan: GameFolderScan(inventory: inventory),
                space: GameFolderScan.space(
                    for: inventory, on: GameFolderSpace.volume(at: manager.paths.root)),
                environmentFolders: GameFolderScan.environmentFolderNames(in: manager.paths.bottles))
        }
    }
}

private enum FolderScanState {
    case idle
    case scanning
    case scanned(FolderScanResult)
    /// The scan refused the folder or failed, with the text to show.
    case failed(String)
}

// MARK: - Rows and notes

/// One `.exe` as a radio choice: its name, the folder it is in, its size.
private struct ExecutableRow: View {
    let executable: GameFolderExecutable
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        let size = executable.size.formatted(.byteCount(style: .file).locale(L10n.language.locale))
        let folder = (executable.path as NSString).deletingLastPathComponent
        Button(action: select) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? TB.lavaText : TB.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(executable.fileName)
                        .font(TB.Typography.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !folder.isEmpty {
                        Text(folder)
                            .font(TB.Typography.meta)
                            .foregroundStyle(TB.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(size)
                    .font(TB.Typography.meta.monospacedDigit())
                    .foregroundStyle(TB.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(executable.path)
        .accessibilityLabel(executable.path)
        .accessibilityValue(size)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A label above a full-width field, with its notes below. The field itself
/// carries the label for VoiceOver.
private struct FolderField<Field: View>: View {
    let title: String
    var help: String?
    /// Why the value cannot be used, shown in place of nothing.
    var problem: String?
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TB.Typography.body.weight(.semibold))
                .accessibilityHidden(true)
            field
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            if let problem {
                FolderNotice(text: problem, kind: .problem)
            }
            if let help {
                Text(help)
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A short note with an icon: information, the data disk, a warning, or a
/// problem that keeps the game from being added.
private struct FolderNotice: View {
    enum Kind { case info, disk, warning, problem }

    let text: String
    let kind: Kind

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(iconColor)
        }
        .font(TB.Typography.meta)
        .foregroundStyle(kind == .problem ? TB.dangerText : TB.textSecondary)
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle"
        case .disk: "internaldrive"
        case .warning, .problem: "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch kind {
        case .info, .disk: TB.textSecondary
        case .warning: TB.warningText
        case .problem: TB.dangerText
        }
    }
}

// MARK: - Progress

/// The import's four steps with the copy's progress, then how it ended.
private struct FolderImportProgressView: View {
    let state: GameFolderImport

    private enum Status { case pending, running, done, failed, stopped }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.title)
                .font(TB.Typography.cardTitle)
                .lineLimit(2)
                .help(state.title)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Text(L(.folderImportEnvironment)).foregroundStyle(TB.textSecondary)
                Text(state.environment).font(TB.Typography.meta.monospaced())
            }
            .accessibilityElement(children: .combine)
            Text(L(.folderImportDestination, state.folderName))
                .foregroundStyle(TB.textSecondary)
        }
        .font(TB.Typography.meta)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)

        VStack(spacing: 0) {
            ForEach(GameFolderImport.Step.allCases, id: \.self) { step in
                if step != .create { TBRowDivider() }
                row(step)
            }
        }
        .cardStyle(padding: 0)

        if state.isRunning {
            VStack(alignment: .leading, spacing: 4) {
                Text(L(.folderImportNoCancelNote))
                Text(L(.folderImportKeepOpen))
            }
            .font(TB.Typography.meta)
            .foregroundStyle(TB.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            outcome
        }
    }

    private func row(_ step: GameFolderImport.Step) -> some View {
        let status = status(of: step)
        let text = text(for: step)
        return HStack(spacing: 12) {
            icon(status, step: step)
                .frame(width: 18, height: 18)
            Text(text)
                .foregroundStyle(status == .pending ? TB.textSecondary : TB.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(.headsetNumberedStep, Int64(step.rawValue + 1), text))
        .accessibilityValue(statusText(status))
        .accessibilityAddTraits(status == .running && step == .copy ? .updatesFrequently : [])
    }

    private func status(of step: GameFolderImport.Step) -> Status {
        let reached: Status
        switch state.outcome {
        case .added?: return .done
        // Only the copy can be cancelled, so it is the step that stopped.
        case .cancelled?: reached = .stopped
        case .failed?: reached = .failed
        case nil: reached = .running
        }
        if step < state.step { return .done }
        return step == state.step ? reached : .pending
    }

    private func text(for step: GameFolderImport.Step) -> String {
        switch step {
        case .create: L(.folderImportStepCreate)
        case .prepare: L(.folderImportStepPrepare)
        case .copy where state.step == .copy:
            L(.folderImportStepCopyProgress, Int64((state.copyFraction * 100).rounded(.down)))
        case .copy: L(.folderImportStepCopy)
        case .profile: L(.folderImportStepProfile)
        }
    }

    @ViewBuilder private func icon(_ status: Status, step: GameFolderImport.Step) -> some View {
        switch status {
        case .done:
            PixelIcon(glyph: .check, size: 10, color: TB.successText)
        case .running where step == .copy:
            ProgressRing(progress: state.copyFraction, lineWidth: 3)
        case .running:
            TBProgressIndicator()
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TB.dangerText)
        case .stopped:
            PixelIcon(glyph: .minus, size: 10, color: TB.warningText)
        case .pending:
            PixelIcon(glyph: .dot, size: 6, color: TB.textSecondary)
        }
    }

    private func statusText(_ status: Status) -> String {
        switch status {
        case .pending: L(.folderImportStepPending)
        case .running: L(.folderImportStepRunning)
        case .done: L(.folderImportStepDone)
        case .failed: L(.folderImportStepFailed)
        case .stopped: L(.folderImportStepStopped)
        }
    }

    private var outcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch state.outcome {
            case .added?:
                HStack(spacing: 8) {
                    PixelIcon(glyph: .check, size: 10, color: TB.successText)
                    Text(L(.folderImportDone))
                }
            case .cancelled?:
                Text(L(.folderImportCancelled))
            case .failed(let failure)?:
                Chip(text: L(.commonError), kind: .failed)
                Text(failure.message(environment: state.environment))
                    .foregroundStyle(TB.dangerText)
                    .textSelection(.enabled)
            case nil:
                EmptyView()
            }
            if let kept = state.keptEnvironment {
                Text(L(.folderImportEnvironmentKept, kept))
                    .foregroundStyle(TB.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }
}

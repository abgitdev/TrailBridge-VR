import SwiftUI
import BasaltBottleKit
import BasaltManagerKit

extension BasaltAppModel {
    var steamWizardEntry: SteamCatalogGame? {
        SteamCatalogGame.all.first { $0.id == steamWizardChoiceID }
    }

    var steamWizardGame: SteamGame? {
        guard let entry = steamWizardEntry else { return nil }
        return steamWizardDisk?.games.first { $0.appID == (entry.appID ?? steamWizardOtherAppID) }
    }

    var steamWizardFacts: SteamWizardFacts {
        var facts = SteamWizardFacts()
        facts.chosen = steamWizardEntry != nil
        guard let disk = steamWizardDisk, let bottle = disk.bottle else { return facts }
        facts.bottleExists = true
        facts.prepared = bottle.isReadyForVR
        facts.steamExists = SteamInstallation.executable(in: bottle.prefix) != nil
        facts.bootstrapReady = steamBootstrapReady[bottle.id] == true
        let activity = steamSetupActivities[bottle.id]
        facts.installingSteam = activity == .installer || activity == .updating || activity == .openingSignIn || activity == .timedOut
        facts.loggedOn = steamConnectionStates[bottle.id] == .loggedOn
        if let game = steamWizardGame {
            facts.gameInstalled = disk.installedAppIDs.contains(game.appID)
            facts.gameDownloading = !facts.gameInstalled && disk.downloads[game.appID] != nil
            facts.profileExists = disk.profiles.contains {
                $0.bottleName == bottle.name && $0.source == .steam
                    && ($0.arguments.contains(game.appID) || $0.environment["SteamAppId"] == game.appID
                        || $0.environment["SteamGameId"] == game.appID)
            }
        }
        return facts
    }

    func pollSteamWizard() async {
        guard !steamWizardChecking, let entry = steamWizardEntry else { return }
        let name: String
        do { name = try entry.bottleName(custom: steamWizardCustomName) }
        catch { reportSteamFailure(L(.wizardCheckNameFailure), error: error); return }
        steamWizardChecking = true
        defer { steamWizardChecking = false }
        // Creating an environment makes its folder before its metadata, so a
        // check during a bottle operation can fail on its own. A failure that
        // remains is reported by the next check, two seconds later.
        let busyAtStart = isBusy
        let manager = manager
        do {
            let disk = try await Task.detached {
                try SteamWizardDiskState.read(name: name, manager: manager)
            }.value
            guard steamWizardEntry == entry,
                  (try? entry.bottleName(custom: steamWizardCustomName)) == name else { return }
            steamWizardDisk = disk
            if let bottle = disk.bottle {
                checkSteamBootstrap(in: bottle)
                await observeSteamDownload(in: bottle, download: steamWizardGame.flatMap { disk.downloads[$0.appID] })
                await pollSteamLeftovers(in: [bottle])
            }
            recheckSteamConnection()
        } catch {
            guard !busyAtStart, !isBusy else { return }
            steamWizardError = SteamWizardCopy.failure(L(.wizardCheckFailure), detail: error.localizedDescription)
        }
    }

    func performSteamWizardOperation(_ lead: String, operation: () async -> Void) async {
        guard !steamWizardWorking else { return }
        steamWizardWorking = true
        steamWizardError = nil
        alertMessage = nil
        await operation()
        if let detail = alertMessage {
            if steamWizardError == nil { steamWizardError = SteamWizardCopy.failure(lead, detail: detail) }
            alertMessage = nil
        }
        await pollSteamWizard()
        steamWizardWorking = false
    }
}

/// UI wording is localized here; the catalog, facts and progression remain unchanged.
private enum SteamWizardPresentation {
    static func title(_ step: SteamWizardStep) -> String {
        switch step {
        case .choose: L(.wizardStepChoose)
        case .create: L(.wizardStepCreate)
        case .prepare: L(.wizardStepPrepare)
        case .steam: L(.wizardStepSteam)
        case .signIn: L(.wizardStepSignIn)
        case .game: L(.wizardStepGame)
        case .profile: L(.wizardStepProfile)
        case .done: L(.wizardStepDone)
        }
    }

    static func name(_ game: SteamCatalogGame) -> String {
        game.id == SteamCatalogGame.other.id ? L(.wizardOtherGame) : game.name
    }

    static func note(_ game: SteamCatalogGame) -> String {
        switch game.id {
        case "2669380": L(.wizardBrutalistickNote)
        case "1032430": L(.wizardBloodTrailNote)
        case "667970": L(.wizardVTOLNote)
        case "1592190": L(.wizardBonelabNote)
        case "629730": L(.wizardBladeSorceryNote)
        default: L(.wizardOtherNote)
        }
    }

    static func activity(_ activity: SteamSetupActivity) -> String {
        switch activity {
        case .installer: L(.wizardActivityInstaller)
        case .updating: L(.wizardActivityUpdating)
        case .timedOut: L(.wizardActivityTimedOut)
        case .cancelled: L(.wizardActivityCancelled)
        case .stopped: L(.wizardActivityStopped)
        case .openingSignIn: L(.wizardActivitySignIn)
        }
    }

    static func activityTitle(_ activity: SteamSetupActivity) -> String {
        switch activity {
        case .installer: L(.wizardInstallingSteam)
        case .updating: L(.wizardUpdatingSteam)
        case .timedOut: L(.wizardUpdateUnconfirmed)
        case .cancelled: L(.wizardInstallationCancelled)
        case .stopped: L(.wizardWaitingStopped)
        case .openingSignIn: L(.wizardOpeningSignIn)
        }
    }
}

/// Shared recovery controls remain available while Steam is busy.
struct SteamSetupProgress: View {
    @ObservedObject var model: BasaltAppModel
    let bottle: DiscoveredBottle

    var body: some View {
        if let activity = model.steamSetupActivities[bottle.id] {
            VStack(alignment: .leading, spacing: 10) {
                // A stuck update is told by `SteamRecoveryPanel`; "waiting
                // for the update" would contradict it.
                if model.steamTroubles[bottle.id] != .updateStuck {
                    Chip(text: SteamWizardPresentation.activityTitle(activity),
                         kind: [.timedOut, .cancelled, .stopped].contains(activity) ? .warning : .progress)
                    Text(SteamWizardPresentation.activity(activity))
                        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: 8) {
                    if [.installer, .updating, .timedOut].contains(activity) {
                        Button(L(.wizardReopenSignIn)) {
                            Task { await model.manuallyOpenSteamSignIn(in: bottle) }
                        }
                        if activity == .timedOut {
                            Button(L(.wizardRetryWait)) { model.continueSteamSetup(in: bottle) }
                        }
                        // Closing Steam is "Close Steam" in `SteamRecoveryPanel`.
                    } else if activity == .openingSignIn {
                        Button(L(.commonStop)) { model.stop() }
                    }
                }
                .buttonStyle(TBQuietButtonStyle())
            }
        }
    }
}

/// "Restart Steam" and "Close Steam" for one environment, with what went
/// wrong in plain words. Shown wherever Steam can run, so that a Steam that
/// hangs under Wine never leaves the user to Activity Monitor.
struct SteamRecoveryPanel: View {
    @ObservedObject var model: BasaltAppModel
    let bottle: DiscoveredBottle

    var body: some View {
        let run = model.steamRun(in: bottle)
        let running = run == .setup || run == .window
        let leftover = run == nil && model.steamLeftovers.contains(bottle.id)
        let trouble = model.steamTroubles[bottle.id]
        let restarting = model.steamRestarting.contains(bottle.id)
        let closing = model.steamClosing.contains(bottle.id) || run == .closing
        if running || leftover || trouble != nil || restarting || closing {
            VStack(alignment: .leading, spacing: 8) {
                if let trouble {
                    Chip(text: Self.title(trouble), kind: Self.kind(trouble))
                    Text(Self.text(trouble))
                        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .stopFailed(let detail) = trouble {
                        DisclosureGroup(L(.commonDetails)) {
                            Text(detail).foregroundStyle(TB.dangerText).textSelection(.enabled)
                        }
                        .font(TB.Typography.meta)
                    }
                } else if leftover {
                    Chip(text: L(.steamLeftoverTitle), kind: .warning)
                    Text(L(.steamLeftover))
                        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if running && trouble == nil {
                    Text(L(.steamFreezeHint))
                        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if restarting {
                    TBProgressIndicator(L(.steamRestarting)).font(TB.Typography.meta)
                } else if closing {
                    TBProgressIndicator(L(.steamClosing)).font(TB.Typography.meta)
                } else {
                    FlowLayout(spacing: 8) {
                        if model.canRestartSteam(in: bottle) {
                            Button(L(.steamRestart)) { Task { await model.restartSteam(in: bottle) } }
                        }
                        if running || leftover || trouble != nil {
                            Button(L(.steamClose), role: .destructive) { Task { await model.closeSteam(in: bottle) } }
                        }
                    }
                    .buttonStyle(TBQuietButtonStyle())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func title(_ trouble: SteamTrouble) -> String {
        switch trouble {
        case .updateStuck: L(.steamUpdateStuckTitle)
        case .downloadStuck: L(.steamDownloadStuckTitle)
        case .stopFailed: L(.steamStopFailedTitle)
        }
    }

    private static func text(_ trouble: SteamTrouble) -> String {
        switch trouble {
        case .updateStuck: L(.steamUpdateStuck)
        case .downloadStuck: L(.steamDownloadStuck)
        case .stopFailed: L(.steamStopFailed)
        }
    }

    private static func kind(_ trouble: SteamTrouble) -> Chip.Kind {
        if case .stopFailed = trouble { return .failed }
        return .warning
    }
}

struct SteamGameWizard: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choice: String
    @State private var customName: String
    @State private var signInRechecked = false

    init(model: BasaltAppModel) {
        self.model = model
        // A fresh start offers the first verified game not yet in the Library.
        _choice = State(initialValue: model.steamWizardChoiceID
                        ?? SteamCatalogGame.firstNotAdded(profiles: model.profiles).id)
        _customName = State(initialValue: model.steamWizardCustomName)
    }

    private var entry: SteamCatalogGame { model.steamWizardEntry ?? SteamCatalogGame.all.first { $0.id == choice }! }

    /// Back to the first step, with the first game not yet in the Library chosen.
    private func startOver() {
        model.steamWizardChoiceID = nil
        model.steamWizardDisk = nil
        model.steamWizardError = nil
        model.steamWizardOtherAppID = nil
        choice = SteamCatalogGame.firstNotAdded(profiles: model.profiles).id
    }
    private var step: SteamWizardStep { model.steamWizardFacts.nextStep }
    private var bottle: DiscoveredBottle? { model.steamWizardDisk?.bottle }
    private var blocked: Bool {
        model.isBusy || model.steamWizardWorking || model.steamSetupActivities.values.contains(.openingSignIn)
            || !model.steamRestarting.isEmpty || !model.steamClosing.isEmpty || model.wineStopping
    }
    private var canStart: Bool { !blocked && !model.sessionState.isActive }

    /// Steam of another environment that this app keeps open, e.g. after
    /// "Add Another Game": the steps that start something wait for it, so
    /// it is offered for closing here.
    private var otherSteamBottle: DiscoveredBottle? {
        model.discoveredBottles.first { candidate in
            candidate.isManaged && candidate.id != bottle?.id
                && [.setup, .window, .closing].contains(model.steamRun(in: candidate))
        }
    }

    var body: some View {
        TBManagementSheet(glyph: .steam, title: L(.wizardTitle),
                          subtitle: L(.wizardSubtitle, Int64(step.rawValue), SteamWizardPresentation.title(step))) {
            stepIndicator
            if step == .choose { chooseGame }
            else {
                gameSummary
                // Only the first check of a choice: the periodic re-check
                // must not hide the step and its button every two seconds.
                if model.steamWizardDisk == nil {
                    TBProgressIndicator(L(.wizardChecking)).frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle(padding: 14)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        currentStep
                        if let bottle, step.rawValue >= SteamWizardStep.steam.rawValue {
                            SteamRecoveryPanel(model: model, bottle: bottle)
                        }
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .buttonStyle(TBQuietButtonStyle())
                        .cardStyle(padding: 14)
                    if let other = otherSteamBottle {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L(.wizardOtherSteamOpen, other.name))
                                .fixedSize(horizontal: false, vertical: true)
                            SteamRecoveryPanel(model: model, bottle: other)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle(padding: 14)
                    }
                }
            }
            if let error = model.steamWizardError {
                VStack(alignment: .leading, spacing: 10) {
                    Chip(text: L(.commonError), kind: .failed)
                    Text(L(.wizardErrorGuidance)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                    DisclosureGroup(L(.commonDetails)) {
                        Text(error).foregroundStyle(TB.dangerText).textSelection(.enabled)
                    }
                    Button(L(.wizardRetryCheck)) {
                        model.steamWizardError = nil
                        Task { await model.pollSteamWizard() }
                    }
                    .buttonStyle(TBQuietButtonStyle())
                }
                .frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 14)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L(.wizardVersionCaveat))
                Text(L(.wizardCaveat))
                Text(L(.wizardCloseNote))
                Text(L(.steamPasswordPrivacy))
            }
            .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
        } actions: {
            if step == .done {
                // The game is in the Library; nothing of it runs from here.
                Button(L(.wizardAddAnother)) { startOver() }
            } else if step != .choose {
                Button(L(.commonBack)) { startOver() }
                    .help(L(.wizardChooseAnother)).disabled(!canStart)
            }
            Button(L(.commonCancel)) { dismiss() }.keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            // Facts advance the wizard automatically; this is the existing action for this step.
            if step == .choose || model.steamWizardDisk != nil {
                HStack(spacing: 10) {
                    primaryAction
                        .buttonStyle(TBPrimaryButtonStyle())
                    if working {
                        TBProgressIndicator(workingText)
                            .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(width: 660, height: 560)
        .onAppear { model.steamWizardPresented = true }
        .onDisappear {
            model.steamWizardPresented = false
            // A game that was added is done with: the next opening chooses anew.
            if step == .done { model.steamWizardChoiceID = nil }
        }
        .task {
            model.steamWizardDisk = nil
            var firstCheck = true
            while !Task.isCancelled {
                await model.pollSteamWizard()
                // Opened again on a game added earlier: start with the choice.
                if firstCheck, model.steamWizardChoiceID != nil, step == .done { startOver() }
                firstCheck = false
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var working: Bool {
        if model.steamWizardWorking || model.isBusy { return true }
        guard let bottle, let activity = model.steamSetupActivities[bottle.id] else { return false }
        return [.installer, .updating, .openingSignIn].contains(activity)
    }

    private var workingText: String {
        switch step {
        case .create: L(.environmentCreating)
        case .prepare: L(.wizardPreparingEnvironment)
        case .steam: L(.wizardWorking)
        case .signIn: L(.wizardOpeningSignIn)
        case .profile: L(.sheetAdding)
        default: L(.wizardWorking)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 7) {
            ForEach(SteamWizardStep.allCases, id: \.rawValue) { item in
                Rectangle()
                    .fill(item.rawValue < step.rawValue ? TB.successText : item == step ? TB.lava : .clear)
                    .overlay(Rectangle().strokeBorder(item.rawValue > step.rawValue ? TB.hairline : .clear))
                    .frame(width: 9, height: 9)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L(.wizardStepCount, Int64(step.rawValue)))
    }

    private func badge(_ game: SteamCatalogGame) -> some View {
        Chip(text: game.isVerified
                ? game.verifiedIn.map { L(.wizardVerifiedIn, $0.text(locale: L10n.language.locale)) }
                    ?? L(.wizardVerified)
                : L(.wizardUnverified),
             kind: game.isVerified ? .success : .unverified)
    }

    private var gameSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 10) {
                Text(SteamWizardPresentation.name(entry)).font(.system(size: 13.5, weight: .semibold))
                badge(entry)
            }
            Text(SteamWizardPresentation.note(entry)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            Text(L(.wizardEnvironment, (try? entry.bottleName(custom: model.steamWizardCustomName)) ?? ""))
            if bottle != nil {
                Text(L(.wizardExisting)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
            if let size = model.steamWizardGame?.sizeOnDisk {
                Text(L(.wizardDiskSize, size.formatted(.byteCount(style: .file).locale(L10n.language.locale))))
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).cardStyle(padding: 14)
    }

    private var chooseGame: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(.wizardChooseGuidance))
            VStack(spacing: 0) {
                ForEach(SteamCatalogGame.all) { game in
                    if game.id != SteamCatalogGame.all.first?.id { TBRowDivider() }
                    Button { choice = game.id } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: choice == game.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(choice == game.id ? TB.lavaText : TB.textSecondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                FlowLayout(spacing: 8) {
                                    Text(SteamWizardPresentation.name(game)).font(.system(size: 13.5, weight: .semibold))
                                    badge(game)
                                    if game.isAdded(in: model.profiles) {
                                        Chip(text: L(.wizardAlreadyInLibrary), kind: .neutral)
                                    }
                                }
                                Text(SteamWizardPresentation.note(game))
                                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice == game.id ? .isSelected : [])
                }
            }
            .cardStyle(padding: 0)
            if choice == SteamCatalogGame.other.id {
                TextField(L(.wizardEnvironmentName), text: $customName).textFieldStyle(.roundedBorder)
                Text(L(.wizardNameRules)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
        }
    }

    @ViewBuilder private var currentStep: some View {
        switch step {
        case .choose: EmptyView()
        case .create:
            Text(L(.wizardCreateGuidance))
            if model.engines.first(where: { $0.kind == .pinned && $0.supportsBasaltDXMT }) == nil {
                Chip(text: L(.wizardEngineMissing), kind: .warning)
                Text(model.wineDownloadOffered ? model.wineDownloadGuidance : L(.wizardEngineGuidance))
                    .foregroundStyle(TB.textSecondary)
                DisclosureGroup(L(.commonDetails)) { Text(L(.wizardEngineTechnical)) }
                Button(L(.wizardOpenSetup)) { model.selection = .setup; dismiss() }
            }
        case .prepare:
            Text(L(.wizardPrepareGuidance))
            DisclosureGroup(L(.commonDetails)) { Text(L(.environmentPrepareTechnical)) }
        case .steam:
            // The installer's text only while Steam is not there yet, or its installer runs.
            if model.steamWizardFacts.steamExists,
               bottle.map({ model.steamSetupActivities[$0.id] }) != .installer {
                Text(L(.wizardSteamUpdateGuidance))
            } else {
                Text(L(.wizardSteamGuidance))
            }
            if let bottle {
                SteamSetupProgress(model: model, bottle: bottle)
                // When the update cannot be confirmed, a sign-in still moves the
                // wizard on: the Steam page's workaround, offered here too.
                // An open Steam window is closed in `SteamRecoveryPanel`.
                if model.steamRun(in: bottle) != .window
                    && model.steamWizardFacts.steamExists && !model.steamWizardFacts.installingSteam {
                    Button(L(.steamOpenSignIn)) { model.launchSteam(in: bottle) }.disabled(!canStart)
                    Text(L(.wizardSteamSignInHint))
                        .font(TB.Typography.caption)
                        .foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .signIn:
            Text(L(.wizardSignInGuidance))
            if let bottle {
                Button(L(.wizardAlreadySignedIn)) {
                    model.recheckSteamConnection()
                    signInRechecked = true
                }
                if signInRechecked && model.steamConnectionStates[bottle.id] != .loggedOn {
                    Text(L(.wizardSignInUnconfirmed)).foregroundStyle(TB.warningText)
                }
            }
        case .game: gameStep
        case .profile:
            Text(L(.wizardProfileGuidance))
        case .done:
            Text(L(.wizardDoneGuidance))
            if entry.needsOpenVR { Text(L(.wizardOpenVRGuidance)) }
            Text(L(.wizardTestReminder)).foregroundStyle(TB.textSecondary)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch step {
        case .choose:
            Button(L(.commonNext)) {
                guard let selected = SteamCatalogGame.all.first(where: { $0.id == choice }) else { return }
                do {
                    _ = try selected.bottleName(custom: customName)
                    model.steamWizardCustomName = customName
                    model.steamWizardDisk = nil
                    model.steamWizardOtherAppID = nil
                    model.steamWizardError = nil
                    model.steamWizardChoiceID = choice
                    Task { await model.pollSteamWizard() }
                } catch { model.reportSteamFailure(L(.wizardCheckNameFailure), error: error) }
            }.disabled(blocked)
        case .create:
            if let engine = model.engines.first(where: { $0.kind == .pinned && $0.supportsBasaltDXMT }) {
                Button(L(.environmentCreate)) {
                    Task {
                        await model.performSteamWizardOperation(L(.wizardCreateFailure)) {
                            _ = await model.createBottle(name: (try? entry.bottleName(custom: model.steamWizardCustomName)) ?? "", engineID: engine.id)
                        }
                    }
                }.disabled(!canStart)
            }
        case .prepare:
            Button(L(.environmentPrepare)) {
                guard let bottle else { return }
                Task { await model.performSteamWizardOperation(L(.wizardPrepareFailure)) { await model.prepareBottle(bottle.name) } }
            }.disabled(!canStart)
        case .steam:
            if let bottle {
                if model.steamWizardFacts.steamExists {
                    Button(L(.wizardContinueSteam)) { model.continueSteamSetup(in: bottle) }.disabled(!canStart)
                } else {
                    Button(L(.steamInstall)) {
                        Task { await model.performSteamWizardOperation(L(.wizardSteamFailure)) { await model.installSteam(in: bottle) } }
                    }.disabled(!canStart)
                }
            }
        case .signIn:
            if let bottle {
                Button(L(.steamOpenSignIn)) { model.launchSteam(in: bottle); signInRechecked = false }.disabled(!canStart)
            }
        case .game:
            if model.steamWizardFacts.gameDownloading {
                // Steam has it; pressing again would only ask Steam once more.
                Button {} label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L(.wizardDownloadingInSteam))
                    }
                }
                .disabled(true)
            } else if let bottle, let appID = entry.appID {
                Button(L(.wizardDownloadGame)) { model.requestSteamGameInstall(appID: appID, in: bottle) }.disabled(blocked)
            }
        case .profile:
            Button(L(.wizardAddToLibrary)) {
                guard let game = model.steamWizardGame else { return }
                Task { await model.performSteamWizardOperation(L(.wizardProfileFailure)) { await model.createSteamProfile(for: game) } }
            }.disabled(blocked)
        case .done:
            Button(L(.streamOpenLibrary)) { model.selection = .library; dismiss() }
        }
    }

    private var gameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chip(text: L(.wizardSignedIn), kind: .success)
            if bottle != nil && entry.appID != nil {
                Text(L(.wizardDownloadGuidance))
            } else {
                Text(L(.wizardOtherInstallGuidance))
                ForEach(model.steamWizardDisk?.games ?? []) { game in
                    Button {
                        model.steamWizardOtherAppID = game.appID
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.steamWizardOtherAppID == game.appID ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                            Text(game.name).lineLimit(2).help(game.name)
                            Spacer(minLength: 0)
                            Chip(text: model.steamWizardDisk?.installedAppIDs.contains(game.appID) == true
                                 ? L(.wizardGameInstalled) : L(.wizardGameIncomplete),
                                 kind: model.steamWizardDisk?.installedAppIDs.contains(game.appID) == true ? .neutral : .warning)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.steamWizardOtherAppID == game.appID ? .isSelected : [])
                }
            }
            if let game = model.steamWizardGame {
                if model.steamWizardFacts.gameDownloading {
                    let total = model.steamWizardDisk?.downloads[game.appID]?.bytesToDownload
                    Text(total.map {
                        L(.wizardDownloadRunning, $0.formatted(.byteCount(style: .file).locale(L10n.language.locale)))
                    } ?? L(.wizardDownloadRunningNoSize))
                } else {
                    Text(model.steamWizardFacts.gameInstalled ? L(.wizardGameConfirmed) : L(.wizardGameUnconfirmed))
                }
            } else { Text(L(.wizardNoManifest)) }
        }
    }
}

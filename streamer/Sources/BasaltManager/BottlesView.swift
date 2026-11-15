import SwiftUI
import AppKit
import BasaltBottleKit
import BasaltManagerKit

struct BottlesView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var showingNewBottle = false
    @State private var importing: DiscoveredBottle?

    var body: some View {
        let managed = model.discoveredBottles.filter(\.isManaged)
        let external = model.discoveredBottles.filter { !$0.isManaged }

        TBManagementPage {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(L(.environmentManaged), count: managed.count)
                VStack(spacing: 0) {
                    if managed.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            TBPixelTile(glyph: .bottles)
                            Text(L(.environmentEmpty)).foregroundStyle(TB.textSecondary)
                            Button(L(.environmentNew)) { showingNewBottle = true }
                                .buttonStyle(TBPrimaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(managed) { bottle in
                        if bottle.id != managed.first?.id { TBRowDivider() }
                        BottleRow(bottle: bottle, model: model) { importing = bottle }
                    }
                }
                .cardStyle(padding: 0)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(.environmentPrepareExplanation))
                    DisclosureGroup(L(.commonDetails)) {
                        Text(L(.environmentPrepareTechnical)).padding(.top, 4)
                    }
                }
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
            if !model.damagedBottles.isEmpty {
                DamagedItemsSection(kind: .environments, items: model.damagedBottles, model: model)
            }
            if !external.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(L(.environmentExternal), count: external.count)
                    Text(L(.environmentExternalExplanation))
                        .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                    VStack(spacing: 0) {
                        ForEach(external) { bottle in
                            if bottle.id != external.first?.id { TBRowDivider() }
                            BottleRow(bottle: bottle, model: model) { importing = bottle }
                        }
                    }
                    .cardStyle(padding: 0)
                    DisclosureGroup(L(.commonDetails)) {
                        Text(L(.environmentCopyTechnical)).padding(.top, 4)
                    }
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                }
            }
        }
        .navigationTitle(L(.sidebarBottles))
        .navigationSubtitle(L10n.plural(.environmentCount, model.discoveredBottles.count))
        .toolbar {
            ToolbarItem {
                Button { showingNewBottle = true } label: {
                    Label(L(.environmentNew), systemImage: "plus")
                }
                .accessibilityLabel(L(.environmentNew))
                .help(L(.environmentNewHelp))
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.isBusy)
            }
        }
        .sheet(isPresented: $showingNewBottle) { NewBottleSheet(model: model) }
        .sheet(item: $importing) { ImportBottleSheet(bottle: $0, model: model) }
    }
}

private struct BottleRow: View {
    let bottle: DiscoveredBottle
    @ObservedObject var model: BasaltAppModel
    let onImport: () -> Void
    @State private var confirmingDeletion = false
    @State private var preparingBottleID: String?

    private var hasSteam: Bool {
        SteamInstallation.executable(in: bottle.prefix) != nil
    }

    private var games: [SteamGame] {
        BottleArtwork.games(inBottle: bottle.id, among: model.steamGames)
    }

    /// The environment an Add Game from Folder import is creating: the import
    /// prepares it itself, and deleting it would pull it from under the copy.
    private var isImportTarget: Bool {
        bottle.managed.map { $0.name == model.gameFolderImportEnvironment } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                TBArtworkThumbnail(
                    url: BottleArtwork.primaryArtwork(forBottle: bottle.id, among: model.steamGames),
                    iconExecutable: bottle.managed.flatMap {
                        BottleArtwork.primaryExecutable(forBottleNamed: $0.name, among: model.games)
                    })
                VStack(alignment: .leading, spacing: 3) {
                    Text(bottle.name).font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(2).help(bottle.name)
                    if !games.isEmpty {
                        let names = games.map(\.name).joined(separator: ", ")
                        Text(names).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                            .lineLimit(2).help(names)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                actionsMenu
            }
            FlowLayout(spacing: 8) {
                if let managed = bottle.managed {
                    if preparingBottleID == bottle.id {
                        Chip(text: L(.environmentPreparing), kind: .progress)
                    } else {
                        Chip(text: managed.dxmtInstalled ? L(.environmentGraphicsReady) : L(.environmentGraphicsMissing),
                             kind: managed.dxmtInstalled ? .success : .unverified)
                        Chip(text: managed.runtimeInstalled ? L(.environmentVRReady) : L(.environmentVRMissing),
                             kind: managed.runtimeInstalled ? .success : .unverified)
                    }
                    if !bottle.isReadyForVR && preparingBottleID != bottle.id {
                        Text(L(.environmentPrepareHint))
                            .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                        Button(L(.environmentPrepare)) {
                            preparingBottleID = bottle.id
                            Task { await model.prepareBottle(bottle.name) }
                        }
                        .buttonStyle(TBQuietButtonStyle()).disabled(model.isBusy || isImportTarget)
                    }
                } else {
                    Chip(text: bottle.origin.label, kind: .neutral)
                    Chip(text: L(.environmentReadOnly), kind: .neutral)
                    Button(L(.environmentCopy), action: onImport)
                        .buttonStyle(TBQuietButtonStyle()).disabled(model.isBusy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            DisclosureGroup(L(.commonDetails)) {
                VStack(alignment: .leading, spacing: 6) {
                    if let managed = bottle.managed {
                        Text(L(.environmentEngineID, managed.engineID))
                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Text(L(.environmentGraphicsTechnical, managed.dxmtInstalled ? L(.environmentInstalled) : L(.environmentNotInstalled)))
                        Text(L(.environmentVRTechnical, managed.runtimeInstalled ? L(.environmentInstalled) : L(.environmentNotInstalled)))
                    }
                    PathText(path: bottle.prefix.path)
                }
                .padding(.top, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onChange(of: model.isBusy) { _, busy in
            if !busy { preparingBottleID = nil }
        }
        .confirmationDialog(L(.environmentDeleteQuestion, bottle.name), isPresented: $confirmingDeletion, titleVisibility: .visible) {
            Button(L(.environmentDelete), role: .destructive) { Task { await model.deleteBottle(bottle.name) } }
            Button(L(.commonCancel), role: .cancel) {}
        } message: {
            Text(L(.environmentDeleteWarning))
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button(L(.libraryShowInFinder)) {
                NSWorkspace.shared.activateFileViewerSelecting([bottle.prefix])
            }
            if bottle.isManaged {
                Divider()
                if hasSteam {
                    Button(L(.steamOpenSignIn)) { model.launchSteam(in: bottle) }
                }
                Button(L(.environmentRunInstaller)) { chooseInstaller() }
                Divider()
                Button(L(.environmentDeleteMenu), role: .destructive) { confirmingDeletion = true }
                    .disabled(model.sessionState.isActive || model.isBusy || isImportTarget)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(TB.Typography.body.weight(.semibold))
                .foregroundStyle(TB.textTertiary)
                .frame(width: TB.Size.iconButton, height: TB.Size.iconButton)
                .background(TB.quietFill, in: RoundedRectangle(cornerRadius: TB.Radius.primaryButton))
                .overlay(RoundedRectangle(cornerRadius: TB.Radius.primaryButton).strokeBorder(TB.quietBorder))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L(.environmentActions, bottle.name))
        .help(L(.environmentActions, bottle.name))
    }

    private func chooseInstaller() {
        guard let url = FilePanels.chooseFile(
            title: L(.environmentChooseInstaller), extensions: ["exe", "msi"]) else { return }
        model.runInstaller(url, in: bottle)
    }
}

private struct NewBottleSheet: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var engineID = ""
    @State private var isCreating = false

    var body: some View {
        TBManagementSheet(glyph: .bottles, title: L(.environmentNewTitle),
                          subtitle: L(.environmentNewSubtitle)) {
            VStack(alignment: .leading, spacing: 14) {
                TextField(L(.environmentName), text: $name, prompt: Text(L(.environmentNameExample)))
                    .textFieldStyle(.roundedBorder)
                DisclosureGroup(L(.commonDetails)) {
                    Picker(L(.environmentEngine), selection: $engineID) {
                        Text(L(.environmentSelectEngine)).tag("")
                        ForEach(model.engines, id: \.id) { engine in
                            Text(engine.supportsBasaltDXMT
                                 ? engine.id : L(.environmentEngineNoVR, engine.id))
                                .tag(engine.id)
                        }
                    }
                    .padding(.top, 8)
                }
                Text(L(.environmentAfterCreation)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
            .disabled(isCreating)
        } actions: {
            if isCreating {
                TBProgressIndicator(L(.environmentCreating)).foregroundStyle(TB.textSecondary)
            }
            Spacer(minLength: 0)
            Button(L(.commonCancel)) { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(isCreating)
            Button(L(.environmentCreate)) {
                isCreating = true
                Task {
                    if await model.createBottle(name: name, engineID: engineID) {
                        dismiss()
                    } else {
                        isCreating = false
                    }
                }
            }
            .keyboardShortcut(.defaultAction).buttonStyle(TBPrimaryButtonStyle())
            .disabled(name.isEmpty || engineID.isEmpty || isCreating || model.isBusy)
        }
        .frame(width: 560, height: 380)
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            if engineID.isEmpty {
                engineID = model.engines.first(where: \.supportsBasaltDXMT)?.id ?? model.engines.first?.id ?? ""
            }
        }
    }
}

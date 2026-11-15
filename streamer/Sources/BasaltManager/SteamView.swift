import SwiftUI
import BasaltManagerKit

struct SteamView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var showingGameWizard = false

    private var managed: [DiscoveredBottle] { model.discoveredBottles.filter(\.isManaged) }
    /// The environment whose Steam window this app has open, if any.
    private var windowBottle: DiscoveredBottle? { managed.first { model.steamRun(in: $0) == .window } }
    private var external: [SteamGame] {
        model.steamGames.filter { $0.bottleOrigin != .managed && !$0.isTool }
    }

    var body: some View {
        TBManagementPage {
            signInCard
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(L(.steamManaged), count: managed.count)
                VStack(spacing: 0) {
                    if managed.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L(.steamNoEnvironments)).foregroundStyle(TB.textSecondary)
                            Button(L(.steamPrepare)) { showingGameWizard = true }
                                .buttonStyle(TBPrimaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    ForEach(managed) { bottle in
                        if bottle.id != managed.first?.id { TBRowDivider() }
                        managedRow(bottle)
                    }
                }
                .cardStyle(padding: 0)
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(L(.steamExternal), count: external.count)
                Text(L(.steamExternalExplanation))
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                VStack(spacing: 0) {
                    if external.isEmpty {
                        Text(L(.steamExternalEmpty))
                            .foregroundStyle(TB.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(external) { game in
                        if game.id != external.first?.id { TBRowDivider() }
                        HStack(spacing: 12) {
                            TBArtworkThumbnail(url: game.artwork, glyph: .steam)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(game.name).font(.system(size: 13.5, weight: .semibold))
                                    .lineLimit(2).help(game.name)
                                Text(L(.steamGameSource, game.bottleOrigin.label, game.bottleName))
                                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                                    .lineLimit(2).help(game.bottleName)
                            }
                            Spacer(minLength: 0)
                            Chip(text: L(.environmentReadOnly), kind: .neutral)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    TBRowDivider()
                    FlowLayout(spacing: 8) {
                        Button(L(.sidebarBottles)) { model.selection = .bottles }
                        Button(L(.steamRefresh)) { Task { await model.refresh() } }
                            .disabled(model.isBusy)
                        Button(L(.steamLibrary)) { model.selection = .library }
                    }
                    .buttonStyle(TBQuietButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .cardStyle(padding: 0)
            }
        }
        // Wine left running with no session (a stop that failed, a crash).
        .task {
            while !Task.isCancelled {
                await model.pollSteamLeftovers(in: managed)
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
        .navigationTitle(L(.commonSteam))
        .navigationSubtitle(L(.steamSubtitle))
        .sheet(isPresented: $showingGameWizard) { SteamGameWizard(model: model) }
    }

    private var signInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TBPixelTile(glyph: .steam)
                Text(L(.steamSignIn)).font(TB.Typography.sectionTitle)
                Spacer(minLength: 0)
            }
            Text(L(.steamSignInGuidance)).fixedSize(horizontal: false, vertical: true)
            Text(L(.steamPasswordPrivacy))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            Button(L(.steamAddGame)) { showingGameWizard = true }
                .buttonStyle(TBPrimaryButtonStyle(emphasized: true))
            if let error = model.steamWizardError {
                TBRowDivider()
                Chip(text: L(.commonError), kind: .failed)
                Text(L(.steamErrorGuidance)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                DisclosureGroup(L(.commonDetails)) {
                    Text(error).foregroundStyle(TB.dangerText).textSelection(.enabled)
                }
            }
            if let bottle = windowBottle {
                TBRowDivider()
                Chip(text: L(.steamRunning), kind: .progress)
                Text(L(.steamWindowGuidance))
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                SteamRecoveryPanel(model: model, bottle: bottle)
                Button(L(.steamShowLog)) { model.selection = .stream }
                    .buttonStyle(TBQuietButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    private func managedRow(_ bottle: DiscoveredBottle) -> some View {
        let installed = SteamInstallation.executable(in: bottle.prefix) != nil
        let count = model.steamGames.filter { $0.bottleID == bottle.id && !$0.isTool }.count
        return VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    environmentIdentity(bottle, count: count)
                    Spacer(minLength: 8)
                    steamActions(bottle, installed: installed)
                }
                VStack(alignment: .leading, spacing: 10) {
                    environmentIdentity(bottle, count: count)
                    steamActions(bottle, installed: installed)
                }
            }
            .disabled(model.isBusy || model.sessionState.isActive
                      || !model.steamRestarting.isEmpty || !model.steamClosing.isEmpty || model.wineStopping)
            // Recovery stays available while the environment's ordinary actions are disabled.
            SteamSetupProgress(model: model, bottle: bottle)
            // An open Steam window has its panel in the sign-in card above.
            if model.steamRun(in: bottle) != .window { SteamRecoveryPanel(model: model, bottle: bottle) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func environmentIdentity(_ bottle: DiscoveredBottle, count: Int) -> some View {
        HStack(spacing: 12) {
            TBPixelTile(glyph: .steam)
            VStack(alignment: .leading, spacing: 3) {
                Text(bottle.name).font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2).help(bottle.name)
                Text(L(.steamInstalledCount, Int64(count)))
                    .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
            }
        }
    }

    private func steamActions(_ bottle: DiscoveredBottle, installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Chip(text: installed ? L(.steamInstalled) : L(.steamNotInstalled),
                 kind: installed ? .neutral : .unverified)
            if installed {
                Button(L(.steamOpenSignIn)) { model.launchSteam(in: bottle) }
            } else {
                Text(L(.steamInstallHint)).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                Button(L(.steamInstall)) { Task { await model.installSteam(in: bottle) } }
            }
        }
        .buttonStyle(TBQuietButtonStyle())
    }
}

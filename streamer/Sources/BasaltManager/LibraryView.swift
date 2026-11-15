import SwiftUI
import AppKit
import BasaltBottleKit
import BasaltCore
import BasaltManagerKit

extension BasaltAppModel {
    /// Detected games and profiles that are not already shown as a
    /// BSManager instance.
    var directLibraryGames: [DetectedGame] {
        let instanceExecutables = Set(bsManagerInstances.map(\.executable.standardizedFileURL))
        return games.filter { game in
            guard game.source == .bsmanager, let executable = game.hostExecutable else {
                return true
            }
            return !instanceExecutables.contains(executable.standardizedFileURL)
        }
    }

    /// The Steam game a launch profile starts, so the profile's card can
    /// show that game's name and artwork instead of its executable's.
    func steamGame(forProfileNamed name: String) -> SteamGame? {
        steamGames.first { profile(for: $0)?.name == name }
    }

    var libraryItemCount: Int {
        steamGames.filter { !$0.isTool }.count + bsManagerInstances.count
            + directLibraryGames.count
    }

    /// The Steam games the Library lists under its two filters, before the
    /// page's own search field.
    var steamGamesByLibraryFilters: [SteamGame] {
        steamGames.filter { (libraryShowTools || !$0.isTool) && (!libraryVROnly || $0.isKnownVRGame) }
    }

    /// The Library has nothing to list, so it shows its two "Add…" buttons
    /// on the page. One rule for the page and for the learning step that
    /// points at those buttons. The search field is the page's own: with
    /// text in it an empty Library says "no results" instead.
    var libraryShowsAddButtons: Bool {
        steamGamesByLibraryFilters.isEmpty && bsManagerInstances.isEmpty && directLibraryGames.isEmpty
            && bsManagerInstallations.isEmpty
            // Games the "VR only" filter hides get their own empty state.
            && !(libraryVROnly && steamGames.contains { (libraryShowTools || !$0.isTool) && !$0.isKnownVRGame })
    }
}

enum LibrarySheet: Identifiable {
    case importBottle(DiscoveredBottle)
    case chooseBottle(BSManagerInstance)
    case installBSManager(URL)
    case addGame
    case addGameFolder
    case steamGameWizard
    case edit(LaunchProfile)
    case settings(String)
    case openVR(LaunchProfile)

    var id: String {
        switch self {
        case .importBottle(let bottle): "import-\(bottle.id)"
        case .chooseBottle(let instance): "choose-bottle-\(instance.id)"
        case .installBSManager(let url): "install-\(url.path)"
        case .addGame: "add-game"
        case .addGameFolder: "add-game-folder"
        case .steamGameWizard: "steam-game-wizard"
        case .edit(let profile): "edit-\(profile.name)"
        case .settings(let profileName): "settings-\(profileName)"
        case .openVR(let profile): "openvr-\(profile.name)"
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var search = ""
    @State private var sheet: LibrarySheet?
    private var vrOnly: Bool { model.libraryVROnly }
    private var showTools: Bool { model.libraryShowTools }

    private let columns = [
        GridItem(.adaptive(minimum: 260, maximum: 380), spacing: TB.Spacing.grid, alignment: .top),
    ]

    private func matches(_ values: String...) -> Bool {
        search.isEmpty || values.contains { $0.localizedCaseInsensitiveContains(search) }
    }

    /// Playable items first, otherwise in discovery (alphabetical) order.
    private func playableFirst<T>(_ items: [T], _ isPlayable: (T) -> Bool) -> [T] {
        items.filter(isPlayable) + items.filter { !isPlayable($0) }
    }

    private var steamGames: [SteamGame] {
        playableFirst(model.steamGames.filter {
            (showTools || !$0.isTool)
                && (!vrOnly || $0.isKnownVRGame)
                && matches($0.name, $0.bottleName)
        }) { model.profile(for: $0) != nil }
    }

    private var bsManagerInstances: [BSManagerInstance] {
        playableFirst(model.bsManagerInstances.filter {
            matches($0.name, $0.directory.path, $0.bottleName ?? "")
        }) { model.profile(for: $0) != nil }
    }

    private var directGames: [DetectedGame] {
        playableFirst(model.directLibraryGames.filter {
            matches($0.title, $0.bottleName)
        }) { $0.profileName != nil }
    }

    /// Steam games matching the search that only the persisted VR filter hides.
    private var hiddenByVROnly: Int {
        guard vrOnly else { return 0 }
        return model.steamGames.filter {
            (showTools || !$0.isTool) && !$0.isKnownVRGame && matches($0.name, $0.bottleName)
        }.count
    }

    private var showsBSManagerSection: Bool {
        (!model.bsManagerInstances.isEmpty || !model.bsManagerInstallations.isEmpty
            || model.steamGames.contains { $0.appID == "620980" }
            || model.games.contains { $0.source == .bsmanager || $0.title == "Beat Saber" })
            && (search.isEmpty || !bsManagerInstances.isEmpty)
    }

    var body: some View {
        let steam = steamGames
        let bsManager = bsManagerInstances
        let direct = directGames
        let isEmpty = steam.isEmpty && bsManager.isEmpty && direct.isEmpty
        let hidden = hiddenByVROnly
        // A Steam game with a profile is listed twice; one of its cards
        // carries the marks a learning step points at.
        let cards: [LearningLibraryMarks.Card] =
            steam.map { .init(id: "steam:\($0.id)", profile: model.profile(for: $0)?.name) }
            + bsManager.map { .init(id: "bs:\($0.id)", profile: model.profile(for: $0)?.name) }
            + direct.map { .init(id: "direct:\($0.id)", profile: $0.profileName) }
        let marked = LearningLibraryMarks.markedCards(cards)

        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    // Before the first refresh the lists are empty, not the
                    // library: "No games yet" would flash for a moment.
                    if !model.libraryLoaded {
                        TBProgressIndicator()
                            .frame(maxWidth: .infinity, minHeight: 360)
                    } else if isEmpty && hidden > 0 {
                        ContentUnavailableView {
                            Label(L(.libraryNoVRGames), systemImage: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(TB.textPrimary)
                        } description: {
                            Text(hiddenGamesText(hidden))
                                .foregroundStyle(TB.textSecondary)
                        } actions: {
                            Button(L(.libraryShowAll)) { model.libraryVROnly = false }
                                .buttonStyle(TBPrimaryButtonStyle())
                        }
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else if isEmpty && !search.isEmpty {
                        ContentUnavailableView {
                            Label(L(.librarySearchEmpty, search), systemImage: "magnifyingglass")
                        } description: {
                            Text(L(.librarySearchEmptyDetail))
                        }
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else if model.libraryShowsAddButtons {
                        emptyLibrary
                    } else {
                        if !steam.isEmpty {
                            section(L(.librarySteamGames), count: steam.count) {
                                ForEach(steam) { game in
                                    SteamGameTile(game: game, model: model,
                                                  marked: marked.contains("steam:\(game.id)")) { sheet = $0 }
                                }
                            }
                        } else if hidden > 0 {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionTitle(title: L(.librarySteamGames), count: 0) {
                                    Button(L(.libraryShowAll)) { model.libraryVROnly = false }
                                        .buttonStyle(TBQuietButtonStyle(compact: true))
                                }
                                Text(hiddenGamesText(hidden))
                                    .font(TB.Typography.body)
                                    .foregroundStyle(TB.textSecondary)
                            }
                        }
                        if showsBSManagerSection {
                            VStack(alignment: .leading, spacing: 14) {
                                SectionTitle(title: L(.commonBSManager), count: bsManager.count) {
                                    BSManagerActions(model: model, present: { sheet = $0 })
                                }
                                if bsManager.isEmpty {
                                    BSManagerHint(hasLauncher: !model.bsManagerInstallations.isEmpty)
                                } else {
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: TB.Spacing.grid) {
                                        ForEach(bsManager) { instance in
                                            BSManagerInstanceTile(instance: instance, model: model,
                                                                  marked: marked.contains("bs:\(instance.id)")) {
                                                sheet = $0
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        if !direct.isEmpty {
                            section(L(.libraryLaunchProfiles), count: direct.count) {
                                ForEach(direct) { game in
                                    DetectedGameTile(game: game, model: model,
                                                     marked: marked.contains("direct:\(game.id)")) { sheet = $0 }
                                }
                            }
                        }
                    }
                    // Whatever the page shows above: a game whose profile
                    // cannot be read must not just be missing from it.
                    if model.libraryLoaded, !model.damagedProfiles.isEmpty {
                        DamagedItemsSection(kind: .games, items: model.damagedProfiles, model: model)
                    }
                }
                .padding(.vertical, TB.Spacing.contentVertical)
                .padding(.horizontal, TB.Spacing.contentHorizontal)
                // The tiles' artwork grows with their width, so the page is
                // taller without the scroll bar.
                .layoutBesideLegacyScroller(width: geometry.size.width)
            }
            .tourScrollsToTarget(on: .library)
        }
        .foregroundStyle(TB.textPrimary)
        .background(TB.windowBackground)
        .navigationTitle(L(.sidebarLibrary))
        .navigationSubtitle(L10n.plural(.libraryGameCount, model.libraryItemCount))
        .searchable(text: $search, placement: .toolbar, prompt: L(.librarySearch))
        .toolbar {
            ToolbarItem {
                Menu {
                    Button(L(.libraryAddSteam)) { sheet = .steamGameWizard }
                    Button(L(.libraryAddGame)) { sheet = .addGame }
                    Button(L(.libraryAddGameFolder)) { sheet = .addGameFolder }
                        .disabled(model.sessionState.isActive || model.isImportingGameFolder)
                    Button(L(.libraryInstallBSManager)) {
                        chooseBSManagerInstaller(model) { sheet = $0 }
                    }
                    .disabled(model.sessionState.isActive)
                } label: {
                    Label(L(.libraryAdd), systemImage: "plus")
                }
                .accessibilityLabel(L(.libraryAdd))
                .help(L(.libraryAddHelp))
            }
            ToolbarItem {
                Menu {
                    Toggle(L(.libraryVROnly), isOn: $model.libraryVROnly)
                    Toggle(L(.libraryShowTools), isOn: $model.libraryShowTools)
                } label: {
                    Label(
                        L(.libraryFilter),
                        systemImage: vrOnly || showTools
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel(L(.libraryFilter))
                .accessibilityValue(activeFilters)
                .help(L(.libraryFilterHelp))
            }
        }
        .onAppear {
            // An import outlives its sheet when another section or a new
            // language rebuilds this page: show its progress again.
            if model.isImportingGameFolder, sheet == nil { sheet = .addGameFolder }
        }
        .sheet(item: $sheet, onDismiss: {
            Task { await model.refreshOpenVRBadges() }
        }) { sheet in
            switch sheet {
            case .importBottle(let bottle):
                ImportBottleSheet(bottle: bottle, model: model)
            case .chooseBottle(let instance):
                BSManagerBottleSheet(instance: instance, model: model)
            case .installBSManager(let installer):
                BSManagerInstallerSheet(installer: installer, model: model)
            case .addGame:
                AddGameSheet(model: model)
            case .addGameFolder:
                AddGameFolderSheet(model: model)
            case .steamGameWizard:
                SteamGameWizard(model: model)
            case .edit(let profile):
                ProfileEditorSheet(profile: profile, model: model)
            case .openVR(let profile):
                OpenVRSupportSheet(profile: profile, model: model)
            case .settings(let profileName):
                PerGameSettingsSheet(profileName: profileName, model: model)
            }
        }
    }

    private func section<Content: View>(
        _ title: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title, count: count)
            LazyVGrid(columns: columns, alignment: .leading, spacing: TB.Spacing.grid) {
                content()
            }
        }
    }

    private func hiddenGamesText(_ count: Int) -> String {
        L10n.plural(.libraryHiddenGames, count)
    }

    /// The toolbar shows active filters only by a filled glyph; VoiceOver reads their names.
    private var activeFilters: String {
        var names = [String]()
        if vrOnly { names.append(L(.libraryVROnly)) }
        if showTools { names.append(L(.libraryShowTools)) }
        return names.joined(separator: ", ")
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label {
                Text(L(.libraryEmpty)).foregroundStyle(TB.textPrimary)
            } icon: {
                PixelIcon(glyph: .library, size: 24, color: TB.textSecondary)
            }
        } description: {
            Text(L(.libraryEmptyDetail))
                .foregroundStyle(TB.textSecondary)
        } actions: {
            // The two ways to add a game, each saying whose way it is. They
            // open the same sheets as the "+" menu, under the same rules.
            // Each quiet link sits in the column it belongs to, so nothing
            // floats between the two buttons.
            HStack(alignment: .top, spacing: 16) {
                addButton(L(.libraryAddSteam), caption: L(.libraryAddSteamCaption),
                          target: .libraryAddSteam, action: { sheet = .steamGameWizard },
                          link: L(.libraryOpenBottles)) { model.selection = .bottles }
                addButton(L(.libraryAddGameFolder), caption: L(.libraryAddFolderCaption),
                          target: .libraryAddFolder, action: { sheet = .addGameFolder },
                          disabled: model.sessionState.isActive || model.isImportingGameFolder,
                          link: L(.libraryLocateBSManager)) { locateBSManager(model) }
            }
            .tourTarget(.chapter(.libraryAddButtons))
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func addButton(
        _ title: String, caption: String, target: SetupTarget, action: @escaping () -> Void,
        disabled: Bool = false, link: String, linkAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            // The title stays on one line in every language; the caption
            // under it may wrap.
            Button(action: action) {
                Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(TBPrimaryButtonStyle())
            .disabled(disabled)
            .tourTarget(.chapter(target), onAccent: true)
            Text(caption)
                .font(TB.Typography.meta)
                .foregroundStyle(TB.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 220)
            Button(link, action: linkAction)
                .buttonStyle(.plain)
                .font(TB.Typography.meta)
                .foregroundStyle(TB.link)
                .padding(.top, 8)
        }
    }
}

@MainActor
private func locateBSManager(_ model: BasaltAppModel) {
    guard let location = FilePanels.chooseFolder(
        title: L(.libraryLocateTitle),
        message: L(.libraryLocateMessage))
    else { return }
    Task { await model.setBSManagerLocation(location) }
}

// MARK: - BSManager

private struct BSManagerActions: View {
    @ObservedObject var model: BasaltAppModel
    let present: (LibrarySheet) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if model.bsManagerInstallations.count == 1,
               let installation = model.bsManagerInstallations.first {
                Button {
                    model.launchBSManager(installation)
                } label: {
                    Label(L(.libraryOpenBSManager), systemImage: "arrow.up.forward.app")
                }
                .disabled(model.sessionState.isActive)
            } else if !model.bsManagerInstallations.isEmpty {
                Menu {
                    ForEach(model.bsManagerInstallations) { installation in
                        Button(installation.bottleName) {
                            model.launchBSManager(installation)
                        }
                    }
                } label: {
                    Label(L(.libraryOpenBSManager), systemImage: "arrow.up.forward.app")
                }
                .fixedSize()
                .disabled(model.sessionState.isActive)
            }

            Menu {
                Button(model.bsManagerInstallations.isEmpty
                       ? L(.libraryInstallWindows) : L(.libraryUpdateWindows)) {
                    chooseBSManagerInstaller(model, present: present)
                }
                .disabled(model.sessionState.isActive)
                Button(L(.libraryOfficialReleases)) {
                    NSWorkspace.shared.open(URL(
                        string: "https://github.com/Zagrios/bs-manager/releases/latest")!)
                }
                Divider()
                Button(L(.libraryLocateInstances)) { locateBSManager(model) }
            } label: {
                if model.bsManagerInstallations.isEmpty {
                    Label(L(.libraryInstallBSManagerAction), systemImage: "arrow.down.circle")
                } else {
                    Label(L(.libraryMore), systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
            }
            .menuIndicator(model.bsManagerInstallations.isEmpty ? .visible : .hidden)
            .fixedSize()
            .accessibilityLabel(model.bsManagerInstallations.isEmpty ? L(.libraryInstallBSManagerAction) : L(.libraryMoreBSManager))
            .help(L(.libraryBSManagerHelp))
        }
        .buttonStyle(TBQuietButtonStyle(compact: true))
    }

}

@MainActor
private func chooseBSManagerInstaller(_ model: BasaltAppModel, present: (LibrarySheet) -> Void) {
    guard !model.bottles.isEmpty else {
        model.alertMessage = L(.libraryNeedBottle)
        return
    }
    guard let url = FilePanels.chooseFile(
        title: L(.libraryInstallerTitle),
        message: L(.libraryInstallerMessage),
        extensions: ["exe"]) else { return }
    present(.installBSManager(url))
}

private struct BSManagerHint: View {
    let hasLauncher: Bool

    var body: some View {
        HStack(spacing: 14) {
            PixelIcon(glyph: .library, size: 24, color: TB.textSecondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(hasLauncher ? L(.libraryNoVersions) : L(.libraryModBeatSaber))
                    .font(TB.Typography.cardTitle)
                    .foregroundStyle(TB.textPrimary)
                Text(hasLauncher
                     ? L(.libraryVersionsHint)
                     : L(.libraryInstallHint))
                    .font(TB.Typography.body)
                    .foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tiles

private struct SteamGameTile: View {
    let game: SteamGame
    @ObservedObject var model: BasaltAppModel
    /// This card carries its profile's marks for a learning step.
    let marked: Bool
    let present: (LibrarySheet) -> Void

    var body: some View {
        let profile = model.profile(for: game)
        GameTile(
            title: game.name,
            subtitle: metadata,
            titleHelp: L(.libraryBottleName, game.bottleName),
            artwork: game.artwork.map(GameArtwork.image)
                ?? .generated(glyph: .library, caption: nil),
            chips: chips,
            profileName: profile?.name,
            marked: marked,
            model: model,
            presentOpenVR: { if let profile { present(.openVR(profile)) } }
        ) {
            if game.bottleOrigin == .managed {
                Button {
                    Task { await model.createSteamProfile(for: game) }
                } label: {
                    Text(L(.libraryCreateProfile)).frame(maxWidth: .infinity)
                }
                .help(L(.libraryCreateProfileHelp))
                .tourTarget(.chapter(.libraryGameAction(game.id)), onAccent: true)
            } else {
                Button {
                    if let bottle = model.discoveredBottles.first(where: { $0.id == game.bottleID }) {
                        present(.importBottle(bottle))
                    } else {
                        model.alertMessage = L(.librarySourceMissing)
                    }
                } label: {
                    Text(L(.libraryCopy)).frame(maxWidth: .infinity)
                }
                .help(L(.libraryCopyHelp))
                .tourTarget(.chapter(.libraryGameAction(game.id)), onAccent: true)
            }
        } menu: {
            if let profile {
                ProfileMenuItems(profile: profile, present: present)
                Divider()
            }
            Button(L(.libraryShowGameFiles)) {
                NSWorkspace.shared.activateFileViewerSelecting([game.installDirectory])
            }
        }
    }

    private var chips: [String] {
        var chips = [game.bottleOrigin == .managed ? L(.commonTrailBridge) : game.bottleOrigin.label]
        if game.isKnownVRGame {
            chips.append(L(.commonVR))
        }
        return chips
    }

    private var metadata: String {
        var parts = [String]()
        if let size = game.sizeOnDisk {
            parts.append(size.formatted(.byteCount(style: .file).locale(L10n.language.locale)))
        }
        if let played = game.lastPlayed {
            parts.append(L(.libraryPlayed, played.formatted(.relative(presentation: .named).locale(L10n.language.locale))))
        }
        return parts.joined(separator: " · ")
    }
}

private struct BSManagerInstanceTile: View {
    let instance: BSManagerInstance
    @ObservedObject var model: BasaltAppModel
    let marked: Bool
    let present: (LibrarySheet) -> Void

    var body: some View {
        let profile = model.profile(for: instance)
        GameTile(
            title: L(.libraryBeatSaberVersion, instance.name),
            subtitle: instance.bottleName.map { L(.libraryBSManagerBottle, $0) } ?? L(.commonBSManager),
            detail: instance.isModded ? L(.libraryModdedBSIPA) : L(.libraryVanilla),
            artwork: .executableIcon(instance.executable, caption: instance.version),
            chips: [L(.commonBSManager)] + (instance.isModded ? [L(.libraryModded)] : []),
            profileName: profile?.name,
            marked: marked,
            model: model,
            presentOpenVR: { if let profile { present(.openVR(profile)) } }
        ) {
            if profile == nil {
                Button { createProfile() } label: {
                    Text(L(.libraryCreateProfile)).frame(maxWidth: .infinity)
                }
                .help(L(.libraryCreateInBottleHelp))
            }
        } menu: {
            if let profile {
                ProfileMenuItems(profile: profile, present: present)
                Divider()
            }
            Button(L(.libraryShowInstance)) {
                NSWorkspace.shared.activateFileViewerSelecting([instance.executable])
            }
        }
    }

    private func createProfile() {
        let bottle = instance.bottleName.flatMap { name in
            model.bottles.first { $0.name == name }
        } ?? (model.bottles.count == 1 ? model.bottles.first : nil)
        if let bottle {
            Task { await model.createBSManagerProfile(for: instance, in: bottle) }
        } else {
            present(.chooseBottle(instance))
        }
    }
}

private struct DetectedGameTile: View {
    let game: DetectedGame
    @ObservedObject var model: BasaltAppModel
    let marked: Bool
    let present: (LibrarySheet) -> Void

    var body: some View {
        let profile = game.profileName.flatMap { name in
            model.profiles.first { $0.name == name }
        }
        let steamGame = game.profileName.flatMap(model.steamGame(forProfileNamed:))
        GameTile(
            title: steamGame?.name ?? game.title,
            subtitle: L(.libraryBottleName, game.bottleName),
            metaHelp: game.executable,
            artwork: artwork(steamGame: steamGame),
            chips: [sourceName],
            extraChips: verificationChips(for: profile),
            profileName: game.profileName,
            marked: marked,
            model: model,
            presentOpenVR: { if let profile { present(.openVR(profile)) } }
        ) {
            if game.profileName == nil {
                Button {
                    Task { await model.createProfile(for: game) }
                } label: {
                    Text(L(.libraryCreateProfile)).frame(maxWidth: .infinity)
                }
            }
        } menu: {
            if let profile {
                ProfileMenuItems(profile: profile, present: present)
            }
            if let executable = game.hostExecutable {
                if profile != nil { Divider() }
                Button(L(.libraryShowInFinder)) {
                    NSWorkspace.shared.activateFileViewerSelecting([executable])
                }
            }
        }
    }

    /// A Steam game's profile shows the game's Steam artwork, like its Steam
    /// card; other games show the icon inside their executable.
    private func artwork(steamGame: SteamGame?) -> GameArtwork {
        if let art = steamGame?.artwork { return .image(art) }
        if let executable = game.hostExecutable { return .executableIcon(executable, caption: nil) }
        return .generated(glyph: .library, caption: nil)
    }

    private var sourceName: String {
        switch game.source {
        case .direct: L(.libraryDirect)
        case .steam: L(.commonSteam)
        case .bsmanager: L(.commonBSManager)
        case .itch: L(.commonItch)
        }
    }

    /// "Not verified" for a profile whose game no headset test covered; the
    /// tiles of the verified Steam games stay as they were.
    private func verificationChips(for profile: LaunchProfile?) -> [(text: String, kind: Chip.Kind)] {
        guard let profile, !SteamCatalogGame.isVerified(profile: profile) else { return [] }
        return [(L(.wizardUnverified), .unverified)]
    }
}

private struct ProfileMenuItems: View {
    let profile: LaunchProfile
    let present: (LibrarySheet) -> Void

    var body: some View {
        Button(L(.libraryEditProfile)) { present(.edit(profile)) }
        Button(L(.libraryStreamSettings)) { present(.settings(profile.name)) }
        Button(L(.libraryOpenVRSupport)) { present(.openVR(profile)) }
    }
}

/// One card shape for every library source: artwork, title block, and a
/// play/setup action with a secondary menu.
private struct GameTile<SetupAction: View, MenuItems: View>: View {
    let title: String
    let subtitle: String
    var detail: String?
    var titleHelp: String?
    var metaHelp: String?
    let artwork: GameArtwork
    var chips: [String] = []
    /// Chips after the status chip, each of its own kind, such as "Not
    /// verified". None unless a tile passes them.
    var extraChips: [(text: String, kind: Chip.Kind)] = []
    /// The launch profile backing this tile, when it is ready to play.
    let profileName: String?
    /// A learning step can point at this card and its status label. False
    /// on the second card of a game that is listed twice.
    var marked = false
    @ObservedObject var model: BasaltAppModel
    let presentOpenVR: () -> Void
    @ViewBuilder var setupAction: SetupAction
    @ViewBuilder var menu: MenuItems
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    private var isLive: Bool {
        guard let profileName else { return false }
        return model.sessionState == .streaming(profile: profileName)
    }

    private var isStarting: Bool {
        guard let profileName else { return false }
        return model.sessionState == .starting(profile: profileName)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TB.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            GameArtworkView(artwork: artwork)
                .overlay(alignment: .topLeading) {
                    if isLive {
                        LiveBadge().padding(10)
                    }
                }
                .overlay {
                    if let profileName, hovering, !model.sessionState.isActive, !model.isImportingGameFolder {
                        Button {
                            Task { await model.launch(profileName: profileName) }
                        } label: {
                            PixelIcon(glyph: .play, size: 16, color: TB.onLava)
                                .frame(width: 52, height: 52)
                                .background(TB.lava, in: Circle())
                                .overlay(Circle().strokeBorder(TB.lavaRim))
                                .shadow(color: TB.lavaGlow, radius: 7, y: 4)
                        }
                        .buttonStyle(.plain)
                        .transition(reduceMotion ? .identity : .opacity)
                        .accessibilityLabel(L(.libraryPlayTitle, title))
                        .help(L(.libraryPlayTitle, title))
                    }
                }

            VStack(alignment: .leading, spacing: TB.Spacing.cardInner) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TB.Typography.cardTitle)
                        .foregroundStyle(TB.textPrimary)
                        .lineLimit(1)
                        .help(titleHelp.map { "\(title)\n\($0)" } ?? title)
                    Text(subtitle)
                        .font(TB.Typography.meta)
                        .foregroundStyle(TB.textSecondary)
                        .lineLimit(1)
                        .help(metaHelp ?? subtitle)
                    if let detail {
                        Text(detail)
                            .font(TB.Typography.meta)
                            .foregroundStyle(TB.textSecondary)
                            .lineLimit(1)
                    }
                }
                // One stop for the title block; the chips and buttons stay separate.
                .accessibilityElement(children: .combine)

                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(chips.enumerated()), id: \.offset) {
                        Chip(text: $0.element, kind: .neutral)
                    }
                    if let profileName {
                        statusChip(for: profileName)
                            .tourTarget(marked ? .chapter(.libraryStatusChip(profileName)) : nil)
                    }
                    ForEach(Array(extraChips.enumerated()), id: \.offset) {
                        Chip(text: $0.element.text, kind: $0.element.kind)
                    }
                }

                if let profileName {
                    effectiveSettings(for: profileName)
                }

                HStack(spacing: 8) {
                    primaryAction
                    Menu { menu } label: {
                        Image(systemName: "ellipsis")
                            .font(TB.Typography.body.weight(.semibold))
                            .foregroundStyle(TB.textTertiary)
                            .frame(width: TB.Size.iconButton, height: TB.Size.iconButton)
                            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: TB.Radius.primaryButton))
                            .overlay(RoundedRectangle(cornerRadius: TB.Radius.primaryButton).strokeBorder(TB.quietBorder))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(L(.commonMoreActions))
                    .help(L(.commonMoreActions))
                }
                .lineLimit(1)
                // The buttons sit at the bottom of a card that a taller
                // neighbour in its row has stretched.
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.top, TB.Spacing.cardTop)
            .padding(.horizontal, TB.Spacing.cardSides)
            .padding(.bottom, TB.Spacing.cardSides)
        }
        // A grid row offers its cells the tallest one's height: every card
        // in a row is as tall as the tallest.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(TB.cardBackground)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isLive ? TB.emberBorder : hovering ? TB.emberBorder.opacity(contrast == .increased ? 1 : 0.5) : TB.cardBorder,
                lineWidth: contrast == .increased ? 2 : 1))
        .overlay {
            if isLive {
                shape.stroke(TB.lava.opacity(0.10), lineWidth: 3).padding(-1.5)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: isLive ? TB.activeShadow : .clear, radius: 14, y: 8)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .onHover { hovering = $0 }
        .tourTarget(marked ? profileName.map { TourTargetID.chapter(.libraryGameTile($0)) } : nil)
    }

    @ViewBuilder private func statusChip(for profileName: String) -> some View {
        let state = model.openVRBadges[profileName]
        let presentation = OpenVRStatusChip.presentation(for: state)
        let text = switch state {
        case .installed: L(.libraryOpenVRReady)
        case .needsSetup: L(.libraryOpenVRSetup)
        case .some(.none), nil: L(.libraryReady)
        }
        let kind: Chip.Kind = presentation.showsCheckmark ? .success : .warning
        // The chip text is short capitals; VoiceOver gets a plain sentence.
        let spoken = switch state {
        case .installed: L(.libraryOpenVRReadyAccessibility)
        case .needsSetup: L(.libraryOpenVRSetupAccessibility)
        case .some(.none), nil: L(.libraryReadyAccessibility)
        }
        if presentation.help != nil {
            Button(action: presentOpenVR) {
                Chip(text: text, kind: kind)
            }
            .buttonStyle(.plain)
            .help(state == .needsSetup
                  ? L(.libraryOpenVRSetupHelp)
                  : L(.libraryOpenVRInstalledHelp))
            .accessibilityLabel(spoken)
        } else {
            Chip(text: text, kind: kind)
                .accessibilityLabel(spoken)
        }
    }

    private func effectiveSettings(for profileName: String) -> some View {
        let settings = model.streamSettings(for: profileName)
        let scope = model.profileSettings[profileName] != nil ? L(.libraryPerGame) : L(.libraryGlobal)
        let resolution = settings.resolution.perEyeResolution
        let dimensions = L(.commonDimensions, String(resolution.width), String(resolution.height))
        let values = L(.libraryEffectiveSettings, presetTitle(settings.qualityPreset), dimensions, Int64(settings.fps))
        let plaque = Text(scope)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(TB.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: 5))

        // Always the same two lines, whatever the texts' length: a line of
        // its own for the scope kept one card lower than its neighbours
        // whenever "General" and the values fitted side by side. The hidden
        // line holds the height when the values shrink.
        return VStack(alignment: .leading, spacing: 4) {
            plaque
            ZStack(alignment: .leading) {
                Text(verbatim: "Ag").hidden().accessibilityHidden(true)
                Text(values).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .font(TB.Typography.caption)
        .foregroundStyle(TB.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(TB.settingsStripFill, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .help(L(.libraryEffectiveSettingsHelp))
    }

    private func presetTitle(_ preset: StreamQualityPreset) -> String {
        switch preset {
        case .performance: L(.libraryPresetPerformance)
        case .balanced: L(.libraryPresetBalanced)
        case .quality: L(.libraryPresetQuality)
        case .high: L(.libraryPresetHigh)
        case .maximum: L(.libraryPresetMaximum)
        case .custom: L(.libraryPresetCustom)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if let profileName {
            if isLive {
                Button(role: .destructive) { model.stop() } label: {
                    Text(L(.commonStop)).frame(maxWidth: .infinity)
                }
                .buttonStyle(TBHeroStopButtonStyle(compact: true))
            } else if isStarting {
                Button {} label: {
                    HStack(spacing: 8) {
                        // The text says it; the indicator's "Working…" would repeat it.
                        TBProgressIndicator().controlSize(.small).accessibilityHidden(true)
                        Text(L(.libraryStarting))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TBPrimaryButtonStyle())
                .disabled(true)
            } else {
                Button {
                    Task { await model.launch(profileName: profileName) }
                } label: {
                    HStack(spacing: 8) {
                        PixelIcon(glyph: .play, size: 8, color: TB.onLava)
                        Text(L(.libraryPlay))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TBPrimaryButtonStyle())
                .disabled(model.sessionState.isActive || model.isImportingGameFolder)
            }
        } else {
            setupAction
                .buttonStyle(TBPrimaryButtonStyle())
        }
    }
}

// MARK: - Artwork

enum GameArtwork {
    case image(URL)
    /// The icon inside a Windows executable; the generated art with this
    /// caption stands in while it loads or when the file has none.
    case executableIcon(URL, caption: String?)
    case generated(glyph: PixelGlyph, caption: String?)
}

private struct GameArtworkView: View {
    let artwork: GameArtwork

    var body: some View {
        // Steam's library header art is 460 × 215.
        Color.clear
            .aspectRatio(460.0 / 215.0, contentMode: .fit)
            .overlay {
                switch artwork {
                case .image(let url):
                    ArtworkImage(url: url).id(url)
                case .executableIcon(let url, let caption):
                    ExecutableIconArt(executable: url) {
                        GeneratedArtwork(glyph: .library, caption: caption)
                    }
                    .id(url)
                case .generated(let glyph, let caption):
                    GeneratedArtwork(glyph: glyph, caption: caption)
                }
            }
            .clipped()
            // A poster-shaped cover (300x450) filling this 460:215 frame is
            // drawn clipped but still catches the mouse where it is not
            // visible: it reached far above and below the card and swallowed
            // the clicks meant for the card's own Play button and for its
            // neighbours. Clipping hides it; this keeps the mouse inside.
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}

private enum ArtworkCache {
    static let images = NSCache<NSURL, NSImage>()
}

/// Loads local Steam artwork off the main thread once, then serves it from
/// memory so library re-renders never touch the disk.
struct ArtworkImage: View {
    let url: URL
    @State private var image: NSImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(url: URL) {
        self.url = url
        _image = State(initialValue: ArtworkCache.images.object(forKey: url as NSURL))
    }

    var body: some View {
        ZStack {
            GeneratedArtwork(glyph: .library, caption: nil)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .task {
            guard image == nil else { return }
            let url = url
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url)
            }.value
            guard let data, let loaded = NSImage(data: data) else { return }
            ArtworkCache.images.setObject(loaded, forKey: url as NSURL)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

private struct GeneratedArtwork: View {
    let glyph: PixelGlyph
    let caption: String?

    var body: some View {
        ZStack {
            TB.artPlaceholder
            GeometryReader { geometry in
                Path { path in
                    let cell = TB.Size.checkerCell
                    let rows = Int(ceil(geometry.size.height / cell))
                    let columns = Int(ceil(geometry.size.width / cell))
                    for row in 0..<rows {
                        for column in 0..<columns where (row + column).isMultiple(of: 2) {
                            path.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell,
                                                width: cell, height: cell))
                        }
                    }
                }
                .fill(TB.artChecker, style: FillStyle(antialiased: false))
            }
            VStack(spacing: 8) {
                PixelIcon(glyph: glyph, size: 24, color: TB.textSecondary)
                if let caption {
                    Text(caption)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(TB.textSecondary)
            .padding(14)
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

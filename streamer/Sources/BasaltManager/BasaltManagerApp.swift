import SwiftUI
import AppKit
import BasaltManagerKit
import BasaltBottleKit
import Darwin
import Combine

@main
@MainActor
private enum TrailBridgeEntry {
    static func main() {
        // A packaged app has its support files inside its own bundle and
        // starts from them in this process: no checkout, no script.
        if let start = PackagedStart.plan(environment: ProcessInfo.processInfo.environment,
                                          resourceURL: Bundle.main.resourceURL) {
            for (name, value) in start.environment { setenv(name, value, 1) }
            FileManager.default.changeCurrentDirectoryPath(start.supportRoot.path)
        }
        // Finder does not inherit the development shell. Re-enter the same
        // workspace environment before initializing SwiftUI, caches or the model.
        if ProcessInfo.processInfo.environment["BASALT_REPO_ROOT"] == nil {
            do {
                let repo = try RepositoryLocator.find(startingAt: Bundle.main.bundleURL)
                let wrapper = repo.appendingPathComponent("scripts/trailbridge-dev.zsh").path
                let arguments = [wrapper, CommandLine.arguments[0]] + Array(CommandLine.arguments.dropFirst())
                let pointers = arguments.map { strdup($0) } + [nil]
                pointers.withUnsafeBufferPointer { buffer in
                    _ = execv(wrapper, buffer.baseAddress!)
                }
                pointers.forEach { free($0) }
                fputs(L(.startupEnvironmentFailure) + "\n", stderr)
            } catch { fputs(L(.startupWorkspaceFailure) + "\n", stderr) }
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = BasaltApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// SwiftUI assigns automatic frame/split-view preference keys. The workspace
/// owns persistence instead, so AppKit must not save those in the Mac profile.
private struct WorkspaceWindowPolicy: NSViewRepresentable {
    final class PolicyView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            guard let window else { return }
            window.isRestorable = false
            window.setFrameAutosaveName("")
            func clearAutosave(_ view: NSView) {
                (view as? NSSplitView)?.autosaveName = nil
                view.subviews.forEach(clearAutosave)
            }
            if let content = window.contentView { clearAutosave(content) }
        }
    }

    func makeNSView(context: Context) -> PolicyView { PolicyView() }
    func updateNSView(_ view: PolicyView, context: Context) {
        view.apply()
        DispatchQueue.main.async { view.apply() }
    }
}

@MainActor
private final class BasaltApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model = BasaltAppModel()
    /// The Learning highlight; holds nothing while no step is shown.
    private let tour = TourHighlight()
    private lazy var learning = LearningController(model: model, highlight: tour) { [weak self] in
        self?.window
    }
    private var window: NSWindow?
    private var aboutWindow: NSWindow?
    private var languageObservation: AnyCancellable?
    private var appearanceObservation: AnyCancellable?

    func applicationShouldSaveSecureApplicationState(_ app: NSApplication) -> Bool { false }
    func applicationShouldRestoreSecureApplicationState(_ app: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Own the window directly: SwiftUI WindowGroup assigns persistent frame
        // keys even when restoration and frame autosave are cleared afterwards.
        NSWindow.allowsAutomaticWindowTabbing = false
        // App-wide, so the About window and menus follow the Settings choice too.
        // @Published emits the new value before it is stored; use the emitted value.
        appearanceObservation = model.$appearance.sink { appearance in
            NSApp.appearance = appearance.nsAppearance
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TrailBridge VR"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 940, height: 640)
        window.contentViewController = NSHostingController(rootView:
            RootView(model: model, showAbout: { [weak self] in self?.showAbout() })
                .environment(\.tourHighlight, tour)
                .environment(\.learning, learning)
                .frame(minWidth: 940, minHeight: 640)
                .background(WorkspaceWindowPolicy()))
        window.center()
        self.window = window
        installMenu()
        // @Published emits before didSet updates L10n. Deliver on the next main
        // run-loop turn so AppKit reads the new language, just like SwiftUI.
        languageObservation = model.$language.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.installMenu()
            if let window = self?.aboutWindow { self?.updateAboutWindow(window) }
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasClaimedGameLogCapture else { return .terminateNow }
        Task {
            await model.waitForClaimedGameLogCaptures()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // First, and at once: a chapter under way is written to disk before
        // the wait for Wine, which can outlast the time the app is given.
        learning.willTerminate()
        model.abandonWineDownload()
        model.stop(waitingForWine: true)
        // After the streamer, which still removes its adb forwards.
        HeadsetSetup(dataRoot: model.dataRoot).stopServerIfStartedHere()
    }

    private func installMenu() {
        let bar = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            item.submenu = menu
            bar.addItem(item)
            return menu
        }
        func add(_ title: String, to menu: NSMenu, action: Selector,
                 key: String = "", target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            menu.addItem(item)
            return item
        }
        let app = submenu(L(.appName))
        _ = add(L(.menuAbout), to: app, action: #selector(showAbout), target: self)
        app.addItem(.separator())
        _ = add(L(.menuSettings), to: app, action: #selector(showSettings), key: ",", target: self)
        app.addItem(.separator())
        _ = add(L(.menuHide), to: app, action: #selector(NSApplication.hide(_:)), key: "h")
        _ = add(L(.menuQuit), to: app, action: #selector(NSApplication.terminate(_:)), key: "q")

        let edit = submenu(L(.menuEdit))
        for (title, action, key) in [
            (L(.menuUndo), "undo:", "z"), (L(.menuCut), "cut:", "x"), (L(.menuCopy), "copy:", "c"),
            (L(.menuPaste), "paste:", "v"), (L(.menuSelectAll), "selectAll:", "a")
        ] { _ = add(title, to: edit, action: NSSelectorFromString(action), key: key) }

        let view = submenu(L(.menuView))
        for (index, section) in ManagerSection.allCases.enumerated() {
            let item = add(section.title, to: view, action: #selector(showSection(_:)),
                           key: "\(index + 1)", target: self)
            item.tag = index
        }
        view.addItem(.separator())
        _ = add(L(.menuRefresh), to: view, action: #selector(refresh), key: "r", target: self)
        let session = submenu(L(.menuSession))
        _ = add(L(.menuStopSession), to: session, action: #selector(stopSession), key: ".", target: self)
        let windows = submenu(L(.menuWindow))
        _ = add(L(.menuMinimize), to: windows, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        _ = add(L(.menuZoom), to: windows, action: #selector(NSWindow.performZoom(_:)))
        NSApplication.shared.windowsMenu = windows
        let help = submenu(L(.menuHelp))
        _ = add(L(.learningTitle), to: help, action: #selector(showLearning), target: self)
        _ = add(L(.learningQuickPathTitle), to: help, action: #selector(startQuickPath), target: self)
        _ = add(L(.menuDiagnostics), to: help, action: #selector(showDiagnostics), target: self)
        NSApplication.shared.mainMenu = bar
    }

    @objc private func showAbout() {
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setFrameAutosaveName("")
        updateAboutWindow(window)
        window.center()
        aboutWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func updateAboutWindow(_ window: NSWindow) {
        window.title = L(.menuAbout)
        let controller = NSHostingController(rootView: AboutView(model: model)
            .background(WorkspaceWindowPolicy()))
        window.contentViewController = controller
        window.setContentSize(controller.view.fittingSize)
    }

    @objc private func showSettings() { model.selection = .settings }
    @objc private func showDiagnostics() { model.showingDiagnostics = true }
    @objc private func showLearning() { learning.openLearning() }
    @objc private func startQuickPath() { learning.startQuickPath() }
    @objc private func showSection(_ sender: NSMenuItem) {
        let sections = Array(ManagerSection.allCases)
        guard sections.indices.contains(sender.tag) else { return }
        model.selection = sections[sender.tag]
    }
    @objc private func refresh() { Task { await model.refresh() } }
    @objc private func stopSession() { model.stop() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(refresh): return !model.isBusy
        case #selector(stopSession): return model.sessionState.isActive
        // Neither leaves a section whose sheet is open.
        case #selector(showLearning): return learning.canOpenLearning
        case #selector(startQuickPath): return learning.canOfferQuickPath
        default: return true
        }
    }
}

private struct RootView: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.learning) private var learning
    let showAbout: () -> Void

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, showAbout: showAbout)
                .navigationSplitViewColumnWidth(min: 200, ideal: TB.Size.sidebarIdeal, max: 280)
        } detail: {
            Group {
                // A settings file that cannot be read comes before every
                // page, Settings included: nothing could be saved there.
                if model.settingsFileProblem != nil {
                    SettingsFileGateView(model: model)
                // Until the data folder answers, only Settings is shown: no
                // other page may read it or create anything in its place.
                } else if model.dataFolderState != .ready, model.selection != .settings {
                    DataFolderGateView(model: model)
                } else {
                    switch model.selection {
                    case .library: LibraryView(model: model)
                    case .steam: SteamView(model: model)
                    case .stream: StreamDashboardView(model: model)
                    case .bottles: BottlesView(model: model)
                    case .headset: HeadsetView(model: model)
                    case .setup: SetupView(model: model)
                    case .settings: SettingsView(model: model)
                    case .diagnostics: DiagnosticsView(model: model)
                    case .learning:
                        if let learning { LearningView(model: model, learning: learning) }
                    }
                }
            }
            // Empty, and so no inset, unless a learning step is shown.
            .safeAreaInset(edge: .top, spacing: 0) { TourHintStrip() }
            .background(TB.windowBackground)
            .toolbar {
                ToolbarItem {
                    if model.isBusy {
                        TBProgressIndicator()
                            .accessibilityLabel(L(.toolbarScanning))
                            .controlSize(.small)
                            .help(L(.toolbarScanning))
                    } else {
                        Button { Task { await model.refresh() } } label: {
                            Label(L(.menuRefresh), systemImage: "arrow.clockwise")
                        }
                        .accessibilityLabel(L(.menuRefresh))
                        .help(L(.toolbarRefreshHelp))
                    }
                }
            }
        }
        .tint(TB.lava)
        .sheet(item: $model.headsetConfirmation) { action in
            HeadsetDownloadSheet(confirmation: action, model: model)
        }
        .sheet(isPresented: $model.showingWineDownload) {
            WineDownloadSheet(model: model)
        }
        .sheet(item: $model.headsetRequest, onDismiss: {
            if !model.headsetRequests.isEmpty { model.headsetRequest = model.headsetRequests.removeFirst() }
        }) { request in
            HeadsetRequestSheet(request: request, model: model)
        }
        .sheet(isPresented: $model.showingDiagnostics) {
            DiagnosticReportSheet(model: model)
        }
        .alert(L(.appName), isPresented: Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )) {
            Button(L(.commonOK)) { model.alertMessage = nil }
            // Only for the launch failures Learning knows how to fix, and not
            // while the quick path's own strip already shows that advice.
            if let learning, !learning.tourShowsFailure,
               let advice = model.alertMessage.flatMap(learning.advice(for:)) {
                Button(L(.learningHowToFix)) {
                    model.alertMessage = nil
                    learning.showAdvice(advice)
                }
            }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .id(model.language)
        .environment(\.locale, model.language.locale)
        .tbReducedMotion()
    }
}

extension ManagerSection {
    var title: String {
        switch self {
        case .library: return L(.sidebarLibrary)
        case .steam: return L(.commonSteam)
        case .stream: return L(.sidebarStream)
        case .headset: return L(.sidebarHeadset)
        case .bottles: return L(.sidebarBottles)
        case .setup: return L(.sidebarSetup)
        case .settings: return L(.sidebarSettings)
        case .diagnostics: return L(.sidebarDiagnostics)
        case .learning: return L(.learningTitle)
        }
    }

    var pixelGlyph: PixelGlyph {
        switch self {
        case .library: return .library
        case .steam: return .steam
        case .stream: return .stream
        case .headset: return .headset
        case .bottles: return .bottles
        case .setup: return .setup
        case .settings: return .settings
        case .diagnostics: return .diagnostics
        case .learning: return .learning
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var model: BasaltAppModel
    @Environment(\.openURL) private var openURL
    @FocusState private var focusedSection: ManagerSection?
    /// The window's own first focus has been checked.
    @State private var checkedFirstFocus = false
    let showAbout: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.learning).padding(.top, 8)
                    groupLabel(L(.sidebarPlay))
                    row(.library)
                    row(.steam)
                    row(.stream)
                    groupLabel(L(.sidebarManage))
                    row(.headset)
                    row(.bottles)
                    row(.setup)
                    row(.settings)
                    row(.diagnostics)
                }
                .padding(.horizontal, 10)
            }
            .scrollContentBackground(.hidden)

            VStack(spacing: 0) {
                SessionSidebarCard(model: model)
                credits
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
            .padding(10)
        }
        // The window gives its first focusable view the keyboard focus. That
        // was Library, the section the app opens on; with Learning above it,
        // the focus outline would sit on an unselected row from the start.
        // `.defaultFocus` does not reach that first focus, so it moves to the
        // selected row once. A click focuses the row it is about to select
        // and is left alone.
        .onChange(of: focusedSection) { _, focused in
            guard !checkedFirstFocus, let focused else { return }
            checkedFirstFocus = true
            let type = NSApp.currentEvent?.type
            guard type != .leftMouseDown, type != .leftMouseUp,
                  focused != model.selection else { return }
            focusedSection = model.selection
        }
        // The app changes the section itself too: a launch opens Stream, a
        // learning step opens its page, the first launch opens Learning.
        // While the keyboard focus is in the sidebar it goes along, or its
        // outline would stay on a row that is no longer the selected one.
        // A click or a key press has already focused the row it selects.
        .onChange(of: model.selection) { _, selection in
            guard let focused = focusedSection, focused != selection else { return }
            focusedSection = selection
        }
        .background { SidebarBackground() }
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(TB.Typography.groupLabel)
            .foregroundStyle(TB.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ section: ManagerSection) -> some View {
        let selected = model.selection == section
        return Button { model.selection = section } label: {
            HStack(spacing: TB.Spacing.navGap) {
                PixelIcon(glyph: section.pixelGlyph, color: selected ? TB.lavaText : TB.iconIdle)
                Text(section.title)
                    .font(TB.Typography.navRow(selected: selected))
                    .foregroundStyle(selected ? TB.navSelectedText : TB.navText)
                    .lineLimit(1)
                    .help(section.title)
                Spacer(minLength: 0)
                switch section {
                case .library:
                    CountBadge(count: model.libraryItemCount, selected: selected)
                case .bottles:
                    CountBadge(count: model.discoveredBottles.count, selected: selected)
                case .setup:
                    if model.missingRequiredSetupCount > 0 {
                        CountBadge(count: model.missingRequiredSetupCount, selected: selected)
                            .help(L(.sidebarMissingSteps, Int64(model.missingRequiredSetupCount)))
                    }
                case .stream:
                    if model.sessionState.isStreaming { LiveBadge(small: true) }
                case .diagnostics:
                    // Stays while any game records, so the switch is not forgotten.
                    if !model.recordingProfileNames.isEmpty {
                        RecordingBadge()
                            .help(L(.sidebarRecordingOn, model.recordingProfileNames.joined(separator: ", ")))
                    }
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, TB.Spacing.navHorizontal)
            .frame(height: TB.Size.navRow)
            .background(selected ? TB.selectionFill : .clear,
                        in: RoundedRectangle(cornerRadius: TB.Radius.navRow))
            .contentShape(RoundedRectangle(cornerRadius: TB.Radius.navRow))
        }
        .buttonStyle(.plain)
        // The sidebar does not scroll to a row, so no id is needed.
        .tourTarget(section == .stream ? .topic(.sidebarStream) : nil, scrolls: false)
        .focusable()
        .focused($focusedSection, equals: section)
        .focusEffectDisabled()
        .overlay {
            // The system focus ring clashes with the lava selection; mark
            // keyboard focus only on rows that are not already selected, and
            // not beside a learning step's own outline.
            if focusedSection == section && !selected {
                HiddenDuringTourStep {
                    RoundedRectangle(cornerRadius: TB.Radius.navRow)
                        .strokeBorder(TB.lavaText, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
        }
        .onKeyPress(.return) {
            model.selection = section
            return .handled
        }
        .onKeyPress(.space) {
            model.selection = section
            return .handled
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.title)
        .accessibilityValue(rowValue(section))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The row label replaces its children, so the badges are read as its value.
    private func rowValue(_ section: ManagerSection) -> String {
        switch section {
        case .library:
            return L10n.plural(.libraryGameCount, model.libraryItemCount)
        case .bottles:
            return L10n.plural(.environmentCount, model.discoveredBottles.count)
        case .setup where model.missingRequiredSetupCount > 0:
            return L(.sidebarMissingSteps, Int64(model.missingRequiredSetupCount))
        case .stream where model.sessionState.isStreaming:
            return L(.sessionStreaming)
        case .diagnostics where !model.recordingProfileNames.isEmpty:
            return L(.sidebarRecordingOn, model.recordingProfileNames.joined(separator: ", "))
        default:
            return ""
        }
    }

    private var credits: some View {
        HStack(spacing: 0) {
            Button(L(.commonGitHub)) { openURL(TBLinks.project) }
                .foregroundStyle(TB.link)
            Text(" · ").foregroundStyle(TB.textSecondary).accessibilityHidden(true)
            Button(L(.sidebarAbout), action: showAbout)
                .foregroundStyle(TB.link)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            if reduceTransparency {
                TB.sidebarBase
            } else if #available(macOS 26.0, *) {
                spots(size: geometry.size).opacity(0.35)
            } else {
                ZStack {
                    TB.sidebarBase
                    spots(size: geometry.size)
                    TB.sidebarVeil
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func spots(size: CGSize) -> some View {
        let side = max(size.width, size.height)
        return ZStack {
            RadialGradient(colors: [TB.sidebarPlum, .clear],
                           center: UnitPoint(x: 1, y: 0.1), startRadius: 0, endRadius: side * 0.60)
            RadialGradient(colors: [TB.sidebarEmber, .clear],
                           center: UnitPoint(x: 0.1, y: 0.95), startRadius: 0, endRadius: side * 0.55)
        }
    }
}

private struct SessionSidebarCard: View {
    @ObservedObject var model: BasaltAppModel

    private var state: SessionState { model.sessionState }

    private var fill: Color {
        switch state {
        case .stopped: return TB.quietFill
        case .starting: return TB.warningFill
        case .streaming: return TB.liveCardFill
        case .utility: return TB.selectionFill
        case .failed: return TB.dangerFill
        }
    }

    private var border: Color {
        switch state {
        case .streaming: return TB.liveCardBorder
        case .failed: return TB.dangerText
        default: return TB.cardBorder
        }
    }

    private var dotColor: Color {
        state.isStreaming ? TB.liveDot : state.tint
    }

    private var blinking: Bool {
        switch state {
        case .starting, .streaming: return true
        default: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.selection = .stream } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        StatusDot(color: dotColor, pulsing: blinking)
                        if state == .stopped {
                            Text(L(.sessionIdle))
                                .font(TB.Typography.body.weight(.semibold))
                                .foregroundStyle(TB.textPrimary)
                        } else {
                            StateLabel(state.eyebrow, size: 13)
                                .foregroundStyle(state.tint)
                                .lineLimit(1)
                                .help(state.eyebrow)
                        }
                        Spacer(minLength: 0)
                        if state.isStreaming {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(elapsed(at: context.date))
                                    .font(TB.Typography.body.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(TB.textPrimary)
                            }
                            .fixedSize()
                            // The Stream page exposes the clock; changing this
                            // button's label every second would make VoiceOver chatter.
                            .accessibilityHidden(true)
                        }
                    }
                    detail
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L(.sidebarOpenStream))

            if state.isActive {
                Button(role: .destructive) { model.stop() } label: {
                    Label(L(.commonStop), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(TBQuietButtonStyle(compact: true))
                .tourTarget(.chapter(.sidebarStop))
            }
        }
        .padding(.vertical, TB.Spacing.sidebarCardVertical)
        .padding(.horizontal, TB.Spacing.sidebarCardHorizontal)
        .tbGlassCard(tint: dotColor, fill: fill, border: border, cornerRadius: TB.Radius.sidebarCard)
        .tourTarget(.topic(.sidebarSession), scrolls: false)
        .contentShape(RoundedRectangle(cornerRadius: TB.Radius.sidebarCard))
        .onTapGesture { model.selection = .stream }
    }

    @ViewBuilder
    private var detail: some View {
        switch state {
        case .starting(let profile), .streaming(let profile):
            let title = model.gameTitle(forProfile: profile)
            Text(title)
                .font(TB.Typography.body.weight(.semibold))
                .foregroundStyle(TB.textPrimary)
                .lineLimit(1)
                .help(title)
            if state.isStreaming {
                let settings = model.displayedStreamSettings
                Text(L(.sidebarStreamSettings, Int64(settings.fps), settings.connection.shortLabel))
                    .font(TB.Typography.caption)
                    .foregroundStyle(TB.textSecondary)
            }
        case .stopped, .utility, .failed:
            Text(state.shortDetail)
                .font(TB.Typography.caption)
                .foregroundStyle(TB.textSecondary)
                .lineLimit(2)
                .help(state.shortDetail)
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let start = model.streamingStartedAt else { return "—" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return L(.sessionElapsed, Int64(seconds / 3600), Int64(seconds / 60 % 60), Int64(seconds % 60))
    }
}

enum TBLinks {
    static let upstream = URL(string: "https://github.com/frenchbaguetteman/BasaltVR")!
    static let project = URL(string: "https://github.com/abgitdev/TrailBridge-VR")!
    static let support = URL(string: "https://ko-fi.com/abgitdev")!
}

private struct AboutView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var showingLicenses = false

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                Text(L(.appName)).font(.system(size: 20, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                   let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                   !version.isEmpty, !build.isEmpty {
                    Text(L(.aboutVersion, version, build))
                        .font(TB.Typography.caption)
                        .foregroundStyle(TB.textSecondary)
                }
                // TrailBridge VR's own copyright; BasaltVR's stays in LICENSE.
                Text(verbatim: "© 2026 abgitdev")
                    .font(TB.Typography.caption)
                    .foregroundStyle(TB.textSecondary)
            }
            Text(L(.aboutDescription))
                .font(TB.Typography.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 3) {
                Link(L(.aboutBasedOn), destination: TBLinks.upstream)
                    .font(TB.Typography.body.weight(.semibold))
                Text(L(.aboutMITLicense))
                    .font(TB.Typography.caption)
                    .foregroundStyle(TB.textSecondary)
            }
            Rectangle().fill(TB.hairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                Link(destination: TBLinks.project) {
                    Label(L(.aboutProjectGitHub), systemImage: "arrow.up.right")
                }
                // Just the link: the project is free and asks nothing in return.
                Link(destination: TBLinks.support) {
                    Label(L(.aboutSupportKoFi), systemImage: "heart")
                }
                Button { showingLicenses = true } label: {
                    Label(L(.aboutLicenses), systemImage: "doc.text")
                }
                .buttonStyle(.plain)
            }
            .font(TB.Typography.body)
            .foregroundStyle(TB.link)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(TB.textPrimary)
        .padding(22)
        .frame(width: 340)
        .background(TB.windowBackground)
        .tint(TB.link)
        .sheet(isPresented: $showingLicenses) { LicensesSheet() }
        .id(model.language)
        .environment(\.locale, model.language.locale)
        .tbReducedMotion()
    }
}

private struct LicensesSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let documents = [
        (name: "LICENSE", extension: Optional<String>.none),
        (name: "THIRD_PARTY_NOTICES", extension: Optional("md"))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L(.licensesTitle)).font(TB.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            ScrollView([.horizontal, .vertical]) {
                Text(licenseText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(14)
            }
            .background(TB.sunkenBackground, in: RoundedRectangle(cornerRadius: TB.Radius.card))
            HStack {
                Spacer()
                Button(L(.commonClose)) { dismiss() }
                    .buttonStyle(TBQuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .foregroundStyle(TB.textPrimary)
        .padding(20)
        .frame(width: 640, height: 520)
        .background(TB.windowBackground)
    }

    private var licenseText: String {
        documents.map { document in
            let filename = document.name + (document.extension.map { "." + $0 } ?? "")
            var candidates = [Bundle.main.url(forResource: document.name, withExtension: document.extension)]
            candidates.append(Bundle.main.resourceURL?
                .appendingPathComponent("BasaltVR", isDirectory: true)
                .appendingPathComponent(filename))
            if let root = ProcessInfo.processInfo.environment["BASALT_REPO_ROOT"] {
                candidates.append(URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(filename))
            }
            let contents = candidates.compactMap { $0 }.lazy.compactMap {
                try? String(contentsOf: $0, encoding: .utf8)
            }.first
            return filename + "\n\n" + (contents ?? L(.licensesMissing))
        }.joined(separator: "\n\n")
    }
}

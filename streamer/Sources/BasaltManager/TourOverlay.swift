import SwiftUI
import BasaltManagerKit

// The Learning section points at real controls. A target draws its own
// outline, so nothing passes geometry up the view tree and the same marker
// works in sidebar rows, form rows, lazy grids, scroll views and sheets.
// While no step is shown, none of this draws or runs anything.

/// A control a learning step can point at.
enum TourTargetID: Hashable {
    /// "Play" in the Stream page's hero.
    case streamPlay
    /// The state label in the Stream page's hero.
    case streamStatus
    /// A control a chapter step points at.
    case chapter(SetupTarget)
    /// A control only a topic of "If something does not work" or "More"
    /// points at; the ones a chapter marks already keep the chapter's id.
    case topic(LearningTopicTarget)

    /// The page the control is on; nil for the sidebar.
    var section: LearningDestination? {
        switch self {
        case .streamPlay, .streamStatus: return .stream
        case .chapter(let target): return target.section
        case .topic(let target): return target.section
        }
    }
}

/// The text shown for the current step.
struct TourHint {
    struct Action {
        let title: String
        var isPrimary = false
        /// Set on a button that opens a short list of tips and further
        /// choices ("Not working?") instead of acting itself.
        var help: Help?
        var perform: () -> Void = {}
    }

    /// What a help button opens.
    struct Help {
        var tips = [String]()
        var actions = [Action]()
    }

    /// Changes whenever what is shown changes, so VoiceOver hears it once.
    let id: String
    /// "Step 2 of 3", already in the interface language.
    let stepLabel: String
    /// One or two short sentences.
    let text: String
    /// The strip shows the first two.
    var actions = [Action]()
    /// A quiet link under the text that opens its `help`: more to read for
    /// a step whose two buttons are both taken. Never one of the buttons.
    var link: Action?
    /// The close button; its title is read by VoiceOver and shown on hover.
    var close: Action?
    /// False for advice shown outside a tour: only a tour step hides the
    /// sidebar's keyboard-focus outline.
    var isTourStep = true
}

/// What is highlighted now. Kept apart from `BasaltAppModel`, so a step
/// redraws only the outlines and the hint strip.
@MainActor
final class TourHighlight: ObservableObject {
    @Published private(set) var target: TourTargetID?
    @Published private(set) var hint: TourHint?

    /// True while the strip shows a step of a tour.
    var showsTourStep: Bool { hint?.isTourStep == true }

    /// A hint without a target shows the strip alone. Showing what is shown
    /// already publishes nothing, so it redraws nothing.
    func show(target: TourTargetID?, hint: TourHint) {
        let shown = self.hint
        let isNewStep = hint.id != shown?.id
        // A button that comes or goes is drawn too, without a new announcement.
        guard isNewStep || target != self.target
                || hint.stepLabel != shown?.stepLabel || hint.text != shown?.text
                || hint.actions.map(\.title) != shown?.actions.map(\.title)
                || hint.link?.title != shown?.link?.title else { return }
        self.target = target
        self.hint = hint
        if isNewStep {
            AccessibilityNotification.Announcement("\(hint.stepLabel). \(hint.text)").post()
        }
    }

    func clear() {
        guard target != nil || hint != nil else { return }
        target = nil
        hint = nil
    }
}

private struct TourHighlightKey: EnvironmentKey {
    static let defaultValue: TourHighlight? = nil
}

extension EnvironmentValues {
    /// Optional on purpose: a window that was not given the object (About)
    /// draws no highlight instead of crashing like a missing environment object.
    var tourHighlight: TourHighlight? {
        get { self[TourHighlightKey.self] }
        set { self[TourHighlightKey.self] = newValue }
    }
}

// MARK: - Target outline

extension View {
    /// Marks a control a learning step can point at: it outlines itself while
    /// it is the current target, and gets a stable id to scroll to. In a form
    /// or list, mark the whole row: only a row's id can be scrolled to.
    /// `onAccent` is for a control filled with the accent colour, where the
    /// usual lava dashes would blend into the control beside them.
    /// A nil id marks nothing: for a view shared by a page and a sheet,
    /// where only the page may be pointed at. `scrolls: false` outlines a
    /// control inside a row without giving it the id; the row then gets the
    /// id with `tourScrollAnchor`.
    func tourTarget(_ id: TourTargetID?, onAccent: Bool = false, scrolls: Bool = true) -> some View {
        modifier(TourTargetModifier(id: id, onAccent: onAccent, scrolls: scrolls))
    }

    /// The row to scroll to for a target that is a control inside it.
    func tourScrollAnchor(_ id: TourTargetID?) -> some View {
        modifier(TourTargetModifier(id: id, onAccent: false, scrolls: true, outlines: false))
    }

    /// Scrolls this page's scroll view, form or list to the current target,
    /// only when the target is on this page. Asked about a control elsewhere
    /// (the sidebar, another page), the scroll proxy moved the other column
    /// as well.
    func tourScrollsToTarget(on section: LearningDestination) -> some View {
        modifier(TourScrollModifier(section: section))
    }
}

private struct TourTargetModifier: ViewModifier {
    let id: TourTargetID?
    let onAccent: Bool
    let scrolls: Bool
    var outlines = true
    @Environment(\.tourHighlight) private var tour

    func body(content: Content) -> some View {
        if let id {
            let marked = content.overlay {
                if outlines, let tour { TourOutline(tour: tour, id: id, onAccent: onAccent) }
            }
            if scrolls {
                marked.id(id)
            } else {
                marked
            }
        } else {
            content
        }
    }
}

/// Observes the highlight here, so a step never redraws the target itself.
private struct TourOutline: View {
    @ObservedObject var tour: TourHighlight
    let id: TourTargetID
    let onAccent: Bool

    var body: some View {
        if tour.target == id { TourOutlineShape(onAccent: onAccent) }
    }
}

/// Dashed and set apart from the control. Selection, keyboard focus and hover
/// use solid lines on the control's own edge, so this cannot be read as
/// "already selected".
private struct TourOutlineShape: View {
    let onAccent: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pulsed = false

    private static let gap: CGFloat = 4
    private static let pulseReach: CGFloat = 10
    private static let halo: CGFloat = 2

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let lineWidth: CGFloat = contrast == .increased ? 3 : 2
        // Beside a lava-filled control, lava dashes read as part of it. There
        // the line takes the text colour, over a band of the page colour: the
        // two are opposites in either theme and with Increase Contrast, so
        // one of them stands out from whatever lies under the outline.
        let line = onAccent ? TB.textPrimary : TB.lavaText
        ZStack {
            if onAccent {
                shape
                    .strokeBorder(TB.windowBackground, lineWidth: lineWidth + 2 * Self.halo)
                    .padding(-(Self.gap + lineWidth + Self.halo))
            }
            shape
                .strokeBorder(line, style: StrokeStyle(
                    lineWidth: lineWidth, lineCap: .round,
                    dash: contrast == .increased ? [] : [6, 5]))
                .padding(-(Self.gap + lineWidth))
            if !reduceMotion {
                // One ring that spreads and fades when the step appears.
                shape
                    .stroke(line, lineWidth: 2)
                    .padding(-(pulsed ? Self.pulseReach : Self.gap))
                    .opacity(pulsed ? 0 : 0.7)
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.6)) { pulsed = true }
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Sidebar focus outline

/// Draws its content only while no tour step is shown. The sidebar wraps its
/// keyboard-focus outline in this: a tour moves to another section without
/// moving the focus, and the solid outline left on the old row read as a
/// second highlight beside the tour's own.
struct HiddenDuringTourStep<Content: View>: View {
    @Environment(\.tourHighlight) private var tour
    @ViewBuilder var content: Content

    var body: some View {
        if let tour {
            HiddenDuringTourStepContent(tour: tour) { content }
        } else {
            content
        }
    }
}

/// Observes the highlight here, so a step never redraws the sidebar row.
private struct HiddenDuringTourStepContent<Content: View>: View {
    @ObservedObject var tour: TourHighlight
    @ViewBuilder var content: Content

    var body: some View {
        if !tour.showsTourStep { content }
    }
}

// MARK: - Scrolling to the target

private struct TourScrollModifier: ViewModifier {
    let section: LearningDestination
    @Environment(\.tourHighlight) private var tour

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.background {
                if let tour { TourScroller(tour: tour, proxy: proxy, section: section) }
            }
        }
    }
}

private struct TourScroller: View {
    @ObservedObject var tour: TourHighlight
    let proxy: ScrollViewProxy
    let section: LearningDestination
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            // `initial` covers a page opened for a step that is already set.
            .onChange(of: tour.target, initial: true) { _, target in
                guard let target, target.section == section else { return }
                let animated = !reduceMotion
                // A page that has just replaced another is laid out one turn later.
                Task { @MainActor in
                    if animated {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                    } else {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
    }
}

// MARK: - Hint strip

/// The hint for the current step, at a fixed place above the page. It takes
/// its own row, so it covers no control and blocks no click.
struct TourHintStrip: View {
    @Environment(\.tourHighlight) private var tour

    var body: some View {
        if let tour { TourHintStripContent(tour: tour) }
    }
}

private struct TourHintStripContent: View {
    @ObservedObject var tour: TourHighlight

    var body: some View {
        if let hint = tour.hint {
            let shape = RoundedRectangle(cornerRadius: TB.Radius.card, style: .continuous)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    VStack(alignment: .leading, spacing: 3) {
                        StateLabel(hint.stepLabel).foregroundStyle(TB.lavaText).lineLimit(2)
                        // Bounded lines, no vertical fixed size: the window asks
                        // every column for its height at a near-zero width, and a
                        // text free to grow answers with a word per line, which
                        // made the whole window content taller than the window.
                        // Five lines hold the longest advice in a 940 pt window.
                        Text(hint.text)
                            .font(.system(size: 15))
                            .foregroundStyle(TB.textPrimary)
                            .lineLimit(5)
                            .help(hint.text)
                    }
                    .accessibilityElement(children: .combine)
                    // Its own stop for the keyboard and VoiceOver, outside
                    // the text it belongs to. A new step gets a new link, so
                    // an open list closes with its step.
                    if let link = hint.link, let help = link.help {
                        TourHelpButton(title: link.title, help: help, isLink: true)
                            .id("\(hint.id)-link")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    ForEach(Array(hint.actions.prefix(2).enumerated()), id: \.offset) {
                        // A new step gets new buttons, so an open help
                        // popover closes with the step it belonged to.
                        actionButton($0.element).id("\(hint.id)-\($0.offset)")
                    }
                    if let close = hint.close {
                        Button(action: close.perform) { Image(systemName: "xmark") }
                            .buttonStyle(TBIconButtonStyle(
                                accessibilityLabel: close.title, compact: true,
                                foreground: TB.textSecondary))
                            .help(close.title)
                    }
                }
                .fixedSize()
            }
            .padding(.vertical, 10)
            .padding(.leading, 18)
            .padding(.trailing, 12)
            .background(TB.cardBackground)
            // The lava bar sets the hint apart from the page's own cards.
            .overlay(alignment: .leading) {
                Rectangle().fill(TB.lava).frame(width: 4).accessibilityHidden(true)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(TB.cardBorder))
            .padding(.horizontal, TB.Spacing.streamHorizontal)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            // Opaque: the page scrolls underneath.
            .background(TB.windowBackground)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func actionButton(_ action: TourHint.Action) -> some View {
        if let help = action.help {
            TourHelpButton(title: action.title, help: help)
        } else if action.isPrimary {
            Button(action.title, action: action.perform).buttonStyle(TBPrimaryButtonStyle())
        } else {
            Button(action.title, action: action.perform).buttonStyle(TBQuietButtonStyle())
        }
    }
}

/// "Not working?": a few tips and the ways on, in a popover under the button,
/// so the strip itself never holds more than two buttons. The Stream page's
/// hero uses it too, for "Can't see the game?" after the quick path.
struct TourHelpButton: View {
    let title: String
    let help: TourHint.Help
    var compact = false
    /// Drawn as a quiet text link instead of a button: the strip's third
    /// control, which must not look like a third button.
    var isLink = false
    @State private var isOpen = false

    @ViewBuilder private var trigger: some View {
        if isLink {
            Button { isOpen.toggle() } label: {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TB.link)
                    .underline()
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button(title) { isOpen.toggle() }
                .buttonStyle(TBQuietButtonStyle(compact: compact))
        }
    }

    var body: some View {
        trigger
            .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(help.tips.enumerated()), id: \.offset) { tip in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            PixelIcon(glyph: .dot, size: 6, color: TB.lavaText)
                            Text(tip.element)
                                .font(TB.Typography.body)
                                .foregroundStyle(TB.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // Tips alone leave no empty row under them.
                    if !help.actions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(help.actions.enumerated()), id: \.offset) { item in
                                let action = item.element
                                if action.isPrimary {
                                    Button(action.title) { choose(action) }.buttonStyle(TBPrimaryButtonStyle())
                                } else {
                                    Button(action.title) { choose(action) }.buttonStyle(TBQuietButtonStyle())
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
    }

    private func choose(_ action: TourHint.Action) {
        isOpen = false
        action.perform()
    }
}

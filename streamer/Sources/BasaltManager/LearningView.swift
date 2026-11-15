import SwiftUI
import BasaltManagerKit

/// The Learning section. A new person gets a short word on what the app
/// does and what it takes, then the chapters in order, each with its real
/// state. Someone whose game has once reached the headset gets "Ready for
/// VR" on top and the chapters folded into one line. Either way the page has
/// one primary button.
struct LearningView: View {
    @ObservedObject var model: BasaltAppModel
    @ObservedObject var learning: LearningController
    /// The folded program is open; the page's own, forgotten with it.
    @State private var showsProgram = false
    /// "More" is open; folded again whenever the page opens.
    @State private var showsMore = false

    var body: some View {
        let page = learning.page
        TBManagementPage {
            switch page.layout {
            case .newcomer:
                if let invitation = page.invitation { invitationCard(invitation) }
                introCard
                needsCard
                programCard(page)
            case .returning:
                readyCard(learning.readiness)
                foldedProgram(page)
                if showsProgram { programCard(page) }
            }
            topicCard(.trouble)
            moreFold
            if showsMore { topicCard(.more) }
        }
        .tint(TB.lava)
        .navigationTitle(L(.learningTitle))
        .task { await learning.pageOpened() }
    }

    // MARK: - Invitation

    private func invitationCard(_ invitation: LearningInvitation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                TBPixelTile(glyph: .learning)
                Text(invitation.text)
                    .font(TB.Typography.sectionTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            HStack(spacing: 8) {
                Button(invitation.startTitle) { learning.answerInvitation(.start) }
                    .buttonStyle(TBPrimaryButtonStyle())
                Button(invitation.laterTitle) { learning.answerInvitation(.later) }
                    .buttonStyle(TBQuietButtonStyle())
            }
            Text(invitation.note)
                .font(TB.Typography.meta)
                .foregroundStyle(TB.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    // MARK: - What the app does, what it takes

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(LearningPage.intro, id: \.self) { line in
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
            }
            scheme
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    /// Mac, the link, the headset: two boxes and a line, read as one phrase.
    private var scheme: some View {
        let parts = LearningPage.scheme
        return HStack(spacing: 10) {
            schemeBox(parts[0])
            VStack(spacing: 4) {
                Text(parts[1])
                    .font(TB.Typography.meta)
                    .foregroundStyle(TB.textSecondary)
                    .lineLimit(1)
                Rectangle().fill(TB.lava).frame(height: 2)
            }
            .frame(minWidth: 110, maxWidth: 190)
            schemeBox(parts[2])
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.joined(separator: " → "))
    }

    private func schemeBox(_ title: String) -> some View {
        Text(title)
            .font(TB.Typography.panelTitle)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(TB.quietFill, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(TB.quietBorder))
            .fixedSize()
    }

    private var needsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LearningPage.needsTitle)
                .font(TB.Typography.panelTitle)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(LearningPage.needs, id: \.self) { need in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        PixelIcon(glyph: .dot, size: 6, color: TB.lavaText).accessibilityHidden(true)
                        Text(need).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    // MARK: - Chapters

    private func programCard(_ page: LearningPage) -> some View {
        VStack(spacing: 0) {
            ForEach(page.rows) { row in
                if row.chapter != page.rows.first?.chapter { TBRowDivider() }
                chapterRow(row)
            }
        }
        .cardStyle(padding: 0)
    }

    private func chapterRow(_ row: LearningProgramRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.title).font(TB.Typography.panelTitle)
                    Chip(text: row.statusText, kind: chipKind(row.status))
                }
                Text(row.purpose)
                    .font(TB.Typography.meta)
                    .foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            // A chapter that waits for another has nothing to press.
            if let action = row.action {
                if row.isPrimary {
                    Button(action.title) { learning.perform(row) }
                        .buttonStyle(TBPrimaryButtonStyle())
                } else {
                    Button(action.title) { learning.perform(row) }
                        .buttonStyle(TBQuietButtonStyle(compact: true))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    /// Facts, never failures: nothing here is red.
    private func chipKind(_ status: LearningProgramRow.Status) -> Chip.Kind {
        switch status {
        case .done: .success
        case .paused: .warning
        case .notStarted, .blocked: .neutral
        }
    }

    /// "4 of 5 done · Show", for someone who has been through it.
    private func foldedProgram(_ page: LearningPage) -> some View {
        HStack(spacing: 6) {
            Text(page.summary).foregroundStyle(TB.textSecondary)
            Text("·").foregroundStyle(TB.textSecondary).accessibilityHidden(true)
            Button(showsProgram ? LearningPage.hideTitle : LearningPage.showTitle) {
                showsProgram.toggle()
            }
            .buttonStyle(.plain)
            .foregroundStyle(TB.link)
            Spacer(minLength: 0)
        }
        .font(TB.Typography.body)
        .padding(.horizontal, 4)
    }

    // MARK: - If something does not work, More

    private func topicCard(_ group: LearningTopic.Group) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.title)
                .font(TB.Typography.panelTitle)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
            ForEach(group.topics, id: \.self) { topic in
                if topic != group.topics.first { TBRowDivider() }
                topicRow(topic)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 0)
    }

    private func topicRow(_ topic: LearningTopic) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.title).font(TB.Typography.body.weight(.semibold))
                Text(topic.purpose)
                    .font(TB.Typography.meta)
                    .foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(LearningTopic.showTitle) { learning.startTopic(topic) }
                .buttonStyle(TBQuietButtonStyle(compact: true))
                .accessibilityLabel("\(LearningTopic.showTitle): \(topic.title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    /// "More ▾": the rarer topics stay folded until asked for.
    private var moreFold: some View {
        Button { showsMore.toggle() } label: {
            HStack(spacing: 6) {
                Text(LearningTopic.Group.more.title)
                Image(systemName: showsMore ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(TB.link)
        .font(TB.Typography.body)
        .padding(.horizontal, 4)
        .accessibilityAddTraits(showsMore ? .isSelected : [])
    }

    // MARK: - Ready for VR

    private func readyCard(_ readiness: LearningReadiness) -> some View {
        let action = readiness.primaryAction
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TBPixelTile(glyph: .learning,
                            color: isAllReady(readiness) ? TB.successText : TB.lavaText)
                Text(L(.learningReadyTitle))
                    .font(TB.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                // Not beside a main button that is "Check again" itself.
                if readiness.showsRecheckInHeader {
                    Button(L(.learningRecheck)) { learning.recheck() }
                        .buttonStyle(TBQuietButtonStyle(compact: true))
                        .disabled(!learning.canRecheck)
                }
            }
            VStack(spacing: 0) {
                ForEach(readiness.rows) { row in
                    TBRowDivider()
                    rowView(row)
                }
                TBRowDivider()
            }
            if let note = action.note {
                Text(note).foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action.title) { learning.perform(action) }
                .buttonStyle(TBPrimaryButtonStyle())
                .disabled(!action.isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    /// Green only when nothing on the card still asks for attention; the
    /// optional sound row does not count.
    private func isAllReady(_ readiness: LearningReadiness) -> Bool {
        readiness.canStartQuickPath && readiness.rows.allSatisfy {
            $0.isOptional || $0.status == .ready || $0.status == .info
        }
    }

    private func rowView(_ row: LearningReadinessRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title).font(TB.Typography.panelTitle)
                if let caption = row.caption {
                    Text(caption).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                }
                Spacer(minLength: 8)
                Chip(text: row.text, kind: chipKind(row))
            }
            if let note = row.note {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    PixelIcon(glyph: .warning, size: 9, color: TB.warningText)
                    Text(note)
                        .font(TB.Typography.meta)
                        .foregroundStyle(TB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    /// A check that could not run is a warning, not an error, and nothing
    /// here is ever red: the card states facts, it does not report failures.
    private func chipKind(_ row: LearningReadinessRow) -> Chip.Kind {
        switch row.status {
        case .checking: .progress
        case .ready: .success
        case .failed: .warning
        case .missing: row.isOptional ? .neutral : .warning
        case .info: .neutral
        }
    }
}

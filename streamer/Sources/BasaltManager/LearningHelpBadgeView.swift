import SwiftUI
import BasaltManagerKit

/// A small "?" beside a control: a click shows a few short sentences on what
/// the control is for. There are exactly four (`LearningHelpBadge`).
struct LearningHelpBadgeButton: View {
    let badge: LearningHelpBadge
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Text("?")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(TB.textSecondary)
                .frame(width: 16, height: 16)
                .background(TB.quietFill, in: Circle())
                .overlay(Circle().strokeBorder(TB.quietBorder))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(badge.label)
        .accessibilityLabel(badge.label)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            Text(badge.text)
                .font(TB.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
                .padding(14)
        }
    }
}

/// A control's own name with its "?" beside it, for a picker's label.
struct LabelWithHelp: View {
    let title: String
    let badge: LearningHelpBadge

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            LearningHelpBadgeButton(badge: badge)
        }
    }
}

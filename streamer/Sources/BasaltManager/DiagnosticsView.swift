// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import BasaltBottleKit
import BasaltManagerKit

/// Per-game diagnostic recording switches and the recordings they produced.
struct DiagnosticsView: View {
    @ObservedObject var model: BasaltAppModel
    @State private var confirmingDeleteAll = false
    @State private var deleting: DiagnosticRecording?

    private var finished: [DiagnosticRecording] {
        model.recordings.filter { !model.isRecordingInProgress($0) }
    }

    var body: some View {
        TBManagementPage {
            header
            games
            recordings
        }
        .tint(TB.controlTint)
        .navigationTitle(L(.sidebarDiagnostics))
        .task { await model.refreshRecordings() }
        .onChange(of: model.sessionState.isActive) { _, _ in
            Task { await model.refreshRecordings() }
        }
        .confirmationDialog(L(.recordingDeleteAllQuestion), isPresented: $confirmingDeleteAll) {
            Button(L(.recordingDeleteAll), role: .destructive) {
                Task { await model.deleteAllRecordings() }
            }
            .disabled(model.gameLogCapturePending)
        } message: {
            Text(L(.recordingDeleteAllDetail,
                   RecordingFormat.size(finished.reduce(0) { $0 + $1.totalBytes })))
        }
        .confirmationDialog(
            L(.recordingDeleteQuestion),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { recording in
            Button(L(.recordingDelete), role: .destructive) {
                Task { await model.deleteRecording(recording) }
            }
            .disabled(model.gameLogCapturePending)
        } message: { recording in
            Text(L(.recordingDeleteDetail, model.gameTitle(forProfile: recording.profileName),
                   RecordingFormat.date(recording.startedAt), RecordingFormat.size(recording.totalBytes)))
        }
    }

    private var header: some View {
        let names = model.recordingProfileNames
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TBPixelTile(glyph: .diagnostics)
                Text(L(.recordingTitle)).font(TB.Typography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            Text(L(.recordingIntro)).foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !names.isEmpty {
                Chip(text: L(.recordingReminder, names.joined(separator: ", ")), kind: .warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 14)
    }

    private var games: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(L(.recordingGames))
            if model.profiles.isEmpty {
                Text(L(.recordingNoGames)).foregroundStyle(TB.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(padding: 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.profiles, id: \.name) { profile in
                        if profile.name != model.profiles.first?.name { TBRowDivider() }
                        GameRecordingRow(profile: profile, model: model)
                    }
                }
                .cardStyle(padding: 0)
            }
        }
    }

    private var recordings: some View {
        let folder = DiagnosticRecordingStore(dataRoot: model.dataRoot).directory
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: L(.recordingList), count: model.recordings.count) {
                Button(L(.recordingDeleteAll)) { confirmingDeleteAll = true }
                    .buttonStyle(TBQuietButtonStyle(compact: true))
                    .disabled(finished.isEmpty || model.gameLogCapturePending)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(.recordingFolder))
                    PathText(path: folder.path)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Text(L(.recordingTotal, RecordingFormat.size(model.recordingsTotalBytes)))
                    .monospacedDigit().foregroundStyle(TB.textTertiary).fixedSize()
                Button {
                    // The folder appears with the first recording.
                    let exists = FileManager.default.fileExists(atPath: folder.path)
                    NSWorkspace.shared.activateFileViewerSelecting([exists ? folder : model.dataRoot])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(TBIconButtonStyle(accessibilityLabel: L(.libraryShowInFinder), compact: true))
                .help(L(.libraryShowInFinder))
            }
            // Saved without a recording being turned on, so the list says why they are there.
            Text(L(.recordingGameLogNote, Int64(GameLogExcerpt.keptExcerpts)))
                .font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.recordings.isEmpty {
                Text(L(.recordingListEmpty)).foregroundStyle(TB.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(padding: 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.recordings) { recording in
                        if recording.id != model.recordings.first?.id { TBRowDivider() }
                        RecordingRow(
                            recording: recording,
                            title: model.gameTitle(forProfile: recording.profileName),
                            summary: model.recordingSummaries[recording.id],
                            inProgress: model.isRecordingInProgress(recording),
                            deleteDisabled: model.gameLogCapturePending,
                            delete: { deleting = recording })
                    }
                }
                .cardStyle(padding: 0)
            }
        }
    }
}

/// One game's two switches. They change the app's own settings only.
private struct GameRecordingRow: View {
    let profile: LaunchProfile
    @ObservedObject var model: BasaltAppModel

    var body: some View {
        let megabits = model.streamSettings(for: profile.name).megabits
        let title = model.gameTitle(forProfile: profile.name)
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(TB.Typography.panelTitle)
                .lineLimit(1).truncationMode(.middle).help(profile.name)
                .accessibilityAddTraits(.isHeader)
            option(L(.recordingFrames), help: L(.recordingFramesHelp),
                   label: L(.recordingFramesFor, title), isOn: binding(\.recordsFrames))
            option(L(.recordingVideo),
                   help: L(.recordingVideoHelp,
                           Int64(DiagnosticRecordingSettings.videoMegabytesPerMinute(megabits: megabits)),
                           Int64(megabits)),
                   label: L(.recordingVideoFor, title), isOn: binding(\.recordsVideo))
            if DiagnosticRecordingSettings(profileEnvironment: profile.environment).isEnabled {
                Text(L(.recordingProfileOverride)).font(TB.Typography.meta)
                    .foregroundStyle(TB.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func option(_ title: String, help: String, label: String,
                        isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(help).font(TB.Typography.meta).foregroundStyle(TB.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The switch reads the game's name, the option and this note.
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            Toggle(label, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(label)
                .accessibilityHint(help)
        }
    }

    private func binding(_ value: WritableKeyPath<DiagnosticRecordingSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.recordingChoice(for: profile.name)[keyPath: value] },
            set: {
                var choice = model.recordingChoice(for: profile.name)
                choice[keyPath: value] = $0
                model.saveRecordingChoice(choice, for: profile.name)
            })
    }
}

/// One recorded session: when, which game, how long, how large, its files
/// and, once its frame CSV has been read, what limited it.
private struct RecordingRow: View {
    let recording: DiagnosticRecording
    /// The game's Library name.
    let title: String
    let summary: RecordingSummaryState?
    let inProgress: Bool
    let deleteDisabled: Bool
    let delete: () -> Void

    private var date: String { RecordingFormat.date(recording.startedAt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(TB.Typography.panelTitle)
                        .lineLimit(1).truncationMode(.middle).help(recording.profileName)
                    if inProgress { Chip(text: L(.recordingInProgress), kind: .progress) }
                    Spacer(minLength: 0)
                    Text(RecordingFormat.size(recording.totalBytes))
                        .monospacedDigit().foregroundStyle(TB.textTertiary).fixedSize()
                }
                Text([date, RecordingFormat.duration(recording.duration)].joined(separator: " · "))
                    .font(TB.Typography.caption).foregroundStyle(TB.textSecondary)
                FlowLayout(spacing: 6) {
                    ForEach(recording.files) { file in
                        Chip(text: L(.recordingFileSize, RecordingFormat.title(file.kind),
                                     RecordingFormat.size(file.bytes)), kind: .neutral)
                    }
                }
                if recording.frames != nil, !inProgress { summaryLines }
            }
            // Game, date, size, files and summary read as one element; the buttons stay separate.
            .accessibilityElement(children: .combine)
            HStack(spacing: 8) {
                Button(L(.libraryShowInFinder)) {
                    NSWorkspace.shared.activateFileViewerSelecting(recording.files.map(\.url))
                }
                .accessibilityLabel(L(.recordingShowLabel, title, date))
                Button(L(.recordingDelete), role: .destructive, action: delete)
                    .accessibilityLabel(L(.recordingDeleteLabel, title, date))
                    .disabled(inProgress || deleteDisabled)
            }
            .buttonStyle(TBQuietButtonStyle(compact: true))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var summaryLines: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L(.recordingSummaryTitle)).font(TB.Typography.caption.weight(.semibold))
                .foregroundStyle(TB.textTertiary)
            switch summary {
            case .ready(let value):
                Text(L(.recordingSummaryFPS, value.framesPerSecond, value.framePeriodMicroseconds / 1000))
                Text(L(.recordingSummaryLate, value.lateShare * 100, value.veryLateShare * 100,
                       FrameTraceSummary.lateFactor, FrameTraceSummary.veryLateFactor))
                Text(L(.recordingSummaryPause, (value.longestPauseMicroseconds + 500) / 1000))
                if value.lateFrames == 0 {
                    Text(L(.recordingSummaryNoLate))
                } else {
                    Text(L(.recordingSummaryCauses,
                           Int64(value.lateCauses.gpu), Int64(value.lateCauses.gameThread),
                           Int64(value.lateCauses.renderThread), Int64(value.lateCauses.other)))
                }
            case .empty:
                Text(L(.recordingSummaryEmpty))
            case nil:
                Text(L(.recordingSummaryReading))
            }
        }
        .font(TB.Typography.meta)
        .foregroundStyle(TB.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }
}

/// Dates, sizes and durations in the app's language rather than the system's.
private enum RecordingFormat {
    static func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.language.locale
        formatter.dateFormat = L(.streamHistoryDateFormat)
        formatter.shortMonthSymbols = L(.streamHistoryMonths).components(separatedBy: "|")
        return formatter.string(from: value)
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.language.locale))
    }

    static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int64(value))
        if seconds >= 3600 {
            return L(.streamDurationHoursMinutes, seconds / 3600, seconds / 60 % 60)
        }
        if seconds >= 60 {
            return L(.streamDurationMinutesSeconds, seconds / 60, seconds % 60)
        }
        return L(.streamDurationSeconds, seconds)
    }

    static func title(_ kind: DiagnosticRecording.FileKind) -> String {
        switch kind {
        case .frames: L(.recordingFileFrames)
        case .sessionLog: L(.recordingFileLog)
        case .gameLog: L(.recordingFileGameLog)
        case .video: L(.recordingFileVideo)
        case .videoIndex: L(.recordingFileVideoIndex)
        }
    }
}

import Foundation

/// "How to start VR again": the order card, then three steps on the Stream
/// page. A value with no clock, timers or I/O: the app feeds it session
/// changes and button presses, and shows what `presentation(in:)` describes.
public struct QuickPathTour: Equatable, Sendable {
    public enum Step: Int, CaseIterable, Sendable {
        /// The whole sequence once, for the connection Play launches with.
        /// "Done" moves on. The card itself names Play, so a launch started
        /// straight from it moves on too, as on step 1. A launch already
        /// under way does not.
        case order
        /// Step 1: press Play. Counts by itself when a launch starts.
        case pressPlay
        /// Step 2: wait for the live state.
        case waitForLive
        /// Step 3: the picture goes to the headset. Completes on the
        /// headset's first frame report of this session.
        case picture

        /// "Step N of 3"; nil for the order card.
        public var number: Int? { self == .order ? nil : rawValue }
        public static let numberedCount = 3
    }

    public enum Phase: Equatable, Sendable {
        case step(Step)
        /// The session failed while a step was shown.
        case failed(message: String)
        /// The headset showed a frame: record the scenario as completed.
        case completed
        /// Closed or skipped to the end; nothing is recorded.
        case closed
    }

    public enum Event: Equatable, Sendable {
        /// The app's session state changed (feed every change, in order).
        case session(LearningSessionPhase)
        /// The headset's first frame report at or after this session's
        /// streaming start.
        case firstFrame
        /// "Done" on the order card or on a step reached with "Back".
        case done
        case back
        /// "Skip this step", inside "Can't see the game?" on the last step:
        /// ends the tour without recording it. The earlier steps cannot be
        /// skipped: the app sees the launch and the live state itself.
        case skip
        /// "Check again": count the step now if the facts already say so.
        case checkAgain
        /// "Try again" after a failure: back to the order card.
        case retry
        case close
    }

    /// The connection the tour started with. What is shown follows the one
    /// Play launches with now, when the app names it (`QuickPathEnvironment`).
    public let connection: StreamConnectionMode
    public private(set) var phase = Phase.step(.order)
    /// The shown step was reached with "Back". It then waits for "Done"
    /// instead of counting itself, so "Back" never jumps forward again.
    /// The order card needs no mark for that: it moves only when the user
    /// acts, with "Done" or by starting a launch.
    public private(set) var isRevisit = false
    public private(set) var session: LearningSessionPhase
    /// The headset has shown a frame in the session that is live now.
    public private(set) var hasFrame = false

    public init(connection: StreamConnectionMode, session: LearningSessionPhase) {
        self.connection = connection
        self.session = session
    }

    public var step: Step? {
        if case .step(let step) = phase { return step }
        return nil
    }

    public var isFinished: Bool { phase == .completed || phase == .closed }

    /// Whether the app should be listening for the headset's first frame.
    public var awaitsFirstFrame: Bool { !isFinished && session == .live && !hasFrame }

    public mutating func handle(_ event: Event) {
        guard !isFinished else { return }
        switch event {
        case .session(let new): sessionChanged(to: new)
        case .firstFrame:
            // A report from a session that is no longer live proves nothing.
            guard session == .live else { return }
            hasFrame = true
            if phase == .step(.picture), !isRevisit { phase = .completed }
        case .done:
            guard let step else { return }
            if step == .order {
                advance(after: step)
            } else if isRevisit {
                recheck(step)
            }
        case .back:
            guard let step, let previous = Step(rawValue: step.rawValue - 1) else { return }
            phase = .step(previous)
            isRevisit = previous != .order
        case .skip:
            guard step == .picture else { return }
            phase = .closed
        case .checkAgain:
            guard let step, step != .order else { return }
            recheck(step)
        case .retry:
            phase = .step(.order)
            isRevisit = false
        case .close:
            phase = .closed
        }
    }

    // MARK: - Transitions

    private mutating func sessionChanged(to new: LearningSessionPhase) {
        let old = session
        session = new
        if new != .live { hasFrame = false }
        guard old != new else { return }

        switch phase {
        case .failed:
            // Play pressed again straight from the failure.
            if new == .starting { show(.waitForLive) }
            if new == .live { show(.picture) }
        case .step(let step):
            if case .failed(let message) = new {
                phase = .failed(message: message)
                isRevisit = false
                return
            }
            guard !isRevisit else { return }
            switch (step, new) {
            // The order card moves on only when the user acts: a launch that
            // starts shows step 2, one that fails is handled above. A launch
            // already under way leaves the card alone when it goes live: the
            // user may have come back to it with "Back". "Done" then lands on
            // the first step still to do.
            case (.order, .starting), (.pressPlay, .starting): show(.waitForLive)
            case (.pressPlay, .live), (.waitForLive, .live): show(.picture)
            case (.waitForLive, .idle), (.waitForLive, .windowsApp): show(.pressPlay)
            case (.picture, .starting): show(.waitForLive)
            case (.picture, .idle), (.picture, .windowsApp): show(.pressPlay)
            default: break
            }
        case .completed, .closed:
            break
        }
    }

    /// What the facts say about a step, without waiting for an event.
    private func isSatisfied(_ step: Step) -> Bool {
        switch step {
        case .order: return false
        case .pressPlay: return session.isVRSession
        case .waitForLive: return session == .live
        case .picture: return session == .live && hasFrame
        }
    }

    /// The first step from `step` on that is still to do; nil when all are done.
    private func firstOpenStep(from step: Step) -> Step? {
        var candidate: Step? = step
        while let current = candidate, isSatisfied(current) {
            candidate = Step(rawValue: current.rawValue + 1)
        }
        return candidate
    }

    private mutating func advance(after step: Step) {
        show(Step(rawValue: step.rawValue + 1).flatMap(firstOpenStep(from:)))
    }

    /// Moves on if the step is already done; otherwise it shows the first
    /// step still to do, which counts itself again from now on.
    private mutating func recheck(_ step: Step) {
        if isSatisfied(step) {
            advance(after: step)
        } else {
            // The first step still to do: the step itself, or an earlier one
            // when the session ended meanwhile (a step 2 revisited after
            // "Stop" shows step 1 again, not "Wait for LIVE").
            show(firstOpenStep(from: .pressPlay))
        }
    }

    private mutating func show(_ step: Step?) {
        isRevisit = false
        phase = step.map(Phase.step) ?? .completed
    }
}

/// The first headset frame report that belongs to the session running now.
/// The console keeps the previous session's samples until the next launch, so
/// only reports at or after this session's streaming start count.
public enum QuickPathFrames {
    public static func hasHeadsetFrame(
        in samples: some Sequence<StreamMetricSample>, since streamingStartedAt: Date?
    ) -> Bool {
        guard let streamingStartedAt else { return false }
        return samples.contains { sample in
            guard let fps = sample.fps else { return false }
            return fps > 0 && sample.date >= streamingStartedAt
        }
    }
}

/// Waits for that first frame report while the console's sample list grows.
/// Each look reads only the samples added since the previous one, so a long
/// list is never scanned again for every new sample.
public struct QuickPathFrameWatch: Equatable, Sendable {
    /// How many samples of the list have been looked at.
    public private(set) var seenCount = 0

    public init() {}

    public mutating func hasHeadsetFrame(
        in samples: [StreamMetricSample], since streamingStartedAt: Date?
    ) -> Bool {
        // A list that got shorter was cleared for a new session or trimmed at
        // the front: what it holds now is looked at once, as a whole.
        let unseen = samples.count >= seenCount ? samples[seenCount...] : samples[...]
        seenCount = samples.count
        return QuickPathFrames.hasHeadsetFrame(in: unseen, since: streamingStartedAt)
    }
}

/// After the quick path completes, the Stream page keeps a quiet "Can't see
/// the game?" link for the rest of that session. The session is known by its
/// streaming start, so nothing has to watch for its end.
public enum QuickPathFollowUp {
    /// `completedSessionStart` is the streaming start of the session the
    /// quick path completed in; `liveSessionStart` is that of the session
    /// streaming now, nil when none is.
    public static func showsCantSeeGame(completedSessionStart: Date?, liveSessionStart: Date?) -> Bool {
        guard let completedSessionStart, let liveSessionStart else { return false }
        return completedSessionStart == liveSessionStart
    }
}

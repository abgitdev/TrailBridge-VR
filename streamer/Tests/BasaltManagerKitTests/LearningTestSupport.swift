import Foundation
import BasaltCore
@testable import BasaltManagerKit

/// Facts for the Learning program and chapter tests.
enum LearningFixture {
    /// The Setup page's seven checks. `missing` lists the ids still to do.
    static func checks(missing: Set<String> = [], unsupportedMac: Bool = false) -> [SetupCheck] {
        let ids: [(String, Bool)] = [
            ("mac", true), ("screen", false), ("adb", false), ("wine", true),
            ("runtime", true), ("dxmt", true), ("audio", false),
        ]
        return ids.map { id, required in
            let status: SetupCheckStatus = id == "mac" && unsupportedMac ? .unavailable
                : missing.contains(id) ? .actionNeeded : .ready
            return SetupCheck(id: id, title: id, detail: "", status: status, required: required)
        }
    }

    static func session(streamed: Bool, connection: StreamConnectionMode = .wifi) -> SessionRecord {
        var settings = StreamLaunchSettings()
        settings.connection = connection
        // A fixed id: two fixtures made apart are the same facts.
        var record = SessionRecord(id: UUID(uuidString: "5E55104E-0000-4000-8000-000000000001")!,
                                   profileName: "BRUTALISTICK VR", settings: settings,
                                   startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        if streamed { record.streamingStartedAt = Date(timeIntervalSince1970: 1_800_000_060) }
        return record
    }

    /// The Mac talks to the headset over USB, and ALVR is on it.
    static func headsetReady(_ facts: inout LearningFacts) {
        headset(.connected, client: PinnedHeadsetDownload.testedALVR.version)(&facts)
    }

    /// What the Headset page's polling saw when adb answered: the headset
    /// on the cable, and the ALVR version on it, if any.
    static func headset(
        _ connection: HeadsetStatus.Connection, client: String? = nil
    ) -> (inout LearningFacts) -> Void {
        { facts in
            facts.headsetChecked = true
            facts.headsetScanError = nil
            facts.headsetConnection = connection
            facts.headsetClientInstalled = client != nil
            facts.headsetClientVersion = client
        }
    }

    /// Its question failed with this, and the status it held stays.
    static func headsetScanFailed(_ error: String) -> (inout LearningFacts) -> Void {
        { facts in
            facts.headsetChecked = true
            facts.headsetScanError = error
        }
    }

    /// What the developer wrapper says when it has no adb to run, as the
    /// Headset page reports it.
    static let wrapperWithoutADB = "Headset command failed: \(AlvrWiredFailure.adbMissing)\n"

    /// A new person on a Mac where nothing is built yet.
    static var unbuiltMac: LearningFacts {
        var facts = LearningFacts()
        facts.setupChecks = checks(missing: ["wine", "runtime", "dxmt"])
        facts.libraryShowsAddButtons = true
        return facts
    }

    /// A new person on a ready Mac: no game, no session, an empty Library.
    static var newcomer: LearningFacts {
        var facts = LearningFacts()
        facts.setupChecks = checks()
        facts.pinnedEngineListed = true
        facts.libraryShowsAddButtons = true
        return facts
    }

    /// A game is ready to launch; nothing has streamed yet.
    static var withGame: LearningFacts {
        var facts = newcomer
        facts.libraryShowsAddButtons = false
        facts.launchableGames = ["BRUTALISTICK VR"]
        facts.selectedGame = "BRUTALISTICK VR"
        facts.openVRBadges = ["BRUTALISTICK VR": .installed]
        return facts
    }

    /// Someone who has played: a game, a streamed session, the quick path.
    static var returning: LearningFacts {
        var facts = withGame
        facts.sessionHistory = [session(streamed: true)]
        facts.progress.quickPathCompleted = true
        facts.gameAudioOn = true
        facts.recommendedPresetSelected = true
        return facts
    }
}

extension LearningFacts {
    /// A copy with one change, for short test lines.
    func with(_ change: (inout LearningFacts) -> Void) -> LearningFacts {
        var copy = self
        change(&copy)
        return copy
    }
}

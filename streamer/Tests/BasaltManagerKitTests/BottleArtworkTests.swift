import XCTest
@testable import BasaltManagerKit
import BasaltBottleKit

final class BottleArtworkTests: XCTestCase {
    private let bottle = DiscoveredBottle(
        name: "one", origin: .managed, prefix: URL(fileURLWithPath: "/tmp/one"), managed: nil)
    private let other = DiscoveredBottle(
        name: "two", origin: .managed, prefix: URL(fileURLWithPath: "/tmp/two"), managed: nil)

    private func game(_ appID: String, _ name: String, in bottle: DiscoveredBottle,
                      art: String?, played: TimeInterval?) -> SteamGame {
        SteamGame(appID: appID, name: name, bottle: bottle,
                  installDirectory: URL(fileURLWithPath: "/tmp/game"),
                  steamExecutable: URL(fileURLWithPath: "/tmp/game/a.exe"),
                  artwork: art.map { URL(fileURLWithPath: "/tmp/" + $0) },
                  sizeOnDisk: nil,
                  lastPlayed: played.map { Date(timeIntervalSince1970: $0) })
    }

    func testPrimaryArtworkPrefersMostRecentlyPlayedGameInThatBottle() {
        let games = [
            game("1", "Older", in: bottle, art: "older.jpg", played: 100),
            game("2", "Newer", in: bottle, art: "newer.jpg", played: 200),
            game("3", "Elsewhere", in: other, art: "other.jpg", played: 900),
        ]
        XCTAssertEqual(BottleArtwork.primaryArtwork(forBottle: bottle.id, among: games)?.lastPathComponent,
                       "newer.jpg")
        XCTAssertEqual(BottleArtwork.games(inBottle: bottle.id, among: games).map(\.name), ["Newer", "Older"])
    }

    func testPrimaryArtworkSkipsGamesWithoutArtAndTools() {
        let games = [
            game("1", "No Art", in: bottle, art: nil, played: 500),
            game("228980", "Steamworks Common Redistributables", in: bottle, art: "tool.jpg", played: 600),
            game("2", "Has Art", in: bottle, art: "art.jpg", played: nil),
        ]
        XCTAssertEqual(BottleArtwork.primaryArtwork(forBottle: bottle.id, among: games)?.lastPathComponent,
                       "art.jpg")
        XCTAssertEqual(BottleArtwork.games(inBottle: bottle.id, among: games).map(\.name), ["No Art", "Has Art"])
    }

    func testPrimaryExecutableIsTheFirstGameByTitleInThatBottle() {
        func detected(_ title: String, _ bottle: String, _ exe: String?) -> DetectedGame {
            DetectedGame(title: title, bottleName: bottle, source: .direct,
                         executable: "C:\\Games\\\(title).exe",
                         hostExecutable: exe.map { URL(fileURLWithPath: "/tmp/" + $0) },
                         profileName: nil)
        }
        let games = [
            detected("Zeta", "one", "zeta.exe"),
            detected("alpha", "one", nil),
            detected("Beta", "one", "beta.exe"),
            detected("Aardvark", "two", "aardvark.exe"),
        ]
        XCTAssertEqual(BottleArtwork.primaryExecutable(forBottleNamed: "one", among: games)?
            .lastPathComponent, "beta.exe", "skips a game without a host executable")
        XCTAssertEqual(BottleArtwork.primaryExecutable(forBottleNamed: "two", among: games)?
            .lastPathComponent, "aardvark.exe")
        XCTAssertNil(BottleArtwork.primaryExecutable(forBottleNamed: "three", among: games))
    }

    func testGamesWithoutPlayDatesAreOrderedByNameAndEmptyBottleHasNoArtwork() {
        let games = [
            game("1", "beta", in: bottle, art: nil, played: nil),
            game("2", "Alpha", in: bottle, art: nil, played: nil),
        ]
        XCTAssertEqual(BottleArtwork.games(inBottle: bottle.id, among: games).map(\.name), ["Alpha", "beta"])
        XCTAssertNil(BottleArtwork.primaryArtwork(forBottle: bottle.id, among: games))
        XCTAssertNil(BottleArtwork.primaryArtwork(forBottle: other.id, among: games))
    }
}

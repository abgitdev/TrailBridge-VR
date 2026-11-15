import Foundation

/// Chooses which Steam game represents a bottle on the Bottles screen.
public enum BottleArtwork {
    /// Installed games in a bottle, most recently played first, then by name.
    public static func games(inBottle bottleID: String, among games: [SteamGame]) -> [SteamGame] {
        games.filter { $0.bottleID == bottleID && !$0.isTool }
            .sorted {
                switch ($0.lastPlayed, $1.lastPlayed) {
                case let (a?, b?) where a != b: return a > b
                case (.some, .none): return true
                case (.none, .some): return false
                default: return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
    }

    /// The artwork of the first ordered game that has any.
    public static func primaryArtwork(forBottle bottleID: String, among games: [SteamGame]) -> URL? {
        self.games(inBottle: bottleID, among: games).lazy.compactMap(\.artwork).first
    }

    /// For a bottle without Steam artwork: the executable of its first game
    /// by title, whose icon can stand in. Games of other bottles are ignored.
    public static func primaryExecutable(forBottleNamed bottleName: String,
                                         among games: [DetectedGame]) -> URL? {
        games.filter { $0.bottleName == bottleName && $0.hostExecutable != nil }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .first?.hostExecutable
    }
}

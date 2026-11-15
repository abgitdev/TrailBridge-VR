import Foundation
import BasaltBottleKit

/// Client presence is independent of installed games and does not imply sign-in.
public enum SteamInstallation {
    public static let installerURL = URL(
        string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!

    public static func executable(in prefix: URL,
                                  fileManager: FileManager = .default) -> URL? {
        ["Program Files (x86)/Steam", "Program Files/Steam"].map {
            prefix.appendingPathComponent("drive_c/\($0)/steam.exe")
        }.first { fileManager.fileExists(atPath: $0.path) }
    }

    public static func connectionLogURL(in prefix: URL, fileManager: FileManager = .default) -> URL {
        let root = executable(in: prefix, fileManager: fileManager)?.deletingLastPathComponent()
            ?? prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam")
        return root.appendingPathComponent("logs/connection_log.txt")
    }

    public static func bootstrapLogURL(in prefix: URL, fileManager: FileManager = .default) -> URL {
        connectionLogURL(in: prefix, fileManager: fileManager).deletingLastPathComponent()
            .appendingPathComponent("bootstrap_log.txt")
    }

    /// Steam notes each change of a game download's state here.
    public static func contentLogURL(in prefix: URL, fileManager: FileManager = .default) -> URL {
        connectionLogURL(in: prefix, fileManager: fileManager).deletingLastPathComponent()
            .appendingPathComponent("content_log.txt")
    }

    /// First run must be allowed to bootstrap before the compatibility helper exists.
    public static func firstRunCommand(bottle: DiscoveredBottle, manager: BottleManager) throws -> BottleLaunchCommand {
        try clientCommand(bottle: bottle, manager: manager, arguments: [])
    }

    public static func installGameCommand(appID: String, bottle: DiscoveredBottle,
                                           manager: BottleManager) throws -> BottleLaunchCommand {
        guard !appID.isEmpty, appID.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw BottleToolError("Steam AppID must contain ASCII digits only.")
        }
        return try clientCommand(bottle: bottle, manager: manager, arguments: [
            "-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox", "+app_install", appID,
        ])
    }

    private static func clientCommand(bottle: DiscoveredBottle, manager: BottleManager,
                                       arguments: [String]) throws -> BottleLaunchCommand {
        guard let managed = bottle.managed else {
            throw BottleToolError("Open Steam only in a managed TrailBridge environment.")
        }
        let verified = try manager.loadBottle(managed.name)
        let prefix = URL(fileURLWithPath: verified.prefixPath)
        guard let steam = executable(in: prefix) else { throw BottleToolError("Steam is not installed.") }
        return try manager.applicationLaunchCommand(bottleName: verified.name,
            executable: BottleManager.winePath(for: steam, prefix: prefix), arguments: arguments,
            currentDirectory: steam.deletingLastPathComponent())
    }

    /// Keep ownership of the actual game process. Steam's -applaunch bootstrap
    /// can exit while a game is still running; Steam authentication remains a
    /// separate prerequisite handled by BottleManager's Steam bootstrap.
    public static func gameProfile(named name: String, game: SteamGame,
                                    prefix: URL, fileManager: FileManager = .default) throws -> LaunchProfile {
        guard game.bottleOrigin == .managed else {
            throw BottleToolError("Copy the game into a TrailBridge bottle first.")
        }
        let knownExecutables = [
            "620980": "Beat Saber.exe",
            "2669380": "BrutalistickVR.exe",
            "1032430": "BTVR/Binaries/Win64/BTVR-Win64-Shipping.exe",
        ]
        let relative = knownExecutables[game.appID]
        let target = relative.map { game.installDirectory.appendingPathComponent($0) }
            ?? game.steamExecutable
        let resolvedPrefix = prefix.resolvingSymlinksInPath().path + "/"
        guard target.resolvingSymlinksInPath().path.hasPrefix(resolvedPrefix),
              game.installDirectory.resolvingSymlinksInPath().path.hasPrefix(resolvedPrefix) else {
            throw BottleToolError("Copy game files into this managed bottle before creating its profile.")
        }
        guard fileManager.fileExists(atPath: target.path) else {
            throw BottleToolError("Game files are incomplete. Finish installation or verify them in Steam first.")
        }
        return LaunchProfile(
            name: name, bottleName: game.bottleName, source: .steam,
            executable: BottleManager.winePath(for: target, prefix: prefix),
            arguments: relative == nil ? ["-applaunch", game.appID] : [],
            workingDirectory: target.deletingLastPathComponent().path,
            environment: relative == nil ? [:] : ["SteamAppId": game.appID, "SteamGameId": game.appID],
            gameRoot: BottleManager.winePath(for: game.installDirectory, prefix: prefix))
    }

    /// Only the managed copy is writable. External libraries remain discovery sources.
    public static func signInCommand(bottle: DiscoveredBottle,
                                     manager: BottleManager) throws -> BottleLaunchCommand {
        guard let managed = bottle.managed else {
            throw BottleToolError("Copy this bottle into TrailBridge before opening Steam.")
        }
        let verified = try manager.loadBottle(managed.name)
        let prefix = URL(fileURLWithPath: verified.prefixPath, isDirectory: true)
        guard let steam = executable(in: prefix) else {
            throw BottleToolError("Steam is not installed in '\(managed.name)'.")
        }
        try manager.installSteamWebHelperCompatibility(inBottle: verified.name)
        return try manager.applicationLaunchCommand(
            bottleName: verified.name,
            executable: BottleManager.winePath(for: steam, prefix: prefix),
            arguments: ["-inhibitbootstrap", "-noverifyfiles", "-no-cef-sandbox"],
            currentDirectory: steam.deletingLastPathComponent())
    }
}

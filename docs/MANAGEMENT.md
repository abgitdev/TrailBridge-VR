# BasaltVR management app

The management app is a native macOS SwiftUI executable in the existing `streamer` package.
It is intentionally a thin front end over `BasaltBottleKit` and `BasaltCore`: bottles, profiles,
stream settings, and safety validation have one implementation shared with the command-line tools.

## Build and run

From the repository root:

```sh
swift build -c release --package-path streamer
swift run -c release --arch arm64 --package-path streamer BasaltVR
```

The release configuration keeps the SwiftUI manager responsive and optimizes the streaming hot
paths. The app launches the already-built `basalt-streamer` executable directly so it can own its
lifecycle and capture its live output; it does not start a second Swift build while a game session
is connecting. Set
`BASALT_REPO_ROOT` if the app is launched with neither the repository nor one of its descendants as
the working directory.

## Current workflow

The window opens on the **Library** once the required setup checks pass and on **Setup** until then.
Sections are also on ⌘1–⌘5, ⌘R rescans, ⌘. stops the active session, and the sidebar footer always
shows the session state with a Stop button.

1. **Setup** checks Apple Silicon and macOS 14, adb, the pinned Wine/DXMT engine, the built OpenXR
   runtime, optional Screen Recording permission, and optional BlackHole audio. **Video in games
   (GStreamer)** checks for the system framework and shows its version when available. Its action
   opens the download of the official GStreamer 1.28.1 package that Wine 11.10 needs. Install it
   with an administrator account, for all users of this Mac, then click **Refresh**. Games can
   still launch when the framework is missing. The adb action
   opens the Headset page, which downloads Google's platform tools, and the BlackHole action
   downloads BlackHole's official installer. Build-related actions open the bottle guide because
   compiling the pinned runtime is a developer operation.
2. **Bottles** shows Basalt-managed prefixes alongside installed Whisky and CrossOver bottles.
   External prefixes are read-only. **Copy into Basalt** creates an isolated pinned-engine bottle,
   APFS-clones the existing prefix without changing its source, and runs Wine's prefix update.
   Prepare then installs DXMT and OpenXR and runs the same loader verification as
   `basaltctl bottle prepare`. Managed bottles can launch Steam or a selected Windows installer.
   **New Bottle** (⇧⌘N) creates an empty bottle on a chosen engine.
3. **Library** parses Steam `libraryfolders.vdf` and installed `appmanifest_*.acf` files in
   every discovered bottle, follows mapped extra Steam-library drives, and uses local Steam artwork
   where available. It also discovers BSManager versions below the default
   `~/BSManager/BSInstances`, the legacy Documents location, BSManager's configured installation
   parent, managed bottles, or a folder selected with **Locate Instances Folder**. The BSManager
   section detects its standard Windows installation inside every Basalt bottle, launches it with
   that bottle's Wine environment, and can run an official Windows installer for installation or
   updates. Versions BSManager creates inside a bottle are picked up automatically after it exits.
   Each external instance remains read-only and can become a profile in a selected Basalt bottle
   with the Steam identity and BSIPA `winhttp` override already set. Toolbar search plus VR-only and tool
   filters are included; playable games sort first in each section. Existing profiles and direct Beat Saber detections appear alongside Steam
   and BSManager games. Steam games in a managed bottle can become `-applaunch APP_ID` profiles
   without re-entering paths. Such a profile is never passed to Steam as it is: at each launch
   TrailBridge starts the game's own executable, chosen from Steam's launch options in
   `appcache/appinfo.vdf` or, without them, from the game folder (see
   [Bottles](BOTTLES.md#profiles)), so the game gets the session's OpenXR environment.
   **Add Game…** (toolbar, `plus`) adds any other Windows game, such as
   one from GOG or itch.io: pick a Basalt bottle and the game's `.exe` inside its `drive_c` (install
   it first with Bottles → ⋯ → Run Windows Installer…). The name comes from the game folder,
   skipping build folders such as `Binaries/Win64` or `bin/win64`. The source is itch.io when a
   folder inside `drive_c` is named for it (the itch app's `itch\apps`, or `Itch Games`), else
   Direct. Optional arguments are split on spaces, without
   quotes. The game folder becomes the working directory and the profile's game folder
   (`gameRoot`). SteamVR games still need OpenComposite from the profile editor; native OpenXR
   games do not. It is the same profile as `basaltctl profile add`.
4. **Profiles** can edit their source, Windows executable, working directory, arguments, and
   environment, or be deleted without removing the game. OpenComposite installation is available
   from More → OpenVR Support… or the profile editor, with the game DLL inside the managed prefix.
5. **Play** (from a game tile, or the Stream page's game picker) starts wired or Wi-Fi ALVR with the selected FPS, bitrate, resolution, latency preset,
   and optional audio input. When audio is enabled, the streamer temporarily routes default
   application output to that loopback and restores the prior output on shutdown. Once the
   authenticated runtime control file exists, the app asks `BasaltBottleKit` for a fully validated
   Wine launch command and owns that child process too.
6. **Stream** shows the session state, the effective stream settings for the selected game, the
   latest Quest FPS, actual wire Mbps, and input-to-display latency with bounded sparkline history
   and average/min/max, and the raw session log (copyable, and clearable between sessions). Stopping the session terminates both children;
   an unexpected streamer exit also terminates the game. While streaming, a health banner explains
   a headset that stopped reporting frames, a sustained frame rate below 90% of the target, latency
   above the latency preset's budget, thermal pressure, or Low Power Mode, with a settings
   suggestion for the next session. **Save** writes the log, or every metric sample of the session
   as CSV for comparing runs.
7. **Recent Sessions** (on the Stream page) records each session's game, settings, streamed
   duration, outcome (ended, stopped, or the failure reason), and whole-session FPS, latency, and
   wire-rate averages, including how often the headset ran below its target. The last 50 sessions
   are kept in `SessionHistory.json` in the data folder; a finished game can be replayed from its row.
   Once a session has stopped, however it ended, and its Wine processes are gone, the app reads
   the log the game wrote itself, which often says why a game that runs shows nothing in the
   headset. A Unity player writes `Player.log` (and `Player-prev.log` for a run before it in the
   same session) in `AppData/LocalLow/<company>/<product>` of the prefix's Windows user, as named
   in `<Game>_Data/app.info` (for a launcher, in the only other `*_Data/app.info` beside it); Unity
   2017.2 to 2018 wrote `output_log.txt` there, older versions `output_log.txt` in `<Game>_Data`.
   An Unreal game writes `<Project>/Saved/Logs/*.log` in `AppData/Local`, or else in the game's
   folder. Only regular files inside the prefix or the game's folder that were written since the
   game started count; a binary file is skipped, UTF-16 with a byte order mark is read as such,
   and of a log larger than 8 MB only the end is read. The excerpt keeps the last 200 lines and
   every line that reports an error, in their order, with personal data replaced in whole lines as
   in a copied log; a line is then cut after 1,000 bytes, and one over 16 KB is left out for a
   note. All of it, headers and notes included, fits in 64 KB, so a long log loses some of the
   last lines or of the errors too; notes say where lines were left out. It is saved as
   `<UTC time>-<profile>.game.log` in the data folder's `Diagnostics` folder, beside the session's
   recording when there is one; of the others the latest 50 are kept. The session log names the
   game's log as the game does (`C:\users\[user]\…`), the session's row in Recent Sessions shows
   the excerpt, and the next launch and a diagnostic report wait until it is saved.
   Every session, with a game log or without, then gives a hint, once, for each error with a known
   cause (`KnownErrorHint.rules`), after the line that names the game's log. What its processes
   print is read as it arrives, so a trimmed or cleared session log loses nothing; the app's own
   lines, which quote paths, and the excerpt's headers and notes are never read. The hints wait
   for the game's log to be read, at most as long as a launch waits for it. A
   `WindowsVideoMedia error` in the game's log or output sends to Setup when GStreamer was missing
   as the game started, and otherwise says that Media Foundation in Wine could not play the video.
   A `DllNotFoundException` for `openvr_api` or a failed OpenVR initialisation sends to the game
   card's **OpenVR Support…**, for OpenComposite, and says to restore the game's own
   `openvr_api.dll` first, by verifying its files in Steam, when none is found. A failed
   `xrCreateInstance`, or the runtime's own reason for refusing one, says that the game could not
   start OpenXR, but only when no runtime connected in the session (the streamer's
   `OpenXR runtime connected` line, read also when it comes late), so Unity's refused first
   request for OpenXR 1.1 gives none. A line of the game's or Steam's output that starts with
   `wineserver crashed` asks to start the game again and to attach a diagnostic report if it
   happens again. GStreamer's known harmless warnings never give a hint. When another launch or a
   utility has taken the log over, the hints are not shown there; the session's record keeps them
   either way.
8. **Settings** persists global stream defaults and per-profile overrides, selects audio and
   USB/Wi-Fi transport, and allows the managed Basalt data directory to be changed from the UI.
9. **Diagnostic Report** (Settings, or **Help › Diagnostic Report…**) previews a bug-report
   snapshot: app version, commit, and control protocol; Mac model, macOS, and power state; setup
   checks; engines, bottles, and profiles; stream settings; the current and recent sessions, with
   the hints the session log gave for each; and,
   optionally, the end of the session log and the excerpt of the game's own log: read anew from
   the running game, else the one saved with the latest session. It can be copied as Markdown for
   a GitHub issue or saved as Markdown or JSON. The home folder and user name (also in Wine's
   `C:/users/<name>` and `Z:\Users\<name>` paths and an Unreal log's `LogInit: User:` line), email
   addresses, Steam IDs, headset serials and host names, Mac host names, IP and MAC addresses, and
   long hex tokens are replaced before anything is shown, and profile environment values are never
   included. Nothing is uploaded.

OpenComposite is a separate GPL-3.0 project by its authors, never bundled with TrailBridge.
Library → More → OpenVR Support… (also in Edit Launch Profile…) finds game DLLs inside the
profile’s managed game folder. Choose a target if several exist, then Download Official Build…
to confirm a download from the official OpenComposite site, or Choose File… to supply a DLL.
The app verifies the PE architecture and shows the file size and SHA-256 before installation.
Uninstall OpenVR Support restores the original DLL and removes only BasaltVR-generated configuration.

TrailBridge VR is published as a DMG. The app in it is signed ad hoc, not with an Apple Developer
ID, and is not notarized. It holds the OpenXR runtime and the DXMT fork and no Wine: the app
downloads the pinned Wine build when it is first set up. Developers build the DMG with:

```sh
make release    # runs packaging/build-dmg.zsh
```

The packager builds the OpenXR runtime from the current sources, takes the DXMT fork from the
ignored build tree and writes the DMG and its SHA-256 to `.local/dist`. It stops when a file in
the app still holds a build path or a name that identifies the Mac or its owner.

## Tests

```sh
swift test --package-path streamer
```

`BasaltManagerKitTests` covers external-bottle metadata, Steam VDF/manifests, artwork, BSManager
default/configured/explicit-location and managed-bottle launcher/instance discovery, Windows/host
path mapping, Beat Saber scanning and source inference, duplicate resolution, stream argument
generation, live-stat parsing, session history persistence and summaries, stream-health rules,
metric CSV export, diagnostic redaction, report rendering, the game log excerpt, its storage
and its place in the report, and the hints for known errors in both logs. `BasaltBottleKitTests`
verifies repository/support-root
discovery, maintenance and VR launch commands, the BSManager Steam prerequisite, profile deletion,
where Unity and Unreal games write their logs inside a prefix, and a real isolated import whose
source remains unchanged.

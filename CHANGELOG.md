# Changelog

All notable changes to TrailBridge VR are documented here.

## 0.2.3 — 2026-11-27

- Add Steam Game lists Tactical Assault VR and The Elder Scrolls V: Skyrim VR as verified in the
  headset, and the README lists them among the tested games.
- The Library marks a verified game as verified also when its profile starts it through
  `steam.exe -applaunch`, as Add Steam Game saves games it knows no executable of.
- Stopping a session no longer gives the hint that Wine crashed. The stop takes Wine's server down,
  and Steam's Wine process reported that as a crash; now only output that reaches the app before
  the stop counts.

## 0.2.2 — 2026-11-25

- Every Steam game starts in the headset, not only the verified ones. A profile made by Add Steam
  Game for any other game used to run `steam.exe -applaunch APP_ID`: Steam then started the game
  without the session's environment, so the OpenXR runtime could not reach the streamer, the
  headset stayed black and the session ended at once. TrailBridge now starts the game's own
  executable, chosen from Steam's launch options in `appinfo.vdf` or from the game folder, with
  `SteamAppId` set. Existing profiles need no change.
- The session log says why a session stays headless: the OpenXR runtime names the missing
  environment, DXMT build or connection, and the app adds a hint when the started file ends within
  seconds, as a launcher that opens the game separately does.
- Setup checks for GStreamer, which Wine uses to play videos in games, and links to the official
  package. Diagnostic reports include its status and version when available. Games can still
  start without it, with one warning per game session in the log.
- The session log shows the first occurrence of each known harmless GStreamer warning and totals
  its repeats when the output closes. Diagnostic reports include repeat counts during a session,
  and recordings keep the full output and final counts.
- Each session keeps an excerpt of the game's own log, where the reason for a black headset often
  is: Electrician Simulator VR ran and sent frames while only its `Player.log` said that it could
  not decode its video. When the session ends, TrailBridge reads a Unity player's `Player.log`
  (`output_log.txt` in older versions) or an Unreal game's `Saved/Logs` and keeps the last 200
  lines and every line that reports an error, with personal data replaced. If Wine could not be
  stopped, the excerpt is still kept and marked as possibly incomplete. The excerpt opens from the
  session in Recent Sessions, is listed on the Diagnostics page and can be included in the
  diagnostic report; it stays on the Mac.
- Diagnostic redaction covers more Steam ID formats, hides full names in account fields and shows
  a game folder outside the Wine C: drive as `[game folder]`.
- When a session ends, the session log gives a short hint for errors whose cause is known, found
  in the game's own log or output or in Wine's output: a video the game could not play, pointing
  to Setup when GStreamer is missing; OpenVR that could not start, pointing to the game's OpenVR
  Support for OpenComposite; OpenXR the game could not start; and a Wine crash. Each hint is given
  once, and the diagnostic report lists the hints of recent sessions. GStreamer's harmless
  warnings never give one, nor does Unity's refused first request for OpenXR 1.1 when the game's
  runtime connects after it.
- The README lists Electrician Simulator VR among the tested games and the diagnostics among the
  features.

## 0.2.1 — 2026-11-15

- Setup recognises Rosetta 2 on every macOS version: the check now runs Intel code, as
  `arch -x86_64` does, instead of looking for a file that newer macOS versions keep elsewhere.
- The README shows screenshots of the app.

## 0.2.0 — 2026-11-15

The first public version of TrailBridge VR. It is built on BasaltVR: its 0.1.0 release and the
later changes on BasaltVR's main branch.

TrailBridge VR adds:

- an **Add Steam Game** wizard that creates a Wine environment, installs Steam with its official
  installer, waits for Steam's updates and adds the game to the Library; five games are marked as
  verified in a headset;
- **Add Game from Folder…**, which copies a Windows game from a folder on any disk into a new
  environment;
- a per-game fix applied before every launch (VTOL VR is switched to one render pass per eye),
  and game icons taken from the executable where there is no Steam artwork;
- OpenVR support through OpenComposite, downloaded on request and limited to tested builds;
- HEVC, quality presets from Performance to Maximum with a recommendation for the Mac in use, an
  encoder mode and per-eye sizes up to 3072 × 3280;
- a Headset page that installs the tested ALVR client and Google's Android platform tools;
- reconnection over USB or Wi-Fi without restarting the game, trusted Wi-Fi headsets and better
  bitrate adaptation;
- game audio from the Mac's own output on macOS 14.2 or newer, or through BlackHole with guided
  setup;
- a Learning guide from a new Mac to the first game;
- a Diagnostics page with an opt-in recording per game of frame timing, the session log and
  video, and personal data removed from copied and saved logs;
- recovery when Steam hangs or its first update stalls;
- **Remove TrailBridge VR…**, which deletes what the app stored on the Mac;
- a data folder on any disk;
- a DMG with the app, the OpenXR runtime and the DXMT fork; the app is not signed by Apple and
  downloads Wine 11.10 when it is first set up;
- patches to the DXMT fork and fixes in the OpenXR runtime;
- ten interface languages, with English and Russian reviewed.

BasaltVR's own history is in the [BasaltVR repository](https://github.com/frenchbaguetteman/BasaltVR).

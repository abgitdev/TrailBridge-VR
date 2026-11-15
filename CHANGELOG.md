# Changelog

All notable changes to TrailBridge VR are documented here.

## 0.2.0 — unreleased

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

# Managed bottles and launch profiles

Milestone 5 is implemented by the `basaltctl` executable in the streamer's Swift package. Its
default data root is `~/Library/Application Support/BasaltVR`; set `BASALT_DATA_DIR` or pass
`--root PATH` to use a different root. Every writable bottle prefix, private engine, metadata
file, and launch profile stays below that root.

> [!IMPORTANT]
> TrailBridge VR does not redistribute the pinned Wine engine. The app from the DMG downloads it
> into the data folder when it is first set up; a source checkout gets it from the build steps
> below.

## Engines and safety

Run the prerequisite check from the repository root:

```sh
swift run --package-path streamer basaltctl doctor
swift run --package-path streamer basaltctl engines
```

The supported VR provider is `pinned-wine-11.10-dxmt-0.80`. Creating one of these bottles uses
an APFS copy-on-write clone of the verified Wine toolchain, so installing the Basalt DXMT fork
cannot affect another bottle. Installed WhiskyWine and GPTK providers are also discoverable for
managed prefixes, but `bottle prepare` deliberately refuses to overlay DXMT into those shared
engines. CrossOver bottles and applications are never modified.

Bottle and profile names accept only 1–64 ASCII letters, digits, dots, underscores, and hyphens;
the first character must be alphanumeric. Loaded metadata is checked against its managed
directory. A pinned engine must remain inside its own bottle, while a shared provider must still
exactly match a currently discovered engine.

## Bottle commands

```sh
swift run --package-path streamer basaltctl bottle list
swift run --package-path streamer basaltctl bottle create beat-saber \
  --engine pinned-wine-11.10-dxmt-0.80
swift run --package-path streamer basaltctl bottle prepare beat-saber
swift run --package-path streamer basaltctl bottle verify beat-saber
```

`create` initializes a win64 prefix. `prepare` installs the built Basalt DXMT Windows and Unix
components into the bottle's private engine, copies the runtime DLL and JSON manifest to
`C:\basalt\runtime`, and writes the Khronos `ActiveRuntime` HKLM value. It then queries that value
and runs `loader_smoke.exe` through the bottle's Wine executable, requiring the managed DXMT
environment to advertise `XR_KHR_D3D11_enable`.

The individual `bottle install-dxmt` and `bottle install-runtime` commands are available for
diagnosis, but `prepare` is the normal idempotent path.

## Profiles

Profiles support `direct`, `steam`, `bsmanager`, and `itch` sources. The source records launcher
intent; the executable and arguments remain explicit so the CLI does not guess per-user install
locations.

```sh
swift run --package-path streamer basaltctl profile add beat-saber-steam \
  --bottle beat-saber --source steam \
  --exe 'C:\Program Files (x86)\Steam\steam.exe' \
  --arg -applaunch --arg 620980 \
  --env STEAM_COMPAT_CONFIG=basalt

swift run --package-path streamer basaltctl profile list
swift run --package-path streamer basaltctl profile show beat-saber-steam
```

Repeat `--arg VALUE` and `--env KEY=VALUE` as needed. `--cwd HOST_PATH` optionally selects the
Wine process's host working directory.

A `steam` profile whose arguments contain `-applaunch APP_ID` is not started through Steam:
`steam.exe -applaunch` only hands the AppID to the running Steam client, which would start the
game with its own environment, without `BASALT_CONTROL`, so the headset would stay black. At each
launch the profile is resolved to the game's own executable (`SteamDirectLaunch`):

1. the executable TrailBridge verified for the game, for the verified games;
2. else Steam's launch option for the app in `appcache/appinfo.vdf` (versions 39 to 42): the
   SteamVR option first, then the default and numbered ones, never options for other systems, beta
   branches, servers or editors; its arguments come first;
3. else the game folder from the app's `appmanifest_APP_ID.acf` in any library listed in
   `libraryfolders.vdf`: a Unity player (`Game.exe` beside `Game_Data`), the `.exe` named like the
   folder, an Unreal `*-Win64-Shipping.exe`, or the only probable game.

An Unreal launcher at the top of the folder is replaced by the game binary it starts, since the
session lasts as long as the started process. Arguments before `-applaunch` are the Steam client's
and are dropped; those after the AppID follow. `SteamAppId` and `SteamGameId` are set, so
Steamworks does not restart the game through Steam. When no file is clearly the game, the launch
fails with a message asking for the executable in Edit Launch Profile….

## OpenComposite

OpenComposite is a separate GPL-3.0 project by its authors and is never bundled with TrailBridge.
In Library → More → OpenVR Support… (also available in Edit Launch Profile…), select a game DLL.
Download Official Build… asks for confirmation before downloading the matching x64 or x86 DLL
from the [official OpenComposite site](https://znix.xyz/OpenComposite/). The app saves it under
`Downloads/OpenComposite/<arch>/openvr_api.dll` in its data folder and displays its size and
SHA-256 after validating the PE architecture. Alternatively, use Choose File… for your own DLL.
Install OpenVR Support preserves the original; Uninstall OpenVR Support restores it and removes
only an ini starting with `; Managed by BasaltVR`. Existing user configuration is preserved.

The command-line installer accepts a separately obtained DLL and the exact target inside the managed prefix:

```sh
swift run --package-path streamer basaltctl opencomposite install beat-saber-steam \
  --artifact /path/to/openvr_api.dll \
  --target "$HOME/Library/Application Support/BasaltVR/Bottles/beat-saber/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Beat Saber/Beat Saber_Data/Plugins/x86_64/openvr_api.dll"
```

The installer requires a PE DLL matching the existing game DLL’s x64 or x86 architecture and an
`openvr_api.dll` destination below that bottle’s prefix, with no symlinks in its target paths.
The game DLL’s first version is retained as
`openvr_api.dll.basalt-original`. The generated `opencomposite.ini` uses the D3D11 path
(`initUsingVulkan=false`).

## Launch

Start the native streamer first; it creates the authenticated loopback control file. Pass the
BlackHole input explicitly when game audio is wanted:

```sh
swift run -c release --package-path streamer basalt-streamer \
  --wired --runtime /tmp/basalt-control \
  --audio-device 'BlackHole 2ch' --route-audio
```

In another terminal:

```sh
swift run -c release --package-path streamer basaltctl run beat-saber-steam \
  --control-file /tmp/basalt-control -- --optional-game-argument
```

The run command refuses incomplete bottles or a missing control file. It maps that file into the
Wine `Z:` drive, enables the private DXMT IOSurface gate, applies the profile environment, and
starts the explicit executable. Extra arguments after `--` are appended for that invocation only.

The generated OpenComposite ini must contain only options understood by the pinned OpenComposite
build: it sets `initUsingVulkan=false`. Unknown options can abort initialization. Audio stays on
the host BlackHole route: `--route-audio` sets and verifies the device's nominal sample rate
at 48 kHz before temporarily directing application output into the loopback. If the rate cannot
be set, the streamer reports an error with guidance to check Audio MIDI Setup. It restores the prior Mac
output on shutdown. The management app adds this flag automatically. Direct CLI users with an
existing Multi-Output route can omit it. Validate the host side with
`basalt-streamer --list-audio-devices` and
`basalt-streamer audio-loopback-selftest --device 'BlackHole 2ch'`.
The loopback self-test also sets and verifies 48 kHz before capture.

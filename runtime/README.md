# BasaltVR OpenXR runtime

This directory is the Windows-facing start of milestone 3. It cross-builds an x86-64 PE
runtime DLL on Apple Silicon, using the official Khronos Windows loader for the end-to-end
test. The OpenXR SDK is pinned to release 1.1.61 commit
`5267613edf3d937e3d77556a106a65c2f82b25c6` and verified by SHA-256 during CMake fetch.

The current checkpoint implements strict loader/runtime negotiation, zero-API-layer enumeration,
instance creation/destruction, instance properties, bounded live-handle registries, HMD system
discovery, primary-stereo view discovery, and a runtime JSON manifest. It recommends the per-eye
view size the streamer configures (even, 256 to 4096 pixels per side), else 1680×1760. It
advertises orientation/position tracking capability; location flags become tracked only while a
fresh ALVR HMD pose is available.

It now conditionally advertises `XR_KHR_D3D11_enable` after an in-process capability gate proves
feature level 11.0 plus D3D11 NT-handle create, reopen, GPU copy, and readback. In that environment
the runtime returns the DXGI adapter LUID, validates the application's D3D11 session binding, and
implements up to four independent three-image color swapchains with format enumeration and
acquire/wait/release. Every swapchain texture uses `D3D11_RESOURCE_MISC_SHARED_NTHANDLE`.
WhiskyWine 7.7 with Apple D3DMetal fails the gate and therefore sees zero runtime graphics
extensions; pinned DXMT v0.80 under Wine 11.10 passes it.

The runtime now also provides FIFO session events, the required session control calls, an
absolute-deadline 72 Hz `xrWaitFrame`/`xrBeginFrame`/`xrEndFrame` contract, and bounded `VIEW`,
`LOCAL`, `LOCAL_FLOOR`, and `STAGE` reference-space handles. Headless sessions stop at `SYNCHRONIZED` with `shouldRender` false.
Sessions authenticated to the native `RuntimeLink` progress through `VISIBLE`/`FOCUSED` with
`shouldRender` true and unwind those states during clean exit.

The `hello_xr` initialization surface is now implemented: bounded instance-scoped path atoms
(`xrStringToPath`/`xrPathToString`), action sets and typed actions with spec name validation,
exact suggested-binding allowlist validation for all nine OpenXR 1.0 core interaction profiles,
localized resolved-source names, interaction-profile change events, core action-set priority,
one-shot session attachment with post-attach immutability, action spaces,
`xrResultToString`/`xrStructureTypeToString`, and
`xrLocateSpace`/`xrLocateViews` with live ALVR LOCAL-from-HEAD poses, correct VIEW/LOCAL transform
composition, and calibrated Quest IPD/asymmetric FOV (with the old ±31.5 mm/symmetric 90° values
only as the pre-calibration fallback). Missing or stale HMD samples clear
tracking-dependent location flags. Because a headless session never reaches `FOCUSED`,
`xrSyncActions` returns `XR_SESSION_NOT_FOCUSED`, every action state is
inactive, no input sources are bound or localizable, and haptics validate without firing.
Connected Quest sessions additionally store Oculus Touch suggestions, snapshot buttons/profile
state at `xrSyncActions`, locate live grip action spaces, expose controller velocity through
`XrSpaceVelocity`, enumerate and localize resolved sources, and forward priority-filtered haptic
apply/stop commands to ALVR. Protocol v7's timestamped `ControllerMask` clears a missing hand's
pose and velocity immediately and permits recovery only from a newer presence/motion sample.
The first fresh head sample defines LOCAL at the viewer's horizontal position and leveled yaw.
Holding the right Quest system/Meta button for 600 ms redefines that origin at the current head
position/yaw and queues `XrEventDataReferenceSpaceChangePending` for LOCAL. Pose lookup observes
the event's `changeTime`, which follows the latest predicted display time `xrWaitFrame` has
returned, so frames already in flight retain the previous space definition. The Quest OS normally
reserves the Meta button, so this gesture is so far exercised only by the control-daemon test; the
runtime logs `right system button pressed` to stderr when ALVR forwards the button on hardware.

`xrEndFrame` now accepts stereo `XrCompositionLayerProjection` layers: it validates layer
flags, session ownership of the layer space and each subimage swapchain, per-view poses and
FOV, in-bounds image rects (`XR_ERROR_SWAPCHAIN_RECT_INVALID`), the 16-layer minimum limit
(`XR_ERROR_LAYER_LIMIT_EXCEEDED`), and that every referenced swapchain has a released image.
Quad layers are validated and accepted but not yet composed (a frame with only quads submits
nothing); extension layers are still rejected. With the Basalt DXMT fork and an authenticated
control connection, accepted projection layers are fence-gated and forwarded by IOSurfaceID to
the native Swift streamer for stereo composition and encoding. This path is machine-verified and
has a Basalt-shaped visible wired-headset diagnostic. The pinned official Khronos `hello_xr`
D3D11 application now also completes a live Quest transport/session run, including `FOCUSED`, two
eye swapchains, Touch action localization, rendering, and clean `STOPPING→IDLE→EXITING` teardown;
the companion live Quest scene is physically confirmed with fused, level/world-fixed stereo,
tracked controller response, analog squeeze, and haptics at 72 fps.
The runtime is not OpenXR-conformant.

Milestone 5's supported persistent installation path is `basaltctl bottle prepare`. It clones the
pinned engine into a Basalt-managed bottle, overlays DXMT there, copies this runtime to
`C:\basalt\runtime`, registers the bottle-local manifest, and reruns `loader_smoke.exe` with the
managed DXMT capability expected. It does not modify the generated acceptance prefixes described
below or any shared Whisky/GPTK/CrossOver engine. See [the bottle guide](../docs/BOTTLES.md).

## Prerequisites

```sh
brew install cmake mingw-w64
```

Run without the project wrapper, the non-graphics smoke expects WhiskyWine at Whisky's normal
per-user library path. Under `scripts/trailbridge-dev.zsh` it instead extracts, without the
DXMT overlay, the pinned Wine 11.10 archive that `test-dxmt.zsh` downloads and verifies, into
`runtime/build/wine-smoke`; run the DXMT suite once first. Override either choice with `WINE`.

## Build and test

From the repository root:

```sh
runtime/scripts/test-wine.zsh
```

The script:

1. Cross-builds the runtime and smoke programs as x86-64 Windows PE binaries.
2. Verifies that the DLL exports only `xrNegotiateLoaderRuntimeInterface`.
3. Runs invalid and valid negotiation plus direct instance-lifecycle checks under Wine.
4. Registers the manifest under the Khronos HKLM key in an isolated generated Wine prefix.
5. Creates a BasaltVR instance and queries its HMD, stereo views, and opaque blend mode through
   the official Khronos Windows loader before destroying it, then exercises path atoms, action
   set/action lifecycle and name validation, exact suggested bindings for all nine OpenXR 1.0 core
   interaction profiles (including cross-profile/wrong-user rejection), and the to-string calls —
   everything available without a session.

The isolated prefix is `runtime/build/wineprefix` by default, or
`.local/wine-tests/wine-smoke/prefix` under the project wrapper (see
[Test prefixes](#test-prefixes)). The script intentionally ignores an ambient `WINEPREFIX` so it
cannot silently change a game bottle. Override `BUILD_DIR`,
`BASALT_WINEPREFIX`, `WINE`, `CMAKE`, or `OBJDUMP` when needed. Do not point
`BASALT_WINEPREFIX` at a game bottle unless you intend to change that bottle's active OpenXR
runtime.

Run the graphics acceptance test separately:

```sh
runtime/scripts/test-dxmt.zsh
```

On its first run this command downloads and SHA-256-verifies two pinned upstream release
artifacts into the ignored `runtime/build/dxmt` tree:

- Gcenx macOS Wine 11.10 x86-64, SHA-256
  `6d0637c3526fbe7051a5f8968dbde68fbc3ac417717648b9331c46642b52173b`.
- DXMT v0.80 built-in, SHA-256
  `8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d`.

The script overlays only its generated Wine extraction, creates a dedicated prefix, runs the
standalone share/reopen/copy/readback probe, the fence frame-completion probe
(`dxmt_fence_probe`), and the IOSurface private-data probe (`dxmt_iosurface_probe`,
asserting absence on stock DXMT). It also verifies that the absolute waitable-timer scheduler
holds 72 Hz under Wine; the previous repeated `Sleep(14)` path measures only about 62 Hz. The
script registers Basalt's manifest only in that prefix, and
then uses the official Khronos loader to exercise reference spaces, session and interaction-profile
events, frame call ordering, exact profile bindings/localized names, action-set priority, action
spaces, velocity, controller loss/recovery, haptics, static `xrLocateSpace`/`xrLocateViews`,
projection-layer submission (accept, quad acceptance/validation, limit/rect/never-released
rejection), FIFO swapchain wait/release order, and two independent three-image D3D11 swapchains.
It also creates and submits a two-slice texture-array swapchain (Unity's Single Pass Instanced
shape), whose slices the runtime copies into per-eye IOSurface exports. It does not modify `/Applications`,
Whisky, CrossOver, or a game bottle. Rosetta 2 is required on Apple Silicon. The generated
prefix is `runtime/build/dxmt/prefix-wine-11.10-dxmt-v0.80`, or
`.local/wine-tests/dxmt-wine-11.10-dxmt-v0.80/prefix` under the project wrapper; the two headset
scripts below share it. Override it only with `BASALT_DXMT_WINEPREFIX`; never point that variable
at a game bottle (see [Test prefixes](#test-prefixes)).

For the visible end-to-end graphics test, connect an authorized Quest over USB, open its ALVR
client, stop any existing streamer, and run:

```sh
runtime/scripts/test-headset.zsh 60
```

The optional argument is the render duration in seconds (5–600). The test starts the release
streamer, runs the OpenXR/D3D11 smoke in a long visual mode, and should display a green
left-controller marker plus a pale world-fixed depth constellation in both eyes. Moving your head
tests world locking; moving the controller in depth changes marker position/size, and squeezing the
grip grows it and shifts it toward yellow. It also requires a fresh live
head pose to reach `xrLocateViews` and
prints the sampled LOCAL-space position. It temporarily overlays only the generated Wine tree with the matched
Basalt DXMT fork and restores stock DXMT during cleanup. Environment overrides are
`BASALT_HEADSET_SECONDS`, `BASALT_HEADSET_FPS`, `BASALT_HEADSET_MBPS`, and
`BASALT_HEADSET_RESOLUTION`. The wired setup sends a normal wake event before foregrounding ALVR,
but keep the headset awake while it starts if its proximity sensor puts it back to sleep. The
streamer requires a fresh Quest tracking timestamp before it declares the video path ready.

For the external-application gate, build and run Khronos' real D3D11 `hello_xr` from the pinned
official 1.1.61 source:

```sh
runtime/scripts/test-khr-hello-xr-headset.zsh
```

The target uses only small MinGW SDK compatibility headers; the upstream sample sources are not
rewritten. It has completed a live Quest run through `FOCUSED`, two D3D11 eye swapchains, localized
Touch actions, roughly 14 seconds of rendering, and clean `STOPPING→IDLE→EXITING` teardown. That is
an external-app runtime/transport/session pass. The separate long-running live Quest gate is also
physically confirmed with fused, level/world-fixed stereo, tracked controller motion, analog
squeeze, and haptics; the left controller menu button requests clean exit from `hello_xr`.

To build without running Wine (`make runtime-build` runs the same preset):

```sh
cmake -S runtime --preset mingw-release
cmake --build runtime/build --parallel
```

IDEs that read `runtime/CMakePresets.json` (VS Code CMake Tools, CLion) pick up the MinGW
toolchain and the same `runtime/build` tree the test scripts use. Configuring `runtime/` with the
host compiler does not produce a usable runtime.

If `runtime/scripts/build-dxmt-fork.zsh` has produced the Basalt DXMT fork
(`runtime/dxmt-fork`, MIT v0.80 base plus the IOSurface texture-export patches), the script
adds a fork phase: with the fork overlaid and its gate off, behavior must be
indistinguishable from stock; with `DXMT_BASALT_IOSURFACE=1`, the probes and the OpenXR
runtime smoke assert that every NT-handle shared texture — including all loader-visible
swapchain images — republishes a nonzero, per-image-distinct `IOSurfaceID` under
`BASALT_GUID_IOSURFACE_ID`, while NT-handle reopen and the GPU copy/readback checks still
pass. The phase ends with the cross-process zero-copy proof: a Wine process uploads a
known pattern into a gated texture through the immediate context, waits an
`ID3D11Fence`, and publishes the ID; a native host tool (`tests/native/iosurface_readback.c`)
maps that IOSurface by ID and must read the exact bytes. The tree is restored to the
pinned stock overlay afterwards, including when a fork-phase step fails.

### Test prefixes

Unless told otherwise, Wine links a new prefix's Windows user folders (Desktop, Documents,
Downloads, Music, Pictures, Videos) to the same folders in the Mac home directory. `test-wine.zsh`,
`test-dxmt.zsh` and both headset scripts source `runtime/scripts/wine-sandbox.zsh`, which does for
their prefix what the app does for managed bottles: per-prefix `XDG_CACHE_HOME`,
`XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME` and `TMPDIR`, an XDG `user-dirs.dirs` that
names per-prefix host folders, and `winemenubuilder` disabled. A prefix directory named `prefix`
keeps these in its sibling `host/` (the managed-bottle layout); any other prefix uses
`<prefix>-host/`. Wine's server socket under `/tmp` and the system Metal shader cache stay outside
the scripts' control.

Before Wine starts, and again once Wine has created the prefix, the scripts refuse a prefix whose
user-folder links point outside the repository and outside its own host folders, and print each
offending link. They never rewrite or delete such a prefix: point the override variable at a new
prefix, remove the disposable prefix yourself, or set `BASALT_ALLOW_EXTERNAL_USER_FOLDERS=1` to
use it anyway.

`scripts/trailbridge-dev.zsh` exports `BASALT_REPO_ROOT`; when it matches the checkout, the
default prefixes move to `.local/wine-tests/<name>/prefix`. The wrapper deliberately clears
`WINEPREFIX`, `BASALT_WINEPREFIX` and `BASALT_DXMT_WINEPREFIX` inherited from the calling shell, so
pass an explicit override after it, for example:

```sh
./scripts/trailbridge-dev.zsh env BASALT_DXMT_WINEPREFIX="$PWD/.local/wine-tests/other/prefix" make dxmt-test
```

## Implementation history

The app-facing and graphics slices, in order:

1. ~~Implement the DXMT texture-export fork~~ Done: `v0.80-basalt.1` builds reproducibly,
   the fork phase of `test-dxmt.zsh` gates it, and the cross-process zero-copy pixel proof
   passes (native `IOSurfaceLookup` readback of D3D11-rendered, fence-confirmed pixels).
2. ~~Control socket + FrameReady + streamer consumption~~ Done end to end. `pe/control.cpp`
   (protocol `pe/basalt_control_protocol.h`) connects via `BASALT_CONTROL`, probes the fork
   GUID, registers swapchain IOSurfaceIDs, and sends `FrameReady` only after the per-frame
   `ID3D11Fence` completes at `xrEndFrame`. Connected sessions report `shouldRender` true,
   progress `SYNCHRONIZED→VISIBLE→FOCUSED` (and unwind on exit), and let
   `xrSyncActions`/haptics succeed with inactive actions; headless behavior is unchanged.
   `test-dxmt.zsh` gates a 21-frame hello_xr-shaped stereo render loop whose per-frame clear
   colors the native daemon verifies byte-exact after each fence-confirmed FrameReady. It then
   repeats the smoke against the Swift streamer's `RuntimeLink`
   (`streamer/Sources/BasaltCore/RuntimeLink.swift`, via `basalt-streamer
   runtime-link-selftest`), which must acknowledge and encode at least 21 frames to H.264
   through the zero-copy IOSurface → CVPixelBuffer → VideoToolbox path. The runtime advertises
   only BGRA/BGRA-sRGB swapchains because CoreVideo cannot wrap DXMT's RGBA IOSurfaces; rejecting
   that format at negotiation prevents a silent black stream. Protocol v9 binds each frame to the exact Quest tracking timestamp
   used by its successful `xrLocateViews` call, preserves it through VideoToolbox into ALVR,
   and requires an ordered post-Metal-read acknowledgement. A strict two-frame window overlaps
   game rendering with native compose/encode while preventing latency accumulation. The control handoff also carries the
   selected per-eye stream dimensions so applications render at the target resolution instead
   of rendering 1680×1760 and immediately downscaling it.
   `runtime/scripts/test-headset.zsh` now runs that producer for a
   visible interval and sends the resulting H.264 through the live wired ALVR path.
3. ~~Feed live ALVR head poses into `xrLocateViews`/`xrLocateSpace`~~ Done: protocol v2 carries
   normalized ALVR HMD poses through a dedicated receive/demultiplex thread, with correct
   VIEW/LOCAL transforms, freshness, and tracked flags.
4. ~~Bridge Quest Touch input and haptics~~ Done for the automated controller boundary: protocol v7
   adds corrected controller grip motion/velocities, sparse buttons, active profiles, reverse
   haptic commands, and an authoritative per-frame `ControllerMask`.
   Controller samples are fairly coalesced per hand, button caches are bounded/flow-controlled,
   and ALVR control loss sends an atomic input reset so retained state cannot stick. A missing-hand
   mask immediately clears pose/velocity, while newer motion recovers tracking. Quest IPD and
   asymmetric per-eye FOV now feed `xrLocateViews` instead of prototype stereo geometry.
   All nine core profiles receive exact allowlist validation; Touch suggestions resolve into
   sync-frozen boolean/float/vector/pose states with localized source names, profile-change events,
   and core action-set priority shared by input, spaces, enumeration, and haptics. Grip action
   spaces work relative to LOCAL/VIEW and as `xrLocateViews` bases. ALVR has already predicted its
   corrected grip pose, so Basalt exposes the supplied linear/angular velocity without extrapolating
   the pose a second time. Stock ALVR transmits corrected grip motion, not its separately
   created aim space. The runtime reconstructs an estimated Touch aim pose (see below).
   The native daemon gates
   pose/velocity, immediate loss and recovery, a button change, profiles, priority, bound/localized
   sources, apply/stop haptics, and time-bounded LOCAL recentering from the Quest reset gesture.
   The pinned official Khronos `hello_xr` completes a live
   external-app transport/session run. The live Quest scene physically verifies level/world-fixed
   stereo, tracked controller response, analog squeeze, and squeeze-triggered haptics at 72 fps;
   M4 is complete.

Keeping the PE ABI side separate from the native compositor makes that platform boundary
explicit and prevents placeholder swapchains from being mistaken for a playable runtime.

### Touch controller poses

Grip preserves ALVR 20.14.1's corrected grip convention. Its Quest 2/3 client sends native
OpenXR grip composed with a local -15 degree X rotation and translation
`(-0.005, -0.005, 0)` metres for the left hand (X mirrored for the right).
It does not send the independently created aim space. See ALVR's
[client pose conversion](https://github.com/alvr-org/ALVR/blob/v20.14.1/alvr/client_openxr/src/interaction.rs).

Aim is reconstructed from OpenComposite's published Quest 2 `openxr_grip` and `tip` model
transforms, removing ALVR's correction when converting between those frames. Relative to
the received corrected grip this gives -43 degrees about local X and approximately
`(0.014694, -0.025989, -0.073316)` metres (X mirrored for the right). These are an estimate
for Quest 3 Touch Plus, not a specified or measured Meta calibration. The
[OpenXR definitions](https://registry.khronos.org/OpenXR/specs/1.0/html/xrspec.html#semantic-paths-standard-pose-identifiers)
define grip at the held hand and aim along the platform's pointing ray (-Z forward);
they do not prescribe a numeric Touch transform. Model values come from
[OpenComposite's Touch profile](https://gitlab.com/znixian/OpenOVR/-/blob/a27e7e6a64bdcd1eff6b7fba1ea2ea34bcf1273d/OpenOVR/Misc/Input/OculusInteractionProfile.cpp).
Both `xrLocateSpace` (target and base) and `xrLocateViews` (action base) apply the chosen
pose before the application's space offset. Velocity includes the offset origin's angular motion.

For a per-game grip compatibility experiment, the runtime reads
`BASALT_TOUCH_GRIP_PITCH_DEGREES` once at the first controller-space lookup. Default: **0**
(off, preserving existing grip/raw poses). It accepts finite degrees from -180 through 180;
missing or invalid values select 0. Positive values rotate grip's -Z toward local +Y.
The rotation applies to both grips, leaves their origins and reconstructed aim unchanged,
and precedes application offsets. Restart the game process after changing the value.

OpenComposite's Touch `/pose/raw` uses its `legacy-left-grip-pose`/`legacy-right-grip-pose` actions
and their identity-offset `gripPoseSpace` spaces,
then multiplies by the inverse of its `openxr_grip` component transform. Its Touch `tip`
is also a fixed profile transform. Separating OpenXR aim therefore does not change these
OpenVR poses. Enabling the grip override does change them, including rendered hands;
keep the variable confined to the game launch profile being tested, never shared globally.
For an initial comparison, +15 degrees cancels ALVR's rotational correction only; it is
a diagnostic value, not a proven locomotion fix. Remove the variable to roll back.

### DXMT feasibility gate

`dxmt_shared_texture_probe.exe` is the first graphics gate. It uses only standard D3D11/DXGI:
create a `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` texture, create and reopen its NT handle, copy
through the GPU, stage it back to the CPU, and verify the pixels. `test-dxmt.zsh` passes this gate
and then repeats the important sharing operation on actual OpenXR-created textures. The current
WhiskyWine 7.7 + Apple D3DMetal engine fails at `QueryInterface(IDXGIResource1)` with
`E_NOINTERFACE`, as expected, so `test-wine.zsh` verifies that the runtime hides D3D11 there.

`dxmt_fence_probe.exe` verifies the Phase-1 frame-completion mechanism from
`docs/DXMT-INTEROP.md` with only public D3D11: a non-shared `ID3D11Fence` signaled on the
immediate context after queued GPU work, waited through `SetEventOnCompletion`. Under the
pinned stack the event fires only after `Signal`, values are monotonic and re-waitable, and
readback pixels are correct; `CreateFence(SHARED)` availability is reported informationally
(available at Wine 11.10 + DXMT v0.80). DXMT's `Map(DO_NOT_WAIT)` bookkeeping cleared ~1 ms
after the fence event, so the event proves GPU-queue ordering, not instant CPU-map readiness.

Passing the stock gate proves that D3D11 swapchain resources can be shared and reopened inside
Wine, but it does not by itself prove native zero-copy handoff. The pinned Basalt DXMT fork adds
that boundary through IOSurface IDs and a Wine Unix-call thunk; the fork phase and native readback
test described above now prove the separate-process handoff. Raw Objective-C object pointers are
never sent to the Swift process.

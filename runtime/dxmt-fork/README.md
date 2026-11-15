# Basalt DXMT fork

Patches for the DXMT texture-export boundary defined in `docs/DXMT-INTEROP.md`: OpenXR
swapchain textures created with `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` become IOSurface-backed
so the BasaltVR streamer daemon can map the same pixels zero-copy in a separate native
process.

## Base and license

The fork base is the upstream **v0.80 tag** (commit `589adb780354b461645b29999cefaf533594ee99`),
the last MIT-licensed DXMT release; later upstream commits are LGPL 2.1+ (see the fork-base
decision in `docs/DXMT-INTEROP.md`). These patches are MIT like the rest of BasaltVR.

## Patches

- `patches/0001-basalt-iosurface-export.patch` — the feature:
  - New unix call `MTLDevice_newTextureFromIOSurface` (index 132, appended to both dispatch
    tables): creates a texture from a fresh IOSurface, or imports one via
    `IOSurfaceLookupFromMachPort`. Returns the global `IOSurfaceID` in
    `WMTTextureInfo.reserved` and an `IOSurfaceCreateMachPort` send right in `.mach_port`.
  - `TextureAllocationFlag::IOSurfaceBacked` plus `Texture::importIOSurface`; the allocation
    records its `iosurfaceID`.
  - Gate in the D3D11 shared-texture path: with **`DXMT_BASALT_IOSURFACE=1`** in the
    environment, `D3D11_RESOURCE_MISC_SHARED_NTHANDLE` textures take the IOSurface path.
    The IOSurface's own mach port feeds DXMT's existing bootstrap/D3DKMT registration, so
    NT-handle `CreateSharedHandle`/`OpenSharedResource1` reopen keeps working
    (`SharedResourceData` gained an `is_iosurface` field; the fork ships as a matched
    DLL/so set exactly like stock DXMT).
  - The texture republishes its `IOSurfaceID` through public
    `ID3D11DeviceChild::GetPrivateData` under `BASALT_GUID_IOSURFACE_ID`
    `{DD807311-529E-4856-A5C0-48BED2048129}` (4 bytes, little-endian `uint32`).
  - Only simple 2D, single-mip, non-array, single-sample textures in `RGBA8`/`BGRA8`
    (plus sRGB) take the IOSurface path; every other NT-shared texture keeps the stock
    `MTLSharedTextureHandle` path even under the gate, so games see no behavior change.
    The unix call also rejects incompatible descriptors defensively (nil texture, not a
    Metal assertion). Without the gate, behavior is bit-for-bit stock.
- `patches/0002-fix-missing-iomanip-include.patch` — build fix for current mingw-w64 GCC
  (`std::setfill`/`std::setw` used without `<iomanip>`).
- `patches/0003-exportless-winemac-metal-view.patch` — creates a normal AppKit/Metal
  child view for single-window games when an otherwise-compatible Wine build hides DXMT's
  optional private mac-driver exports.
- `patches/0004-force-unity-openxr-multipass.patch` — reports
  `VPAndRTArrayIndexFromAnyShaderFeedingRasterizer` as unavailable. Unity OpenXR then uses
  its multipass fallback, matching Basalt's independent 2D IOSurface eye swapchains and
  preventing single-pass fullscreen lighting from reaching only one eye. The patch's own
  comment predates texture-array support and says Basalt rejects array swapchains; the
  runtime now accepts them (each slice is copied into a per-eye IOSurface export), but
  multipass remains the path Unity takes.
- `patches/0005-include-functional-for-libcxx.patch` and
  `patches/0007-include-iterator-for-libcxx.patch` — include the standard headers
  required by `std::equal_to` and `std::back_inserter` when building with LLVM-MinGW.
- `patches/0006-use-public-metal-atomic-api.patch` — use Metal's public atomic add
  wrapper for the tessellation work counter; the private compiler intrinsic's
  signature differs between toolchain versions.
- `patches/0008-respect-xdg-cache-home.patch` — resolve relative AIR and Metal cache
  paths under an absolute `XDG_CACHE_HOME` when provided. Without it, preserve the
  upstream Darwin cache location.
- `patches/0011-opt-in-failure-diagnostics.patch` — with
  `DXMT_BASALT_DIAGNOSTICS=1` and an absolute, symlink-free `BASALT_REPO_ROOT`,
  write private per-process results below `.local/diagnostics/dxmt-<pid>-<uuid>/`:
  - Failed render, mesh and compute pipeline descriptors, errors, function names
    and the exact AIR-containing `.metallib` inputs, including cached inputs.
  - The first Metal command-buffer failure, its identity and label, plus encoder
    labels and execution status when Metal supplies them. The first error also
    gets one `err:` line in the session log.
  Instrumentation is off by default. It retains shader-library bytes and enables
  additional Metal error tracking only in diagnostic mode, which increases memory
  and CPU overhead. Invalid output roots disable it; there is no fallback output
  path. Dumps may contain game shaders and are local debugging artifacts.
- `patches/0012-sink-discard-into-merge.patch` — move `discard_fragment` from
  branches whose only successor is a merge block into that merge block. Apple's
  Metal compiler service crashes on a block with PHI nodes when every predecessor
  calls `air.discard_fragment`; the crash also loses other pipelines being
  compiled in the same service process. The discard may be followed by
  side-effect-free instructions, and the pass repeats until no block has the
  shape. A predecessor that branches conditionally, or runs a side effect after
  its discard, is left alone.
- `patches/0013-limit-mesh-paint-dilation-loop.patch` — stop the search loop of
  one pixel shader, identified by its bytecode hash, after a single iteration.
  The shader fills empty texels of a baked position texture and has no early
  exit; run several times in a row it costs more than a frame on Apple GPUs.
  Only this shader's cache key changes.

## Building

```sh
runtime/scripts/build-dxmt-fork.zsh
```

Pins and verifies: DXMT v0.80 by commit, LLVM `llvmorg-15.0.7` by commit (built from source
on the first run — tens of minutes), and the Wine 8.16 build-tools tarball by SHA-256 (the
same tree DXMT's own CI used to produce the official v0.80 release binaries, which
`test-dxmt.zsh` already validates under the pinned Gcenx Wine 11.10). Prerequisites beyond
`runtime/README.md`: `brew install meson ninja` and an Xcode with the Metal toolchain.

Output: `runtime/build/dxmt/fork-install/{x86_64-windows/*.dll,x86_64-unix/winemetal.so}`,
tagged `v0.80-basalt.1` in the source checkout. The PE DLLs and winemetal.so are a matched
set — never mix them with stock v0.80 binaries.

## Verifying

`runtime/tests/dxmt_iosurface_probe.cpp` asserts both sides: with `DXMT_BASALT_IOSURFACE=1`
and `BASALT_EXPECT_IOSURFACE=1`, NT-handle textures must republish nonzero, distinct
IOSurfaceIDs; without the gate the GUID must be absent. `test-dxmt.zsh` remains the stock
regression gate.

`test-dxmt.zsh --fork-only` requires built fork artifacts and runs only the fork
gates. This is useful when stock has already been checked or its fixed Darwin
cache location is unsuitable. It explicitly reports that stock was not rerun.

# Third-party notices

TrailBridge VR is built on BasaltVR (https://github.com/frenchbaguetteman/BasaltVR) and, like
BasaltVR, is released under the MIT License. The LICENSE file keeps BasaltVR's copyright notice
next to TrailBridge VR's.

The projects below keep their own licenses and trademarks. The LICENSES folder holds the license
texts of the components named below.

## In this repository and the app

- The source code of TrailBridge VR and BasaltVR: MIT.
- The DXMT patches in `runtime/dxmt-fork/patches`: MIT, like the rest of the project.
- The streamer implements the ALVR v20 protocol to talk to the ALVR client. ALVR
  (https://github.com/alvr-org/ALVR) is MIT-licensed.
- No third-party applications or binaries.

The app that `scripts/trailbridge-app.zsh` builds holds the manager, its icon, LICENSE and this
file. It runs the streamer, the OpenXR runtime, the DXMT fork and Wine from the checkout.

## Downloaded and built by the build scripts

Pinned by SHA-256 or Git commit and kept in the ignored `runtime/build` folder:

- Khronos OpenXR SDK 1.1.61: headers for the OpenXR runtime, and the OpenXR loader for the test
  programs. Apache-2.0; the main headers and the loader are Apache-2.0 OR MIT, and the loader
  includes JsonCpp (public domain or MIT). See `LICENSES/OpenXR-SDK-Apache-2.0.txt` and
  `LICENSES/OpenXR-SDK-COPYING.adoc`. The optional Khronos `hello_xr` test build also downloads
  OpenXR-SDK-Source (Apache-2.0).
- DXMT v0.80 by Feifan He: the base of the Basalt DXMT fork, and the stock release for the
  graphics tests. MIT (`LICENSES/DXMT-MIT.txt`). Its source also contains files from other
  projects under their own licenses, among them Microsoft's DXBCParser (MIT), utility code from
  DXVK (zlib/libpng) and DirectX headers from Wine and MinGW-w64 (LGPL-2.1-or-later).
- LLVM 15.0.7: built from source and linked statically into the DXMT fork. Apache-2.0 with LLVM
  exceptions.
- Wine 11.10 (macOS build by Gcenx): runs the games. LGPL-2.1-or-later, with component-specific
  licenses.
- Wine 8.16 build tree used by DXMT's own CI: needed only to build the DXMT fork.
  LGPL-2.1-or-later, with component-specific licenses.
- DirectXMath: only for the optional Khronos `hello_xr` test build. MIT
  (`LICENSES/DirectXMath-MIT.txt`).

The Windows binaries are built with the MinGW-w64 or LLVM-MinGW toolchain that you install, and
some of its runtime libraries are linked into them statically; see that toolchain's licenses.

## Downloaded by the app on request

Only when you start that step, and only from the official source:

- Wine 11.10 (macOS build by Gcenx) from Gcenx's GitHub releases, pinned by SHA-256 and unpacked
  into the data folder: runs the games. LGPL-2.1-or-later, with component-specific licenses.
- The Steam installer from Valve: installs Steam inside an environment. Valve's terms apply; you
  accept the Steam agreement yourself in the installer.
- OpenComposite from its official site (only the builds that were tested), or a file you choose:
  placed in a game's folder as `openvr_api.dll`. GPL-3.0; never bundled with or linked into
  TrailBridge VR.
- The ALVR client 20.14.1 from ALVR's GitHub releases: installed on the headset. MIT.
- Android SDK Platform-Tools 37.0.1 from Google: `adb` for the USB connection. Google's Android
  SDK terms apply: https://developer.android.com/studio/terms
- The BlackHole 2ch 0.7.1 installer from Existential Audio: an optional audio driver that you
  install yourself. GPL-3.0; not bundled.

## The DMG

`make release` (`packaging/build-dmg.zsh`) builds `TrailBridge-VR-<version>-macos-arm64.dmg`. It
holds `TrailBridge VR.app`, a link to the Applications folder and `Read Me First.txt`. The app is
signed ad hoc: it has no Apple Developer ID signature and is not notarized. LICENSE and this file
are in the app's `Contents/Resources` folder, and the LICENSES folder is in
`Contents/Resources/BasaltVR`.

Inside the app:

- The manager, the streamer and `basaltctl`: TrailBridge VR and BasaltVR code. MIT (`LICENSE`).
  They use only the libraries of macOS.
- `basalt_openxr.dll`, the OpenXR runtime compiled against the Khronos OpenXR headers, and
  `steamwebhelper_compat.exe`: TrailBridge VR and BasaltVR code. MIT. The headers are
  Apache-2.0 OR MIT (`LICENSES/OpenXR-SDK-Apache-2.0.txt`, `LICENSES/OpenXR-SDK-COPYING.adoc`).
- `loader_smoke.exe`: a test program that contains the Khronos OpenXR loader 1.1.61
  (Apache-2.0 OR MIT, the same files) and, inside the loader, JsonCpp (public domain or MIT;
  `LICENSES/JsonCpp-LICENSE.txt`).
- The DXMT fork (`d3d10core.dll`, `d3d11.dll`, `dxgi.dll`, `winemetal.dll` and `winemetal.so`):
  DXMT v0.80 by Feifan He with the patches in `runtime/dxmt-fork/patches`. MIT
  (`LICENSES/DXMT-MIT.txt`). Built into these files:
  - Microsoft's DXBCParser, in `d3d11.dll` and `winemetal.so`. MIT
    (`LICENSES/DXBCParser-MIT.txt`).
  - Utility code from DXVK, in `d3d10core.dll`, `d3d11.dll` and `dxgi.dll`. zlib/libpng
    (`LICENSES/DXVK-zlib.txt`).
  - LLVM 15.0.7, in `winemetal.so`. Apache-2.0 with LLVM exceptions
    (`LICENSES/LLVM-Apache-2.0-with-LLVM-exceptions.txt`). Its regular-expression code by Henry
    Spencer has its own notice (`LICENSES/LLVM-regex-COPYRIGHT.txt`).
  - Wine's `winecrt0` start-up code, linked statically into `winemetal.dll`, from the Wine 8.16
    build tree that DXMT's own CI uses. LGPL-2.1-or-later (`LICENSES/LGPL-2.1.txt`); its source
    is at https://github.com/3Shain/wine, tag `v8.16-3shain`. The rest of `winemetal.dll` is
    DXMT's MIT code. `runtime/scripts/build-dxmt-fork.zsh` builds the file again from DXMT's
    source and the `libwinecrt0.a` of that build tree, so it can be rebuilt with a changed
    `winecrt0`.
  - SHA-1 and SHA-256 code that is in the public domain, and `tl::generator` (CC0).
  - DirectX headers from MinGW-w64 and Wine (LGPL-2.1-or-later, `LICENSES/LGPL-2.1.txt`), used
    as headers only.
- Runtime libraries of the LLVM-MinGW toolchain, linked statically into the Windows files above:
  - the MinGW-w64 runtime (`LICENSES/MinGW-w64-runtime.txt`);
  - LLVM's libc++, libc++abi, libunwind and compiler-rt. Apache-2.0 with LLVM exceptions; parts
    of them are also under the older University of Illinois/NCSA and MIT licenses. Each has its
    own license file: `LICENSES/LLVM-libcxx-LICENSE.txt`, `LICENSES/LLVM-libcxxabi-LICENSE.txt`,
    `LICENSES/LLVM-libunwind-LICENSE.txt` and `LICENSES/LLVM-compiler-rt-LICENSE.txt`. The texts
    are the ones of LLVM 15.0.7; the toolchain's own LLVM is newer and ships only the main
    LLVM license.

Not inside: Wine, Steam, ALVR, OpenComposite, BlackHole, Android platform tools, games and store
credentials. The app downloads Wine from Gcenx's releases when you start that step.

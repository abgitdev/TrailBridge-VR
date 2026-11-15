#!/bin/zsh
set -euo pipefail

readonly repo_dir=${0:A:h:h}
if [[ ${BASALT_REPO_ROOT:-} != "$repo_dir" ]]; then
    exec "$repo_dir/scripts/trailbridge-dev.zsh" "$0" "$@"
fi
# One version for the whole project: the VERSION file and the commit count.
version=$("$repo_dir/scripts/version.zsh")
build_number=$("$repo_dir/scripts/version.zsh" --build)
readonly version build_number
if [[ ${1:-} != --no-build ]]; then
    swift build -c release --arch arm64 --package-path "$repo_dir/streamer"
fi

readonly app_dir="$repo_dir/.local/apps/TrailBridge VR.app"
for directory in "$repo_dir/.local/apps" "$app_dir" "$app_dir/Contents" "$app_dir/Contents/MacOS"; do
    [[ ! -L "$directory" ]] || { print -u2 "Refusing linked app directory: $directory"; exit 1; }
done
mkdir -p "$app_dir/Contents/MacOS"
# Replace the executable atomically: overwriting a previously launched Mach-O
# can retain a stale code-signing cache entry and make macOS kill the new build.
cp "$repo_dir/streamer/.build/release/BasaltVR" "$app_dir/Contents/MacOS/TrailBridgeVR.new.$$"
mv -f "$app_dir/Contents/MacOS/TrailBridgeVR.new.$$" "$app_dir/Contents/MacOS/TrailBridgeVR"
# Unquoted heredoc: ${version} and ${build_number} are its only expansions.
# Keep $, backticks and backslashes out of the rest of it.
cat > "$app_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleName</key><string>TrailBridge VR</string>
<key>CFBundleDisplayName</key><string>TrailBridge VR</string>
<key>CFBundleIdentifier</key><string>local.trailbridge.vr.manager</string>
<key>CFBundleExecutable</key><string>TrailBridgeVR</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${build_number}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>TrailBridge streams game audio to your headset.</string>
<key>NSAudioCaptureUsageDescription</key><string>TrailBridge VR records the sound your Mac plays during a VR session and sends it to your headset.</string>
<key>NSHumanReadableCopyright</key><string>© 2026 abgitdev. Based on BasaltVR. See bundled licenses.</string>
</dict></plist>
PLIST
mkdir -p "$app_dir/Contents/Resources"
cp "$repo_dir/packaging/icon/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$repo_dir/LICENSE" "$repo_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/"
plutil -lint "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
print "Built $app_dir"

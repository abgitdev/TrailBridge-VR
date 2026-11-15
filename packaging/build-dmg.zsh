#!/bin/zsh

# Builds the TrailBridge VR disk image:
#   .local/dist/TrailBridge-VR-<version>-macos-arm64.dmg and its .sha256
#
# The app inside is signed ad hoc only. It is not signed with a Developer ID
# and not notarized, so people allow it once in System Settings > Privacy &
# Security > Open Anyway. Wine is not inside: the app downloads it on request.
#
# Inputs that can be overridden, for example for a build from a Git worktree:
#   BASALT_BUILD_NUMBER            CFBundleVersion; default: the commit count
#   BASALT_DMG_RUNTIME_BUILD_DIR   where the OpenXR runtime is built;
#                                  default: runtime/build-dmg
#   BASALT_OPENXR_SDK_SOURCE_DIR   unpacked Khronos OpenXR SDK sources;
#                                  default: runtime/build/_deps/openxr_sdk-src
#   BASALT_DXMT_BUILD_DIR          the built DXMT fork;
#                                  default: runtime/build/dxmt/fork-install
# A relative path is taken from the folder the command is run in.
#
# Writes only to .local/dist, the runtime build folder, its own Swift build
# folder (.local/cache/swift-dmg) and the build's temporary folder.
# runtime/build and streamer/.build, which the developer app runs from, are
# read at most and never changed.

set -euo pipefail

readonly repo_dir=${0:A:h:h}
# Before the wrapper changes the working directory.
for variable in BASALT_DMG_RUNTIME_BUILD_DIR BASALT_OPENXR_SDK_SOURCE_DIR BASALT_DXMT_BUILD_DIR; do
    [[ -z ${(P)variable:-} ]] || export "$variable=${${(P)variable}:a}"
done
if [[ ${BASALT_REPO_ROOT:-} != "$repo_dir" ]]; then
    exec "$repo_dir/scripts/trailbridge-dev.zsh" "$0" "$@"
fi
if (( $# > 0 )); then
    print -u2 "Usage: ${0:t}   (the version comes from the VERSION file)"
    exit 2
fi

fail() {
    print -u2 "error: $*"
    exit 1
}

# Plain assignments, so a failing version helper stops the script.
version=$("$repo_dir/scripts/version.zsh")
build_number=${BASALT_BUILD_NUMBER:-$("$repo_dir/scripts/version.zsh" --build)}
readonly version build_number
[[ $build_number == <-> ]] || fail "BASALT_BUILD_NUMBER must be a whole number"
grep -Fq "## ${version} " "$repo_dir/CHANGELOG.md" ||
    fail "CHANGELOG.md has no heading for ${version}"

readonly app_name="TrailBridge VR.app"
readonly volume_name="TrailBridge VR"
readonly dmg_name="TrailBridge-VR-${version}-macos-arm64.dmg"
readonly dist_dir="$repo_dir/.local/dist"
readonly app_dir="$dist_dir/$app_name"
readonly contents_dir="$app_dir/Contents"
readonly macos_dir="$contents_dir/MacOS"
readonly resources_dir="$contents_dir/Resources"
readonly support_dir="$resources_dir/BasaltVR"
readonly swift_build_dir="$repo_dir/.local/cache/swift-dmg"
readonly runtime_build_dir=${${BASALT_DMG_RUNTIME_BUILD_DIR:-$repo_dir/runtime/build-dmg}:a}
readonly openxr_source_dir=${${BASALT_OPENXR_SDK_SOURCE_DIR:-$repo_dir/runtime/build/_deps/openxr_sdk-src}:a}
readonly dxmt_dir=${${BASALT_DXMT_BUILD_DIR:-$repo_dir/runtime/build/dxmt/fork-install}:a}

# The path with its links resolved, also for a folder that does not exist yet.
real_path() {
    if [[ -e $1 ]]; then
        print -r -- "${1:A}"
    else
        print -r -- "${1:h:A}/${1:t}"
    fi
}

# The runtime build folder is deleted before each build. It must never be a
# runtime/build folder, which a developer app runs from and which holds the
# DXMT fork and the downloaded sources, nor a folder that holds this build's
# inputs. The Mac's file system does not tell upper case from lower case.
readonly runtime_build_real=$(real_path "$runtime_build_dir")
[[ ${(L)runtime_build_real}/ != */runtime/build/* ]] ||
    fail "BASALT_DMG_RUNTIME_BUILD_DIR must not be in a runtime/build folder"
for input in "$repo_dir/runtime" "$openxr_source_dir" "$dxmt_dir"; do
    [[ ${(L)$(real_path "$input")}/ != ${(L)runtime_build_real}/* ]] ||
        fail "BASALT_DMG_RUNTIME_BUILD_DIR must not hold the build's inputs"
done

for tool in swift cmake codesign hdiutil ditto plutil shasum perl strip file xattr \
    x86_64-w64-mingw32-g++; do
    command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "required tool is unavailable: /usr/libexec/PlistBuddy"

for directory in "$repo_dir/.local" "$repo_dir/.local/cache" "$swift_build_dir" \
    "$dist_dir" "$app_dir"; do
    [[ ! -L $directory ]] || fail "refusing a linked folder: $directory"
done
# A build that stops halfway must not leave an older app or image to be
# published.
readonly dmg_path="$dist_dir/$dmg_name"
rm -rf "$app_dir"
rm -f "$dmg_path" "$dmg_path.sha256"

# The build number counts commits, so it does not tell such a build apart.
if uncommitted=$(git -C "$repo_dir" status --porcelain 2>/dev/null) && [[ -n $uncommitted ]]; then
    print -u2 "warning: the checkout has uncommitted changes in ${#${(f)uncommitted}} path(s);" \
        "the DMG is built from the files as they are now"
fi

# THIRD_PARTY_NOTICES.md lists the runtime libraries of LLVM-MinGW as the ones
# linked into the Windows binaries. GCC's MinGW-w64 links others, under other
# licenses.
[[ $(x86_64-w64-mingw32-g++ --version 2>/dev/null) == *clang* ]] ||
    fail "the DMG is built with LLVM-MinGW; x86_64-w64-mingw32-g++ on PATH is another compiler"

work_dir=$(mktemp -d "${${TMPDIR:-/tmp}%/}/trailbridge-dmg.XXXXXX")
readonly work_dir
trap 'rm -rf "$work_dir"' EXIT
# zsh skips the EXIT trap when a signal ends the script.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

step() {
    print
    print "==> $*"
}

# --- Native executables -------------------------------------------------------

# Built in a folder of its own: the developer app starts the streamer from
# streamer/.build, and a build there would change it under a running setup.
step "Swift release build"
swift_arguments=(
    -c release --arch arm64
    --package-path "$repo_dir/streamer"
    --scratch-path "$swift_build_dir"
)
swift build "${swift_arguments[@]}"
swift_bin_dir=$(swift build "${swift_arguments[@]}" --show-bin-path)
readonly swift_bin_dir
for executable in BasaltVR basalt-streamer basaltctl; do
    [[ -x $swift_bin_dir/$executable ]] ||
        fail "release executable is missing: $swift_bin_dir/$executable"
done

# --- OpenXR runtime -----------------------------------------------------------

# Always built from the current sources into its own folder: a runtime older
# than the streamer speaks another control protocol and leaves the headset
# black, and runtime/build belongs to the developer app.
step "OpenXR runtime (fresh Release build in ${runtime_build_dir})"
# Only a folder that this script made, or a CMake build folder, is replaced.
# The mark is there from the start, also when a build is interrupted early.
readonly runtime_build_mark="$runtime_build_dir/.trailbridge-dmg-build"
if [[ -e $runtime_build_dir || -L $runtime_build_dir ]]; then
    [[ -d $runtime_build_dir && ! -L $runtime_build_dir &&
       ( -f $runtime_build_mark || -f $runtime_build_dir/CMakeCache.txt ) ]] ||
        fail "not a build folder of this script, refusing to replace it: $runtime_build_dir"
    rm -rf "$runtime_build_dir"
fi
mkdir -p "$runtime_build_dir"
: > "$runtime_build_mark"
cmake_arguments=(
    -S "$repo_dir/runtime"
    -B "$runtime_build_dir"
    -DCMAKE_TOOLCHAIN_FILE="$repo_dir/runtime/cmake/toolchains/mingw-x86_64.cmake"
    -DCMAKE_BUILD_TYPE=Release
)
if [[ -f $openxr_source_dir/CMakeLists.txt ]]; then
    # Sources that an earlier runtime build downloaded and checked: no network.
    # That build recorded the archive's SHA-256; it must be the one pinned now,
    # or the DMG would be built with another SDK version without a word.
    pinned_hash=$(awk '
        /^FetchContent_Declare\(/ { getline; inside = ($1 == "openxr_sdk") }
        inside && $1 == "URL_HASH" { print $2; exit }
        /^\)/ { inside = 0 }
    ' "$repo_dir/runtime/CMakeLists.txt")
    [[ $pinned_hash == SHA256=* ]] ||
        fail "runtime/CMakeLists.txt does not pin the OpenXR SDK by SHA-256"
    openxr_stamp="${openxr_source_dir:h}/openxr_sdk-subbuild/openxr_sdk-populate-prefix"
    openxr_stamp+="/src/openxr_sdk-populate-stamp/openxr_sdk-populate-urlinfo.txt"
    [[ -f $openxr_stamp ]] ||
        fail "the local OpenXR SDK sources have no download record next to them;" \
            "build the runtime again (make runtime-build): $openxr_source_dir"
    grep -Fxq "hash=${pinned_hash}" "$openxr_stamp" ||
        fail "the local OpenXR SDK sources are not the version pinned in runtime/CMakeLists.txt;" \
            "build the runtime again (make runtime-build): $openxr_source_dir"
    print "PASS: the local OpenXR SDK sources are the pinned version"
    cmake_arguments+=(
        -DFETCHCONTENT_SOURCE_DIR_OPENXR_SDK="$openxr_source_dir"
        -DFETCHCONTENT_FULLY_DISCONNECTED=ON
    )
elif [[ -n ${BASALT_OPENXR_SDK_SOURCE_DIR:-} ]]; then
    fail "BASALT_OPENXR_SDK_SOURCE_DIR has no OpenXR SDK sources: $openxr_source_dir"
else
    print "No local OpenXR SDK sources; CMake downloads the pinned archive and checks its SHA-256."
fi
cmake "${cmake_arguments[@]}"
cmake --build "$runtime_build_dir" --parallel \
    --target basalt_openxr loader_smoke steamwebhelper_compat
readonly runtime_files=(
    basalt_openxr.dll basalt_openxr.json loader_smoke.exe steamwebhelper_compat.exe
)
for name in "${runtime_files[@]}"; do
    [[ -s $runtime_build_dir/bin/$name ]] ||
        fail "the runtime build did not produce bin/$name"
done

# --- DXMT fork ----------------------------------------------------------------

step "DXMT fork (${dxmt_dir})"
[[ -d $dxmt_dir ]] ||
    fail "the DXMT fork is not built: run runtime/scripts/build-dxmt-fork.zsh"
BASALT_DXMT_BUILD_DIR="$dxmt_dir" "$repo_dir/runtime/scripts/verify-dxmt-artifacts.zsh"
# build-dxmt-fork.zsh records the patch set in the commit it builds from.
readonly dxmt_source_dir="${dxmt_dir:h}/src"
if [[ -d $dxmt_source_dir/.git ]]; then
    patches_sha=$(cat "$repo_dir"/runtime/dxmt-fork/patches/*.patch | shasum -a 256 | awk '{print $1}')
    git -C "$dxmt_source_dir" log -1 --format=%B | grep -Fq "patches-sha ${patches_sha}" ||
        fail "the DXMT fork was built from other patches: run runtime/scripts/build-dxmt-fork.zsh"
    print "PASS: the DXMT fork matches runtime/dxmt-fork/patches"
else
    print "note: no DXMT source tree next to the artifacts; the patch set was not compared"
fi

# --- App bundle ---------------------------------------------------------------

step "App bundle"
# The development wrapper's umask keeps new files private to this account.
# The app must be readable for every account on the Mac that installs it.
umask 022
mkdir -p "$macos_dir" "$resources_dir" \
    "$support_dir/runtime/build/bin" \
    "$support_dir/runtime/build/dxmt/fork-install/x86_64-unix" \
    "$support_dir/runtime/build/dxmt/fork-install/x86_64-windows"

cp "$swift_bin_dir/BasaltVR" "$macos_dir/TrailBridgeVR"
cp "$swift_bin_dir/basalt-streamer" "$swift_bin_dir/basaltctl" "$macos_dir/"
# Drop the debug map: it only lists object files of this checkout.
strip -S "$macos_dir"/*

cp "$repo_dir/packaging/Info.plist" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${version}" \
    -c "Set :CFBundleVersion ${build_number}" \
    "$contents_dir/Info.plist"
plutil -lint "$contents_dir/Info.plist"

cp "$repo_dir/packaging/icon/AppIcon.icns" "$resources_dir/AppIcon.icns"
cp "$repo_dir/LICENSE" "$repo_dir/THIRD_PARTY_NOTICES.md" "$resources_dir/"

for name in "${runtime_files[@]}"; do
    cp "$runtime_build_dir/bin/$name" "$support_dir/runtime/build/bin/$name"
done
cp "$dxmt_dir/x86_64-unix/winemetal.so" \
    "$support_dir/runtime/build/dxmt/fork-install/x86_64-unix/winemetal.so"
for name in d3d10core.dll d3d11.dll dxgi.dll winemetal.dll; do
    cp "$dxmt_dir/x86_64-windows/$name" \
        "$support_dir/runtime/build/dxmt/fork-install/x86_64-windows/$name"
done

# Only what Git tracks or would add: an ignored note or screenshot in these
# folders stays out of the app. A file that is not committed yet is named.
if git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$repo_dir" ls-files -z --cached --others --exclude-standard -- docs LICENSES |
        while IFS= read -r -d '' file; do
            [[ ${file:t} != .* && -f $repo_dir/$file && ! -L $repo_dir/$file ]] || continue
            mkdir -p "$support_dir/${file:h}"
            cp "$repo_dir/$file" "$support_dir/$file"
        done
    git -C "$repo_dir" ls-files -z --others --exclude-standard -- docs LICENSES |
        while IFS= read -r -d '' file; do
            [[ ${file:t} != .* ]] || continue
            print -u2 "warning: not in Git yet, included in the app: $file"
        done
else
    ditto "$repo_dir/docs" "$support_dir/docs"
    ditto "$repo_dir/LICENSES" "$support_dir/LICENSES"
fi
[[ -f $support_dir/docs/BOTTLES.md ]] || fail "docs/BOTTLES.md is missing from the app"
# Every license file that the notices name must be in the app.
named_licenses=$(grep -o 'LICENSES/[A-Za-z0-9._+-]*' "$repo_dir/THIRD_PARTY_NOTICES.md")
for license in ${(u)${(f)named_licenses}}; do
    license=${license%.}
    [[ -s $support_dir/$license ]] ||
        fail "THIRD_PARTY_NOTICES.md names a file that is not in the app: $license"
done
for name in README.md CHANGELOG.md SECURITY.md SUPPORT.md LICENSE THIRD_PARTY_NOTICES.md; do
    cp "$repo_dir/$name" "$support_dir/$name"
done
print -r -- \
    "{\"format\":1,\"version\":\"${version}\",\"architecture\":\"arm64\",\"dxmtIncluded\":true,\"wineIncluded\":false}" \
    > "$support_dir/BasaltVR.support.json"

# Copies keep the modes of their sources, and some of those are private.
find "$app_dir" \( -name .DS_Store -o -name '.git*' \) -delete
find "$app_dir" -type d -exec chmod 755 {} +
find "$app_dir" -type f -perm -u+x -exec chmod 755 {} +
find "$app_dir" -type f ! -perm -u+x -exec chmod 644 {} +
xattr -cr "$app_dir"

# --- Build paths --------------------------------------------------------------

# Compilers leave absolute build paths in the binaries (LLVM's assertions in
# winemetal.so, for one). Each folder that took part in the build is replaced
# by a neutral name of the same length, which keeps every binary offset.
private_prefixes=("$repo_dir")
for directory in "$runtime_build_dir" "$openxr_source_dir" "$dxmt_dir"; do
    [[ $directory != "$repo_dir"/* ]] || continue
    # An input from another checkout: binaries built there name that checkout.
    if [[ $directory == */runtime/build* ]]; then
        directory=${directory%%/runtime/build*}
    fi
    (( ${private_prefixes[(Ie)$directory]} )) || private_prefixes+=("$directory")
done
# Longest first, so a checkout nested in another one is replaced whole.
private_prefixes=(${(f)"$(
    for prefix in "${private_prefixes[@]}"; do
        print -r -- "${#prefix} $prefix"
    done | sort -rn | cut -d' ' -f2-
)"})
public_prefixes=()
for prefix in "${private_prefixes[@]}"; do
    neutral="/TrailBridgeVR/build"
    (( ${#neutral} <= ${#prefix} )) || neutral="/tb"
    (( ${#neutral} <= ${#prefix} )) ||
        fail "a build folder path is too short to be replaced"
    while (( ${#neutral} < ${#prefix} )); do
        neutral+="_"
    done
    public_prefixes+=("$neutral")
done

step "Build paths"
find "$app_dir" -type f -print0 |
    BASALT_PRIVATE_PREFIXES=${(F)private_prefixes} \
    BASALT_PUBLIC_PREFIXES=${(F)public_prefixes} \
    perl -e '
        use strict;
        use warnings;
        my @from = split /\n/, $ENV{BASALT_PRIVATE_PREFIXES};
        my @to = split /\n/, $ENV{BASALT_PUBLIC_PREFIXES};
        local $/ = "\0";
        my $changed = 0;
        while (my $path = <STDIN>) {
            chomp $path;
            open my $in, "<:raw", $path or die "cannot read $path: $!\n";
            my $data = do { local $/; <$in> };
            close $in;
            my $count = 0;
            for my $index (0 .. $#from) {
                $count += ($data =~ s/\Q$from[$index]\E/$to[$index]/g);
            }
            next unless $count;
            open my $out, "+<:raw", $path or die "cannot write $path: $!\n";
            print {$out} $data;
            close $out or die "cannot write $path: $!\n";
            $changed++;
        }
        print "Replaced build paths in $changed file(s)\n";
    '

# --- Privacy gate -------------------------------------------------------------

# Fails the build when a staged file still holds something that identifies
# this Mac or its owner. Every file is read as bytes and compared without
# regard to case, as UTF-8 and as UTF-16 (Windows binaries). Only the file and
# the name of the check are printed, never the value.
gate_names=()
gate_values=()
add_gate_check() {
    local name=$1 value=$2
    [[ -n $value ]] || return 0
    [[ $value != *$'\n'* ]] || fail "cannot check a value that spans lines: $name"
    if (( ${#value} < 3 )); then
        print "note: privacy check skipped, the value is too short to search for: $name"
        return 0
    fi
    gate_names+=("$name")
    gate_values+=("$value")
}
for prefix in "${private_prefixes[@]}"; do
    add_gate_check "build folder path" "$prefix"
done
add_gate_check "home folder path" "${HOME:-}"
add_gate_check "macOS account name" "$(id -un)"
add_gate_check "full user name" "$(id -F 2>/dev/null || true)"
add_gate_check "computer name" "$(scutil --get ComputerName 2>/dev/null || true)"
add_gate_check "local host name" "$(scutil --get LocalHostName 2>/dev/null || true)"
add_gate_check "host name" "$(scutil --get HostName 2>/dev/null || true)"
add_gate_check "global git user.name" "$(git config --global user.name 2>/dev/null || true)"
add_gate_check "global git user.email" "$(git config --global user.email 2>/dev/null || true)"
readonly gate_names gate_values

privacy_gate() {
    local folder=$1
    find "$folder" -type f -print0 |
        BASALT_GATE_NAMES=${(F)gate_names} \
        BASALT_GATE_VALUES=${(F)gate_values} \
        BASALT_GATE_FOLDER="$folder" \
        perl -e '
            use strict;
            use warnings;
            use Encode qw(decode encode);
            my @names = split /\n/, $ENV{BASALT_GATE_NAMES};
            # Lower-case the ASCII letters only; every other character stays.
            my @values = map { (my $text = decode("UTF-8", $_)) =~ tr/A-Z/a-z/; $text }
                split /\n/, $ENV{BASALT_GATE_VALUES};
            # The file is lower-cased byte by byte below, so the same is done
            # to the encoded value: in UTF-16 a byte of a non-Latin letter can
            # fall into the range A-Z.
            my @needles = map {
                my @bytes = (encode("UTF-8", $_), encode("UTF-16LE", $_));
                tr/A-Z/a-z/ for @bytes;
                \@bytes;
            } @values;
            my $folder = $ENV{BASALT_GATE_FOLDER};
            local $/ = "\0";
            my ($files, $failures) = (0, 0);
            while (my $path = <STDIN>) {
                chomp $path;
                open my $in, "<:raw", $path or die "cannot read $path: $!\n";
                my $data = do { local $/; <$in> };
                close $in;
                $data =~ tr/A-Z/a-z/;
                $files++;
                for my $index (0 .. $#names) {
                    next unless grep { index($data, $_) >= 0 } @{ $needles[$index] };
                    (my $shown = $path) =~ s/^\Q$folder\E\/?//;
                    print STDERR "privacy gate: $shown: contains the $names[$index]\n";
                    $failures++;
                }
            }
            exit 1 if $failures;
            print "PASS: privacy gate, $files file(s), " . scalar(@names) . " check(s)\n";
        ' || fail "the privacy gate found personal data in the staged files"
}

step "Privacy gate (app)"
privacy_gate "$app_dir"

# --- Signing ------------------------------------------------------------------

step "Ad-hoc signature"
# Inner code first. The bundle comes last: signing it signs the manager and
# seals everything else.
find "$app_dir" -type f ! -path "$macos_dir/TrailBridgeVR" -print0 |
    while IFS= read -r -d '' candidate; do
        [[ $(file -b "$candidate") == *Mach-O* ]] || continue
        codesign --force --sign - --timestamp=none "$candidate"
    done
codesign --force --sign - --timestamp=none "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

# The bundled command-line tool must find the packaged support files without a
# source checkout, a working directory inside one or the wrapper's environment.
(
    cd /private/tmp
    env -u BASALT_REPO_ROOT -u BASALT_DATA_DIR \
        "$macos_dir/basaltctl" --root "$work_dir/no-data" engines >/dev/null
) || fail "the bundled basaltctl does not find its support files"
print "PASS: the bundled basaltctl finds its support files"

# --- Disk image ---------------------------------------------------------------

step "Disk image"
readonly image_dir="$work_dir/image"
mkdir -p "$image_dir"
ditto "$app_dir" "$image_dir/$app_name"
ln -s /Applications "$image_dir/Applications"
sed "s/@DMG_NAME@/${dmg_name}/g" "$repo_dir/packaging/ReadMeFirst.txt" \
    > "$image_dir/Read Me First.txt"
chmod 644 "$image_dir/Read Me First.txt"
privacy_gate "$image_dir"
# The copy that goes into the image, not the one it was made from.
codesign --verify --deep --strict "$image_dir/$app_name"

hdiutil create -volname "$volume_name" -fs APFS -format UDZO \
    -srcfolder "$image_dir" -ov "$dmg_path"
hdiutil verify "$dmg_path"

(
    cd "$dist_dir"
    shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
    chmod 644 "$dmg_name" "$dmg_name.sha256"
)

print
print "Built    $dmg_path"
print "Checksum $(cat "$dmg_path.sha256")"
print "App      $app_dir (version ${version}, build ${build_number})"
print "Signed ad hoc only: no Developer ID, not notarized. Wine is not included."

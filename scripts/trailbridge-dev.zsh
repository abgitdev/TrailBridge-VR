#!/bin/zsh

set -euo pipefail

if (( $# == 0 )); then
    print -u2 "Usage: ${0:t} command [args...]"
    exit 2
fi

readonly repo_dir=${0:A:h:h}
readonly local_dir="$repo_dir/.local"
for directory in "$local_dir" "$local_dir"/{cache,config,data,state,tmp,tools,downloads,diagnostics} "$local_dir/cache"/{clang,swift}; do
    if [[ -L "$directory" ]]; then
        print -u2 "Refusing a symlink in the TrailBridge workspace: $directory"
        exit 1
    fi
done

umask 077
mkdir -p "$local_dir"/{config,data,state,tmp,tools,downloads,diagnostics} "$local_dir/cache"/{clang,swift}

export BASALT_REPO_ROOT="$repo_dir"
export BASALT_DATA_DIR="$local_dir/data"
export TMPDIR="$local_dir/tmp/"
export XDG_CACHE_HOME="$local_dir/cache"
export XDG_CONFIG_HOME="$local_dir/config"
export XDG_DATA_HOME="$local_dir/data"
export XDG_STATE_HOME="$local_dir/state"
export PYTHONDONTWRITEBYTECODE=1
export PIP_CACHE_DIR="$XDG_CACHE_HOME/pip"
export CLANG_MODULE_CACHE_PATH="$XDG_CACHE_HOME/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$XDG_CACHE_HOME/swift"
export BUILD_DIR="$repo_dir/runtime/build"
unset WINEPREFIX BASALT_WINEPREFIX BASALT_DXMT_WINEPREFIX
unset WINEDLLPATH WINEDLLOVERRIDES XR_RUNTIME_JSON

# Portable, pinned tools; no global package-manager installation is needed.
# Keep absent tool directories out of PATH during the initial bootstrap.
for tool_bin in \
    "$local_dir/tools/cmake-3.31.8-macos-universal/CMake.app/Contents/bin" \
    "$local_dir/tools/llvm-mingw-20261104-ucrt-macos-universal/bin"; do
    if [[ -d "$tool_bin" ]]; then
        path=("$tool_bin" $path)
    fi
done
path=("$repo_dir/scripts/tools" "$local_dir/tools/build-python/bin" "$local_dir/tools/platform-tools" $path)
export PATH

cd "$repo_dir"
exec "$@"

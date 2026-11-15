#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
repo_dir=${runtime_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}
toolchain=${runtime_dir}/cmake/toolchains/mingw-x86_64.cmake
source "${script_dir}/wine-sandbox.zsh"

cmake_bin=${CMAKE:-$(command -v cmake || true)}
objdump_bin=${OBJDUMP:-$(command -v x86_64-w64-mingw32-objdump || true)}
if [[ -n ${WINE:-} ]]; then
    wine_bin=${WINE}
elif wine_sandbox_project_mode; then
    # Under scripts/trailbridge-dev.zsh: a separate extraction, without the DXMT
    # overlay, of the pinned Wine 11.10 archive that test-dxmt.zsh downloads
    # (same SHA-256). This smoke expects the runtime to hide D3D11.
    wine_archive=${build_dir}/dxmt/artifacts/wine-devel-11.10-osx64.tar.xz
    wine_extract_dir=${build_dir}/wine-smoke/wine-11.10
    wine_bin=${wine_extract_dir}/Wine\ Devel.app/Contents/Resources/wine/bin/wine
    if [[ ! -e ${wine_extract_dir} && -f ${wine_archive} ]]; then
        if [[ $(shasum -a 256 "${wine_archive}" | awk '{print $1}') != \
              6d0637c3526fbe7051a5f8968dbde68fbc3ac417717648b9331c46642b52173b ]]; then
            print -u2 "FAIL: ${wine_archive} has the wrong SHA-256"
            exit 1
        fi
        mkdir -p "${wine_extract_dir}.partial.$$"
        tar -xJf "${wine_archive}" -C "${wine_extract_dir}.partial.$$"
        mv "${wine_extract_dir}.partial.$$" "${wine_extract_dir}"
    fi
else
    wine_bin=${HOME}/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64
fi
# Intentionally ignore ambient WINEPREFIX: this script writes the active-runtime HKLM value.
wine_sandbox_default_prefix wine-smoke "${build_dir}/wineprefix"
wine_prefix=${${BASALT_WINEPREFIX:-${REPLY}}:a}
unset XR_RUNTIME_JSON

if [[ -z ${cmake_bin} || -z ${objdump_bin} || ! -x ${wine_bin} ]]; then
    print -u2 "Missing CMake, MinGW objdump, or Wine (${wine_bin}). See runtime/README.md."
    exit 1
fi
wine_sandbox_prepare "${wine_prefix}" BASALT_WINEPREFIX

configure_args=(
    -S "${runtime_dir}"
    -B "${build_dir}"
    -DCMAKE_BUILD_TYPE=Release
)
if [[ ! -f ${build_dir}/CMakeCache.txt ]]; then
    configure_args+=("-DCMAKE_TOOLCHAIN_FILE=${toolchain}")
fi
"${cmake_bin}" "${configure_args[@]}"
"${cmake_bin}" --build "${build_dir}" --parallel

bin_dir=${build_dir}/bin
dll=${bin_dir}/basalt_openxr.dll
manifest=${bin_dir}/basalt_openxr.json

if [[ $(file "${dll}") != *"PE32+ executable (DLL)"*"x86-64"* ]]; then
    print -u2 "FAIL: ${dll} is not a PE32+ x86-64 DLL"
    exit 1
fi

export_names=$("${objdump_bin}" -p "${dll}" | awk '
    /\[Ordinal\/Name Pointer\] Table/ { in_exports = 1; next }
    /The Function Table/ { in_exports = 0 }
    in_exports && /\+base/ { print $NF }
    /^Export Table:/ { llvm_exports = 1; next }
    llvm_exports && /^[^[:space:]]/ { llvm_exports = 0 }
    llvm_exports && /^[[:space:]]*[0-9]+[[:space:]]+0x[0-9a-fA-F]+[[:space:]]+/ { print $NF }
')
if [[ ${export_names} != "xrNegotiateLoaderRuntimeInterface" ]]; then
    print -u2 "FAIL: unexpected DLL exports: ${export_names}"
    exit 1
fi

pushd "${bin_dir}" >/dev/null
WINEPREFIX=${wine_prefix} WINEDEBUG=-all "${wine_bin}" \
    ./negotiation_smoke.exe ./basalt_openxr.dll
wine_sandbox_verify "${wine_prefix}" BASALT_WINEPREFIX

# WhiskyWine reports an elevated token, so the Khronos loader correctly ignores
# XR_RUNTIME_JSON. Register the runtime in an isolated generated prefix instead.
manifest_windows="Z:${manifest//\//\\}"
WINEPREFIX=${wine_prefix} WINEDEBUG=-all "${wine_bin}" reg.exe add \
    'HKLM\Software\Khronos\OpenXR\1' \
    /v ActiveRuntime /t REG_SZ /d "${manifest_windows}" /f
# This build's runtime is registered, so the clock extension must be there.
WINEPREFIX=${wine_prefix} WINEDEBUG=-all BASALT_EXPECT_COUNTER_TIME_EXTENSION=1 \
    "${wine_bin}" ./loader_smoke.exe
trace_windows="Z:${build_dir//\//\\}\\frame-trace-smoke.csv"
WINEPREFIX=${wine_prefix} WINEDEBUG=-all "${wine_bin}" ./frame_trace_smoke.exe "${trace_windows}"
popd >/dev/null

print "PASS: PE inspection, direct ABI smoke, and official-loader Wine smoke"

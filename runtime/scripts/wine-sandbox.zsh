# Sourced by the runtime test scripts after they set `repo_dir`; not a command.
#
# Keeps disposable Wine test prefixes away from the Mac home folder. Wine with
# default settings links a new prefix's Windows user folders (Desktop,
# Documents, Downloads, Music, Pictures, Videos) to the same folders in the
# home directory. Like BottleManager does for managed bottles, the scripts
# give every Wine process per-prefix XDG_* and TMPDIR folders, an XDG
# user-dirs.dirs that names per-prefix host folders, and a disabled
# winemenubuilder, so a freshly created prefix links only to its own folders.
# A prefix that already links elsewhere is refused and never rewritten;
# BASALT_ALLOW_EXTERNAL_USER_FOLDERS=1 uses it anyway.
#
# Host folders: a prefix directory named `prefix` uses its sibling `host`
# (the managed-bottle layout); any other prefix uses `<prefix>-host`.

# True under scripts/trailbridge-dev.zsh, which exports BASALT_REPO_ROOT.
wine_sandbox_project_mode() {
    [[ ${BASALT_REPO_ROOT:-} == "${repo_dir}" ]]
}

# Sets REPLY to the default prefix: .local/wine-tests/<name>/prefix under the
# project wrapper, otherwise the upstream default given as $2.
wine_sandbox_default_prefix() {
    if wine_sandbox_project_mode; then
        REPLY=${repo_dir}/.local/wine-tests/$1/prefix
    else
        REPLY=$2
    fi
}

# Fails when the prefix links a Windows user folder outside the repository
# and outside its own host folders. Usage: wine_sandbox_check <prefix> <override variable>
wine_sandbox_check() {
    local prefix=$1 override=$2
    local repo_root=${repo_dir:A} folders=${wine_sandbox_host:A}/folders
    local link target next directory hop
    local -a links offending
    links=("${prefix}"/drive_c/users/*(N@) "${prefix}"/drive_c/users/*/*(N@))
    # Older Wine nests "My Music" and similar folders inside a real Documents folder.
    for directory in "${prefix}"/drive_c/users/*/*(N/); do
        links+=("${directory}"/*(N@))
    done
    for link in "${links[@]}"; do
        # Follow the link chain by hand: ${link:A} leaves a dangling link unresolved.
        target=${link}
        for hop in {1..16}; do
            [[ -L ${target} ]] || break
            next=$(readlink -- "${target}")
            [[ ${next} == /* ]] || next=${target:h}/${next}
            target=${next}
        done
        target=${target:A}
        if [[ ${target} == "${repo_root}"/* || ${target} == "${folders}" || ${target} == "${folders}"/* ]]; then
            continue
        fi
        offending+=("  ${link} -> ${target}")
    done
    wine_sandbox_links=${#links}
    wine_sandbox_outside=${#offending}
    if (( ${#offending} == 0 )); then
        return 0
    fi
    if [[ ${BASALT_ALLOW_EXTERNAL_USER_FOLDERS:-} == 1 ]]; then
        print -ru2 -- "WARNING: BASALT_ALLOW_EXTERNAL_USER_FOLDERS=1 accepts user-folder links outside the repository:"
        print -rlu2 -- "${offending[@]}"
        return 0
    fi
    print -ru2 -- "FAIL: the Wine prefix links Windows user folders outside the repository:"
    print -rlu2 -- "${offending[@]}"
    print -ru2 -- "Nothing was changed. Point ${override} at a new prefix, remove this disposable"
    print -ru2 -- "prefix yourself, or set BASALT_ALLOW_EXTERNAL_USER_FOLDERS=1 to use it anyway."
    exit 1
}

# Refuses a polluted prefix, then prepares and exports its host folders.
# Usage: wine_sandbox_prepare <prefix> <override variable>
wine_sandbox_prepare() {
    local prefix=${1:a} override=$2
    if [[ ${prefix:t} == prefix ]]; then
        wine_sandbox_host=${prefix:h}/host
    else
        wine_sandbox_host=${prefix}-host
    fi
    local key component name folder candidate
    if wine_sandbox_project_mode && [[ -z ${(P)override:-} ]]; then
        mkdir -p "${prefix}" "${wine_sandbox_host}"
        for candidate in "${prefix}" "${wine_sandbox_host}"; do
            if [[ ${candidate:A} != "${repo_dir:A}"/* ]]; then
                print -ru2 -- "FAIL: the default test prefix resolves outside the repository: ${candidate}"
                exit 1
            fi
        done
    fi
    wine_sandbox_check "${prefix}" "${override}"

    for key component in XDG_CACHE_HOME cache XDG_CONFIG_HOME config \
            XDG_DATA_HOME data XDG_STATE_HOME state TMPDIR tmp; do
        mkdir -p "${wine_sandbox_host}/${component}"
        export "${key}=${wine_sandbox_host}/${component}"
    done
    local -a entries
    for key name in DESKTOP Desktop DOCUMENTS Documents DOWNLOAD Downloads \
            PICTURES Pictures MUSIC Music VIDEOS Videos TEMPLATES Templates; do
        folder=${wine_sandbox_host}/folders/${name}
        mkdir -p "${folder}"
        folder=${folder//\\/\\\\}
        entries+=("XDG_${key}_DIR=\"${folder//\"/\\\"}\"")
    done
    local config=${wine_sandbox_host}/config/user-dirs.dirs
    print -rl -- "${entries[@]}" > "${config}.$$"
    mv -f "${config}.$$" "${config}"
    # No native Start Menu or desktop shortcuts from these prefixes.
    export WINEDLLOVERRIDES=${WINEDLLOVERRIDES:+${WINEDLLOVERRIDES};}winemenubuilder.exe=d
    print -r -- "Wine test prefix: ${prefix}"
}

# Repeats the check once Wine has created the prefix and reports the result.
# Usage: wine_sandbox_verify <prefix> <override variable>
wine_sandbox_verify() {
    wine_sandbox_check "${1:a}" "$2"
    if (( wine_sandbox_outside == 0 )); then
        print -r -- "PASS: ${wine_sandbox_links} Windows user-folder link(s) of the test prefix stay inside the repository or its host folders"
    fi
}

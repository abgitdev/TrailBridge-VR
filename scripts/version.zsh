#!/bin/zsh
# The one place the TrailBridge VR version is read from.
#   version.zsh          prints the version stored in the VERSION file
#   version.zsh --build  prints the build number: the count of commits on HEAD,
#                        or 0 when git or the repository is unavailable
set -euo pipefail

readonly repo_dir=${0:A:h:h}

case ${1:-} in
    '')
        readonly version_file="$repo_dir/VERSION"
        if [[ ! -f $version_file ]]; then
            print -u2 "error: version file is missing: $version_file"
            exit 1
        fi
        version=$(<"$version_file")
        if [[ ! $version =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$' ]]; then
            print -u2 "error: $version_file must hold one version like 0.2.0 or 0.2.0-preview.1"
            exit 1
        fi
        print -r -- "$version"
        ;;
    --build)
        build_number=$(git -C "$repo_dir" rev-list --count HEAD 2>/dev/null) || build_number=0
        [[ $build_number == <-> ]] || build_number=0
        print -r -- "$build_number"
        ;;
    *)
        print -u2 "Usage: ${0:t} [--build]"
        exit 2
        ;;
esac

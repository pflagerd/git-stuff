#!/bin/bash
# Install the packages needed to build and test git-stuff.
#
# Only Ubuntu and its derivatives (Kubuntu, Linux Mint, Pop!_OS, ...) are
# handled. On anything else she gets a warning and the list of Ubuntu
# package names, and nothing is installed.
#
# Safe to run repeatedly: only missing packages are installed.

set -euo pipefail

# ldc: the LDC D compiler; its ldmd2 wrapper takes dmd-style flags (Makefile's DC)
packages=(ldc make git python3)

# os-release(5): /etc/os-release, falling back to /usr/lib/os-release.
# OS_RELEASE_FILE overrides both, for testing this script.
os_release=${OS_RELEASE_FILE:-/etc/os-release}
[[ -r $os_release ]] || os_release=/usr/lib/os-release
if [[ ! -r $os_release ]]; then
    echo "setup.sh: warning: cannot read os-release; cannot tell which distribution this is." >&2
    echo "setup.sh: install these (Ubuntu package names) yourself: ${packages[*]}" >&2
    exit 1
fi

# os-release is defined as shell-compatible variable assignments, so it can be
# sourced. Do it in a subshell so its variables don't leak into this script.
# The path is only known at run time, so ShellCheck can't follow it (SC1090).
# shellcheck source=/dev/null
read -r id id_like < <(. "$os_release"; echo "${ID:-} ${ID_LIKE:-}")

# Ubuntu itself has ID=ubuntu; derivatives list ubuntu in ID_LIKE.
if [[ $id != ubuntu && " $id_like " != *" ubuntu "* ]]; then
    echo "setup.sh: warning: this is not Ubuntu or an Ubuntu derivative (ID=$id, ID_LIKE=$id_like)." >&2
    echo "setup.sh: only apt on Ubuntu derivatives is supported; nothing was installed." >&2
    echo "setup.sh: install the equivalents of these Ubuntu packages yourself: ${packages[*]}" >&2
    exit 1
fi

missing=()
for package in "${packages[@]}"; do
    # Prints "install ok installed" only for a fully installed package.
    status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
    [[ $status == "install ok installed" ]] || missing+=("$package")
done

if (( ${#missing[@]} == 0 )); then
    echo "setup.sh: all required packages are installed: ${packages[*]}"
    exit 0
fi

echo "setup.sh: installing: ${missing[*]}"
sudo=()
(( EUID == 0 )) || sudo=(sudo)
"${sudo[@]}" apt-get install "${missing[@]}"

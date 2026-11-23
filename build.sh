#!/bin/sh
# Builds the N64 game plugins with dub, on Linux, macOS or Windows (Git Bash, MSYS2).
# On Windows, build.ps1 does the same from PowerShell.
#
#   ./build.sh                               # every plugin, release build
#   ./build.sh mp2 mp3                       # just these
#   ./build.sh --debug mp1
#   ./build.sh --install ~/RMG/Plugin/Execution
#
# Run ./build.sh --help for all the options.
set -eu

usage() {
    cat <<EOF
Usage: $0 [options] [plugin...]

Builds the plugins with dub (release builds by default) into bin/:
MarioParty1.dll on Windows, libMarioParty1.so on Linux, libMarioParty1.dylib on
macOS.

Plugins (default: all):
  mp1    Mario Party 1 (MarioParty1)
  mp2    Mario Party 2 (MarioParty2)
  mp3    Mario Party 3 (MarioParty3)
  mg64   Mario Golf 64 (MarioGolf64)

Options:
  -d, --debug           Debug build: keeps array bounds checks and asserts
  -i, --install DIR     Also copy the built plugins into DIR, such as an
                        emulator's execution plugin folder
  -c, --compiler NAME   D compiler for dub to use (dmd, ldc2, gdc)
  -h, --help            Show this help

Requirements: a D compiler with a recent dub (vibe.d's packages need one newer
than some distributions ship, such as Debian 12's dub 1.27; the official ones
from https://dlang.org/download.html work), and on Linux, OpenSSL's development
files (libssl-dev) and a C compiler for linking. pkg-config is optional.
EOF
}

die() {
    echo "$0: $*" >&2
    exit 1
}

# The dub configuration's output name for a plugin
target_name() {
    case "$1" in
        mp1)  echo MarioParty1 ;;
        mp2)  echo MarioParty2 ;;
        mp3)  echo MarioParty3 ;;
        mg64) echo MarioGolf64 ;;
        *)    return 1 ;;
    esac
}

build_type=release
install_dir=
compiler=
plugins=

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--debug)    build_type=debug ;;
        -i|--install)  [ $# -ge 2 ] || die "$1 needs a folder"; install_dir=$2; shift ;;
        --install=*)   install_dir=${1#*=} ;;
        -c|--compiler) [ $# -ge 2 ] || die "$1 needs a compiler"; compiler=$2; shift ;;
        --compiler=*)  compiler=${1#*=} ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "unknown option $1 (see --help)" ;;
        *)             target_name "$1" >/dev/null || die "unknown plugin $1 (see --help)"
                       plugins="$plugins $1" ;;
    esac
    shift
done
[ -n "$plugins" ] || plugins="mp1 mp2 mp3 mg64"

command -v dub >/dev/null 2>&1 || die "dub isn't on the PATH (it comes with the D compilers: https://dlang.org/download.html)"
if [ -n "$install_dir" ] && [ ! -d "$install_dir" ]; then
    die "$install_dir isn't a folder"
fi

cd "$(dirname "$0")"

for plugin in $plugins; do
    name=$(target_name "$plugin")
    echo "Building $name ($build_type)..."
    if [ -n "$compiler" ]; then
        dub build --build="$build_type" --config="$plugin" --compiler="$compiler"
    else
        dub build --build="$build_type" --config="$plugin"
    fi

    # dub names the library for the platform
    file=
    for candidate in "bin/$name.dll" "bin/lib$name.so" "bin/lib$name.dylib"; do
        if [ -f "$candidate" ] && { [ -z "$file" ] || [ "$candidate" -nt "$file" ]; }; then
            file=$candidate
        fi
    done
    [ -n "$file" ] || die "dub didn't make $name's library"
    echo "Built $file"

    if [ -n "$install_dir" ]; then
        cp "$file" "$install_dir/"
        echo "Installed $file into $install_dir"
    fi
done

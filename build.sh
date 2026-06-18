#!/usr/bin/env bash
# build.sh — compile vcpulimit with the right V flags for the host platform.
#
# Usage:
#   ./build.sh                 # build ./vcpulimit
#   ./build.sh -o path/binary  # custom output path
#   ./build.sh -c              # clean build artifacts then build
#
# Requirements:
#   * v (vlang) 0.5.x on PATH  — brew install vlang / scoop install v
#   * bdw-gc headers + lib     — brew install bdw-gc (macOS) / apt install libgc-dev (Linux)
#
# Why each flag:
#   -enable-globals     vcpulimit uses a __global flag toggled by a C signal handler.
#   -prod               release build (drops bounds checks in the 100µs tick loop).
#   LDFLAGS=-L<gc lib>  V's runtime links against libgc; on Homebrew the path is
#                       not on the default linker search list.
set -euo pipefail

# ---- args ----
output="./vcpulimit"
clean=0
while [ $# -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        -c) clean=1; shift ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ---- locate v ----
if ! command -v v >/dev/null 2>&1; then
    echo "error: 'v' (vlang) not found on PATH" >&2
    echo "  install: https://vlang.io#installation" >&2
    exit 1
fi

# ---- detect bdw-gc lib path (macOS Homebrew needs an explicit -L) ----
gc_ldflags=""
case "$(uname -s)" in
    Darwin)
        brew_prefix="$(brew --prefix bdw-gc 2>/dev/null || true)"
        if [ -n "$brew_prefix" ] && [ -d "$brew_prefix/lib" ]; then
            gc_ldflags="-L$brew_prefix/lib"
        fi
        ;;
    Linux)
        # Most distros ship libgc in the default search path; nothing to do.
        ;;
esac

# ---- optional clean ----
if [ "$clean" = 1 ]; then
    rm -f "$output" cpulimit
    find . -name "._*" -delete 2>/dev/null || true
    echo "cleaned"
fi

# ---- build ----
echo "compiling vcpulimit -> $output"
LDFLAGS="$gc_ldflags" v -enable-globals -prod . -o "$output"

# ---- strip + verify ----
if [ -x "$output" ]; then
    size=$(wc -c <"$output" | tr -d ' ')
    echo "built $output ($size bytes)"
    "$output" --help >/dev/null && echo "smoke test: --help ok"
else
    echo "build failed: $output not produced" >&2
    exit 1
fi

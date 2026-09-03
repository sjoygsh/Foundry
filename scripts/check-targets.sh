#!/bin/sh
# Everything a milestone owes, in one command.
#
# ADR-0008: macOS is the primary target and is tested at runtime; Windows and Linux are
# build-checked every milestone, with no obligation to run them there until a backend
# for those platforms exists. "Supported" currently means "compiles" — this script is
# what keeps that claim honest rather than aspirational.

set -eu

cd "$(dirname "$0")/.."

ZIG="${ZIG:-zig}"
command -v "$ZIG" >/dev/null 2>&1 || ZIG="$HOME/.local/bin/zig"

echo "== zig version"
"$ZIG" version
pinned="$(cat .zigversion)"
actual="$("$ZIG" version)"
if [ "$actual" != "$pinned" ]; then
    echo "error: zig $actual does not match the pinned $pinned (see .zigversion, ADR-0001)" >&2
    echo "       run ./scripts/install-zig.sh" >&2
    exit 1
fi

echo
echo "== native: build and run tests (null platform backend)"
"$ZIG" build test

# The SDL3 backend is built and its tests run too. They are headless by design — nothing
# in the suite calls SDL_Init — so this needs no display and is safe anywhere. Without
# it, the backend that actually ships would only be compiled when someone remembered to
# ask for it.
echo
echo "== native: build and run tests (SDL3 platform backend)"
"$ZIG" build test -Dplatform=sdl3

# Both backends are checked against both targets. The null backend proves the engine
# builds without SDL at all; the SDL3 backend proves SDL itself cross-compiles, which is
# a stronger claim than ADR-0008 assumed was available.
for target in x86_64-windows-gnu x86_64-linux-gnu; do
    for backend in null sdl3; do
        echo
        echo "== $target: compile check ($backend backend)"
        "$ZIG" build check -Dtarget="$target" -Dplatform="$backend"
    done
done

echo
echo "all checks passed"

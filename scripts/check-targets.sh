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
echo "== native: build and run tests"
"$ZIG" build test

for target in x86_64-windows-gnu x86_64-linux-gnu; do
    echo
    echo "== $target: compile check"
    "$ZIG" build check -Dtarget="$target"
done

echo
echo "all checks passed"

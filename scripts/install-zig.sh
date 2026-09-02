#!/bin/sh
# Install the Zig release Foundry is pinned to.
#
# Deliberately not a package-manager install (ADR-0001, ADR-0014): an unrelated
# `brew upgrade` must not be able to move the compiler. The tarball is fetched
# from ziglang.org, verified against a hash recorded here, and extracted to a
# versioned path so several releases can coexist and an upgrade is an explicit
# act of re-pointing the symlink.
#
# Upgrading Zig is a deliberate project decision made between milestones, never
# during one. To upgrade: add the new version's hashes below, change PINNED,
# and run this script again.

set -eu

PINNED=0.16.0

# sha256 of the official tarball, per host. From https://ziglang.org/download/index.json
SHA_aarch64_macos=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
SHA_x86_64_macos=0387557ed1877bc6a2e1802c8391953baddba76081876301c522f52977b52ba7
SHA_aarch64_linux=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17
SHA_x86_64_linux=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00

PREFIX="${ZIG_PREFIX:-$HOME/.local/zig}"
BINDIR="${ZIG_BINDIR:-$HOME/.local/bin}"

case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) echo "install-zig: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
    arm64|aarch64) arch=aarch64 ;;
    x86_64|amd64)  arch=x86_64 ;;
    *) echo "install-zig: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

host="${arch}-${os}"
eval "expected=\${SHA_${arch}_${os}:-}"
if [ -z "$expected" ]; then
    echo "install-zig: no recorded hash for $host at $PINNED" >&2
    exit 1
fi

dest="$PREFIX/$PINNED"

if [ -x "$dest/zig" ]; then
    have="$("$dest/zig" version)"
    if [ "$have" = "$PINNED" ]; then
        echo "zig $PINNED already installed at $dest"
    else
        echo "install-zig: $dest/zig reports $have, expected $PINNED" >&2
        exit 1
    fi
else
    url="https://ziglang.org/download/$PINNED/zig-$host-$PINNED.tar.xz"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    echo "fetching $url"
    curl -fsSL --retry 3 "$url" -o "$tmp/zig.tar.xz"

    if command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "$tmp/zig.tar.xz" | cut -d' ' -f1)"
    else
        actual="$(sha256sum "$tmp/zig.tar.xz" | cut -d' ' -f1)"
    fi

    if [ "$actual" != "$expected" ]; then
        echo "install-zig: checksum mismatch for $host $PINNED" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        exit 1
    fi
    echo "checksum ok"

    mkdir -p "$dest"
    tar -xJf "$tmp/zig.tar.xz" -C "$dest" --strip-components=1
    echo "installed to $dest"
fi

mkdir -p "$BINDIR"
ln -sfn "$dest/zig" "$BINDIR/zig"
echo "linked $BINDIR/zig -> $dest/zig"

# Record what the project is pinned to, for humans and for CI.
printf '%s\n' "$PINNED" > "$(dirname "$0")/../.zigversion"

"$BINDIR/zig" version

case ":$PATH:" in
    *":$BINDIR:"*) ;;
    *) echo ""
       echo "note: $BINDIR is not on your PATH. Add it, e.g.:"
       echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" ;;
esac

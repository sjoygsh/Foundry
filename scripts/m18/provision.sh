#!/bin/bash
# Prepares a fresh Ubuntu 24.04 x86_64 GPU machine for M18 (the Linux desktop proof).
#
# Run it over SSH as the default user, which has passwordless sudo. It is idempotent: run it,
# reboot when it says so, and run it again; the second run finishes and checks everything.
#
# Everything is fetched from its official source and verified against a hash recorded in
# AGENTS.md or here, and installed at a versioned path, never through a package manager where
# the project pins a version (ADR-0014): Zig, the Vulkan SDK, RenderDoc. The system packages
# are the distribution's own: the GPU driver, the two window systems and their tools.

set -euo pipefail

TAG="${FOUNDRY_TAG:-main}"
REPO="https://github.com/sjoygsh/Foundry.git"
NVIDIA="${NVIDIA_DRIVER:-570}"

SDK_VERSION=1.4.357.0
SDK_ARCHIVE="vulkansdk-linux-x86_64-$SDK_VERSION.tar.xz"
SDK_SHA=0f09bf6a0625e346bf004be70b92907e934a4c76606b323441b2baf3a5a0e66d
RENDERDOC_VERSION=1.46
RENDERDOC_ARCHIVE="renderdoc_$RENDERDOC_VERSION.tar.gz"
RENDERDOC_SHA=6fedf15eab1288d9a81889ba8a4452dca53f5c10de8162be32a0f8972f62dc09

say() { printf '\n== %s\n' "$*"; }

fetch() { # url sha256 destination
    if [ -f "$3" ] && echo "$2  $3" | sha256sum -c --status; then return; fi
    curl -fsSL --retry 3 -o "$3.part" "$1"
    echo "$2  $3.part" | sha256sum -c --quiet
    mv "$3.part" "$3"
}

mkdir -p "$HOME/downloads" "$HOME/tools" "$HOME/m18"

# -- 1. The distribution's packages -------------------------------------------------------
say "system packages"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -q
sudo apt-get install -yq --no-install-recommends \
    git curl ca-certificates xz-utils ubuntu-drivers-common \
    xserver-xorg-core xserver-xorg-input-libinput x11-xserver-utils x11-utils xdotool \
    openbox tint2 imagemagick \
    sway grim wtype weston \
    libx11-6 libxext6 libxcursor1 libxi6 libxfixes3 libxrandr2 libxss1 libxtst6 \
    libxkbcommon0 libxkbcommon-x11-0 libwayland-client0 libwayland-cursor0 libwayland-egl1 \
    libdecor-0-0 libegl1 libgl1 libvulkan1 \
    python3 time procps

# -- 2. The GPU driver: Ubuntu's signed prebuilt modules, and the desktop userspace ---------
# `ubuntu-drivers install nvidia:<n>` picks the signed module package for this kernel. The
# desktop (not `-server`, not `-headless`) userspace is the one with the Vulkan ICD and GBM.
say "NVIDIA driver $NVIDIA"
if ! dpkg -s "nvidia-driver-$NVIDIA" >/dev/null 2>&1; then
    sudo ubuntu-drivers install "nvidia:$NVIDIA"
fi
# A Wayland compositor on NVIDIA needs kernel modesetting (GBM, DRM render nodes).
echo "options nvidia-drm modeset=1 fbdev=1" | sudo tee /etc/modprobe.d/foundry-m18-nvidia.conf >/dev/null
if ! nvidia-smi >/dev/null 2>&1; then
    say "REBOOT NEEDED: run 'sudo reboot', then run this script again"
    exit 0
fi

# -- 3. Zig, from the repository's own installer --------------------------------------------
say "Foundry at $TAG"
if [ ! -d "$HOME/Foundry/.git" ]; then git clone -q "$REPO" "$HOME/Foundry"; fi
git -C "$HOME/Foundry" fetch -q --tags origin
git -C "$HOME/Foundry" checkout -q "$TAG"
git -C "$HOME/Foundry" log --oneline -1
(cd "$HOME/Foundry" && ./scripts/install-zig.sh)
export PATH="$HOME/.local/bin:$PATH"

# -- 4. The Vulkan SDK, core component, at a versioned root ---------------------------------
say "Vulkan SDK $SDK_VERSION"
fetch "https://sdk.lunarg.com/sdk/download/$SDK_VERSION/linux/$SDK_ARCHIVE" "$SDK_SHA" "$HOME/downloads/$SDK_ARCHIVE"
if [ ! -d "$HOME/VulkanSDK/$SDK_VERSION/x86_64/bin" ]; then
    mkdir -p "$HOME/VulkanSDK"
    tar -xJf "$HOME/downloads/$SDK_ARCHIVE" -C "$HOME/VulkanSDK"
fi

# -- 5. RenderDoc, portable, its layer never registered -------------------------------------
say "RenderDoc $RENDERDOC_VERSION"
fetch "https://renderdoc.org/stable/$RENDERDOC_VERSION/$RENDERDOC_ARCHIVE" "$RENDERDOC_SHA" "$HOME/downloads/$RENDERDOC_ARCHIVE"
if [ ! -d "$HOME/tools/renderdoc_$RENDERDOC_VERSION" ]; then
    tar -xzf "$HOME/downloads/$RENDERDOC_ARCHIVE" -C "$HOME/tools"
fi

# -- 6. The environment every later step uses -----------------------------------------------
cat > "$HOME/m18/env.sh" <<EOF
# Sourced by every M18 step. Nothing here is Foundry's; it is where this machine keeps tools.
export PATH="\$HOME/.local/bin:\$HOME/VulkanSDK/$SDK_VERSION/x86_64/bin:\$PATH"
export VULKAN_SDK="\$HOME/VulkanSDK/$SDK_VERSION/x86_64"
# The SDK's layers by path, never registered; the loader is the system's (libvulkan1), as a
# player's would be (\`vulkan.md\` §4).
export VK_ADD_LAYER_PATH="\$VULKAN_SDK/share/vulkan/explicit_layer.d"
export VK_LOADER_LAYERS_DISABLE='~implicit~'
export RENDERDOC="\$HOME/tools/renderdoc_$RENDERDOC_VERSION"
export XDG_RUNTIME_DIR="/run/user/\$(id -u)"
EOF

# -- 7. Dependencies fetched now, so the timed work never waits on the network --------------
say "Zig dependencies"
(cd "$HOME/Foundry" && zig build --fetch=all)

say "ready"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
# shellcheck disable=SC1091
. "$HOME/m18/env.sh"
vulkaninfo --summary 2>/dev/null | sed -n '/Devices:/,$p' | head -20

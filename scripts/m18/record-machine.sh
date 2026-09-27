#!/bin/bash
# Records what M18's evidence ran on, for its Resolution (`vulkan.md` §2.2): distribution,
# kernel, CPU, GPU and driver, the Vulkan loader and device, the window systems and the tools.
# It prints no address, host name or user name.

set -uo pipefail
# shellcheck disable=SC1091
. "$HOME/m18/env.sh"

row() { printf '%-20s %s\n' "$1" "$2"; }
row distribution "$(. /etc/os-release; echo "$PRETTY_NAME")"
row kernel "$(uname -r)"
row cpu "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs) x$(nproc)"
row memory "$(free -g | awk '/Mem:/ {print $2 " GiB"}')"
if command -v nvidia-smi >/dev/null; then
    row gpu "$(nvidia-smi --query-gpu=name,driver_version,vbios_version --format=csv,noheader)"
else
    row gpu "$(lspci | grep -E 'VGA compatible controller|3D controller' | cut -d: -f3- | xargs)"
    row mesa "$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers)"
fi
row vulkan-loader "$(dpkg-query -W -f='${Version}' libvulkan1)"
row vulkan-device "$(vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|apiVersion|driverVersion' | head -3 | awk -F= '{print $2}' | xargs)"
row xorg "$(dpkg-query -W -f='${Version}' xserver-xorg-core)"
row desktop "$(gnome-shell --version 2>/dev/null || echo none) (Xwayland $(dpkg-query -W -f='${Version}' xwayland 2>/dev/null))"
row openbox "$(dpkg-query -W -f='${Version}' openbox)"
row sway "$(dpkg-query -W -f='${Version}' sway) (wlroots $(dpkg-query -W -f='${Version}' 'libwlroots*' 2>/dev/null | head -1))"
row weston "$(dpkg-query -W -f='${Version}' weston)"
row wayland "$(dpkg-query -W -f='${Version}' libwayland-client0)"
row zig "$(zig version)"
row vulkan-sdk "$(basename "$(dirname "$VULKAN_SDK")") ($(glslangValidator --version | head -1))"
row renderdoc "$("$RENDERDOC/bin/renderdoccmd" version 2>/dev/null | head -1)"
row foundry "$(git -C "$HOME/Foundry" describe --tags --always)"

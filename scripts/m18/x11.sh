#!/bin/bash
# Starts or stops an X11 desktop on display :0, on the GPU, for M18 runs over SSH.
#
#   x11.sh start | stop | shot <file.png>
#
# A cloud GPU has no monitor, so the NVIDIA X driver drives a virtual 1920x1080 screen with no
# display device. Openbox manages the windows (minimise, restore, resize) and tint2's taskbar
# shows each window's icon, which is what "the icon, visibly on X11" is checked against.
# Afterwards a step runs with `DISPLAY=:0` and no `WAYLAND_DISPLAY`, so SDL chooses X11 itself.

set -euo pipefail
cmd="${1:-}"
log="$HOME/m18/x11"
mkdir -p "$log"

bus_id() { # nvidia-smi's 00000000:00:1E.0 is Xorg's PCI:0:30:0, in decimal
    local id
    id="$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader | head -1)"
    IFS=':.' read -r _ bus dev fn <<<"$id"
    printf 'PCI:%d:%d:%d' "0x$bus" "0x$dev" "0x$fn"
}

case "$cmd" in
start)
    cat > "$log/xorg.conf" <<EOF
Section "ServerLayout"
    Identifier "m18"
    Screen 0 "screen"
EndSection
Section "Device"
    Identifier "gpu"
    Driver "nvidia"
    BusID "$(bus_id)"
    Option "AllowEmptyInitialConfiguration" "True"
    Option "UseDisplayDevice" "None"
EndSection
Section "Screen"
    Identifier "screen"
    Device "gpu"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Virtual 1920 1080
    EndSubSection
EndSection
EOF
    sudo cp "$log/xorg.conf" /etc/X11/foundry-m18.conf
    # Root, on a console of its own: there is no seat or display manager over SSH.
    sudo nohup Xorg :0 vt7 -config foundry-m18.conf -noreset -nolisten tcp \
        -logfile "$log/Xorg.0.log" >/dev/null 2>&1 &
    for _ in $(seq 50); do sudo env DISPLAY=:0 xset q >/dev/null 2>&1 && break; sleep 0.2; done
    # The server is root's; this user may draw on it.
    sudo env DISPLAY=:0 xhost "+si:localuser:$(id -un)" >/dev/null
    DISPLAY=:0 xset q >/dev/null
    DISPLAY=:0 xset s off -dpms
    DISPLAY=:0 nohup openbox >"$log/openbox.log" 2>&1 &
    DISPLAY=:0 nohup tint2 >"$log/tint2.log" 2>&1 &
    sleep 1
    DISPLAY=:0 xdpyinfo | grep -E "dimensions|depth of root"
    grep -E "NVIDIA\(0\): (Virtual screen|.*GPU)" "$log/Xorg.0.log" | head -3 || true
    ;;
stop)
    pkill -x tint2 || true
    pkill -x openbox || true
    sudo pkill -x Xorg || true
    ;;
shot)
    DISPLAY=:0 import -window root "${2:?shot needs a file name}"
    ;;
*)
    echo "usage: x11.sh start | stop | shot <file.png>" >&2
    exit 2
    ;;
esac

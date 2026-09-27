#!/bin/bash
# Starts or stops an X11 desktop on the GPU, for M18 runs over SSH.
#
#   x11.sh start | stop | display | shot <file.png>
#
# A cloud NVIDIA GPU has no monitor, so its X driver drives a virtual 1920x1080 screen with no
# display device. Any other GPU is taken to have a monitor: Xorg's modesetting driver drives it
# on a console of its own, and `stop` gives the console back to the desktop that had it.
# Openbox manages the windows (minimise, restore, resize) and tint2's taskbar shows each
# window's icon, which is what "the icon, visibly on X11" is checked against. The display is
# the first free one (a desktop's Xwayland may hold :0), and `x11.sh display` prints it; a step
# runs with that `DISPLAY` and no `WAYLAND_DISPLAY`, so SDL chooses X11 itself.

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

nvidia() { command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; }
display() { cat "$log/display"; }

case "$cmd" in
start)
    n=0; while [ -e "/tmp/.X11-unix/X$n" ]; do n=$((n + 1)); done
    echo ":$n" > "$log/display"; D=":$n"
    sudo fgconsole > "$log/previous-vt" 2>/dev/null || echo 1 > "$log/previous-vt"
    config=()
    if nvidia; then
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
    config=(-config foundry-m18.conf)
    fi
    # Root, on a console of its own: there is no seat or display manager over SSH.
    sudo nohup Xorg "$D" vt7 "${config[@]}" -noreset -nolisten tcp \
        -logfile "$log/Xorg.log" >/dev/null 2>&1 &
    for _ in $(seq 50); do sudo env DISPLAY="$D" xset q >/dev/null 2>&1 && break; sleep 0.2; done
    # The server is root's; this user may draw on it.
    sudo env DISPLAY="$D" xhost "+si:localuser:$(id -un)" >/dev/null
    DISPLAY="$D" xset q >/dev/null
    DISPLAY="$D" xset s off -dpms
    DISPLAY="$D" setsid nohup openbox >"$log/openbox.log" 2>&1 </dev/null &
    DISPLAY="$D" setsid nohup tint2 >"$log/tint2.log" 2>&1 </dev/null &
    sleep 1
    echo "DISPLAY=$D"
    DISPLAY="$D" xdpyinfo | grep -E "dimensions|depth of root"
    grep -E "(NVIDIA|modeset)\(0\): (Virtual screen|.*GPU|glamor|Output .* connected)" "$log/Xorg.log" | head -4 || true
    ;;
stop)
    pkill -x tint2 || true
    pkill -x openbox || true
    sudo pkill -x Xorg || true
    [ -f "$log/previous-vt" ] && sudo chvt "$(cat "$log/previous-vt")" || true
    ;;
display)
    display
    ;;
shot)
    DISPLAY="$(display)" import -window root "${2:?shot needs a file name}"
    ;;
*)
    echo "usage: x11.sh start | stop | display | shot <file.png>" >&2
    exit 2
    ;;
esac

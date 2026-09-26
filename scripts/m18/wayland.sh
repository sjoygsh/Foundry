#!/bin/bash
# Starts or stops a Wayland compositor on the GPU, for M18 runs over SSH.
#
#   wayland.sh start [sway|weston] | stop | env | shot <file.png>
#
# Sway (wlroots) by default: its headless backend renders with GLES on the GPU's render node,
# `swaymsg` resizes and hides windows, and `grim` captures the output. Weston is the fallback
# if sway will not start on this driver. There is no XWayland, so a run here cannot fall back to
# X11: SDL must choose Wayland itself.
#
# `eval "$(wayland.sh env)"` gives a shell WAYLAND_DISPLAY and SWAYSOCK, and unsets DISPLAY.

set -euo pipefail
cmd="${1:-}"
log="$HOME/m18/wayland"
mkdir -p "$log"
runtime="/run/user/$(id -u)"

render_node() {
    for node in /dev/dri/renderD*; do
        [ "$(basename "$(readlink -f "/sys/class/drm/$(basename "$node")/device/driver")")" = nvidia ] && { echo "$node"; return; }
    done
    ls /dev/dri/renderD* | head -1
}

case "$cmd" in
start)
    which="${2:-sway}"
    rm -f "$runtime"/wayland-m18 "$runtime"/wayland-m18.lock
    if [ "$which" = sway ]; then
        cat > "$log/sway.conf" <<'EOF'
xwayland disable
output HEADLESS-1 resolution 1920x1080@60Hz position 0 0
default_border normal
focus_follows_mouse no
EOF
        env -u DISPLAY -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$runtime" \
            WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=gles2 \
            WLR_RENDER_DRM_DEVICE="$(render_node)" \
            nohup sway --unsupported-gpu -c "$log/sway.conf" >"$log/sway.log" 2>&1 &
    else
        env -u DISPLAY XDG_RUNTIME_DIR="$runtime" \
            nohup weston --backend=headless --renderer=gl --width=1920 --height=1080 \
            --socket=wayland-m18 >"$log/weston.log" 2>&1 &
    fi
    for _ in $(seq 50); do ls "$runtime"/wayland-* >/dev/null 2>&1 && break; sleep 0.2; done
    ls "$runtime"/wayland-* | grep -v lock
    tail -5 "$log/$which.log"
    ;;
stop)
    pkill -x sway || true
    pkill -x weston || true
    ;;
env)
    socket="$(ls "$runtime" | grep -E '^wayland-[^.]+$' | head -1)"
    echo "unset DISPLAY; export XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=$socket"
    sway_ipc="$(ls "$runtime"/sway-ipc.*.sock 2>/dev/null | head -1 || true)"
    [ -n "$sway_ipc" ] && echo "export SWAYSOCK=$sway_ipc"
    ;;
shot)
    eval "$("$0" env)"
    grim "${2:?shot needs a file name}"
    ;;
*)
    echo "usage: wayland.sh start [sway|weston] | stop | env | shot <file.png>" >&2
    exit 2
    ;;
esac

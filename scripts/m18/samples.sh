#!/bin/bash
# M18's sample runs (RUNBOOK §5): both samples from a relocated install, one window system at a
# time, with validation through the loader.
#
#   samples.sh prepare                        copy ~/m18/prefix to "~/m18/moved install"
#   samples.sh <session> <run>                reload | resize | room | user | nolayers
#   samples.sh <session> start <app> [VAR=value...]      start one by hand, for the input run
#   samples.sh <session> key <key...> | type <text> | click <x> <y> | shot <file> | stop <name>
#
# Sessions:
#   x11    the display `x11.sh` started, on the monitor, driven by xdotool;
#   gnome  the logged-in desktop's own Wayland compositor, on the monitor. It lets no client
#          drive another (and gives no focus to a window started from SSH), so only the runs that
#          need no driving use it: reload, room, user, nolayers, and resize without minimising.
#          It must be on screen: a compositor that is not sends no frame callbacks, and a
#          Wayland swapchain then waits for ever;
#   sway   `wayland.sh start sway`, driven through its own IPC (`swaymsg`) and its virtual
#          keyboard (`wtype`). Sway has no minimise: the scratchpad hides a window and shows it
#          again, and that is what the resize run records.
#
# Each run starts from the moved copy with only system directories on PATH and HOME at a
# scratch root per session. Its log and its validation log go to ~/m18/runs.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# Where this machine keeps the SDK: the validation layer is passed to a run by path.
# shellcheck disable=SC1091
. "$HOME/m18/env.sh"
install="$HOME/m18/moved install"
runs="$HOME/m18/runs"
runtime="/run/user/$(id -u)"
mkdir -p "$runs"

if [ "${1:-}" = prepare ]; then
    rm -rf "$install" && cp -r "$HOME/m18/prefix" "$install"
    rm -rf "$HOME"/m18/home-*
    ls "$install/bin" "$install/content"
    exit 0
fi

S="${1:?x11, gnome or sway}"; shift
cmd="${1:?a run or an action}"; shift
case "$S" in
# Each session also gets the XDG_SESSION_TYPE its login would have: SDL tries Wayland's default
# socket unless it names another kind, and this machine's desktop holds one.
x11)   display="$(DISPLAY= "$here/x11.sh" display)"; session=(DISPLAY="$display" XDG_SESSION_TYPE=x11) ;;
gnome) session=(WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland) ;;
sway)
    eval "$("$here/wayland.sh" env)"
    [ -n "${SWAYSOCK:-}" ] || { echo "sway is not running: wayland.sh start sway" >&2; exit 2; }
    session=(WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_SESSION_TYPE=wayland)
    ;;
*) echo "x11, gnome or sway, not '$S'" >&2; exit 2 ;;
esac
home="$HOME/m18/home-$S"
mkdir -p "$home"

# One process from the moved copy: the environment a player's would have, and validation.
launch() { # name layers(validate|none) app [VAR=value...]
    local name="$1" layers="$2" app="$3"; shift 3
    local vk
    if [ "$layers" = validate ]; then
        vk=(VK_LOADER_LAYERS_DISABLE='~implicit~' VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
            VK_KHRONOS_VALIDATION_DEBUG_ACTION=VK_DBG_LAYER_ACTION_LOG_MSG
            VK_KHRONOS_VALIDATION_REPORT_FLAGS=error,warn,info
            VK_KHRONOS_VALIDATION_VALIDATE_SYNC=true
            VK_KHRONOS_VALIDATION_LOG_FILENAME="$runs/$S-$name-validation.log")
        [ -n "${VK_ADD_LAYER_PATH:-}" ] && vk+=(VK_ADD_LAYER_PATH="$VK_ADD_LAYER_PATH")
    else
        vk=(VK_LOADER_LAYERS_DISABLE='~all~')
    fi
    rm -f "$runs/$S-$name-validation.log" "$runs/$S-$name.exit"
    env -i HOME="$home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime" "${session[@]}" \
        "${vk[@]}" "$@" "$install/bin/$app" > "$runs/$S-$name.log" 2>&1 &
    echo $! > "$runs/$S.pid"
}

title_of() { case "$1" in sandbox) echo "Foundry Sandbox" ;; room) echo "The Long Hall" ;; esac; }

window() { # x11: the sample's window, by its process and exact title; visible or minimised
    DISPLAY="$display" xdotool search --sync --pid "$(cat "$runs/$S.pid")" --name "^$(title_of "$1")\$" | head -1
}

minimise() { # app
    case "$S" in
    x11)  DISPLAY="$display" xdotool windowminimize "$(window "$1")" ;;
    sway) swaymsg "[title=\"^$(title_of "$1")\$\"] move scratchpad" >/dev/null ;;
    *)    echo "no minimise from outside on $S" >&2; return 1 ;;
    esac
}

restore() { # app
    case "$S" in
    x11)  DISPLAY="$display" xdotool windowactivate --sync "$(window "$1")" ;;
    sway) swaymsg "[title=\"^$(title_of "$1")\$\"] scratchpad show" >/dev/null ;;
    esac
}

close() { # app: the window system's own close request, never a signal
    case "$S" in
    x11)  DISPLAY="$display" xdotool windowactivate --sync "$(window "$1")" key --clearmodifiers alt+F4 ;;
    sway) swaymsg "[title=\"^$(title_of "$1")\$\"] kill" >/dev/null ;;
    gnome) kill -TERM "$(cat "$runs/$S.pid")" ;;
    esac
}

key() { # xdotool's key names; sway gets them through wtype
    case "$S" in
    x11)  DISPLAY="$display" xdotool key --clearmodifiers "$1" ;;
    sway) wtype -k "$1" ;;
    *)    echo "no input from outside on $S" >&2; return 1 ;;
    esac
}

shot() {
    case "$S" in
    x11)  "$here/x11.sh" shot "$1" ;;
    sway) grim "$1" ;;
    *)    return 1 ;;
    esac
}

wait_exit() { # pid seconds
    for _ in $(seq $(($2 * 5))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done
    return 1
}

run_and_wait() { # name seconds
    local pid; pid="$(cat "$runs/$S.pid")"
    # Only the shell that launched a sample can collect its status; a later `stop` says "ended".
    if wait_exit "$pid" "$2"; then
        wait "$pid" 2>/dev/null; local status=$?
        if [ "$status" = 127 ]; then echo ended > "$runs/$S-$1.exit"; else echo "$status" > "$runs/$S-$1.exit"; fi
    else echo timeout > "$runs/$S-$1.exit"; kill "$pid"; fi
}

summary() { # name
    local log="$runs/$S-$1.log" vlog="$runs/$S-$1-validation.log"
    echo "-- $S $1: exit $(cat "$runs/$S-$1.exit" 2>/dev/null)"
    grep -E "video driver|rhi backend|window icon|window [0-9]+x[0-9]+|skipped|resized|picked|card:|lamps|lit|p95|median|error\(|warning\(" "$log" |
        grep -v "^debug" | sed -E 's/[0-9]+x[0-9]+ points.*/<size>/' | sort | uniq -c | sort -rn | head -30
    echo "   reloads: $(grep -c "reloaded 'sandbox:textures.sprites'" "$log")"
    if [ "$1" != nolayers ] && [ ! -f "$vlog" ]; then echo "   validation: NO LOG, the layer did not load"; fi
    if [ -f "$vlog" ]; then
        # The layer's own notices are "Validation Information"; only these two are findings.
        echo "   validation: $(grep -c '^Validation Error' "$vlog") error(s), $(grep -c '^Validation Warning' "$vlog") warning(s), $(grep -c '^Validation Information' "$vlog") notice(s)"
    fi
}

case "$cmd" in
reload)
    launch reload validate sandbox FOUNDRY_SANDBOX_FRAMES=900 FOUNDRY_SANDBOX_WALK=60 FOUNDRY_SANDBOX_PICK_EVERY=90
    pid="$(cat "$runs/$S.pid")"
    sheet="$install/content/sandbox/textures/sprites.png"
    (while kill -0 "$pid" 2>/dev/null; do touch "$sheet"; sleep 0.2; done) &
    run_and_wait reload 120
    summary reload
    ;;
resize)
    # A minimised window's frames are skipped unpaced, so the run is bounded by a close.
    launch resize validate sandbox FOUNDRY_SANDBOX_RESIZE_EVERY=120
    sleep 5
    if [ "$S" != gnome ]; then
        for round in 1 2; do
            minimise sandbox; sleep 2
            shot "$runs/$S-resize-hidden-$round.png"
            restore sandbox; sleep 4
        done
    else
        sleep 12
    fi
    shot "$runs/$S-resize.png"
    close sandbox
    run_and_wait resize 30
    summary resize
    ;;
room)
    launch room validate room FOUNDRY_ROOM_AUTOPILOT=1 FOUNDRY_ROOM_OVERLAY=1 FOUNDRY_ROOM_FRAMES=600
    sleep 6; shot "$runs/$S-room.png"
    run_and_wait room 120
    summary room
    ;;
user)
    # A home of its own: the preferences earlier runs saved would outrank the package's size.
    home="$HOME/m18/home-$S-user"; rm -rf "$home"
    mods="$home/.local/share/foundry-sandbox/mods"
    mkdir -p "$mods"
    # A package's files sit beside its compiled file, as an installed package's do.
    cp -r "$HOME/m18/usercfg" "$mods/usercfg"
    env -i HOME="$home" PATH=/usr/bin:/bin "$install/bin/fpack" --out "$mods/usercfg.fpk" \
        --dependency "$install/content/core.fpk" --dependency "$install/content/sandbox.fpk" \
        "$HOME/m18/usercfg" || exit 1
    launch user validate sandbox FOUNDRY_SANDBOX_FRAMES=300 FOUNDRY_SANDBOX_PACKAGES=usercfg:changes
    sleep 3
    if [ "$S" = x11 ]; then
        DISPLAY="$display" xprop -id "$(window sandbox)" _NET_WM_ICON > "$runs/$S-user-icon.txt"
    fi
    shot "$runs/$S-user.png"
    run_and_wait user 60
    summary user
    [ -f "$runs/$S-user-icon.txt" ] && head -c 160 "$runs/$S-user-icon.txt" && echo
    ;;
nolayers)
    launch nolayers none sandbox FOUNDRY_SANDBOX_FRAMES=600
    run_and_wait nolayers 60
    summary nolayers
    ;;
start)
    app="${1:?sandbox or room}"; shift
    launch "input-$app" validate "$app" "$@"
    sleep 3
    if [ "$S" = x11 ]; then DISPLAY="$display" xwininfo -id "$(window "$app")" | grep -E "Absolute|Width|Height"; fi
    if [ "$S" = sway ]; then swaymsg -t get_tree | grep -E '"name"|"rect"' -A4 | grep -E 'name|"x"|"y"|width|height' | head -20; fi
    ;;
key)   for k in "$@"; do key "$k"; sleep 0.15; done ;;
type)
    case "$S" in
    x11)  DISPLAY="$display" xdotool type --delay 80 "$1" ;;
    sway) wtype -d 80 "$1" ;;
    esac
    ;;
click) # output coordinates
    case "$S" in
    x11)  DISPLAY="$display" xdotool mousemove "$1" "$2" sleep 0.2 click 1 ;;
    sway) swaymsg "seat - cursor set $1 $2" >/dev/null; sleep 0.2
          swaymsg "seat - cursor press button1" >/dev/null; sleep 0.05
          swaymsg "seat - cursor release button1" >/dev/null ;;
    esac
    ;;
shot)  shot "$1" ;;
close) close "${1:?app}" ;;
stop)
    run_and_wait "${1:?name}" 30
    summary "${1:?name}"
    ;;
*) echo "unknown run or action '$cmd'" >&2; exit 2 ;;
esac

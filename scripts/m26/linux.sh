#!/bin/bash
# M26 Step 7: the court on Linux/Vulkan, on a machine `scripts/m18/provision.sh` built.
#
#   linux.sh desktop                 the logged-in GNOME unlocked, on screen and kept awake
#   linux.sh suites                  the whole graph natively, validation required, on x11.sh's display
#   linux.sh install                 a ReleaseSafe install, moved and made read-only
#   linux.sh plays <session>         win, caught and fell, validated and with layers off
#   linux.sh sandbox3d <session>     M25's tour and walker, validated
#   linux.sh capture <session>       capture_linux.py's seven checks
#
# Sessions are scripts/m18/samples.sh's: x11 (x11.sh's Xorg and openbox), sway (headless,
# wayland.sh; `start sway-input` for capture) and gnome (the logged-in desktop, which must be on
# screen: run `desktop` first). Every log goes to
# ~/m26/runs. Like samples.sh, a play starts from the moved copy with only system directories on
# PATH, a scratch HOME and the environment a login of that kind has.

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
m18="$HOME/m18"
# shellcheck disable=SC1091
. "$m18/env.sh"
repo="$HOME/Foundry"
runs="$HOME/m26/runs"
install="$HOME/m26/moved install"
runtime="/run/user/$(id -u)"
mkdir -p "$runs"

fail() { echo "FAILED: $*" >&2; exit 1; }

session_env() { # session -> the variables a login of that kind has
    case "$1" in
    x11)   echo "DISPLAY=$("$m18/x11.sh" display) XDG_SESSION_TYPE=x11" ;;
    gnome) echo "WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland" ;;
    sway)
        eval "$("$m18/wayland.sh" env)"
        [ -n "${SWAYSOCK:-}" ] || fail "sway is not running: wayland.sh start sway"
        echo "WAYLAND_DISPLAY=$WAYLAND_DISPLAY SWAYSOCK=$SWAYSOCK XDG_SESSION_TYPE=wayland" ;;
    *) fail "x11, gnome or sway, not '$1'" ;;
    esac
}

zigrun() { # name args...: one zig build in the repository, its exit judged, its log kept
    local name="$1"; shift
    (cd "$repo" && nice -n 10 zig build "$@" --summary all) > "$runs/$name.log" 2>&1
    local status=$?
    grep -aE "^Build Summary" "$runs/$name.log" | tail -2
    [ $status = 0 ] || fail "$name exited $status; see $runs/$name.log"
    echo "$name passed"
}

hashes() { (cd "$install" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }

case "${1:-}" in
desktop)
    # A GNOME that has locked or blanked discards every frame (wp_presentation_feedback
    # `discarded`) and paces clients at about 20 ms: M18's "unexplained" GNOME pacing. Unlock
    # it, hold an idle inhibitor for the rest of the session, wake the monitor, and make the
    # pointer move one-to-one so ydotool's moves land where they are sent.
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus"
    session="$(loginctl list-sessions --no-legend | awk -v u="$(id -un)" '$3 == u && $4 == "seat0" {print $1; exit}')"
    [ -n "$session" ] || fail "no seat0 session for $(id -un)"
    sudo loginctl unlock-session "$session"
    pgrep -f "gnome-session-inhibit.*Foundry" >/dev/null ||
        setsid nohup gnome-session-inhibit --inhibit idle:suspend --reason "Foundry runs" sleep infinity >/dev/null 2>&1 </dev/null &
    gdbus call --session --dest org.gnome.Mutter.DisplayConfig --object-path /org/gnome/Mutter/DisplayConfig \
        --method org.freedesktop.DBus.Properties.Set org.gnome.Mutter.DisplayConfig PowerSaveMode "<0>" >/dev/null
    gsettings set org.gnome.desktop.peripherals.mouse accel-profile flat
    gsettings set org.gnome.desktop.peripherals.mouse speed 0
    [ -S "$runtime/.ydotool_socket" ] ||
        sudo setsid nohup ydotoold -p "$runtime/.ydotool_socket" -o "$(id -u):$(id -g)" >/dev/null 2>&1 </dev/null &
    sleep 2
    echo "session $session: locked $(loginctl show-session "$session" -p LockedHint --value), display $(cat /sys/class/drm/card*-*/dpms | sort -u | tr '\n' ' ')"
    ;;
suites)
    # GNOME first, while it is on screen: a Wayland compositor on a background console fails
    # the swapchain (VK_ERROR_OUT_OF_DEVICE_MEMORY from Mesa's WSI), it does not merely stall.
    pgrep -x Xorg >/dev/null && fail "stop x11.sh first: GNOME must be on screen"
    export VK_LOADER_LAYERS_DISABLE='~implicit~'
    if [ -S "$runtime/wayland-0" ]; then
        (export WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland
         zigrun gnome-windows vulkan-window-test native-window-test -Drhi=vulkan) || exit 1
    fi
    "$m18/x11.sh" start >/dev/null
    # shellcheck disable=SC2046
    export $(session_env x11)
    zigrun null-debug test -Dplatform=null -Drhi=null
    zigrun null-release court-test -Dplatform=null -Drhi=null -Doptimize=ReleaseSafe
    zigrun vulkan-debug test vulkan-test -Drhi=vulkan
    zigrun vulkan-release court-test render3d-test -Drhi=vulkan -Doptimize=ReleaseSafe
    zigrun x11-windows vulkan-window-test native-window-test -Drhi=vulkan
    ;;
install)
    stage="$HOME/m26/stage"
    rm -rf "$stage"; [ -d "$install" ] && chmod -R u+w "$install" && rm -rf "$install"
    zigrun install install -Drhi=vulkan -Doptimize=ReleaseSafe --prefix "$stage"
    mv "$stage" "$install"
    chmod -R a-w "$install"
    hashes > "$HOME/m26/installed.sha256"
    echo "$(wc -l < "$HOME/m26/installed.sha256") files, read-only, at the moved copy"
    ;;
plays)
    S="${2:?a session}"
    read -ra senv <<<"$(session_env "$S")"
    home="$HOME/m26/home-$S"; prefs="$HOME/m26/prefs-$S"
    rm -rf "$home" "$prefs"; mkdir -p "$home" "$prefs"
    for layers in validation off; do
        for play in win caught fell; do
            name="$S-$layers-$play"; log="$runs/$name.log"; vlog="$runs/$name-validation.log"
            rm -f "$log" "$vlog"
            if [ $layers = validation ]; then
                vk=(VK_LOADER_LAYERS_DISABLE='~implicit~' VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
                    VK_ADD_LAYER_PATH="$VK_ADD_LAYER_PATH"
                    VK_KHRONOS_VALIDATION_DEBUG_ACTION=VK_DBG_LAYER_ACTION_LOG_MSG
                    VK_KHRONOS_VALIDATION_REPORT_FLAGS=error,warn,info
                    VK_KHRONOS_VALIDATION_VALIDATE_SYNC=true
                    VK_KHRONOS_VALIDATION_LOG_FILENAME="$vlog")
            else
                vk=(VK_LOADER_LAYERS_DISABLE='~all~')
            fi
            (cd "$install" && timeout 300 env -i HOME="$home" PATH=/usr/bin:/bin \
                XDG_RUNTIME_DIR="$runtime" "${senv[@]}" "${vk[@]}" FOUNDRY_COURT_PLAY=$play \
                FOUNDRY_COURT_WORKERS=0 FOUNDRY_COURT_PACKAGES= FOUNDRY_COURT_SAVE_DIR="$prefs" \
                "$install/bin/court") > "$log" 2>&1
            status=$?
            [ $status = 0 ] || fail "$name exited $status; see $log"
            grep -qE 'replay: [0-9]+ tick hashes matched a fresh simulation' "$log" || fail "$name: no replay"
            grep -qE 'stopped after [0-9]+ frames \(0 skipped\)' "$log" || fail "$name: skipped frames"
            grep -qE '0 dropped; 0 mixer command\(s\) and 0 event\(s\) dropped' "$log" || fail "$name: drops"
            if [ $layers = validation ]; then
                [ -f "$vlog" ] || fail "$name: the validation layer did not load"
                if grep -qE '^Validation (Error|Warning)|VUID-|SYNC-HAZARD' "$vlog"; then fail "$name: validation not clean"; fi
            fi
            echo "$name passed: $(grep -oE 'stopped after [0-9]+ frames \(0 skipped\), [0-9]+ ticks' "$log")"
        done
    done
    [ -z "$(ls -A "$prefs")" ] || fail "a scripted run wrote preferences"
    diff -q <(hashes) "$HOME/m26/installed.sha256" >/dev/null || fail "the install changed"
    echo "$S: six play-throughs passed; the install is unchanged"
    ;;
sandbox3d)
    # M25's tour and walker from the same moved copy, validated: the third existing sample.
    S="${2:?a session}"
    read -ra senv <<<"$(session_env "$S")"
    home="$HOME/m26/home-$S-3d"; rm -rf "$home"; mkdir -p "$home"
    name="$S-sandbox3d"; log="$runs/$name.log"; vlog="$runs/$name-validation.log"; rm -f "$log" "$vlog"
    (cd "$install" && timeout 300 env -i HOME="$home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime" \
        "${senv[@]}" VK_LOADER_LAYERS_DISABLE='~implicit~' VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
        VK_ADD_LAYER_PATH="$VK_ADD_LAYER_PATH" VK_KHRONOS_VALIDATION_DEBUG_ACTION=VK_DBG_LAYER_ACTION_LOG_MSG \
        VK_KHRONOS_VALIDATION_REPORT_FLAGS=error,warn,info VK_KHRONOS_VALIDATION_VALIDATE_SYNC=true \
        VK_KHRONOS_VALIDATION_LOG_FILENAME="$vlog" FOUNDRY_SANDBOX3D_WALK=tour FOUNDRY_SANDBOX3D_FRAMES=2400 \
        FOUNDRY_SANDBOX3D_SAVE_DIR="$home/prefs" "$install/bin/sandbox3d") > "$log" 2>&1
    status=$?
    [ $status = 0 ] || fail "$name exited $status; see $log"
    grep -q 'tour: pass' "$log" || fail "$name: the tour did not pass"
    grep -q 'tour: walker pass' "$log" || fail "$name: the walker did not pass"
    grep -qE 'stopped after [0-9]+ frames \(0 skipped\)' "$log" || fail "$name: skipped frames"
    [ -f "$vlog" ] || fail "$name: the validation layer did not load"
    if grep -qE '^Validation (Error|Warning)|VUID-|SYNC-HAZARD' "$vlog"; then fail "$name: validation not clean"; fi
    echo "$name passed: $(grep -oE 'tour: replay pass \([0-9]+ ticks' "$log"), $(grep -oE 'stopped after [0-9]+ frames \(0 skipped\)' "$log")"
    ;;
capture)
    S="${2:?a session}"
    read -ra senv <<<"$(session_env "$S")"
    out="$runs/capture"; mkdir -p "$out"; rm -rf "$out/$S-"*
    env -i HOME="$HOME/m26/home-$S" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime" \
        YDOTOOL_SOCKET="$runtime/.ydotool_socket" "${senv[@]}" \
        python3 -I "$here/capture_linux.py" "$S" "$install/bin/court" "$out"
    ;;
*)
    echo "usage: linux.sh desktop | suites | install | plays|sandbox3d|capture <session>" >&2
    exit 2
    ;;
esac

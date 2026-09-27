#!/bin/bash
# One RenderDoc capture of the relocated sandbox on X11, inspected by capture.py (RUNBOOK §6).
#
#   capture.sh <out dir>
#
# RenderDoc stays unpacked and unregistered. Its shipped layer manifest names the library by the
# path it was built at, so a scratch copy names the unpacked one and the sandbox is given that
# directory with VK_ADD_LAYER_PATH, the layer enabled by name, and every implicit layer still
# filtered. qrenderdoc runs with a scratch HOME, so the machine keeps no RenderDoc settings.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$HOME/m18/env.sh"
out="${1:?an output directory}"
mkdir -p "$out/layer" "$out/home"
sed "s|\"library_path\": \"[^\"]*\"|\"library_path\": \"$RENDERDOC/lib/librenderdoc.so\"|" \
    "$RENDERDOC/etc/vulkan/implicit_layer.d/renderdoc_capture.json" > "$out/layer/renderdoc_capture.json"
display="$(DISPLAY= "$here/x11.sh" display)"
# A fresh qrenderdoc asks its analytics question before it runs a script, and waits on it. The
# script exits without saving settings, so the question comes every time: answer "do not gather"
# and OK, by their places in RenderDoc 1.46's dialog.
(for _ in $(seq 60); do
    w="$(DISPLAY="$display" xdotool search --onlyvisible --name '^Analytics$' 2>/dev/null | head -1 || true)"
    if [ -n "$w" ]; then
        DISPLAY="$display" xdotool windowactivate --sync "$w" mousemove --window "$w" 28 376 click 1 \
            sleep 0.3 mousemove --window "$w" 460 414 click 1
        break
    fi
    sleep 1
done) &

env -i HOME="$out/home" PATH=/usr/bin:/bin DISPLAY="$display" XDG_SESSION_TYPE=x11 XDG_RUNTIME_DIR="/run/user/$(id -u)" \
    M18_OUT="$out" M18_SANDBOX="$HOME/m18/moved install/bin/sandbox" \
    M18_ENV_HOME="$HOME/m18/home-capture" M18_ENV_PATH=/usr/bin:/bin M18_ENV_DISPLAY="$display" M18_ENV_XDG_SESSION_TYPE=x11 \
    M18_ENV_VK_ADD_LAYER_PATH="$out/layer" M18_ENV_VK_INSTANCE_LAYERS=VK_LAYER_RENDERDOC_Capture \
    M18_ENV_VK_LOADER_LAYERS_DISABLE='~implicit~' \
    timeout 180 "$RENDERDOC/bin/qrenderdoc" --python "$here/capture.py" > "$out/qrenderdoc.log" 2>&1 || true
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(json.dumps({k: v for k, v in r.items() if k != 'actions'}, indent=1)); print(len(r.get('actions', [])), 'actions')" "$out/capture.json"

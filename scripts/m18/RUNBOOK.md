# M18 runbook: the Linux desktop proof on a rented GPU

M18's exit criteria are in `docs/ROADMAP.md`. This is the order to meet them on one rented
Ubuntu 24.04 x86_64 machine with an NVIDIA GPU (AWS `g4dn.xlarge`, a Tesla T4), reached over SSH
from the Mac. Nothing here names an address, a host or a user; pass the address on the command
line and never write it into the repository.

The machine costs money by the hour, so **everything that can fail cheaply fails first**. Steps 1
to 3 decide in about twenty minutes whether this GPU can present to both window systems. If it
cannot, stop the instance: a stopped instance costs only its disk, and the problem can be
studied without paying for a GPU.

```sh
# on the Mac
H=ubuntu@<address>                 # never recorded
K=~/.ssh/foundry_m18_aws_ed25519
ssh -i $K $H 'mkdir -p m18' && scp -i $K scripts/m18/*.sh $H:m18/
ssh -i $K $H
```

## 0. A dead man's switch (first, always)

```sh
sudo shutdown -h +180     # the instance stops itself in three hours; renew with a new time
```

The launch sets shutdown behaviour to **stop**, so this never deletes anything.

## 1. Provision (about 15 minutes)

```sh
FOUNDRY_TAG=main ~/m18/provision.sh     # installs the driver; says when to reboot
sudo reboot                              # then reconnect
FOUNDRY_TAG=main ~/m18/provision.sh     # finishes: Zig, SDK, RenderDoc, dependencies
~/m18/record-machine.sh | tee ~/m18/machine.txt
```

## 2. Go or no-go: X11 (about 5 minutes)

```sh
. ~/m18/env.sh && cd ~/Foundry
~/m18/x11.sh start
zig build install -Drhi=vulkan --prefix ~/m18/prefix      # both samples, content compiled here
DISPLAY=:0 FOUNDRY_SANDBOX_FRAMES=300 ~/m18/prefix/bin/sandbox 2>&1 | tee ~/m18/go-x11.log
~/m18/x11.sh shot ~/m18/go-x11.png
```

Go when the log names SDL's `x11` video driver, `rhi backend: vulkan on 'Tesla T4'` and
`presenting`, and the screenshot shows the sandbox. If Xorg will not start, read
`~/m18/x11/Xorg.0.log`.

## 3. Go or no-go: Wayland (about 5 minutes)

```sh
~/m18/x11.sh stop && ~/m18/wayland.sh start           # or: wayland.sh start weston
eval "$(~/m18/wayland.sh env)"
FOUNDRY_SANDBOX_FRAMES=300 ~/m18/prefix/bin/sandbox 2>&1 | tee ~/m18/go-wayland.log
~/m18/wayland.sh shot ~/m18/go-wayland.png
```

Go when the log names `wayland`. No-go on either: `sudo shutdown -h now`, and study it stopped.

## 4. The whole test graph, natively, validation required (about 20 minutes)

In the X11 session (the surface and window tests need a display):

```sh
~/m18/wayland.sh stop; ~/m18/x11.sh start; export DISPLAY=:0; unset WAYLAND_DISPLAY
zig build test -Drhi=vulkan --summary all 2>&1 | tee ~/m18/test-x11.log | tail -3
zig build vulkan-window-test native-window-test -Drhi=vulkan 2>&1 | tee ~/m18/window-x11.log | tail -3
```

Then the two window tests again under Wayland (`~/m18/window-wayland.log`).

## 5. Each window system, from a relocated install (about 30 minutes each)

Copy the prefix to a directory whose name has a space, delete nothing the copy needs, and run
with only system directories on `PATH`, `HOME` at a scratch root per session, and validation
through the loader:

```sh
cp -r ~/m18/prefix "$HOME/m18/moved install"
run() { env -i HOME="$HOME/m18/home-$S" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    ${DISPLAY:+DISPLAY=$DISPLAY} ${WAYLAND_DISPLAY:+WAYLAND_DISPLAY=$WAYLAND_DISPLAY} \
    VK_LOADER_LAYERS_DISABLE='~implicit~' VK_ADD_LAYER_PATH="$VK_ADD_LAYER_PATH" \
    VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
    VK_KHRONOS_VALIDATION_REPORT_FLAGS=error,warn,info VK_KHRONOS_VALIDATION_VALIDATE_SYNC=true \
    VK_KHRONOS_VALIDATION_LOG_FILENAME="$HOME/m18/$S-validation-$1.log" "${@:2}"; }
```

The same five runs as Windows' Step 8 (`vulkan.md`), with `S=x11` then `S=wayland`, the samples'
own switches driving them (`FOUNDRY_SANDBOX_FRAMES`, `_WALK`, `_PICK_EVERY`, `_RESIZE_EVERY`,
`FOUNDRY_ROOM_AUTOPILOT`, `_OVERLAY`; read each in `samples/*/main.zig`):
1. the sandbox walking and picking for 900 frames while its installed sprite sheet is touched
   every 200 ms: texture reload with frames in flight;
2. the sandbox resizing itself, minimised and restored twice from outside, then closed:
   X11 `xdotool windowminimize` / `windowactivate` / `windowclose`; sway has no minimise, so
   `swaymsg '[title=…] move scratchpad'` / `scratchpad show`, recorded as what it is;
3. the room on autopilot with the overlay, then real keys and a click: `xdotool key`/`click`
   on X11, `wtype` on Wayland;
4. the sandbox with a user package in the scratch `HOME`'s mods directory (size, volume, icon);
5. the sandbox with every layer disabled (`VK_LOADER_LAYERS_DISABLE='~all~'`, no validation).

Screenshots with `x11.sh shot` / `wayland.sh shot`. **The icon on X11:** tint2's taskbar in the
screenshot, and `xprop -id <window> _NET_WM_ICON` for its sizes. Wayland may leave the icon to
the compositor; record what sway shows, honestly.

Every validation log must hold no error and no warning.

## 6. RenderDoc and pacing (about 20 minutes)

In the X11 session, `$RENDERDOC/bin/renderdoccmd capture` launches the relocated sandbox with the
layer by path, captures a frame, and `qrenderdoc --python <script>` inspects it as on Windows
(`vulkan.md`, Step 9). Pacing: the sandbox's last-240-frame summary, presenting and minimised.
A virtual screen has no display to pace against: record whatever interval FIFO gives, and say so.

## 7. Bring everything home, then end the machine

```sh
# on the Mac
scp -i $K -r "$H:m18/*.log" "$H:m18/*.png" "$H:m18/*.txt" "$H:m18/*.rdc" <evidence dir>
```

Then the owner **terminates** the instance (its disk goes with it), and deletes the key pair and
the security group. Then delete `~/.ssh/foundry_m18_aws_ed25519` on the Mac.

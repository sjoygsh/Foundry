# M18 runbook: the Linux desktop proof over SSH

M18's exit criteria are in `docs/ROADMAP.md`, and what they produced is in
`docs/design/linux-desktop.md`. This is how to run them again on one Ubuntu x86_64 machine
with a hardware Vulkan driver, reached over SSH from the Mac. Nothing here names an address, a
host or a user. Pass the address on the command line, and never write it into the repository.

Two routes are prepared:
- **A Linux installation on a PC with a monitor.** This is what M18 used: a second drive of the
  Windows target's PC, with an Intel Arc on Mesa. X11 runs on the monitor on a console of its
  own. Wayland runs on the logged-in desktop's compositor, and on a headless sway that can be
  scripted.
- **A rented cloud GPU** (for example AWS `g4dn.xlarge`, NVIDIA T4). It has no monitor, so X11
  is a virtual screen, and Wayland is headless sway only. `provision.sh` installs the NVIDIA
  driver when it finds that GPU. Start with a dead man's switch (`sudo shutdown -h +180`, with
  the instance's shutdown behaviour set to *stop*), because the machine costs money by the hour.

```sh
# on the Mac
H=<user>@<address>                      # never recorded
ssh $H 'mkdir -p m18' && scp scripts/m18/* $H:m18/
```

## 1. Provision

```sh
FOUNDRY_TAG=main ~/m18/provision.sh     # NVIDIA only: reboot when told, and run it again
~/m18/record-machine.sh | tee ~/m18/machine.txt
```

It fetches Zig, the pinned Vulkan SDK and RenderDoc, checks each against its hash, and writes
`~/m18/env.sh`. LunarG's server can be very slow. `curl -C -` resumes the SDK download, and the
distribution's `glslang-tools`, `spirv-tools` and `vulkan-validationlayers` can stand in for
early go/no-go runs. Repeat the evidence with the pinned SDK, after uninstalling the
distribution's layer so that the loader finds nothing else.

A desktop that suspends or blanks will drop the connection. Turn off its idle suspend (on GNOME:
`gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing` and
`org.gnome.desktop.session idle-delay 0`, in the user's session bus).

## 2. Sessions

```sh
. ~/m18/env.sh && cd ~/Foundry
~/m18/x11.sh start          # Xorg on vt7, openbox, tint2; `x11.sh display` prints its DISPLAY
~/m18/x11.sh stop           # and gives the console back to the desktop that had it
~/m18/wayland.sh start sway # headless sway on the GPU's render node; `wayland.sh env` for a shell
```

- **Run Wayland evidence on a compositor that is on screen,** or on sway. A compositor on a
  background console sends no frame callbacks, and a swapchain waits on it.
- **Give each process the `XDG_SESSION_TYPE` its login would have.** SDL tries `wayland-0`
  unless that variable names another kind of session. `samples.sh` does this.
- **Start openbox and tint2 from a plain `ssh` call,** not `ssh -tt`. They lost their display
  once when a terminal session closed.

## 3. The whole test graph, natively, with validation required

```sh
DISPLAY=$(~/m18/x11.sh display) XDG_SESSION_TYPE=x11 zig build test -Drhi=vulkan --summary all
DISPLAY=… zig build vulkan-window-test native-window-test -Drhi=vulkan --summary all
WAYLAND_DISPLAY=wayland-0 zig build vulkan-window-test native-window-test -Drhi=vulkan   # the desktop, on screen
```

## 4. Both samples from a relocated install

```sh
zig build install -Drhi=vulkan --prefix ~/m18/prefix
~/m18/samples.sh prepare                               # copies it to "~/m18/moved install"
for r in reload resize room user nolayers; do ~/m18/samples.sh x11 $r; done
for r in reload resize room user nolayers; do ~/m18/samples.sh sway $r; done
~/m18/samples.sh gnome reload; ~/m18/samples.sh gnome resize   # the desktop compositor, undriven
```

The user-package run compiles `~/m18/usercfg`, a package kept outside the repository, with the
moved copy's own `fpack`. It overrides `sandbox:config.main` with 960×540, volume 0.50 and a
16×16 `sandbox:icon`, and requires `sandbox:content`.

**Real input** is driven by hand through `samples.sh <session> start room`, `key`, `type`,
`click` and `stop`:
- **X11:** xdotool, pointer and keys.
- **sway:** its virtual keyboard only. Hold one open first with `wtype -s 600000 &`, or the key
  arrives before the client has a keyboard. No pointer reaches a client in headless sway.
- **GNOME:** nothing. It lets no client drive another, and it gives no focus to a window started
  over SSH, so synthetic keys go to whatever window had focus.

## 5. RenderDoc and pacing

```sh
~/m18/capture.sh ~/m18/capture      # on X11; writes capture.json, the .rdc, and two PNGs
```

It points a scratch copy of RenderDoc's layer manifest at the unpacked library, because the
shipped manifest names the directory it was built in. It then answers qrenderdoc's first-run
analytics question, captures, replays and inspects the largest draw. Pacing is each sample's
last-240-frame summary at exit.

## 6. Bring everything home, then leave nothing behind

Copy `~/m18/runs`, `~/m18/capture`, the test logs and `machine.txt` to the Mac. Then stop the
sessions, remove the key from `authorized_keys`, and reboot, or terminate a rented instance and
delete its key pair and security group. Delete the SSH key on the Mac.

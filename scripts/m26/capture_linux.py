#!/usr/bin/env python3
# M26 Step 7: the court's pointer capture checked from outside the process, on Linux.
#
#   capture_linux.py x11   <court> <output-dir>     the display `x11.sh` started (DISPLAY set)
#   capture_linux.py sway  <court> <output-dir>     `wayland.sh start sway-input` (its env applied)
#   capture_linux.py gnome <court> <output-dir>     the logged-in desktop, driven by ydotool
#
# The same seven checks as Windows (`capture_windows.ps1`): the title releases the pointer,
# play captures it, pause releases it, resume captures it, focus loss releases it, regaining
# focus does not capture it, and an explicit resume does. It is an OS-level proof, not a
# person's play report.
#
# How "captured" is read differs by window system, and each reading is the window system's own:
# - X11: another client's XGrabPointer is refused with AlreadyGrabbed, the pointer sits inside
#   the court's window, and XFixes reports the cursor image fully transparent.
# - Wayland: the protocol between the court and the compositor (WAYLAND_DEBUG=client): captured
#   from the compositor's `locked` until its `unlocked` or the court's `destroy` of that lock. A
#   lock the compositor did not grant is never reported as captured.

import ctypes
import os
import re
import subprocess
import sys
import time

TITLE = "Foundry Court"


def fail(message):
    print(f"FAILED: {message}", file=sys.stderr)
    sys.exit(1)


class X11:
    GRAB_SUCCESS, ALREADY_GRABBED = 0, 1

    class Image(ctypes.Structure):
        _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short),
                    ("width", ctypes.c_ushort), ("height", ctypes.c_ushort),
                    ("xhot", ctypes.c_ushort), ("yhot", ctypes.c_ushort),
                    ("cursor_serial", ctypes.c_ulong),
                    ("pixels", ctypes.POINTER(ctypes.c_ulong)),
                    ("atom", ctypes.c_ulong), ("name", ctypes.c_char_p)]

    def __init__(self):
        self.x = ctypes.CDLL("libX11.so.6")
        self.xf = ctypes.CDLL("libXfixes.so.3")
        self.x.XOpenDisplay.restype = ctypes.c_void_p
        self.x.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x.XDefaultRootWindow.restype = ctypes.c_ulong
        self.x.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        self.x.XGrabPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int,
                                        ctypes.c_uint, ctypes.c_int, ctypes.c_int,
                                        ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
        self.x.XUngrabPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        self.x.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self.x.XFree.argtypes = [ctypes.c_void_p]
        self.x.XQueryPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + \
            [ctypes.POINTER(ctypes.c_ulong)] * 2 + [ctypes.POINTER(ctypes.c_int)] * 4 + \
            [ctypes.POINTER(ctypes.c_uint)]
        self.xf.XFixesGetCursorImage.restype = ctypes.POINTER(X11.Image)
        self.xf.XFixesGetCursorImage.argtypes = [ctypes.c_void_p]
        self.d = self.x.XOpenDisplay(None)
        if not self.d:
            fail("no X display")
        self.root = self.x.XDefaultRootWindow(self.d)

    def window(self, pid):
        out = subprocess.run(["xdotool", "search", "--pid", str(pid), "--name", f"^{TITLE}$"],
                             capture_output=True, text=True).stdout.split()
        return int(out[0]) if out else None

    def grabbed(self):
        result = self.x.XGrabPointer(self.d, self.root, 0, 0, 1, 1, 0, 0, 0)
        if result == X11.GRAB_SUCCESS:
            self.x.XUngrabPointer(self.d, 0)
        self.x.XSync(self.d, 0)
        return result == X11.ALREADY_GRABBED

    def hidden(self):
        image = self.xf.XFixesGetCursorImage(self.d)
        if not image:
            fail("XFixesGetCursorImage failed")
        c = image.contents
        pixels = [c.pixels[i] for i in range(c.width * c.height)]
        self.x.XFree(image)
        return all((p >> 24) & 0xff == 0 for p in pixels)

    def inside(self, window):
        geometry = subprocess.run(["xdotool", "getwindowgeometry", "--shell", str(window)],
                                  capture_output=True, text=True).stdout
        g = dict(line.split("=", 1) for line in geometry.split())
        root, child = ctypes.c_ulong(), ctypes.c_ulong()
        rx, ry, wx, wy = (ctypes.c_int() for _ in range(4))
        mask = ctypes.c_uint()
        self.x.XQueryPointer(self.d, self.root, ctypes.byref(root), ctypes.byref(child),
                             ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(wx),
                             ctypes.byref(wy), ctypes.byref(mask))
        x, y = int(g["X"]), int(g["Y"])
        return x <= rx.value < x + int(g["WIDTH"]) and y <= ry.value < y + int(g["HEIGHT"])


class Court:
    def __init__(self, session, court, output):
        self.session, self.output = session, output
        self.log = os.path.join(output, f"{session}-capture.log")
        if os.path.exists(self.log):
            fail(f"stale evidence: {self.log}")
        env = dict(os.environ)
        env.update(FOUNDRY_COURT_FRAMES="5400", FOUNDRY_COURT_WORKERS="0",
                   FOUNDRY_COURT_PACKAGES="", VK_LOADER_LAYERS_DISABLE="~all~",
                   FOUNDRY_COURT_SAVE_DIR=os.path.join(output, f"{session}-preferences"))
        for name in ("FOUNDRY_COURT_PLAY", "FOUNDRY_COURT_OVERLAY", "VK_INSTANCE_LAYERS"):
            env.pop(name, None)
        if session != "x11":
            env["WAYLAND_DEBUG"] = "client"
        os.makedirs(env["FOUNDRY_COURT_SAVE_DIR"], exist_ok=True)
        self.file = open(self.log, "w")
        self.process = subprocess.Popen([court], cwd=os.path.dirname(os.path.dirname(court)),
                                        env=env, stdout=self.file, stderr=subprocess.STDOUT)
        self.x11 = X11() if session == "x11" else None
        self.window = None
        deadline = time.time() + 20
        while time.time() < deadline and self.process.poll() is None:
            if self.x11:
                self.window = self.x11.window(self.process.pid)
                if self.window:
                    break
            elif "xdg_toplevel" in open(self.log, errors="replace").read():
                break
            time.sleep(0.2)
        else:
            fail("the court's window did not appear")
        time.sleep(1.5)

    # -- reading capture ----------------------------------------------------------------
    # The compositor's `locked`/`unlocked`, and the court's own `destroy` of the lock, which
    # is how SDL releases one: no `unlocked` follows a destroyed lock.
    LOCK = re.compile(r"zwp_locked_pointer_v1[#@](\d+)\.(locked|unlocked|destroy)\(\)")

    def captured(self):
        if self.x11:
            return self.x11.grabbed() and self.x11.hidden() and self.x11.inside(self.window)
        events = self.LOCK.findall(open(self.log, errors="replace").read())
        return bool(events) and events[-1][1] == "locked"

    def expect(self, want, name):
        deadline = time.time() + 3
        while time.time() < deadline:
            if self.process.poll() is not None:
                fail(f"{name}: the court exited")
            if self.captured() == want:
                print(f"{name} passed")
                return
            time.sleep(0.05)
        fail(f"{name} did not reach captured={want}")

    def hold(self, want, name, seconds=1.5):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if self.captured() != want:
                fail(f"{name}: captured became {not want}")
            time.sleep(0.05)
        print(f"{name} passed")

    # -- driving it, through each window system's own way in ------------------------------
    def key(self, name):
        if self.session == "x11":
            subprocess.run(["xdotool", "key", "--window", str(self.window), "--clearmodifiers", name], check=True)
        elif self.session == "sway":
            subprocess.run(["wtype", "-k", name], check=True)
        else:
            code = {"Return": 28, "Escape": 1}[name]
            subprocess.run(["ydotool", "key", f"{code}:1", f"{code}:0"], check=True)
        time.sleep(0.3)

    def focus(self):
        if self.session == "x11":
            subprocess.run(["xdotool", "windowactivate", "--sync", str(self.window)], check=True)
        elif self.session == "sway":
            subprocess.run(["swaymsg", "workspace", "1"], check=True, capture_output=True)
            subprocess.run(["swaymsg", f'[title="^{TITLE}$"] focus'], check=True, capture_output=True)
            # Sway centres a floating window. Its cursor needs a pointer device, which
            # `wayland.sh start sway-input` gives it: ydotool's, nudged so it arrives. It is
            # parked inside the window above the menus, since a hovered button is the one
            # Enter presses.
            subprocess.run(["swaymsg", "seat - cursor set 960 260"], check=True, capture_output=True)
            subprocess.run(["ydotool", "mousemove", "-x", "20", "-y", "0"], check=True)
            subprocess.run(["ydotool", "mousemove", "-x", "-20", "-y", "0"], check=True)
        elif getattr(self, "away", False):
            gnome_workspace(-1)
            self.away = False
        else:
            # An unlocked GNOME focuses the new window itself. A Wayland lock takes hold only
            # under the pointer: a person's hand is on the mouse, and this one is moved to the
            # screen's centre, where GNOME places the window, and nudged, since a move to where
            # the pointer already is sends nothing. (Alt+Tab would open the switcher, which
            # takes the pointer away from the window.)
            subprocess.run(["ydotool", "mousemove", "--absolute", "-x", "960", "-y", "540"], check=True)
            time.sleep(0.3)
            subprocess.run(["ydotool", "mousemove", "-x", "20", "-y", "0"], check=True)
            time.sleep(0.3)
            subprocess.run(["ydotool", "mousemove", "-x", "-20", "-y", "0"], check=True)
        time.sleep(0.5)

    def lose_focus(self):
        if self.session == "x11":
            other = subprocess.Popen(["xmessage", "-name", "focusproof", "Foundry capture focus-loss proof"])
            time.sleep(1)
            # xmessage sets no _NET_WM_PID; its instance name is what it is found by.
            out = subprocess.run(["xdotool", "search", "--sync", "--classname", "focusproof"],
                                 capture_output=True, text=True, timeout=10).stdout.split()
            subprocess.run(["xdotool", "windowactivate", "--sync", out[0]], check=True)
            self.other = other
        elif self.session == "sway":
            subprocess.run(["swaymsg", "workspace", "2"], check=True, capture_output=True)
        else:
            gnome_workspace(+1)
            self.away = True
        time.sleep(0.5)

    def close(self):
        if self.x11:
            getattr(self, "other", None) and self.other.kill()
            # The window manager's close request, never a destroyed window (which SDL reports
            # as a lost window and exits on).
            subprocess.run(["xdotool", "windowactivate", "--sync", str(self.window), "key", "--clearmodifiers", "alt+F4"])
        elif self.session == "sway":
            subprocess.run(["swaymsg", f'[title="^{TITLE}$"] kill'], capture_output=True)
        else:
            self.process.terminate()
        try:
            status = self.process.wait(15)
        except subprocess.TimeoutExpired:
            self.process.kill()
            fail("the court did not close")
        if status != 0 and not (self.session == "gnome" and status == -15):
            fail(f"the court exited {status}")


def gnome_workspace(direction):
    # Super+Page Down / Page Up: GNOME's own workspace switch, through a uinput keyboard.
    page = 109 if direction > 0 else 104
    subprocess.run(["ydotool", "key", "125:1", f"{page}:1", f"{page}:0", "125:0"], check=True)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("x11", "sway", "gnome"):
        fail("usage: capture_linux.py x11|sway|gnome <court> <output-dir>")
    session, court, output = sys.argv[1], os.path.abspath(sys.argv[2]), sys.argv[3]
    os.makedirs(output, exist_ok=True)
    c = Court(session, court, output)
    try:
        c.focus()
        c.expect(False, "Title releases pointer")
        c.key("Return")
        c.expect(True, "Playing hides and confines pointer")
        c.key("Escape")
        c.expect(False, "Pause releases pointer")
        c.key("Return")
        c.expect(True, "Resume captures pointer")
        c.lose_focus()
        c.expect(False, "Focus loss releases pointer")
        c.focus()
        c.hold(False, "Regaining focus does not capture")
        c.key("Return")
        c.expect(True, "Explicit resume after focus loss captures")
        c.close()
    finally:
        if c.process.poll() is None:
            c.process.kill()
    print(f"Seven OS-level capture checks passed on {session}. No person's play report is claimed.")


if __name__ == "__main__":
    main()

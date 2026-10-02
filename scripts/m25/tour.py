#!/usr/bin/env python3
"""Developer proof: two real processes, same native poses byte for byte. Not a build tool.

Install ReleaseSafe, move the prefix, make it read-only, then:
  python3 scripts/m25/tour.py <relocated>/bin/sandbox3d <scratch-output>
The child PATH contains no Zig or SDK; HOME/APPDATA are disposable. Works for null and
Metal here; Windows execution/qualification is M25 Step 6, not claimed by this driver.
"""
import os
from pathlib import Path
import re
import subprocess
import sys


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: tour.py <relocated-sandbox3d> <scratch-output>")
    executable, output = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    for index in range(2):
        home = output / f"user-{index}"
        home.mkdir(exist_ok=True)
        trace = output / f"poses-{index}.bin"
        # Refuse stale artifacts rather than accidentally accepting an earlier run.
        if trace.exists():
            raise SystemExit(f"proof output already exists: {trace}; choose a fresh output")
        env = {"HOME": str(home), "APPDATA": str(home),
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               "FOUNDRY_SANDBOX3D_PACKAGES": "plinth:content,orbiter:content",
               "FOUNDRY_SANDBOX3D_NATIVE": "orbiter:content",
               "FOUNDRY_SANDBOX3D_NATIVE_TRACE": str(trace),
               "FOUNDRY_SANDBOX3D_WALK": "tour",
               "FOUNDRY_SANDBOX3D_OVERLAY": "0",
               "FOUNDRY_SANDBOX3D_WORKERS": "0"}
        with (output / f"tour-{index}.log").open("wb") as log:
            subprocess.run([str(executable)], env=env, stdout=log, stderr=log,
                           check=True, timeout=180)
        text = (output / f"tour-{index}.log").read_text()
        for required in ["tour: plinth pass", "tour: orbiter pass", "tour: replay pass",
                         "tour: walker pass", "cb99ccfcf2b6d6c3"]:
            if required not in text:
                raise SystemExit(f"run {index} missing {required}")
        if not re.search(r"stopped after \d+ frames \(0 skipped\)", text):
            raise SystemExit(f"run {index} skipped frames")
        print(f"native tour process {index}: pass", flush=True)
    first, second = [(output / f"poses-{index}.bin").read_bytes() for index in range(2)]
    if len(first) != 360 * 3 * 16 * 4 or first != second:
        raise SystemExit("native pose traces differ or are incomplete")
    print(f"fresh-process native replay: {len(first)} bytes identical", flush=True)


if __name__ == "__main__":
    main()

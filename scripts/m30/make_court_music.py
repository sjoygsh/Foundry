#!/usr/bin/env python3
"""Write the court's soundtrack and the `nocturne` mod's music (docs/design/music.md §9).

    python3 scripts/m30/make_court_music.py <scratch-dir>

Synthesises every track and stinger deterministically: chords, a bass line, soft percussion
and a melody, at 48 kHz stereo. The court's music is at 96 bpm in 4/4 and nocturne's at 72 bpm
in 3/4, so both have bars of exactly 2.5 seconds. Each piece is encoded at quality 4 by the
reference libvorbis (`reference.py` builds the tool in <scratch-dir>), and the `.ogg` files are
written into the repository:

- `samples/court/content/music/tracks/`: title, calm_a, calm_b and chase. The title has an
  eight-bar intro before its looped body, and this prints its loop points (M31,
  docs/design/mixing.md §11); the other pieces are as M30 wrote them, byte for byte;
- `samples/court/content/music/stingers/`: beacon, gate and ending;
- `samples/court/testdata/mods/nocturne/music/`: nocturne_a, nocturne_b and beacon.

The source WAVs stay in scratch. The build never runs this; run it from the repository root
with `zig` on PATH.
"""

import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reference  # noqa: E402

RATE = 48000
TAU = 2 * math.pi
COURT = "samples/court/content/music"
NOCTURNE = "samples/court/testdata/mods/nocturne/music"


def lcg(seed: int):
    """A fixed generator, so the noise in the percussion is the same on every run."""
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        yield ((state >> 33) / (1 << 31)) * 2 - 1


def hz(note: int) -> float:
    """A MIDI note number's frequency: 69 is A4, 440 Hz."""
    return 440.0 * 2 ** ((note - 69) / 12)


class Track:
    """Two channels of `seconds`, into which notes are added where they sound."""

    def __init__(self, seconds: float):
        self.frames = round(seconds * RATE)
        self.left = [0.0] * self.frames
        self.right = [0.0] * self.frames

    def add(self, start: float, length: float, pan: float, voice, wrap=None):
        """Adds `voice(t)` from `start` for `length` seconds, panned -1 left to 1 right. With
        `wrap`, a frame, what would ring past the end is added from that frame instead, so a
        loop's last notes carry on into its first bar as they would if it really repeated."""
        first = round(start * RATE)
        gl = math.cos((pan + 1) * math.pi / 4)
        gr = math.sin((pan + 1) * math.pi / 4)
        if wrap is not None:
            for i in range(round(length * RATE)):
                k = first + i
                if k >= self.frames:
                    k = wrap + (k - self.frames)
                v = voice(i / RATE)
                self.left[k] += v * gl
                self.right[k] += v * gr
            return
        count = min(round(length * RATE), self.frames - first)
        for i in range(max(count, 0)):
            v = voice(i / RATE)
            self.left[first + i] += v * gl
            self.right[first + i] += v * gr

    def finish(self, peak: float = 0.7, tail: float = 0.01):
        """Scales to `peak` and fades the last `tail` seconds, so a cut note cannot click."""
        top = max(max(abs(x) for x in self.left), max(abs(x) for x in self.right), 1e-9)
        scale = peak / top
        fade = round(tail * RATE)
        for i in range(self.frames):
            g = scale * min(1.0, (self.frames - 1 - i) / fade) if fade else scale
            self.left[i] *= g
            self.right[i] *= g


def envelope(attack: float, decay: float):
    """A note's shape: a linear attack, then an exponential decay."""
    def at(t: float) -> float:
        return t / attack if t < attack else math.exp(-(t - attack) / decay)
    return at


def pad(freq: float, length: float, detune: float):
    """A soft, slowly breathing chord tone: two sines a little apart, faded in and out."""
    edge = min(0.4, length / 3)

    def voice(t: float) -> float:
        shape = min(1.0, t / edge, (length - t) / edge)
        return 0.12 * shape * (math.sin(TAU * freq * t) + 0.5 * math.sin(TAU * freq * (1 + detune) * t))
    return voice


def bass(freq: float):
    env = envelope(0.01, 0.35)
    return lambda t: 0.35 * env(t) * (math.sin(TAU * freq * t) + 0.3 * math.sin(TAU * 2 * freq * t))


def pluck(freq: float, decay: float = 0.25):
    """A bright note that falls away: a fundamental and two partials, the upper ones faster."""
    env = envelope(0.005, decay)
    return lambda t: 0.2 * env(t) * (math.sin(TAU * freq * t)
                                     + 0.4 * math.exp(-t * 6) * math.sin(TAU * 2 * freq * t)
                                     + 0.15 * math.exp(-t * 10) * math.sin(TAU * 3 * freq * t))


def bell(freq: float, decay: float = 0.8):
    """A struck tone with an inharmonic partial, for the stingers."""
    env = envelope(0.003, decay)
    return lambda t: 0.25 * env(t) * (math.sin(TAU * freq * t)
                                      + 0.5 * math.exp(-t * 3) * math.sin(TAU * 2.76 * freq * t)
                                      + 0.25 * math.exp(-t * 5) * math.sin(TAU * 5.4 * freq * t))


def kick():
    def voice(t: float) -> float:
        # The pitch falls from 120 Hz to 45 Hz; this is its phase, integrated.
        phase = TAU * (45 * t + 75 * (1 - math.exp(-t * 30)) / 30)
        return 0.5 * math.exp(-t * 9) * math.sin(phase)
    return voice


def hat(seed: int, level: float = 0.06):
    noise = lcg(seed)
    last = [0.0]

    def voice(t: float) -> float:
        n = next(noise)
        high = n - last[0]  # a difference is a crude high-pass: what a hat needs
        last[0] = n
        return level * math.exp(-t * 60) * high
    return voice


# A minor and its neighbours, as root notes and chord tones (MIDI numbers).
CHORDS = {
    "Am": (57, (57, 60, 64)),
    "F": (53, (53, 57, 60)),
    "C": (48, (55, 60, 64)),
    "G": (55, (55, 59, 62)),
    "Dm": (50, (57, 62, 65)),
    "E": (52, (56, 59, 64)),
    "Em": (52, (55, 59, 64)),
}


def play_bars(track: Track, first: int, bars: int, beats: int, tempo: float, progression, *,
              drums: bool, hats: bool, melody: bool, busy: bool, seed: int, wrap=None) -> None:
    """Bars `first` to `first + bars` of `track`, the progression starting again at `first`."""
    beat = 60.0 / tempo
    bar = beat * beats
    for n in range(first, first + bars):
        root, tones = CHORDS[progression[(n - first) % len(progression)]]
        start = n * bar
        for k, note in enumerate(tones):
            track.add(start, bar + 0.3, (k - 1) * 0.5, pad(hz(note), bar + 0.3, 0.003 * (k + 1)), wrap)
        for b in range(beats):
            t = start + b * beat
            if b == 0 or (busy and b % 2 == 0):
                track.add(t, beat * 1.5, 0, bass(hz(root - 12)), wrap)
            if drums and (b == 0 or (beats == 4 and b == 2) or (busy and b % 2 == 1 and n % 2 == 1)):
                track.add(t, 0.5, 0, kick(), wrap)
            if hats:
                for h in range(4 if busy else 2):
                    track.add(t + h * beat / (4 if busy else 2), 0.08, 0.4, hat(seed + n * 64 + b * 8 + h, 0.05 if h % 2 else 0.07), wrap)
        if melody:
            step = beat / (4 if busy else 2)
            pattern = (0, 1, 2, 1, 2, 0, 1, 2) if busy else (0, 2, 1, 2)
            count = beats * (4 if busy else 2)
            for i in range(count):
                if not busy and (n + i) % 5 == 4:
                    continue  # rests, so a calm line breathes
                note = tones[pattern[i % len(pattern)]] + 12
                track.add(start + i * step, 0.6, -0.3, pluck(hz(note), 0.18 if busy else 0.35), wrap)


def compose(name: str, bars: int, beats: int, tempo: float, progression, *,
            drums: bool, hats: bool, melody: bool, busy: bool, seed: int) -> Track:
    beat = 60.0 / tempo
    bar = beat * beats
    track = Track(bars * bar)
    play_bars(track, 0, bars, beats, tempo, progression, drums=drums, hats=hats, melody=melody, busy=busy, seed=seed)
    track.finish()
    print(f"{name}: {bars} bars, {track.frames / RATE:.1f} s")
    return track


def title() -> Track:
    """The title (mixing.md §11): eight bars of chords and bass, then an eight-bar body with
    the melody and soft hats, which the court loops by the loop points its record gives. The
    body's tail wraps into its own first bar and nothing is faded at the end, so the seam is
    the music carrying on rather than a cut."""
    intro, body, beats, tempo = 8, 8, 4, 96
    bar = 60.0 / tempo * beats  # 2.5 s exactly
    track = Track((intro + body) * bar)
    loop_start = round(intro * bar * RATE)
    play_bars(track, 0, intro, beats, tempo, ("Am", "F", "Dm", "E"),
              drums=False, hats=False, melody=False, busy=False, seed=1)
    play_bars(track, intro, body, beats, tempo, ("Am", "F", "Dm", "E"),
              drums=False, hats=True, melody=True, busy=False, seed=1, wrap=loop_start)
    track.finish(tail=0)
    print(f"title: {intro} bars of intro, then {body} looped; loop_start {loop_start}  loop_end {track.frames}")
    return track


def stinger(name: str, seconds: float, notes, voice_of, spacing: float, pan_spread: float) -> Track:
    track = Track(seconds)
    for i, note in enumerate(notes):
        pan = (i / max(len(notes) - 1, 1) * 2 - 1) * pan_spread
        track.add(i * spacing, seconds - i * spacing, pan, voice_of(hz(note)))
    track.finish(peak=0.8, tail=0.05)
    print(f"{name}: {seconds:.1f} s")
    return track


def write_wav(path: str, track: Track) -> None:
    data = bytearray()
    for l, r in zip(track.left, track.right):
        data += struct.pack("<hh", max(-32768, min(32767, round(l * 32767))),
                            max(-32768, min(32767, round(r * 32767))))
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, RATE, RATE * 4, 4, 16))
        f.write(b"data" + struct.pack("<I", len(data)) + bytes(data))


def pieces():
    """(directory, name, track): every piece, in a fixed order, which fixes its serial."""
    calm = ("Am", "F", "C", "G")
    yield COURT + "/tracks", "title", title()
    yield COURT + "/tracks", "calm_a", compose("calm_a", 20, 4, 96, calm,
                                               drums=True, hats=True, melody=True, busy=False, seed=2)
    yield COURT + "/tracks", "calm_b", compose("calm_b", 20, 4, 96, ("F", "G", "Em", "Am"),
                                               drums=True, hats=True, melody=False, busy=False, seed=3)
    yield COURT + "/tracks", "chase", compose("chase", 13, 4, 96, ("Am", "Am", "F", "E"),
                                              drums=True, hats=True, melody=True, busy=True, seed=4)
    yield COURT + "/stingers", "beacon", stinger("beacon", 1.6, (69, 73, 76, 81), bell, 0.08, 0.6)
    yield COURT + "/stingers", "gate", stinger("gate", 2.5, (45, 52, 57, 61), lambda f: pad(f, 2.5, 0.004), 0.0, 0.5)
    yield COURT + "/stingers", "ending", stinger("ending", 3.0, (76, 72, 69, 64, 57), lambda f: bell(f, 1.2), 0.15, 0.5)
    yield NOCTURNE, "nocturne_a", compose("nocturne_a", 16, 3, 72, ("Dm", "Am", "F", "E"),
                                          drums=False, hats=False, melody=True, busy=False, seed=5)
    yield NOCTURNE, "nocturne_b", compose("nocturne_b", 16, 3, 72, ("F", "C", "Dm", "Am"),
                                          drums=False, hats=True, melody=True, busy=False, seed=6)
    yield NOCTURNE, "beacon", stinger("nocturne beacon", 2.0, (62, 69, 74, 77), lambda f: pluck(f, 0.6), 0.12, 0.7)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    scratch = os.path.abspath(sys.argv[1])
    tool = reference.build(scratch)
    total_ogg = 0
    total_wav = 0
    for index, (directory, name, track) in enumerate(pieces()):
        os.makedirs(directory, exist_ok=True)
        source = os.path.join(scratch, f"music-{os.path.basename(directory)}-{name}.wav")
        write_wav(source, track)
        ogg = os.path.join(directory, name + ".ogg")
        reference.encode(tool, source, ogg, 0.4, 0x46430000 + index)
        size = os.path.getsize(ogg)
        wav = track.frames * 4
        total_ogg += size
        total_wav += wav
        print(f"  {ogg}: {size} bytes, {wav / size:.1f}x smaller than 16-bit WAV")
    print(f"all: {total_ogg} bytes against {total_wav} as 16-bit WAV ({total_wav / total_ogg:.1f}x)")


if __name__ == "__main__":
    main()

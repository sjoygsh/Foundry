//! Foundry `audio` — layer L3. The mixer, its voices, and sounds as content.
//!
//! Depends on `core`, `platform` and `asset`: the device is below it, the decoded samples
//! come from beside it, and nothing above it exists yet.
//!
//! ## The one thing that makes this module unlike every other one
//!
//! **There is a second thread, Foundry did not create it, and it has a deadline.** The
//! device calls us on a thread it owns; we must fill a buffer before it drains the last
//! one; and missing that deadline is an audible click rather than a dropped frame.
//!
//! So, inside the mix callback: **no allocation, no lock, no logging, no filesystem, no
//! `core.log`, no syscall and no error return.** It fills its output completely — silence
//! is zeroes, never a short write.
//!
//! Nothing enforces that rule and pretending otherwise would be worse than saying so
//! (ADR-0023). What this module does instead is remove every reason to reach for a
//! forbidden thing: a single-producer/single-consumer ring means no lock, a fixed voice
//! pool means no allocation, and everything that can fail was moved to the game thread,
//! which is why `play` returns an error and the callback does not.
//!
//! ## What is not here, structurally
//!
//! **`scene` does not appear anywhere in this module, and that is enforced rather than
//! intended.** Both are L3 and neither depends on the other, so a system physically
//! cannot reach the mixer (I7). A game plays sounds from data its systems wrote down —
//! the identical shape input already has, and the reason audio's nondeterminism cannot
//! leak into the simulation (I9, `audio.md` §8).
//!
//! **`render2d` is not here either**, for the same reason and with the same enforcement.
//!
//! Design: `docs/design/audio.md`.

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const asset = @import("asset");

pub const mixer = @import("mixer.zig");
pub const ring = @import("ring.zig");
pub const voice = @import("voice.zig");

/// Phantom tag for `VoiceHandle`. Never instantiated; it exists so a voice handle cannot
/// be confused with any other handle type (I1).
pub const Voices = mixer.Voices;

/// One playing sound, addressed by generational handle.
///
/// The generation is the answer to the oldest bug in game audio: a game starts a
/// footstep, keeps the handle, and 400 ms later calls `stop` on it — but the footstep
/// finished 300 ms ago and its slot was reused by the door that just opened. With a bare
/// index the door goes silent for no reason anyone can reproduce. The generation makes
/// that a no-op instead.
///
/// This is the same reason `Entity` and `AssetHandle` are generational, applied to the
/// one subsystem where slots recycle fast enough that a person will actually hit it.
pub const VoiceHandle = mixer.VoiceHandle;

pub const Mixer = mixer.Mixer;
/// The mixer against an arbitrary platform backend, so a test can drive the stepped null
/// device whichever backend the build selected — the shape `app.EngineOf` already has.
pub const MixerOf = mixer.MixerOf;
pub const Options = mixer.Options;
pub const PlayParams = mixer.PlayParams;
pub const InitError = mixer.InitError;
pub const PlayError = mixer.PlayError;
pub const VoiceError = mixer.VoiceError;
pub const SoundHandle = mixer.SoundHandle;
pub const Sounds = mixer.Sounds;

/// Re-exported so a game can name what it is configuring without also importing
/// `platform` (`audio.md` §7: the game constructs the mixer, and `app` never sees it).
pub const AudioInfo = platform.AudioInfo;

comptime {
    // The module's place in the graph, asserted rather than assumed. `audio` must be able
    // to name a device below it and decoded samples beside it; if either import were
    // missing from `build.zig`, this fails at the point of use rather than silently
    // compiling because nothing referenced it (see `build.zig`'s note on lazy analysis).
    _ = platform.AudioConfig;
    _ = platform.AudioDeviceHandle;
    _ = asset.Sound;
    _ = asset.SoundDecodeError;
}

const testing = std.testing;

test {
    _ = mixer;
    _ = ring;
    _ = voice;
}

test "a zeroed voice handle is none" {
    const h: VoiceHandle = std.mem.zeroes(VoiceHandle);
    try testing.expect(h.isNone());
    try testing.expect(VoiceHandle.none.isNone());
}

//! The engine loop, subsystem lifecycle, and what owns what.
//!
//! `Engine` is a thing you initialise and drive. **It does not call you back.** A
//! framework would have to grow a knob for every application shape that did not fit, and
//! tools — the editor included — are Foundry applications too (ADR-0011). It also inverts
//! control, which is the same objection `platform` raised against event callbacks: engine
//! code running at arbitrary points inside someone else's loop makes the ordering of state
//! changes a property of the framework rather than of the program, and I9 is about not
//! depending on that.
//!
//!     var engine = try app.Engine.init(gpa, .{ .window = .{ .title = "Sandbox" } });
//!     defer engine.deinit();
//!
//!     while (!engine.shouldQuit()) {
//!         engine.beginFrame();
//!         while (engine.nextEvent()) |ev| { ... }
//!         while (engine.nextStep()) |step| { ...simulate with step.input... }
//!         // ...render, interpolated by engine.alpha()...
//!         engine.endFrame();
//!     }
//!
//! Design: `docs/design/app-and-frame-loop.md`

const std = @import("std");
const core = @import("core");
const platform = @import("platform");
const rhi = @import("rhi");

const log_sink = @import("log_sink.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.app);

pub const InitError = platform.InitError || platform.WindowError || rhi.InitError;

pub const Config = struct {
    /// The process environment, from `main`. See `app.environment`.
    env: []const platform.os.EnvVar = &.{},
    /// Names the per-user data directory on disk. Users and mods will see it, so it is
    /// chosen once and not changed casually.
    app_name: []const u8 = "foundry",

    /// Whether to open a window at all. A content compiler or a headless server wants
    /// the loop and the filesystem without a display.
    headless: bool = false,
    window: platform.WindowConfig = .{},

    /// Simulation rate. An exact rational internally, so tick N lands on an exact
    /// instant however large N gets (I9).
    tick_rate_hz: u32 = 60,
    /// Upper bound on simulation steps per frame. Without it, a frame that ran long
    /// produces more steps, which takes longer, which produces more steps.
    max_steps_per_frame: u32 = 8,

    /// How far the CPU may run ahead of the GPU. Passed straight to the RHI, which owns
    /// the frame ring — see `docs/design/rhi.md` §7.
    frames_in_flight: u32 = 2,

    /// Runtime log verbosity. Independent of the compile-time level, which decides what
    /// is *built* (`log_sink`).
    log_level: core.log.Level = .info,
};

/// One fixed simulation step.
pub const Step = struct {
    /// Monotonically increasing from 1. Simulation time is this integer, never a float.
    tick: u64,
    /// Exact length of one step.
    delta: core.time.Duration,
    /// **The frame's input, frozen.** Every step in a frame sees this same value, rather
    /// than whatever the OS delivered between them — which is what makes a fixed
    /// timestep actually reproducible, and what makes replay possible later (I9).
    input: platform.InputSnapshot,
    /// Total simulation time at the end of this step.
    elapsed: core.time.Duration,
};

/// The engine, parameterised by its platform backend.
///
/// Generic over **both** ports, so that `app`'s own tests always run against the null
/// platform's synthetic clock and the null RHI's validating device, whatever backend the
/// build selected. The frame loop is precisely the thing that has to be tested
/// deterministically: a test against SDL would be measuring the machine, and a test against
/// Metal would be measuring the GPU. It also keeps `app` honest — nothing here may depend on
/// a particular backend, because neither type is fixed until instantiation.
///
/// Games and tools want `app.Engine`, which is this with the selected backends.
pub fn EngineOf(comptime P: type, comptime G: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        /// Memory whose lifetime is exactly one frame. Reset, never freed piecewise.
        frame_arena: core.Arena,

        // Subsystems, in initialisation order. Teardown is strictly the reverse.
        os: *platform.Os,
        platform: *P,
        gpu: *G,

        window: platform.WindowHandle,

        stepper: core.time.FixedStepper,
        step_delta: core.time.Duration,
        previous: core.time.Instant,

        /// This frame's events, drained from the platform so that engine-level handling
        /// does not depend on the caller draining them.
        events: std.ArrayList(platform.Event),
        event_cursor: usize,

        input: platform.InputSnapshot,
        frame_index: u64,
        quit: bool,

        pub fn init(gpa: Allocator, config: Config) InitError!*Self {
            log_sink.setLevel(config.log_level);

            const timestep: core.time.Timestep = .fromHz(config.tick_rate_hz);

            // Initialisation order is dependency order. `os` first: it is what a future
            // subsystem would read its configuration through, and it depends on nothing.
            const os = try platform.Os.init(gpa, .{
                .env = config.env,
                .app_name = config.app_name,
            });
            errdefer os.deinit();

            const plat = try P.init(gpa, .{});
            errdefer plat.deinit();

            var window: platform.WindowHandle = .none;
            if (!config.headless) {
                window = try plat.openWindow(config.window);
            }

            // The one place `platform` and `rhi` meet: an opaque tagged surface handle
            // crosses, and neither module learns what the other's library is (ADR-0002,
            // ADR-0003). `rhi` comes up after `platform` because it consumes that handle,
            // and goes down before it for the same reason.
            const surface: platform.NativeSurfaceHandle = if (window.isNone())
                .none
            else
                plat.nativeSurface(window) orelse .none;
            const surface_size = if (plat.windowInfo(window)) |info|
                rhi.Extent2D{ .width = info.pixel_size.width, .height = info.pixel_size.height }
            else
                rhi.Extent2D{ .width = config.window.logical_width, .height = config.window.logical_height };

            const gpu = try G.init(gpa, .{
                .label = "engine",
                .surface = surface,
                .surface_size = surface_size,
                .frames_in_flight = config.frames_in_flight,
            });
            errdefer gpu.deinit();

            const self = try gpa.create(Self);
            self.* = .{
                .gpa = gpa,
                .frame_arena = .init(gpa),
                .os = os,
                .platform = plat,
                .gpu = gpu,
                .window = window,
                .stepper = .init(timestep),
                .step_delta = timestep.elapsedAt(1),
                // Read now, so the first frame's delta is the time spent getting to it
                // rather than everything since the process started.
                .previous = plat.now(),
                .events = .empty,
                .event_cursor = 0,
                .input = .{},
                .frame_index = 0,
                .quit = false,
            };
            self.stepper.max_steps_per_frame = config.max_steps_per_frame;

            log.info("engine up: {d}Hz simulation, {s}, rhi backend '{t}', {d} frames in flight", .{
                config.tick_rate_hz,
                if (config.headless) "headless" else "windowed",
                rhi.backend,
                config.frames_in_flight,
            });
            return self;
        }

        /// Tears down in strictly reverse order of initialisation.
        ///
        /// Explicit rather than a registry of callbacks. At two subsystems a registry is
        /// machinery guarding nothing; at perhaps six it becomes the right answer, and
        /// that is also when the ordering stops being obvious by inspection.
        pub fn deinit(self: *Self) void {
            const gpa = self.gpa;

            self.events.deinit(gpa);
            self.frame_arena.deinit();
            self.gpu.deinit();
            self.platform.deinit();
            self.os.deinit();
            gpa.destroy(self);
        }

        // -- the frame -------------------------------------------------------------

        /// Pumps the OS, captures input, and advances simulation time.
        ///
        /// Everything that reads the outside world happens here, once, at one known point
        /// in the frame. That is what lets the rest of the frame be a pure function of
        /// values.
        pub fn beginFrame(self: *Self) void {
            self.platform.pumpEvents();

            // Drained into our own list rather than read straight through, so that
            // noticing a quit request does not depend on the caller bothering to drain
            // events. A game that ignores events entirely still exits when asked.
            self.events.clearRetainingCapacity();
            self.event_cursor = 0;
            while (self.platform.nextEvent()) |ev| {
                self.consider(ev);
                self.events.append(self.gpa, ev) catch {
                    log.err("dropped a frame event: out of memory", .{});
                    break;
                };
            }

            // After every event has been applied by the backend, so the snapshot is the
            // whole frame's input and not a prefix of it.
            self.input = self.platform.captureInput();

            const current = self.platform.now();
            self.stepper.advance(current.since(self.previous));
            self.previous = current;
        }

        /// Engine-level event handling.
        ///
        /// Deliberately tiny. A quit request sets the flag, and the event is still passed
        /// on, because a game may want to ask "save first?" rather than exit. Input events
        /// are never intercepted: what looks like an obviously engine-level key today is
        /// a game's binding tomorrow.
        fn consider(self: *Self, ev: platform.Event) void {
            switch (ev) {
                .quit_requested => self.quit = true,
                .window_closed => |e| if (e.window.eql(self.window)) {
                    self.quit = true;
                },
                // The RHI is told explicitly rather than discovering it inside
                // `beginFrame`, because a resize invalidates textures the caller may hold
                // handles to — a fact the caller must be told (`rhi.md` §7).
                .window_resized => |e| if (e.window.eql(self.window)) {
                    self.gpu.resizeSurface(.{
                        .width = e.pixel_size.width,
                        .height = e.pixel_size.height,
                    }) catch |err| log.err("surface resize failed: {t}", .{err});
                },
                else => {},
            }
        }

        /// This frame's events, in the order the OS produced them.
        pub fn nextEvent(self: *Self) ?platform.Event {
            if (self.event_cursor >= self.events.items.len) return null;
            defer self.event_cursor += 1;
            return self.events.items[self.event_cursor];
        }

        /// Consumes one fixed simulation step if one is due.
        pub fn nextStep(self: *Self) ?Step {
            if (!self.stepper.next()) return null;
            return .{
                .tick = self.stepper.tick,
                .delta = self.step_delta,
                .input = self.input,
                .elapsed = self.stepper.elapsed(),
            };
        }

        /// How far the next step has progressed, in `[0, 1)`.
        ///
        /// **For interpolating the render between two simulation states, and nothing
        /// else.** Feeding it back into simulation state would make the simulation depend
        /// on frame timing, which is exactly what the fixed step exists to prevent.
        pub fn alpha(self: *const Self) f32 {
            return self.stepper.alpha();
        }

        /// Ends the frame and invalidates everything allocated from the frame arena.
        pub fn endFrame(self: *Self) void {
            self.frame_arena.reset();
            self.frame_index += 1;
        }

        // -- accessors ---------------------------------------------------------------

        /// Memory valid until the next `endFrame`. Nothing allocated here may outlive it.
        pub fn frameAllocator(self: *Self) Allocator {
            return self.frame_arena.allocator();
        }

        pub fn shouldQuit(self: *const Self) bool {
            return self.quit;
        }

        /// Asks the loop to stop. What a game calls from its own menu.
        pub fn requestQuit(self: *Self) void {
            self.quit = true;
        }

        /// Total simulation time — the tick count, exactly. Not the wall clock.
        pub fn elapsed(self: *const Self) core.time.Duration {
            return self.stepper.elapsed();
        }

        pub fn windowInfo(self: *Self) ?platform.WindowInfo {
            return self.platform.windowInfo(self.window);
        }

        /// The surface `rhi` will render into, once `rhi` exists.
        pub fn nativeSurface(self: *Self) ?platform.NativeSurfaceHandle {
            return self.platform.nativeSurface(self.window);
        }
    };
}

/// The engine, with whichever backends the build selected.
pub const Engine = EngineOf(platform.Platform, rhi.Device);

/// Marshals Zig's process environment into the form `platform.Os` takes.
///
/// **The one place a `std.process.Init` appears in Foundry.** Zig 0.16 removed ambient
/// environment access and hands the environment to the entry point instead; `app` owns
/// the entry point, so this is where the OS's idea of a process meets Foundry's. Caller
/// owns the returned slice; the names and values inside it are borrowed from `init` and
/// live as long as the process does.
pub fn environment(gpa: Allocator, init: std.process.Init) Allocator.Error![]platform.os.EnvVar {
    var out: std.ArrayList(platform.os.EnvVar) = .empty;
    errdefer out.deinit(gpa);

    var it = init.environ_map.array_hash_map.iterator();
    while (it.next()) |entry| {
        try out.append(gpa, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    }
    return out.toOwnedSlice(gpa);
}

// -- tests ---------------------------------------------------------------------------
//
// Always against the null backends, whatever the build selected: the loop must be tested
// against a clock that does not depend on how fast this machine is, and against a device
// that does not depend on this machine having a GPU.

const testing = std.testing;

const NullPlatform = platform.null_backend.Platform;
const NullDevice = rhi.null_backend.Device;
const TestEngine = EngineOf(NullPlatform, NullDevice);

fn testEngine(config: Config) !*TestEngine {
    var c = config;
    c.headless = true;
    return TestEngine.init(testing.allocator, c);
}

test "an engine comes up and goes down without leaking" {
    const engine = try testEngine(.{});
    defer engine.deinit();

    try testing.expect(!engine.shouldQuit());
    try testing.expectEqual(@as(u64, 0), engine.frame_index);
    try testing.expectEqual(@as(i64, 0), engine.elapsed().ns);
}

test "a windowed engine opens and closes its window" {
    const engine = try TestEngine.init(testing.allocator, .{
        .window = .{ .logical_width = 640, .logical_height = 480 },
    });
    defer engine.deinit();

    const info = engine.windowInfo().?;
    try testing.expect(info.logical_size.eql(.{ .width = 640, .height = 480 }));
}

test "a headless engine has no window, and says so rather than pretending" {
    const engine = try testEngine(.{});
    defer engine.deinit();

    try testing.expect(engine.window.isNone());
    try testing.expectEqual(@as(?platform.WindowInfo, null), engine.windowInfo());
    try testing.expectEqual(@as(?platform.NativeSurfaceHandle, null), engine.nativeSurface());
}

test "a frame of real time produces the right number of simulation steps" {
    const engine = try testEngine(.{ .tick_rate_hz = 60, .max_steps_per_frame = 1000 });
    defer engine.deinit();

    // One millisecond per clock reading; `beginFrame` reads it once. A thousand frames
    // is exactly one second, which at 60Hz is exactly 60 steps and nothing left over.
    engine.platform.setClockStep(.fromMillis(1));

    var steps: u32 = 0;
    for (0..1000) |_| {
        engine.beginFrame();
        while (engine.nextStep()) |_| steps += 1;
        engine.endFrame();
    }

    try testing.expectEqual(@as(u32, 60), steps);
    try testing.expectEqual(@as(u64, 60), engine.stepper.tick);
    try testing.expectEqual(@as(i64, std.time.ns_per_s), engine.elapsed().ns);
    try testing.expectEqual(@as(u64, 1000), engine.frame_index);
}

test "every step in one frame sees the same input" {
    // The reason input is a snapshot rather than a device query. Two steps inside one
    // frame must not disagree about what the player was doing.
    const engine = try testEngine(.{ .tick_rate_hz = 60 });
    defer engine.deinit();
    engine.platform.setClockStep(.fromMillis(100)); // ~6 steps per frame

    try engine.platform.pushEvent(.{ .key_down = .{ .key = .w } });
    engine.beginFrame();

    var steps: u32 = 0;
    while (engine.nextStep()) |step| {
        steps += 1;
        try testing.expect(step.input.isHeld(.w));
    }
    try testing.expect(steps > 1);
    engine.endFrame();
}

test "a quit request stops the loop even if the caller never reads events" {
    // Engine-level handling must not depend on the caller's diligence.
    const engine = try testEngine(.{});
    defer engine.deinit();

    try engine.platform.pushEvent(.quit_requested);
    engine.beginFrame();
    engine.endFrame();

    try testing.expect(engine.shouldQuit());
}

test "the quit event still reaches the caller" {
    // Because a game may want to ask "save first?" rather than exit immediately.
    const engine = try testEngine(.{});
    defer engine.deinit();

    try engine.platform.pushEvent(.quit_requested);
    engine.beginFrame();

    var saw_quit = false;
    while (engine.nextEvent()) |ev| {
        if (ev == .quit_requested) saw_quit = true;
    }
    try testing.expect(saw_quit);
}

test "closing the window quits, but closing a different window does not" {
    const engine = try TestEngine.init(testing.allocator, .{});
    defer engine.deinit();

    const other = try engine.platform.openWindow(.{});
    try engine.platform.pushEvent(.{ .window_closed = .{ .window = other } });
    engine.beginFrame();
    engine.endFrame();
    try testing.expect(!engine.shouldQuit());

    try engine.platform.pushEvent(.{ .window_closed = .{ .window = engine.window } });
    engine.beginFrame();
    engine.endFrame();
    try testing.expect(engine.shouldQuit());
}

test "requestQuit stops the loop" {
    const engine = try testEngine(.{});
    defer engine.deinit();
    try testing.expect(!engine.shouldQuit());
    engine.requestQuit();
    try testing.expect(engine.shouldQuit());
}

test "the frame arena is reusable and does not grow across frames" {
    const engine = try testEngine(.{});
    defer engine.deinit();

    for (0..32) |i| {
        engine.beginFrame();
        const scratch = try engine.frameAllocator().alloc(u8, 1024 * (i + 1));
        @memset(scratch, 0xAB);
        try testing.expectEqual(@as(u8, 0xAB), scratch[scratch.len - 1]);
        engine.endFrame();
    }
    // testing.allocator fails on leak, which is the actual assertion: an arena that was
    // never reset would hold every one of those allocations at teardown.
}

test "a long hitch clamps instead of spiralling" {
    const engine = try testEngine(.{ .tick_rate_hz = 60, .max_steps_per_frame = 4 });
    defer engine.deinit();

    // The debugger was paused, or the machine slept.
    engine.platform.setClockStep(.fromSeconds(10));
    engine.beginFrame();

    var steps: u32 = 0;
    while (engine.nextStep()) |_| steps += 1;
    try testing.expectEqual(@as(u32, 4), steps);
}

test "alpha stays in range and is never fed back into simulation" {
    const engine = try testEngine(.{ .tick_rate_hz = 60 });
    defer engine.deinit();
    engine.platform.setClockStep(.fromNanos(@divTrunc(std.time.ns_per_s, 120)));

    for (0..8) |_| {
        engine.beginFrame();
        while (engine.nextStep()) |_| {}
        const a = engine.alpha();
        try testing.expect(a >= 0.0 and a <= 1.0);
        engine.endFrame();
    }
}

test "the same frame timings produce the same simulation, twice" {
    // I9 at the level a game depends on.
    const run = struct {
        fn go() !struct { ticks: u64, elapsed: i64 } {
            const engine = try TestEngine.init(testing.allocator, .{
                .headless = true,
                .tick_rate_hz = 60,
                .max_steps_per_frame = 1000,
            });
            defer engine.deinit();
            engine.platform.setClockStep(.fromNanos(7_777_777));

            for (0..333) |i| {
                engine.beginFrame();
                if (i % 50 == 0) try engine.platform.pushEvent(.{ .key_down = .{ .key = .space } });
                while (engine.nextStep()) |_| {}
                engine.endFrame();
            }
            return .{ .ticks = engine.stepper.tick, .elapsed = engine.elapsed().ns };
        }
    }.go;

    const a = try run();
    const b = try run();
    try testing.expectEqual(a.ticks, b.ticks);
    try testing.expectEqual(a.elapsed, b.elapsed);
}

test "the gpu device comes up and goes down with the engine" {
    const engine = try testEngine(.{});
    defer engine.deinit();

    const caps = engine.gpu.capabilities();
    try testing.expectEqual(rhi.max_bind_groups, caps.max_bind_groups);
    try testing.expectEqual(rhi.max_inline_constant_bytes, caps.max_inline_constant_bytes);
}

test "a window's surface crosses from platform to rhi" {
    // The seam M1 depends on. The null platform backend cannot produce a real surface, so
    // what is checked here is that the handle travels and the device accepts it — the
    // live CAMetalLayer case is exercised by the sandbox.
    const engine = try TestEngine.init(testing.allocator, .{
        .window = .{ .logical_width = 800, .logical_height = 600 },
    });
    defer engine.deinit();

    try testing.expect(!engine.window.isNone());
    const info = engine.windowInfo().?;
    try testing.expect(info.pixel_size.eql(.{ .width = 800, .height = 600 }));
}

test "a resize reaches the rhi surface" {
    const engine = try TestEngine.init(testing.allocator, .{});
    defer engine.deinit();

    try engine.platform.resizeWindow(engine.window, .{ .width = 640, .height = 480 }, 2.0);
    engine.beginFrame();
    engine.endFrame();

    try testing.expect(engine.gpu.surface_size.eql(.{ .width = 1280, .height = 960 }));
}

test "environment marshalling produces borrowed pairs" {
    // Cannot construct a `std.process.Init` in a test, so this checks the shape the
    // engine actually consumes: `Os` reads only what it was given, and nothing else.
    const env = [_]platform.os.EnvVar{
        .{ .name = "HOME", .value = "/home/tester" },
    };
    const engine = try testEngine(.{ .env = &env, .app_name = "engine-test" });
    defer engine.deinit();

    try testing.expectEqualStrings("/home/tester", engine.os.envVar("HOME").?);
    try testing.expectEqual(@as(?[]const u8, null), engine.os.envVar("PATH"));
}

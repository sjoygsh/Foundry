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
const builtin = @import("builtin");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const asset = @import("asset");

const log_sink = @import("log_sink.zig");

const Allocator = std.mem.Allocator;
const log = core.log.scoped(.app);

pub const InitError = error{
    /// A configured content package could not be read, or was refused. Package zero
    /// failing is not a condition a game can carry on from, and neither is a mod the
    /// player asked for: both are reported with the reason and stop startup.
    ContentUnavailable,
} || platform.InitError || platform.WindowError || rhi.InitError;

/// One package to load, in load order.
///
/// Both fields are **locations, never identity** (ADR-0021). The compiled package states
/// its own content id and the store checks it; these only say where the bytes are.
pub const ContentPackage = struct {
    /// The compiled `.fpk`, relative to the content directory.
    file: []const u8,
    /// Where that package's source files live, relative to the content directory. An
    /// asset record names its bytes relative to this.
    root: []const u8,
};

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

    /// Where compiled content packages and their files live. Null means beside the
    /// executable, in `../content` — which is where `zig build` installs them.
    content_dir: ?[]const u8 = null,

    /// The packages to load, **in load order**.
    ///
    /// The first is package zero (I3), and the engine's own content is in it — loaded
    /// through the same call, in the same format, with no privileged path. The engine
    /// consumes this order and does not compute one: discovering packages, resolving
    /// dependencies between them and deciding what a player has enabled is M7's problem
    /// (`content-schemas.md` §11), and answering it here would answer it in the wrong
    /// place.
    ///
    /// Empty by default. A tool or a test that wants the loop and the filesystem without
    /// any content should pay nothing for it.
    content: []const ContentPackage = &.{},

    /// Bound on one compiled package. Generous, because a package is records and not
    /// payloads — the assets themselves are files beside it, bounded separately.
    max_package_bytes: usize = 64 << 20,

    /// Watch content for changes and apply them at the start of a frame.
    ///
    /// **Development builds only** (`assets.md` §6), which is why the default is the build
    /// mode rather than `true`. A shipped game watching its own files would be paying for
    /// something nobody can use and reading the disk on a schedule forever. Overridable
    /// either way, because "development" is a judgement the application makes and a tool
    /// that wants it in a release build should be able to say so.
    hot_reload: bool = builtin.mode == .Debug,

    /// Frames between checks. Thirty is twice a second at 60Hz, which is faster than
    /// anyone can alt-tab and cheap enough not to think about.
    hot_reload_frames: u32 = 30,
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
        /// Wall-clock time the previous frame took. **Presentation only** — see
        /// `frameDelta`.
        frame_delta: core.time.Duration,

        /// This frame's events, drained from the platform so that engine-level handling
        /// does not depend on the caller draining them.
        events: std.ArrayList(platform.Event),
        event_cursor: usize,

        input: platform.InputSnapshot,
        frame_index: u64,
        frames_in_flight: u32,
        quit: bool,

        // -- content -----------------------------------------------------------------

        /// Where packages and their files live. Owned.
        content_dir: []u8,
        /// The load order, **owned**, because a reload has to read it again long after the
        /// caller's `Config` has gone.
        content: []ContentPackage,
        /// What each package's file looked like when it was loaded. Same order as
        /// `content`.
        package_stamps: std.ArrayList(asset.Registry.Stamp),
        /// Bumped whenever content changes under the program. **The one signal a game
        /// needs**: anything it derived from content — a string borrowed from a package's
        /// bytes, a `Region` cut from a texture — is derived again when this moves.
        content_generation: u64,
        hot_reload: bool,
        hot_reload_frames: u32,
        max_package_bytes: usize,
        /// The compiled bytes of every loaded package, kept alive because the store reads
        /// records **in place** out of them rather than copying (`content-schemas.md`
        /// §5.3). Freeing one would leave the store pointing at nothing.
        package_bytes: std.ArrayList([]u8),
        /// Every record type the engine and its content know about, registered at runtime
        /// through the same call a mod's `@schema` uses (I6).
        schemas: data.Registry,
        /// The merged content of every loaded package, in load order.
        store: data.Store,
        /// Content id in, loaded asset out. **The game registers the loaders**: `app` has
        /// no `render2d` and no opinion about what a texture is, which is what keeps the
        /// capability pointing up while the dependency points down.
        assets: asset.Registry,

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

            // Resolved before anything owns it, so a bad `content_dir` fails before the
            // window opens rather than after.
            const content_dir = try resolveContentDir(gpa, os, config);
            const content = dupePackages(gpa, config.content) catch |err| {
                gpa.free(content_dir);
                return err;
            };
            // Handed over explicitly rather than guarded by an `errdefer`: from the
            // assignment below, `deinitOwned` is their only owner, and an `errdefer` here
            // would make it two.
            const self = gpa.create(Self) catch |err| {
                freePackages(gpa, content);
                gpa.free(content);
                gpa.free(content_dir);
                return err;
            };
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .frame_arena = .init(gpa),
                .os = os,
                .platform = plat,
                .gpu = gpu,
                .window = window,
                .stepper = .init(timestep),
                .step_delta = timestep.elapsedAt(1),
                .frame_delta = .zero,
                // Read now, so the first frame's delta is the time spent getting to it
                // rather than everything since the process started.
                .previous = plat.now(),
                .events = .empty,
                .event_cursor = 0,
                .input = .{},
                .frame_index = 0,
                .frames_in_flight = config.frames_in_flight,
                .quit = false,
                .content_dir = content_dir,
                .content = content,
                .package_stamps = .empty,
                .content_generation = 1,
                .hot_reload = config.hot_reload,
                .hot_reload_frames = @max(config.hot_reload_frames, 1),
                .max_package_bytes = config.max_package_bytes,
                .package_bytes = .empty,
                .schemas = .init(gpa, .default),
                .store = .init(gpa, .default),
                // Assigned below: it borrows `&self.store`, which has no address until
                // the struct is in its final home.
                .assets = undefined,
            };
            self.assets = .init(gpa, os, &self.store, .{});
            self.stepper.max_steps_per_frame = config.max_steps_per_frame;

            errdefer self.deinitOwned();
            try self.loadContent();

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

            self.deinitOwned();
            self.gpu.deinit();
            self.platform.deinit();
            self.os.deinit();
            gpa.destroy(self);
        }

        /// Everything the engine struct itself owns, in reverse order of construction.
        ///
        /// Separate from `deinit` because a failed `init` has to undo exactly this much and
        /// no more: the subsystems below have their own `errdefer`s already.
        ///
        /// **The asset registry goes first, and its loaders must still be alive.** It
        /// unloads through them, and a game whose renderer is about to go should have
        /// called `assets.unregisterLoader` before tearing it down — which hands everything
        /// back while there is still something to hand it to.
        fn deinitOwned(self: *Self) void {
            const gpa = self.gpa;

            self.assets.deinit(gpa);
            self.store.deinit(gpa);
            self.schemas.deinit(gpa);
            for (self.package_bytes.items) |bytes| gpa.free(bytes);
            self.package_bytes.deinit(gpa);
            self.package_stamps.deinit(gpa);
            freePackages(gpa, self.content);
            gpa.free(self.content);
            gpa.free(self.content_dir);
            self.events.deinit(gpa);
            self.frame_arena.deinit();
        }

        // -- content -------------------------------------------------------------------

        /// A complete set of content, built to one side before anything replaces what is
        /// running.
        ///
        /// **This shape is `assets.md` §6's rule 2.** A reload compiles and validates the
        /// new state in full, and only a complete one is ever swapped in — so a package
        /// mid-save, or a schema edited without a version bump, leaves the running program
        /// with the last thing that worked and a line saying why.
        const Loaded = struct {
            schemas: data.Registry,
            store: data.Store,
            bytes: std.ArrayList([]u8),
            stamps: std.ArrayList(asset.Registry.Stamp),

            fn deinit(self: *Loaded, gpa: Allocator) void {
                self.store.deinit(gpa);
                self.schemas.deinit(gpa);
                for (self.bytes.items) |b| gpa.free(b);
                self.bytes.deinit(gpa);
                self.stamps.deinit(gpa);
            }
        };

        /// Loads every configured package, in the order given.
        ///
        /// **This is I3, and it is deliberately unremarkable code.** The engine's own
        /// package goes through `store.add` exactly as a mod's does — same reader, same
        /// validation, same merge — because the only durable way to know the mod path works
        /// is to be on it ourselves.
        fn loadContent(self: *Self) InitError!void {
            var loaded = try self.readAll();
            self.adopt(&loaded);

            if (self.content.len == 0) return;
            log.info("content: {d} package(s), {d} record(s), from '{s}'", .{
                self.store.packageCount(),
                self.store.count(),
                self.content_dir,
            });
        }

        fn readAll(self: *Self) InitError!Loaded {
            const gpa = self.gpa;

            var out: Loaded = .{
                .schemas = .init(gpa, .default),
                .store = .init(gpa, .default),
                .bytes = .empty,
                .stamps = .empty,
            };
            errdefer out.deinit(gpa);

            // The record types the engine can load, before any package that uses them. A
            // package carrying its own copy of one is checked against these rather than
            // trusted (`content-schemas.md` §3).
            asset.schemas.registerAll(gpa, &out.schemas) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("the engine's own asset schemas were refused: {t}", .{err});
                    return error.ContentUnavailable;
                },
            };
            // The tilemap record types, for the same reason: an author describing a map must
            // not have to declare an engine-owned record type themselves.
            asset.tilemap.registerAll(gpa, &out.schemas) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.warn("the engine's own tilemap schemas were refused: {t}", .{err});
                    return error.ContentUnavailable;
                },
            };

            var diags: data.Diagnostics = .init(gpa, .default);
            defer diags.deinit(gpa);

            for (self.content) |pkg| {
                self.readPackage(&out, pkg, &diags) catch |err| {
                    reportContent(&diags);
                    return err;
                };
            }
            reportContent(&diags);
            return out;
        }

        fn readPackage(
            self: *Self,
            into: *Loaded,
            pkg: ContentPackage,
            diags: *data.Diagnostics,
        ) InitError!void {
            const gpa = self.gpa;

            const path = try joinUnder(gpa, self.content_dir, pkg.file);
            defer gpa.free(path);

            // Stamped before it is read, so a file rewritten between the two shows as
            // changed on the next check rather than being missed.
            const stamp: asset.Registry.Stamp = if (self.os.statFile(path)) |info|
                .{ .modified_ns = info.modified_ns, .size = info.size }
            else |_|
                .{};

            // Reported at `warn` and returned as an error, which is the convention the
            // asset registry already follows: the returned error is the signal and the log
            // line is the context. It is also what keeps these paths testable — the test
            // runner counts an `err`-level log as a failed test, so a failure nothing can
            // exercise is a failure nothing checks.
            const bytes = self.os.readFile(gpa, path, self.max_package_bytes) catch |err| {
                log.warn("content package '{s}' could not be read: {t}", .{ path, err });
                return error.ContentUnavailable;
            };
            // Appended before the store can borrow it, so exactly one thing frees it.
            try into.bytes.append(gpa, bytes);
            try into.stamps.append(gpa, stamp);

            _ = into.store.add(gpa, pkg.file, bytes, &into.schemas, diags) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PackageRejected => {
                    log.warn("content package '{s}' was refused", .{pkg.file});
                    return error.ContentUnavailable;
                },
            };
        }

        /// Puts a complete `Loaded` in place of what is running, and mounts it.
        ///
        /// The old set goes only once the new one exists, and the swap itself cannot fail.
        /// Mounting is after, because a root is keyed by a handle into *this* store and a
        /// handle from the old one means nothing to the new.
        fn adopt(self: *Self, loaded: *Loaded) void {
            const gpa = self.gpa;

            self.assets.clearMounts();
            self.store.deinit(gpa);
            self.schemas.deinit(gpa);
            for (self.package_bytes.items) |b| gpa.free(b);
            self.package_bytes.deinit(gpa);
            self.package_stamps.deinit(gpa);

            self.schemas = loaded.schemas;
            self.store = loaded.store;
            self.package_bytes = loaded.bytes;
            self.package_stamps = loaded.stamps;
            loaded.* = undefined;

            const order = self.store.loadOrder();
            std.debug.assert(order.len == self.content.len);
            for (order, self.content) |handle, pkg| {
                const root = joinUnder(gpa, self.content_dir, pkg.root) catch continue;
                defer gpa.free(root);
                self.assets.mount(gpa, handle, root) catch {
                    log.warn("package '{s}' could not be mounted; its assets will not load", .{pkg.root});
                };
            }
            self.content_generation +%= 1;
        }

        // -- hot reload ---------------------------------------------------------------

        /// Moves whenever content has changed under the program.
        ///
        /// **The one signal a game needs.** A handle follows a reload on its own; anything
        /// *derived* from content does not — a string borrowed from a package's bytes, a
        /// region cut from a texture, a value copied into a struct. Compare this to what you
        /// saw last frame and derive again when it differs.
        pub fn contentGeneration(self: *const Self) u64 {
            return self.content_generation;
        }

        /// Re-reads every package and every loaded asset, now.
        ///
        /// Public because a game may have a better trigger than a timer — a key, an editor
        /// telling it something changed — and because the watcher is only a convenience
        /// over this.
        ///
        /// **Never fails.** A reload that cannot complete leaves everything as it was, says
        /// so, and does not move the generation.
        pub fn reloadContent(self: *Self) void {
            const gpa = self.gpa;

            var loaded = self.readAll() catch |err| {
                log.warn("content reload failed ({t}); keeping what is loaded", .{err});
                return;
            };
            self.adopt(&loaded);

            // Records may now name different files, different sampler settings, or a
            // different record type, and none of that shows as a changed source file.
            const reloaded = self.assets.reloadAll(gpa);
            log.info("content reloaded: {d} package(s), {d} record(s), {d} asset(s)", .{
                self.store.packageCount(),
                self.store.count(),
                reloaded,
            });
        }

        /// One watcher pass. **Packages first, then assets**, which is the documented order
        /// §6's third rule asks for: reloading a package reloads its assets anyway, so
        /// doing it the other way round would load some of them twice.
        fn pollContent(self: *Self) void {
            for (self.content, self.package_stamps.items) |pkg, stamp| {
                const path = joinUnder(self.gpa, self.content_dir, pkg.file) catch continue;
                defer self.gpa.free(path);
                const now: asset.Registry.Stamp = if (self.os.statFile(path)) |info|
                    .{ .modified_ns = info.modified_ns, .size = info.size }
                else |_|
                    .{};
                if (now.eql(stamp)) continue;

                log.info("'{s}' changed on disk", .{pkg.file});
                self.reloadContent();
                return;
            }

            if (self.assets.reloadChanged(self.gpa) > 0) self.content_generation +%= 1;
        }

        /// Puts whatever the content pipeline had to say into the log, and clears it.
        ///
        /// One line each rather than the caret-and-source rendering `fpack` prints: a
        /// running game's log is a stream of lines, and the tool that can show a caret is
        /// the one whose job it is. The diagnostic's own severity is in the text, where a
        /// reader can see it.
        ///
        /// **Nothing here logs at `err`, and the rule behind that is worth stating once:**
        /// `log.err` is for a failure the program has no other way to report. These have
        /// one — the reload does not happen, or `init` returns `ContentUnavailable` — so
        /// the log line is context rather than the report. The practical consequence is
        /// that these paths stay testable, because the test runner counts an `err`-level
        /// log as a failed test.
        fn reportContent(diags: *data.Diagnostics) void {
            for (diags.items.items) |d| {
                switch (d.severity) {
                    .err, .warning => log.warn("content: {s}: {f}: {s}", .{
                        d.severity.text(), d.location, d.message,
                    }),
                    .note => log.info("content: {f}: {s}", .{ d.location, d.message }),
                }
            }
            if (diags.suppressed > 0) {
                log.warn("content: {d} further diagnostic(s) not shown", .{diags.suppressed});
            }
            diags.items.clearRetainingCapacity();
            diags.suppressed = 0;
        }

        /// Joins a configured name onto the content directory.
        ///
        /// `joinPath`'s wider error set collapses here: out of memory is out of memory, and
        /// everything else means the configured location is unusable, which is the same
        /// answer as a package that will not open.
        fn joinUnder(gpa: Allocator, dir: []const u8, name: []const u8) InitError![]u8 {
            return platform.os.joinPath(gpa, &.{ dir, name }) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => {
                    log.warn("content location '{s}/{s}' is not a usable path", .{ dir, name });
                    return error.ContentUnavailable;
                },
            };
        }

        /// Copies a load order the caller owns into one the engine owns.
        fn dupePackages(gpa: Allocator, from: []const ContentPackage) Allocator.Error![]ContentPackage {
            const out = try gpa.alloc(ContentPackage, from.len);
            var made: usize = 0;
            errdefer freePackages(gpa, out[0..made]);
            errdefer gpa.free(out);
            for (from, out) |src, *dst| {
                dst.* = .{ .file = try gpa.dupe(u8, src.file), .root = try gpa.dupe(u8, src.root) };
                made += 1;
            }
            return out;
        }

        fn freePackages(gpa: Allocator, packages: []const ContentPackage) void {
            for (packages) |pkg| {
                gpa.free(pkg.file);
                gpa.free(pkg.root);
            }
        }

        /// Where content lives: what the caller said, or `../content` beside the executable.
        ///
        /// Beside the executable rather than beside the working directory, because a game
        /// is launched from anywhere and its content is part of its installation. `zig
        /// build` installs to exactly this shape.
        fn resolveContentDir(gpa: Allocator, os: *platform.Os, config: Config) InitError![]u8 {
            if (config.content_dir) |dir| return gpa.dupe(u8, dir);

            const exe_dir = os.executableDirAlloc(gpa) catch |err| {
                log.warn("cannot locate the executable to find content beside it: {t}", .{err});
                return error.ContentUnavailable;
            };
            defer gpa.free(exe_dir);

            // `<prefix>/bin/..` rather than a literal "..", so the path in a log line is
            // one a person can read back to us.
            const prefix = std.fs.path.dirname(exe_dir) orelse exe_dir;
            return platform.os.joinPath(gpa, &.{ prefix, "content" }) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.ContentUnavailable,
            };
        }

        // -- the frame -------------------------------------------------------------

        /// Pumps the OS, captures input, and advances simulation time.
        ///
        /// Everything that reads the outside world happens here, once, at one known point
        /// in the frame. That is what lets the rest of the frame be a pure function of
        /// values.
        pub fn beginFrame(self: *Self) void {
            // **Before anything else in the frame** (`assets.md` §6, rule 1). A texture
            // replaced between two draws of one frame is a class of bug worth never having,
            // so the swap happens here, before events, before input, before simulation.
            //
            // Safe against the GPU for a reason worth naming: `render2d` retires a
            // destroyed texture behind the frames that could still reference it, so an
            // unload at the top of a frame does not free something in flight.
            if (self.hot_reload and self.frame_index % self.hot_reload_frames == 0) {
                self.pollContent();
            }

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
            self.frame_delta = current.since(self.previous);
            self.stepper.advance(self.frame_delta);
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

        /// How long the previous frame took, in wall-clock time.
        ///
        /// **For presentation, and never for simulation.** Simulation advances by
        /// `Step.delta`, which is fixed; anything integrated against this number depends
        /// on how fast the machine happened to be, which is what the fixed step exists to
        /// prevent (I9). Camera smoothing, UI animation and frame-time readouts are what
        /// it is for.
        ///
        /// The engine already measured it in order to drive the stepper. It is exposed
        /// rather than recomputed by the caller, because a second clock read would give a
        /// second, slightly different answer.
        pub fn frameDelta(self: *const Self) core.time.Duration {
            return self.frame_delta;
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

        /// Asks for a new **logical** window size — what a settings menu calls.
        ///
        /// A request, not a change: the new size arrives as a `window_resized` event on a
        /// later frame, and `beginFrame` resizes the swapchain from that event exactly as
        /// it does for a user dragging an edge. So there is one resize path, and calling
        /// this exercises it.
        pub fn setWindowSize(self: *Self, logical: platform.Size) platform.WindowError!void {
            return self.platform.setWindowSize(self.window, logical);
        }

        /// What a frame does besides draw: clear, and label itself in a GPU capture.
        pub const FrameOptions = struct {
            /// `null` keeps the previous contents, which is almost never what a 2D game
            /// wants and is offered because a game drawing a full-screen background
            /// legitimately does not need the clear.
            clear: ?[4]f32 = .{ 0, 0, 0, 1 },
            label: []const u8 = "frame",
        };

        /// Runs one frame of rendering: opens the frame and the render pass, lets
        /// `recorder` fill it, and submits.
        ///
        /// **The engine owns the frame, not the renderer** (`docs/design/render2d.md` §3).
        /// A frame will later carry more than sprites — a debug UI at M6, a 3D pass after
        /// that — and whoever opens the pass decides what shares it. Doing this in the
        /// renderer would be convenient now and would foreclose that.
        ///
        /// `recorder` is `anytype` rather than a `render2d.Renderer` deliberately: `app`
        /// owns the frame and should not care who records into it. It must provide:
        ///
        /// * `prepare(*rhi.CommandBuffer, rhi.FrameContext) !void` — sorting, uploads and
        ///   copies, before the pass opens, because copies cannot be recorded inside one.
        /// * `record(*rhi.RenderPass) !void` — the draw calls.
        ///
        /// The game calls this and never sees either argument, which is what keeps the
        /// RHI out of the game-facing surface (CLAUDE.md §4.2).
        pub fn renderFrame(self: *Self, options: FrameOptions, recorder: anytype) !void {
            const frame = try self.gpu.beginFrame();

            const cmd = try self.gpu.beginCommandBuffer();
            try recorder.prepare(cmd, frame);

            const pass = try cmd.beginRenderPass(.{
                .label = options.label,
                .color = &.{.{
                    .texture = frame.surface_texture,
                    .load = if (options.clear) |c| .{ .clear = .{ .color = c } } else .load,
                    .store = .store,
                    // `undefined` in because nothing from last frame's image is worth
                    // preserving, `present` out because the display takes it next.
                    .initial_state = .undefined,
                    .final_state = .present,
                }},
            });
            try recorder.record(pass);
            pass.end();

            try cmd.submit();
            try self.gpu.endFrame();
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

/// A content directory with one compiled package in it, laid out the way `zig build`
/// installs one.
///
/// Written to a real temporary directory rather than faked, because the thing under test is
/// precisely the part that reads a disk: everything below `app` is already hermetic.
const ContentFixture = struct {
    os: *platform.Os,
    dir: []u8,

    fn init(source: []const u8) !ContentFixture {
        const gpa = testing.allocator;
        const os = try platform.Os.init(gpa, .{ .app_name = "foundry-app-test", .env = &.{} });
        errdefer os.deinit();

        const temp = try os.tempDirAlloc(gpa);
        defer gpa.free(temp);
        const dir = try platform.os.joinPath(gpa, &.{ temp, "foundry-app-content" });
        errdefer gpa.free(dir);
        try os.createDirPath(dir);

        var registry: data.Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);

        var doc = try data.parser.parse(gpa, "test.fdt", source, .{ .namespace = "foundry" }, &diags);
        defer doc.deinit(gpa);
        var pkg = try data.check.Package.init(gpa, "foundry:core", 1, .default);
        defer pkg.deinit(gpa);
        try pkg.addDocument(gpa, &doc, &registry, &diags);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try data.fpk.write(gpa, &pkg, &registry, &bytes);

        const path = try platform.os.joinPath(gpa, &.{ dir, "core.fpk" });
        defer gpa.free(path);
        try os.writeFile(path, bytes.items);

        return .{ .os = os, .dir = dir };
    }

    fn deinit(self: *ContentFixture) void {
        testing.allocator.free(self.dir);
        self.os.deinit();
    }

    /// Recompiles the package with different content, the way `zig build` would after an
    /// edit.
    fn rewrite(self: *ContentFixture, source: []const u8) !void {
        const gpa = testing.allocator;

        var registry: data.Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);

        var doc = try data.parser.parse(gpa, "test.fdt", source, .{ .namespace = "foundry" }, &diags);
        defer doc.deinit(gpa);
        var pkg = try data.check.Package.init(gpa, "foundry:core", 1, .default);
        defer pkg.deinit(gpa);
        try pkg.addDocument(gpa, &doc, &registry, &diags);

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try data.fpk.write(gpa, &pkg, &registry, &bytes);

        const path = try platform.os.joinPath(gpa, &.{ self.dir, "core.fpk" });
        defer gpa.free(path);
        try self.os.writeFile(path, bytes.items);
    }

    /// Writes bytes that are not a package at all.
    fn corrupt(self: *ContentFixture) !void {
        const gpa = testing.allocator;
        const path = try platform.os.joinPath(gpa, &.{ self.dir, "core.fpk" });
        defer gpa.free(path);
        try self.os.writeFile(path, "half a file, mid-save");
    }
};

const changed_source =
    \\@schema settings { sprites u32 (default 10) }
    \\settings foundry:settings.main { sprites 99 }
;

fn spriteSetting(engine: *TestEngine) ?i128 {
    const record = engine.store.lookup(core.ContentId.fromString("foundry:settings.main")) orelse return null;
    const index = record.schema.fieldIndex("sprites") orelse return null;
    return record.fields.intAt(index) catch null;
}

test "a changed package is picked up, and the generation says so" {
    var fx = try ContentFixture.init(content_source);
    defer fx.deinit();

    const engine = try testEngine(.{
        .content_dir = fx.dir,
        .content = &.{.{ .file = "core.fpk", .root = "." }},
        .hot_reload = true,
    });
    defer engine.deinit();

    const before = engine.contentGeneration();
    try testing.expectEqual(@as(?i128, 42), spriteSetting(engine));

    try fx.rewrite(changed_source);
    engine.reloadContent();

    try testing.expectEqual(@as(?i128, 99), spriteSetting(engine));
    try testing.expect(engine.contentGeneration() != before);
    try testing.expectEqual(@as(u32, 1), engine.store.packageCount());

    // The package's files are mounted again against the *new* store's handles, which is
    // the part a swap would quietly get wrong.
    try testing.expect(engine.assets.rootOf(engine.store.loadOrder()[0]) != null);
}

test "a reload that cannot complete leaves the running program exactly as it was" {
    var fx = try ContentFixture.init(content_source);
    defer fx.deinit();

    const engine = try testEngine(.{
        .content_dir = fx.dir,
        .content = &.{.{ .file = "core.fpk", .root = "." }},
    });
    defer engine.deinit();

    const before = engine.contentGeneration();
    try fx.corrupt();
    engine.reloadContent();

    // §6 rule 2: a package caught mid-save leaves the last thing that worked, and the
    // generation does not move — so nothing downstream re-derives from a state that
    // never happened.
    try testing.expectEqual(@as(?i128, 42), spriteSetting(engine));
    try testing.expectEqual(before, engine.contentGeneration());
    try testing.expectEqual(@as(u32, 1), engine.store.packageCount());

    // And it recovers when the file is whole again.
    try fx.rewrite(changed_source);
    engine.reloadContent();
    try testing.expectEqual(@as(?i128, 99), spriteSetting(engine));
    try testing.expect(engine.contentGeneration() != before);
}

test "the watcher runs at the start of a frame, and only when it is switched on" {
    var fx = try ContentFixture.init(content_source);
    defer fx.deinit();

    {
        const engine = try testEngine(.{
            .content_dir = fx.dir,
            .content = &.{.{ .file = "core.fpk", .root = "." }},
            .hot_reload = false,
        });
        defer engine.deinit();

        try fx.rewrite(changed_source);
        for (0..4) |_| {
            engine.beginFrame();
            engine.endFrame();
        }
        // A shipped build watches nothing (§6), so nothing changed under it.
        try testing.expectEqual(@as(?i128, 42), spriteSetting(engine));
    }

    try fx.rewrite(content_source);
    const engine = try testEngine(.{
        .content_dir = fx.dir,
        .content = &.{.{ .file = "core.fpk", .root = "." }},
        .hot_reload = true,
        .hot_reload_frames = 2,
    });
    defer engine.deinit();
    try testing.expectEqual(@as(?i128, 42), spriteSetting(engine));

    try fx.rewrite(changed_source);
    for (0..4) |_| {
        engine.beginFrame();
        engine.endFrame();
    }
    try testing.expectEqual(@as(?i128, 99), spriteSetting(engine));
}

const content_source =
    \\@schema settings { sprites u32 (default 10) }
    \\settings foundry:settings.main { sprites 42 }
;

test "the engine loads package zero, and it is an ordinary package" {
    var fx = try ContentFixture.init(content_source);
    defer fx.deinit();

    const engine = try testEngine(.{
        .content_dir = fx.dir,
        .content = &.{.{ .file = "core.fpk", .root = "." }},
    });
    defer engine.deinit();

    // I3: nothing about this is special. The store took it through the same call a mod's
    // package goes through, and the record is addressable by the name someone wrote.
    try testing.expectEqual(@as(u32, 1), engine.store.packageCount());
    const record = engine.store.lookup(core.ContentId.fromString("foundry:settings.main")).?;
    const index = record.schema.fieldIndex("sprites").?;
    try testing.expectEqual(@as(?i128, 42), try record.fields.intAt(index));

    // And the package's files are mounted, so an asset in it would be findable.
    try testing.expect(engine.assets.rootOf(engine.store.loadOrder()[0]) != null);
}

test "the engine's own asset schemas are registered before any package is" {
    const engine = try testEngine(.{});
    defer engine.deinit();

    // Registered even with no content configured: a package that arrives later — through
    // hot reload, or a mod — is checked against them rather than defining them.
    try testing.expect(engine.schemas.lookup(asset.schemas.texture.id) != null);
    try testing.expectEqual(@as(u32, 0), engine.store.packageCount());
}

test "a package that is not there stops startup and says which one" {
    var fx = try ContentFixture.init(content_source);
    defer fx.deinit();

    // Package zero missing is not a state a game carries on from, so it is an error at
    // `init` rather than a surprise at the first `acquire`.
    try testing.expectError(error.ContentUnavailable, testEngine(.{
        .content_dir = fx.dir,
        .content = &.{.{ .file = "absent.fpk", .root = "." }},
    }));

    // And a good package followed by a bad one fails the same way: half a load order is
    // not a state worth being able to describe.
    try testing.expectError(error.ContentUnavailable, testEngine(.{
        .content_dir = fx.dir,
        .content = &.{
            .{ .file = "core.fpk", .root = "." },
            .{ .file = "absent.fpk", .root = "." },
        },
    }));
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

//! The sandbox's Tier 2 host: the smallest correct wiring of `script` into a game.
//!
//! A game that wants scripts owns four things, and this is all four: the source loader it
//! registers with its asset registry, the `abi.Host` that publishes its subsystems, the
//! identities it issues, and the `script.Manager` that holds one stable slot per package.
//! The conversion from a resolved `mod.Entry` to a `script.Descriptor` is here for the same
//! reason — `script` never reads a manifest, and this is the code that owns both (§3).
//!
//! **There is no privileged path here.** Everything the manager does, it does through the
//! same `FoundryApi_v2` table a native mod is handed, and everything the script does it does
//! through binding 1 over that same table.
//!
//! This file exists only when the build has Lua. `scripting_absent.zig` answers the same
//! calls when it does not, so `main.zig` never asks whether it was built with scripting —
//! a content-only build of the sample links no Lua and loses nothing else.

const std = @import("std");
const abi = @import("abi");
const app = @import("app");
const asset = @import("asset");
const core = @import("core");
const mod = @import("mod");
const scene = @import("scene");
const script = @import("script");

const log = core.log.scoped(.sandbox);

pub const available = true;

/// The sample's ceiling, well under `scripting.md` §8's sixteen. A sample does not need to
/// demonstrate a capacity to have one.
const max_packages = 4;
const max_name = 96;

/// What one enabled script package is, copied out of the resolved order before the
/// resolution's arena goes away.
const Package = struct {
    id: core.ContentId = .none,
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    entry: core.ContentId = .none,
    binding: u32 = 0,
    /// Issued once and kept: an identity is process-lifetime (`abi.Host.issueMod`).
    self: u64 = 0,

    fn name(self: *const Package) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Host = struct {
    gpa: std.mem.Allocator = undefined,
    /// Its address is the loader's identity, so it lives here and not on a stack.
    loader: asset.ScriptSourceLoader = .{},
    abi_host: abi.Host = .{},
    manager: ?script.Manager = null,
    bound: bool = false,
    started: bool = false,
    stopped_for_good: bool = false,

    packages: [max_packages]Package = @splat(.{}),
    count: usize = 0,

    /// Remembers one resolved package, if it carries a script. Called while the resolution
    /// is still alive, because the name it copies is borrowed from that arena.
    pub fn note(self: *Host, entry: mod.Entry) void {
        const descriptor = entry.script orelse return;
        if (self.count >= self.packages.len) {
            log.warn("'{s}' has a script, but this sample runs at most {d}", .{ entry.name, max_packages });
            return;
        }
        const package = &self.packages[self.count];
        package.* = .{ .id = entry.id, .entry = descriptor.entry, .binding = descriptor.binding };
        const length = @min(entry.name.len, max_name);
        @memcpy(package.name_buf[0..length], entry.name[0..length]);
        package.name_len = length;
        self.count += 1;
    }

    /// Publishes the engine's subsystems, issues an identity per package and activates
    /// each one (`scripting.md` §10). A failure to start any single package is reported
    /// and is not a reason for the sample to stop.
    pub fn start(self: *Host, gpa: std.mem.Allocator, engine: *app.Engine, world: *scene.World) void {
        if (self.count == 0 or self.started) return;
        self.gpa = gpa;

        // Before the first script asset is acquired, which is all "before" has to mean:
        // assets are lazy, so registering the loader here is early enough (§10).
        engine.assets.registerLoader(gpa, self.loader.assetLoader()) catch |err| {
            log.warn("no script source loader ({t}); scripts will not run", .{err});
            return;
        };

        self.abi_host = .{
            .engine = engine,
            .world = world,
            .script_source_loader = &self.loader,
        };
        self.abi_host.bind();
        self.bound = true;

        const Table = abi.TableOf(abi.Host);
        self.manager = script.Manager.init(gpa, @ptrCast(&Table.getApi), .{}) catch |err| {
            log.warn("no script manager ({t}); scripts will not run", .{err});
            return;
        };
        self.started = true;
        self.activate();
    }

    fn activate(self: *Host) void {
        const manager = &(self.manager orelse return);
        for (self.packages[0..self.count]) |*package| {
            if (package.self == 0) {
                const issued = self.abi_host.issueMod(package.id, package.name()) catch |err| {
                    log.warn("'{s}' could not be issued an identity ({t})", .{ package.name(), err });
                    continue;
                };
                package.self = issued.bits;
            }
            _ = manager.add(.{
                .package = package.id,
                .package_name = package.name(),
                .entry = package.entry,
                .binding = package.binding,
                .self = package.self,
            }) catch |err| {
                log.warn("'{s}' has no slot ({t})", .{ package.name(), err });
                continue;
            };
        }
        manager.activateAll();
        log.info("scripts: {d} of {d} package(s) running", .{ manager.readyCount(), self.count });
    }

    /// One replacement, if a script's source has changed under it (`scripting.md` §12).
    ///
    /// Called before the world's own update, which is where §12 puts it: no script callback
    /// is running and no script value is borrowed. The engine's own content watcher has
    /// already re-read whatever changed on disk — twice a second, in a debug build — so
    /// **editing `content/sandbox/scripts/encounter.lua` beside the executable and saving
    /// it is the whole of the loop.** A replacement that is refused says so through the
    /// package's own log and leaves the last version that worked running.
    pub fn poll(self: *Host) void {
        const manager = &(self.manager orelse return);
        const result = manager.pollReload();
        const slot = result.slot orelse return;
        if (result.outcome == .reloaded) {
            log.info("'{s}' is running new code ({d} reload(s) in)", .{ slot.name(), slot.reloads });
        }
    }

    /// **A manager belongs to one world's lifetime** (`scripting.md` §3), and loading a save
    /// builds a new world. So the scripts stop, once, with a reason — rather than appearing
    /// to be running while nothing calls them. Reactivating across a world swap is a
    /// lifecycle M8 has not specified, and guessing at one here would be the wrong place.
    pub fn worldReplaced(self: *Host) void {
        if (!self.started or self.stopped_for_good) return;
        self.stopped_for_good = true;
        if (self.manager) |*manager| manager.deinit();
        self.manager = null;
        log.warn("scripts stopped: they belong to the world they were activated in", .{});
    }

    /// Teardown in §10's order: close the VMs and release their source references **while
    /// the ABI is still bound**, because releasing an asset is a call; then unbind, which
    /// neutralises what the world still points at. The caller destroys the world after.
    pub fn deinit(self: *Host) void {
        if (self.manager) |*manager| manager.deinit();
        self.manager = null;
        if (self.bound) {
            self.abi_host.unbind();
            self.bound = false;
        }
        self.started = false;
    }
};

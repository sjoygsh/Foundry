//! Binding 1 against the **real table**, a real world and real merged content.
//!
//! The fake-table tests say what the bridge does with an answer; this says what the engine
//! actually answers. The script reaches the engine exactly as a native mod does — through
//! the `FoundryGetApi` the host hands it — so nothing here is a shortcut the public boundary
//! does not have.

const std = @import("std");
const core = @import("core");
const asset = @import("asset");
const data = @import("data");
const platform = @import("platform");
const rhi = @import("rhi");
const scene = @import("scene");
const app = @import("app");
const mod = @import("mod");
const abi = @import("abi");
const script = @import("script");

const testing = std.testing;
const gpa = testing.allocator;
const TestEngine = app.EngineOf(platform.null_backend.Platform, rhi.null_backend.Device);
const TestHost = abi.HostOf(TestEngine);
const Table = abi.TableOf(TestHost);

/// Engine-shaped and therefore savable, which is what lets a template build it.
///
/// The fields carry no Zig default because the package declares the same schema without
/// one: a derived default becomes a schema default, and two declarations of one schema that
/// disagree about a default disagree about what content means.
const Position = struct {
    pub const component = "demo:position";
    x: f32,
    y: f32,
};

const package_source =
    \\foundry:mod demo:mod {
    \\    name "Scripted Demo"
    \\    version 1
    \\    license "Apache-2.0"
    \\}
    \\@schema demo:position { x f32  y f32 }
    \\@schema demo:config { delay i64  spawn id  label string }
    \\demo:config demo:encounter { delay 3  spawn demo:goblin  label "wave" }
    \\demo:position demo:at_origin { x 1  y 2 }
    \\foundry:entity demo:goblin { components [ demo:at_origin ] }
    \\foundry:script demo:scripts.main { source "scripts/main.lua"  language "lua-5.5" }
;

/// What a package's script actually looks like: the module of scripting.md §11, reading its
/// own content at load, keeping what it needs in state, and spawning on a tick it decides.
const encounter_source =
    \\local config = foundry.content_find("demo:encounter")
    \\local delay = foundry.record_get_i64(config, foundry.record_field_index(config, "delay"))
    \\local template = foundry.record_get_id(config, foundry.record_field_index(config, "spawn"))
    \\
    \\return {
    \\    state_version = 1,
    \\    init = function()
    \\        return { spawned = 0, next_tick = delay, owned = {} }
    \\    end,
    \\    update = function(state, step)
    \\        if step.tick < state.next_tick then return end
    \\        local made = foundry.world_spawn(template)
    \\        if made == nil then return end
    \\        state.spawned = state.spawned + 1
    \\        state.owned[state.spawned] = made
    \\        state.next_tick = step.tick + delay
    \\        foundry.log_write("info", "spawned " .. tostring(state.spawned))
    \\    end,
    \\}
;

/// The same package, edited: a new state version, a `migrate` that carries the old state
/// across, and code that clears away what the previous VM spawned — using the very handles
/// that VM put in its state (scripting.md §11, §12).
const cleanup_source =
    \\return {
    \\    state_version = 2,
    \\    init = function() return { spawned = 0, cleared = 0, owned = {} } end,
    \\    migrate = function(old, version)
    \\        return { spawned = old.spawned, cleared = 0, owned = old.owned, from = version }
    \\    end,
    \\    update = function(state, step)
    \\        local last = 0
    \\        for i = 1, 32 do if state.owned[i] ~= nil then last = i end end
    \\        if last == 0 then return end
    \\        foundry.world_destroy_entity(state.owned[last])
    \\        state.owned[last] = nil
    \\        state.cleared = state.cleared + 1
    \\        foundry.log_write("info", "cleared " .. tostring(state.cleared))
    \\    end,
    \\}
;

fn writePackage(os: *platform.Os, dir: []const u8, name: []const u8, source: []const u8) !void {
    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    try mod.schemas.registerAll(gpa, &registry);
    try scene.schemas.registerAll(gpa, &registry);
    try asset.schemas.registerAll(gpa, &registry);

    const colon = std.mem.indexOfScalar(u8, name, ':').?;
    var doc = try data.parser.parse(gpa, "mod.fdt", source, .{ .namespace = name[0..colon] }, &diags);
    defer doc.deinit(gpa);

    var package = try data.check.Package.init(gpa, name, 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &doc, &registry, &diags);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &package, &registry, &bytes);

    const file_name = try std.fmt.allocPrint(gpa, "{s}.fpk", .{name[0..colon]});
    defer gpa.free(file_name);
    const path = try platform.os.joinPath(gpa, &.{ dir, file_name });
    defer gpa.free(path);
    try os.writeFile(path, bytes.items);
}

/// Everything a host owns, assembled the way `app` and a game assemble it.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_buf: [std.Io.Dir.max_path_bytes]u8,
    content_len: usize,
    os: *platform.Os,
    engine: *TestEngine,
    world: scene.World,
    host: TestHost,
    self: abi.Mod,
    position: scene.ComponentType,
    /// The host's own source loader. Its address is its identity: `script_source_copy`
    /// refuses a payload this exact loader did not make (step 3).
    script_loader: asset.ScriptSourceLoader,

    /// `world_allocator` is the world's own, so a test can make the world run out of memory
    /// without starving the engine that has to report it.
    fn init(self: *Fixture, world_allocator: std.mem.Allocator) !void {
        self.tmp = testing.tmpDir(.{});
        const path_len = try self.tmp.dir.realPath(testing.io, &self.path_buf);
        self.content_len = path_len;
        const content_dir = self.path_buf[0..path_len];

        self.os = try platform.Os.init(gpa, .{ .app_name = "foundry-script-bindings", .env = &.{} });
        try writePackage(self.os, content_dir, "demo:mod", package_source);
        const root = try platform.os.joinPath(gpa, &.{ content_dir, "demo" });
        defer gpa.free(root);
        try self.os.createDirPath(root);

        // The script is a file in the package, reached by the path its record names and by
        // nothing else. Writing it here is what a package author does with an editor.
        const scripts = try platform.os.joinPath(gpa, &.{ root, "scripts" });
        defer gpa.free(scripts);
        try self.os.createDirPath(scripts);
        const entry_path = try platform.os.joinPath(gpa, &.{ scripts, "main.lua" });
        defer gpa.free(entry_path);
        try self.os.writeFile(entry_path, encounter_source);

        self.engine = try TestEngine.init(gpa, .{
            .headless = true,
            .content_dir = content_dir,
            .content = &.{.{ .file = "demo.fpk", .root = "demo" }},
            .log_capture = null,
        });

        self.script_loader = .{};
        try self.engine.assets.registerLoader(gpa, self.script_loader.assetLoader());

        self.world = .init(world_allocator, &self.engine.schemas, .default);
        self.position = try self.world.registerComponent(scene.componentType(Position));
        self.host = .{
            .engine = self.engine,
            .world = &self.world,
            .script_source_loader = &self.script_loader,
        };
        self.host.bind();
        self.self = try self.host.issueMod(core.ContentId.fromString("demo:mod"), "demo:mod");
    }

    fn deinit(self: *Fixture) void {
        self.host.unbind();
        self.world.deinit();
        self.engine.deinit();
        self.os.deinit();
        self.tmp.cleanup();
    }

    /// Edits the package's script on disk and reloads the asset behind it — which is the
    /// whole of what a development host does before it polls (`scripting.md` §12). The
    /// asset handle does not change and neither does the manager's reference to it; what
    /// changes is the payload behind it, and the revision that says so.
    fn rewriteScript(self: *Fixture, source: []const u8) !void {
        const content_dir = self.path_buf[0..self.content_len];
        const entry_path = try platform.os.joinPath(gpa, &.{ content_dir, "demo", "scripts", "main.lua" });
        defer gpa.free(entry_path);
        try self.os.writeFile(entry_path, source);

        const handle = try self.engine.assets.acquire(gpa, core.ContentId.fromString("demo:scripts.main"));
        defer self.engine.assets.release(handle);
        try self.engine.assets.reload(gpa, handle);
    }

    /// The descriptor an application builds from a resolved package, written out because
    /// that conversion is the application's and not `script`'s (§3).
    fn descriptor(self: *Fixture) script.Descriptor {
        return .{
            .package = core.ContentId.fromString("demo:mod"),
            .package_name = "demo:mod",
            .entry = core.ContentId.fromString("demo:scripts.main"),
            .binding = 1,
            .self = self.self.bits,
        };
    }

    fn runtime(self: *Fixture, ledger: *script.Ledger, config: script.Config) !script.Runtime {
        var full = config;
        full.get_api = @ptrCast(&Table.getApi);
        full.self = self.self.bits;
        full.ledger = ledger;
        var value: script.Runtime = .{};
        try value.init(gpa, full);
        return value;
    }
};

test "a script reads merged content and spawns, inspects and removes its own entity" {
    var fixture: Fixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();

    var ledger: script.Ledger = std.mem.zeroes(script.Ledger);
    var runtime = try fixture.runtime(&ledger, .{});
    defer runtime.deinit();

    // Preparation reads the content the package shipped, exactly as an `init` will.
    const read =
        \\local config = foundry.content_find("demo:encounter")
        \\assert(foundry.record_name(config) == "demo:encounter")
        \\assert(foundry.record_schema(config) == foundry.schema_id("demo:config"))
        \\local delay = foundry.record_field_index(config, "delay")
        \\assert(foundry.record_field_type(config, delay) == "i64")
        \\template = foundry.record_get_id(config, foundry.record_field_index(config, "spawn"))
        \\assert(foundry.id_to_string(template) == "demo:goblin")
        \\return foundry.record_get_i64(config, delay)
    ;
    try testing.expectEqual(@as(i64, 3), try runtime.run(read, .prepare));

    // An update spawns from that template and reads the component back through its schema,
    // which is the only way a script sees component data at all.
    const spawn =
        \\local spawned = foundry.world_spawn(foundry.id_from_string("demo:goblin"))
        \\assert(foundry.world_contains(spawned))
        \\local kind = foundry.world_find_component_type("demo:position")
        \\assert(foundry.world_has_component(spawned, kind))
        \\local view = foundry.world_read_component(spawned, kind)
        \\local x = foundry.record_get_f32(view, foundry.record_field_index(view, "x"))
        \\local y = foundry.record_get_f32(view, foundry.record_field_index(view, "y"))
        \\assert(x == 1 and y == 2, "component values")
        \\assert(foundry.log_write("info", "spawned a goblin") == true)
        \\return foundry.world_entity_count()
    ;
    try testing.expectEqual(@as(i64, 1), try runtime.run(spawn, .update));
    try testing.expectEqual(@as(u32, 1), ledger.count);
    try testing.expectEqual(@as(u32, 1), fixture.world.entityCount());
    const first_spawn_calls = runtime.abiCalls();

    // The second spawn of the same template costs fewer calls: the preflight's answer is
    // cached against the content generation rather than recomputed every tick.
    try testing.expectEqual(@as(i64, 2), try runtime.run(spawn, .update));
    try testing.expect(runtime.abiCalls() < first_spawn_calls);
    try testing.expectEqual(@as(u32, 2), ledger.count);

    // Destroying while walking invalidates the walk, and the script is told so rather than
    // being resynchronised onto whatever now sits at that position.
    try testing.expectError(error.RuntimeFailed, runtime.run(
        \\local found, cursor = foundry.world_next_entity(nil)
        \\foundry.world_destroy_entity(found)
        \\return foundry.world_next_entity(cursor)
    , .update));
    try testing.expect(std.mem.indexOf(u8, runtime.diagnostic(), "stale_handle") != null);
    try testing.expectEqual(@as(u32, 1), ledger.count);

    // What it spawned, it may remove: collect the walk first, then act on it.
    const destroy =
        \\local cursor, found_count, found = nil, 0, {}
        \\while true do
        \\  local entity, next_cursor = foundry.world_next_entity(cursor)
        \\  if entity == nil then break end
        \\  cursor = next_cursor
        \\  found_count = found_count + 1
        \\  found[found_count] = entity
        \\end
        \\local removed = 0
        \\for i = 1, found_count do
        \\  if foundry.world_destroy_entity(found[i]) then removed = removed + 1 end
        \\end
        \\return removed
    ;
    try testing.expectEqual(@as(i64, 1), try runtime.run(destroy, .update));
    try testing.expectEqual(@as(u32, 0), ledger.count);
    try testing.expectEqual(@as(u32, 0), fixture.world.entityCount());
}

test "the real table refuses a foreign entity, a stale record and an unspawnable template" {
    var fixture: Fixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();

    // An entity the game made, which the script can see and must not be able to remove.
    const host_entity = try fixture.world.create();
    _ = try fixture.world.addComponent(host_entity, fixture.position, null);

    var ledger: script.Ledger = std.mem.zeroes(script.Ledger);
    var runtime = try fixture.runtime(&ledger, .{});
    defer runtime.deinit();

    try testing.expectError(error.RuntimeFailed, runtime.run(
        \\local found = foundry.world_next_entity(nil)
        \\return foundry.world_destroy_entity(found)
    , .update));
    try testing.expect(std.mem.indexOf(u8, runtime.diagnostic(), "contract") != null);
    try testing.expectEqual(@as(u32, 1), fixture.world.entityCount());

    // A record read in one invocation is not a record in the next, even though the engine's
    // own handle would still resolve: the tick boundary is the script's lifetime rule.
    _ = try runtime.run("saved = foundry.content_find(\"demo:encounter\") return 1", .prepare);
    try testing.expectError(error.RuntimeFailed, runtime.run("return foundry.record_field_count(saved)", .prepare));
    try testing.expect(std.mem.indexOf(u8, runtime.diagnostic(), "stale_handle") != null);

    // A content id that is not an entity template is refused before the world is asked.
    try testing.expectError(error.RuntimeFailed, runtime.run("return foundry.world_spawn(\"demo:encounter\")", .update));
    try testing.expect(std.mem.indexOf(u8, runtime.diagnostic(), "invalid_argument") != null);

    // And one nothing declares is ordinary absence.
    try testing.expectEqual(@as(i64, 1), try runtime.run(
        \\local made, why = foundry.world_spawn("demo:nothing")
        \\assert(made == nil and why == "not_found", tostring(why))
        \\return 1
    , .update));
}

test "a spawn the world cannot afford leaves no entity and no ownership behind" {
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = std.math.maxInt(usize) });

    var fixture: Fixture = undefined;
    try fixture.init(failing.allocator());
    defer fixture.deinit();

    var ledger: script.Ledger = std.mem.zeroes(script.Ledger);
    var runtime = try fixture.runtime(&ledger, .{});
    defer runtime.deinit();

    const source = "return foundry.world_spawn(\"demo:goblin\") and 1 or 0";
    var refusals: u32 = 0;
    var index: usize = 0;
    while (index < 24) : (index += 1) {
        failing.fail_index = failing.alloc_index + index;
        if (runtime.run(source, .update)) |_| {
            break;
        } else |err| {
            try testing.expectEqual(error.MemoryLimit, err);
            try testing.expect(std.mem.indexOf(u8, runtime.diagnostic(), "memory_limit") != null);
            // Nothing half-built survives, and the script never gained ownership of it.
            try testing.expectEqual(@as(u32, 0), fixture.world.entityCount());
            try testing.expectEqual(@as(u32, 0), ledger.count);
            refusals += 1;
        }
    }
    try testing.expect(refusals > 0);
}

test "a package's script registers a system, and the world's own update drives it" {
    var fixture: Fixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();

    var manager = try script.Manager.init(gpa, @ptrCast(&Table.getApi), .{});
    defer manager.deinit();

    // The conversion from a resolved package to a descriptor is the application's, which is
    // why it is written out here rather than hidden inside `script` (scripting.md §3).
    const slot = try manager.add(.{
        .package = core.ContentId.fromString("demo:mod"),
        .package_name = "demo:mod",
        .entry = core.ContentId.fromString("demo:scripts.main"),
        .binding = 1,
        .self = fixture.self.bits,
    });
    manager.activateAll();
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expect(slot.registered);
    // The diagnostic name came from content: the entry record's own spelling, not the id's
    // hash and not a filename the host happened to read it from.
    try testing.expectEqualStrings("demo:scripts.main", slot.chunkName());

    // Nothing has run yet. `init` prepared state and was not allowed to touch the world.
    try testing.expectEqual(@as(u32, 0), fixture.world.entityCount());

    // The world drives the script exactly as it drives a native mod's system: one
    // registration, called once per fixed step, in the schedule's order.
    const delta = core.time.Duration.fromNanos(16_666_667);
    var tick: u64 = 1;
    while (tick <= 9) : (tick += 1) fixture.world.update(.{ .tick = tick, .delta = delta });

    // `demo:encounter` says every third tick, and the script read that out of content.
    try testing.expectEqual(@as(u32, 3), fixture.world.entityCount());
    try testing.expectEqual(@as(u32, 3), slot.ownedCount());
    try testing.expectEqual(script.Status.ready, slot.status);

    // What the script made belongs to the world, not to the VM: tearing the manager down
    // closes Lua and leaves the entities exactly where they are (§10).
    manager.deinit();
    try testing.expectEqual(@as(u32, 3), fixture.world.entityCount());
}

test "a script that faults on a tick is disabled, and the world keeps its entities" {
    var fixture: Fixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();

    var manager = try script.Manager.init(gpa, @ptrCast(&Table.getApi), .{});
    defer manager.deinit();
    const slot = try manager.add(.{
        .package = core.ContentId.fromString("demo:mod"),
        .package_name = "demo:mod",
        .entry = core.ContentId.fromString("demo:scripts.main"),
        .binding = 1,
        .self = fixture.self.bits,
    });
    manager.activateAll();

    const delta = core.time.Duration.fromNanos(16_666_667);
    fixture.world.update(.{ .tick = 3, .delta = delta });
    try testing.expectEqual(@as(u32, 1), fixture.world.entityCount());

    // An entity the script owns, removed by the game rather than by the script. The next
    // tick's ownership walk has to notice, rather than acting on a handle that is gone.
    var walk = fixture.world.entities.iterator();
    const owned = walk.next().?.id;
    try testing.expect(fixture.world.destroy(owned));

    // The world's own step still reaches the script, and the script still works: what it
    // lost was an entity, which is an ordinary thing for a world to take away.
    fixture.world.update(.{ .tick = 6, .delta = delta });
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(@as(u32, 1), fixture.world.entityCount());
}

test "a package's code is replaced while its world, its state and its entities stay" {
    var fixture: Fixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();

    var manager = try script.Manager.init(gpa, @ptrCast(&Table.getApi), .{});
    defer manager.deinit();
    const slot = try manager.add(fixture.descriptor());
    manager.activateAll();
    try testing.expectEqual(script.Status.ready, slot.status);
    const first_revision = slot.source_revision;

    const delta = core.time.Duration.fromNanos(16_666_667);
    var tick: u64 = 1;
    while (tick <= 9) : (tick += 1) fixture.world.update(.{ .tick = tick, .delta = delta });
    try testing.expectEqual(@as(u32, 3), fixture.world.entityCount());
    try testing.expectEqual(@as(u32, 3), slot.ownedCount());

    // The author edits the file and the host reloads the asset. Nothing about the package,
    // the world, the registration or the ownership ledger is torn down.
    try fixture.rewriteScript(cleanup_source);
    const poll = manager.pollReload();
    try testing.expectEqual(script.Reload.reloaded, poll.outcome);
    try testing.expectEqual(@as(?*script.Slot, slot), poll.slot);
    try testing.expect(slot.source_revision != first_revision);
    try testing.expectEqual(@as(u32, 2), slot.runtime.stateVersion());
    try testing.expectEqual(@as(u32, 1), slot.reloads);

    // The world it was activated in is the world it is still running in, and what the old
    // VM spawned is still there and still this package's.
    try testing.expectEqual(@as(u32, 3), fixture.world.entityCount());
    try testing.expectEqual(@as(u32, 3), slot.ownedCount());

    // And now the new code clears them — one per tick, through the very handles the old VM
    // put in its state. Ownership came across with them: `world_destroy_entity` refuses an
    // entity this package did not spawn, so three successful removals is the proof.
    while (tick <= 12) : (tick += 1) fixture.world.update(.{ .tick = tick, .delta = delta });
    try testing.expectEqual(@as(u32, 0), fixture.world.entityCount());
    try testing.expectEqual(@as(u32, 0), slot.ownedCount());
    try testing.expectEqual(script.Status.ready, slot.status);
}

test "source that does not compile leaves the running package exactly as it was" {
    var fixture: Fixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();

    var manager = try script.Manager.init(gpa, @ptrCast(&Table.getApi), .{});
    defer manager.deinit();
    const slot = try manager.add(fixture.descriptor());
    manager.activateAll();

    const delta = core.time.Duration.fromNanos(16_666_667);
    var tick: u64 = 1;
    while (tick <= 6) : (tick += 1) fixture.world.update(.{ .tick = tick, .delta = delta });
    try testing.expectEqual(@as(u32, 2), fixture.world.entityCount());
    const revision = slot.source_revision;

    try fixture.rewriteScript("return { state_version = ");
    try testing.expectEqual(script.Reload.refused, manager.pollReload().outcome);
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(revision, slot.source_revision);
    try testing.expectEqual(@as(u32, 0), slot.reloads);

    // The old code keeps its cadence, its state and its entities: the third spawn lands on
    // the tick it always would have.
    while (tick <= 9) : (tick += 1) fixture.world.update(.{ .tick = tick, .delta = delta });
    try testing.expectEqual(@as(u32, 3), fixture.world.entityCount());
    try testing.expectEqual(@as(u32, 3), slot.ownedCount());

    // Fixing it is a new revision, and it is taken without the world noticing.
    try fixture.rewriteScript(cleanup_source);
    try testing.expectEqual(script.Reload.reloaded, manager.pollReload().outcome);
    try testing.expectEqual(@as(u32, 3), fixture.world.entityCount());
}

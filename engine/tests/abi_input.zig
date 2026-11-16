//! Input from outside, in C (`docs/design/input.md` §10, M45 Step 7).
//!
//! `fixtures/input_client.c` is a C99 dynamic library compiled against `foundry.h` alone, loaded
//! through the ordinary native loader and handed `FoundryApi_v8`. It calls every input entry point
//! and every refusal, and answers `FOUNDRY_OK` only if all of them answered what the header says.
//! This test is its host: it scripts a map, two views and the player's overrides, as an engine's
//! `inputSources` would lend them, and counts the entities the client's system makes for each step
//! whose tick view was right.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");
const mod = @import("mod");
const scene = @import("scene");
const input = @import("input");
const app = @import("app");
const abi = @import("abi");
const options = @import("mod_pipeline_options");

const testing = std.testing;
const gpa = testing.allocator;

const content =
    \\foundry:input_context t:context.walk { priority 10 }
    \\foundry:input_context t:context.menu { priority 20 blocks true }
    \\foundry:input_action t:action.jump {
    \\    kind "button"
    \\    contexts [ t:context.walk ]
    \\    bindings [ { source "key.space" } { source "pad.south" } ]
    \\}
    \\foundry:input_action t:action.move {
    \\    kind "vector"
    \\    contexts [ t:context.walk ]
    \\    bindings [ { source "key.w" axis "y" } { source "pad.left_stick" deadzone 0.2 } ]
    \\}
    \\foundry:input_action t:action.pause {
    \\    kind "button"
    \\    rebindable false
    \\    contexts [ t:context.walk t:context.menu ]
    \\    bindings [ { source "key.escape" } ]
    \\}
;

fn cid(text: []const u8) core.ContentId {
    return core.ContentId.fromString(text);
}

/// What the client expects: J pressed in the frame and only held in the step, motion in counts,
/// a PlayStation pad in slot 1, jump rebound to J, and pause's override ignored.
const Script = struct {
    store: input.map.Fixture,
    base: input.Map = .empty,
    map: input.Map = .empty,
    actions: input.Actions = undefined,
    overrides: input.Overrides = .empty,
    frame_input: platform.InputSnapshot = .{},
    tick_input: platform.InputSnapshot = .{},
    frame_actions: input.Frame = .empty,
    tick_actions: input.Frame = .empty,
    sources: app.InputSources = undefined,

    fn init(self: *Script) !void {
        self.* = .{ .store = .init() };
        try self.store.add("t", content);
        self.base = try self.store.build();
        try self.overrides.set(gpa, cid("t:action.jump"), &.{.{ .source = .{ .key = .j } }});
        try self.overrides.set(gpa, cid("t:action.pause"), &.{.{ .source = .{ .key = .p } }});
        self.map = try self.base.apply(gpa, &self.overrides);
        self.actions = .init(&self.map);
        try self.actions.enable(cid("t:context.walk"));
        platform.key.setKey(&self.frame_input.keys_held, .j, true);
        platform.key.setKey(&self.frame_input.keys_pressed, .j, true);
        self.frame_input.focused = true;
        self.frame_input.mouse.motion = .{ .x = 3, .y = -1 };
        self.frame_input.mouse.motion_unit = .counts;
        self.frame_input.gamepads[1] = .{ .connected = true, .handle = .{ .index = 1, .generation = 2 }, .kind = .playstation, .face = .{ .cross, .circle, .square, .triangle } };
        self.frame_input.gamepads[1].axes[@intFromEnum(platform.GamepadAxis.left_y)] = 0.5;
        platform.key.setKey(&self.tick_input.keys_held, .j, true);
        self.tick_input.focused = true;
        self.frame_actions = self.actions.evaluate(&self.frame_input, .{}).*;
        self.tick_actions = self.actions.evaluate(&self.tick_input, .{}).*;
        self.sources = .{
            .frame = .{ .input = &self.frame_input, .actions = &self.frame_actions },
            .tick = .{ .input = &self.tick_input, .actions = &self.tick_actions },
            .map = &self.map,
            .actions = &self.actions,
            .overrides = &self.overrides,
        };
    }

    fn deinit(self: *Script) void {
        self.overrides.deinit(gpa);
        self.map.deinit(gpa);
        self.base.deinit(gpa);
        self.store.deinit();
    }
};

fn copyLibrary(os: *platform.Os, root: []const u8, source: []const u8) !void {
    try os.createDirPath(root);
    const name = try abi.libraryFileNameAlloc(gpa, "input_client");
    defer gpa.free(name);
    const destination = try platform.os.joinPath(gpa, &.{ root, name });
    defer gpa.free(destination);
    const bytes = try os.readFile(gpa, source, 64 << 20);
    defer gpa.free(bytes);
    try os.writeFile(destination, bytes);
}

const entry: mod.Entry = .{
    .id = core.ContentId.fromString("t:input_client"),
    .name = "t:input_client",
    .base_dir = "",
    .file = "",
    .root = "lib",
    .version = 1,
    .abi = .{ .min = 8, .max = 8 },
    .native = "input_client",
};

fn run(sources: ?*const app.InputSources, steps: u64) !usize {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const base = path_buf[0..path_len];
    var os = try platform.Os.init(gpa, .{ .app_name = "foundry-abi-input", .env = &.{} });
    defer os.deinit();
    const library_dir = try platform.os.joinPath(gpa, &.{ base, "lib" });
    defer gpa.free(library_dir);
    try copyLibrary(os, library_dir, options.input_client_path);

    var registry: data.Registry = .init(gpa, .default);
    defer registry.deinit(gpa);
    var world: scene.World = .init(gpa, &registry, .default);
    defer world.deinit();
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);

    var host: abi.Host = .{ .world = &world, .input = sources };
    host.bind();
    defer host.unbind();
    var loader = abi.NativeLoaderOf(abi.Host).init(gpa, &host);
    defer loader.deinit();
    var here = entry;
    here.base_dir = base;
    try loader.load(&.{here}, &diags);
    for (diags.items.items) |d| std.debug.print("{s}\n", .{d.message});
    // Loaded means its init answered FOUNDRY_OK: every check in it passed.
    try testing.expectEqual(@as(usize, 1), loader.loaded.items.len);
    try testing.expect(host.modId(loader.loaded.items[0].self) != null);
    defer loader.shutdown();
    for (1..steps + 1) |tick| world.update(.{ .tick = tick, .delta = .fromMillis(16) });
    return world.entityCount();
}

test "a C client reads keys, the mouse, pads and actions through v8, and every refusal" {
    var script: Script = undefined;
    try script.init();
    defer script.deinit();
    // Three steps, each seeing the tick view: J held, its edge not there. One entity each.
    try testing.expectEqual(@as(usize, 3), try run(&script.sources, 3));
}

test "a C client handed no input is answered unavailable by every v8 call" {
    try testing.expectEqual(@as(usize, 0), try run(null, 0));
}

//! The package lifecycle against a **fake host**: what the manager does with what a host
//! answers (scripting.md §10).
//!
//! Nothing here links an engine subsystem, deliberately. A lifecycle test that needed a real
//! world could not make registration fail, could not exhaust a capacity, and could not run
//! one broken package beside a healthy one without breaking the healthy one too — which is
//! exactly the matrix step 5 owes. The real table's semantics are proved separately, in
//! `engine/tests/script_bindings.zig`.

const std = @import("std");
const core = @import("core");
const script = @import("root.zig");

const c = script.c;
const testing = std.testing;
const gpa = testing.allocator;

fn hashOf(name: []const u8) u64 {
    return core.ContentId.fromString(name).hash;
}

/// A host with assets, a log and a system registry, and no world behind any of it.
const Host = struct {
    const max_sources = 8;
    const max_systems = 8;
    const max_logs = 32;

    const Source = struct {
        id: u64 = 0,
        name: []const u8 = "",
        text: []const u8 = "",
        revision: u64 = 1,
        refs: i32 = 0,
    };

    const System = struct {
        id: u64 = 0,
        name: []const u8 = "",
        ctx: ?*anyopaque = null,
        update: ?*const fn (?*anyopaque, [*c]const c.FoundryStep) callconv(.c) void = null,
    };

    var table: c.FoundryApi_v2 = undefined;
    var sources: [max_sources]Source = undefined;
    var source_count: usize = 0;
    var systems: [max_systems]System = undefined;
    var system_count: usize = 0;
    var register_result: c.FoundryResult = 0;
    var publish_world: bool = true;
    /// What a content reload looks like from a script's side: the number it reads changes
    /// and nothing else does.
    var content_generation: u64 = 1;
    var log_text: [max_logs][512]u8 = undefined;
    var log_len: [max_logs]usize = undefined;
    var log_count: usize = 0;

    fn reset() void {
        table = std.mem.zeroes(c.FoundryApi_v2);
        table.version = 2;
        table.size = @sizeOf(c.FoundryApi_v2);
        table.result_name = &resultName;
        table.log_write = &logWrite;
        table.content_find = &contentFind;
        table.record_name = &recordName;
        table.asset_acquire = &assetAcquire;
        table.asset_release = &assetRelease;
        table.script_source_copy = &sourceCopy;
        table.world_register_system = &registerSystem;
        table.content_generation = &contentGeneration;
        sources = @splat(.{});
        source_count = 0;
        systems = @splat(.{});
        system_count = 0;
        register_result = c.FOUNDRY_OK;
        publish_world = true;
        content_generation = 1;
        log_count = 0;
    }

    fn getApi(version: u32) callconv(.c) ?*const anyopaque {
        if (version != 2) return null;
        if (!publish_world) {
            // A host may publish the table and no world; `world_register_system` is then
            // absent rather than a pointer that answers with a lie.
            table.world_register_system = null;
        }
        return &table;
    }

    fn onlyV1(version: u32) callconv(.c) ?*const anyopaque {
        _ = version;
        return null;
    }

    /// Publishes one script asset and returns the descriptor a host would hand the manager.
    fn publish(name: []const u8, entry_name: []const u8, text: []const u8, binding: u32) script.Descriptor {
        sources[source_count] = .{
            .id = hashOf(entry_name),
            .name = entry_name,
            .text = text,
            .revision = @intCast(source_count + 1),
        };
        source_count += 1;
        return .{
            .package = .{ .hash = hashOf(name) },
            .package_name = name,
            .entry = .{ .hash = hashOf(entry_name) },
            .binding = binding,
            .self = @as(u64, source_count) << 8 | 1,
        };
    }

    /// One source file edited in place, exactly as a person editing it would look from
    /// here: different bytes behind the same asset, under a revision that has moved on.
    fn edit(entry_name: []const u8, text: []const u8) void {
        const source = find(hashOf(entry_name)).?;
        source.text = text;
        source.revision += 1;
    }

    fn find(id: u64) ?*Source {
        for (sources[0..source_count]) |*source| {
            if (source.id == id) return source;
        }
        return null;
    }

    fn logged(needle: []const u8) bool {
        for (0..log_count) |i| {
            if (std.mem.indexOf(u8, log_text[i][0..log_len[i]], needle) != null) return true;
        }
        return false;
    }

    /// One fixed step through every registered system, in registration order.
    fn tick(n: u64) void {
        const step: c.FoundryStep = .{ .tick = n, .delta_ns = 16_666_667 };
        for (systems[0..system_count]) |system| {
            if (system.update) |update| update(system.ctx, &step);
        }
    }

    fn contentGeneration(out: [*c]u64) callconv(.c) c.FoundryResult {
        out.* = content_generation;
        return c.FOUNDRY_OK;
    }

    fn resultName(result: c.FoundryResult) callconv(.c) c.FoundryStr {
        const name: []const u8 = switch (result) {
            c.FOUNDRY_OK => "ok",
            c.FOUNDRY_ERR_NOT_FOUND => "not_found",
            c.FOUNDRY_ERR_LIMIT => "limit",
            c.FOUNDRY_ERR_ALREADY_EXISTS => "already_exists",
            c.FOUNDRY_ERR_UNAVAILABLE => "unavailable",
            else => "internal",
        };
        return .{ .ptr = name.ptr, .len = name.len };
    }

    fn logWrite(self: c.FoundryMod, level: c.FoundryLogLevel, message: c.FoundryStr) callconv(.c) c.FoundryResult {
        _ = level;
        if (self.bits == 0) return c.FOUNDRY_ERR_INVALID_HANDLE;
        if (log_count >= max_logs) return c.FOUNDRY_ERR_LIMIT;
        const length = @min(@as(usize, @intCast(message.len)), log_text[log_count].len);
        @memcpy(log_text[log_count][0..length], message.ptr[0..length]);
        log_len[log_count] = length;
        log_count += 1;
        return c.FOUNDRY_OK;
    }

    /// A script asset is an ordinary content record, so it has a name like any other.
    fn contentFind(id: c.FoundryContentId, out: [*c]c.FoundryRecord) callconv(.c) c.FoundryResult {
        const source = find(id.hash) orelse return c.FOUNDRY_ERR_NOT_FOUND;
        out.*.bits = source.id;
        return c.FOUNDRY_OK;
    }

    fn recordName(record: c.FoundryRecord, out: [*c]c.FoundryStr) callconv(.c) c.FoundryResult {
        const source = find(record.bits) orelse return c.FOUNDRY_ERR_NOT_FOUND;
        out.* = .{ .ptr = source.name.ptr, .len = source.name.len };
        return c.FOUNDRY_OK;
    }

    fn assetAcquire(id: c.FoundryContentId, out: [*c]c.FoundryAsset) callconv(.c) c.FoundryResult {
        const source = find(id.hash) orelse return c.FOUNDRY_ERR_NOT_FOUND;
        source.refs += 1;
        out.*.bits = source.id;
        return c.FOUNDRY_OK;
    }

    fn assetRelease(asset: c.FoundryAsset) callconv(.c) c.FoundryResult {
        const source = find(asset.bits) orelse return c.FOUNDRY_ERR_INVALID_HANDLE;
        source.refs -= 1;
        return c.FOUNDRY_OK;
    }

    fn sourceCopy(
        asset: c.FoundryAsset,
        buffer: [*c]u8,
        capacity: u64,
        needed: [*c]u64,
        revision: [*c]u64,
    ) callconv(.c) c.FoundryResult {
        const source = find(asset.bits) orelse return c.FOUNDRY_ERR_INVALID_HANDLE;
        if (capacity != 0 and buffer == null) return c.FOUNDRY_ERR_INVALID_ARGUMENT;
        needed.* = source.text.len;
        revision.* = source.revision;
        // Exactly what the real call does: the size is written, and too little capacity —
        // the sizing probe's zero included — is `limit` rather than a copy.
        if (capacity < source.text.len) return c.FOUNDRY_ERR_LIMIT;
        @memcpy(buffer[0..source.text.len], source.text);
        return c.FOUNDRY_OK;
    }

    fn registerSystem(self: c.FoundryMod, desc: [*c]const c.FoundrySystemDesc) callconv(.c) c.FoundryResult {
        if (register_result != c.FOUNDRY_OK) return register_result;
        if (self.bits == 0 or desc == null) return c.FOUNDRY_ERR_INVALID_HANDLE;
        if (system_count >= max_systems) return c.FOUNDRY_ERR_LIMIT;
        systems[system_count] = .{
            .id = desc.*.id.hash,
            .name = desc.*.name.ptr[0..@intCast(desc.*.name.len)],
            .ctx = desc.*.ctx,
            .update = desc.*.update,
        };
        system_count += 1;
        return c.FOUNDRY_OK;
    }
};

/// A module that counts the ticks it has seen and says so, which is all binding 1 needs to
/// make a package's behaviour observable without a world.
const counting_module =
    \\return {
    \\    state_version = 1,
    \\    init = function() return { seen = 0 } end,
    \\    update = function(state, step)
    \\        state.seen = state.seen + 1
    \\        foundry.log_write("info", "tick " .. tostring(step.tick))
    \\    end,
    \\}
;

fn managerFor(limits: script.Limits) !script.Manager {
    return script.Manager.init(gpa, &Host.getApi, limits);
}

test "a script package becomes one registered system, and ticks reach it" {
    Host.reset();
    const descriptor = Host.publish("demo:mod", "demo:scripts.main", counting_module, 1);

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(descriptor);
    manager.activateAll();

    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(@as(usize, 1), Host.system_count);
    // The identity the world sees is the package's own, not a name derived from a path.
    try testing.expectEqual(hashOf("demo:mod"), Host.systems[0].id);
    try testing.expectEqualStrings("demo:mod", Host.systems[0].name);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(slot)), Host.systems[0].ctx);
    try testing.expectEqual(@as(u32, 1), slot.runtime.stateVersion());

    Host.tick(1);
    Host.tick(2);
    try testing.expect(Host.logged("tick 1"));
    try testing.expect(Host.logged("tick 2"));
    try testing.expectEqual(script.Status.ready, slot.status);

    // One registration, for the world's lifetime: a tick never adds another.
    try testing.expectEqual(@as(usize, 1), Host.system_count);
}

test "two packages activate in the order they were added and own nothing of each other's" {
    Host.reset();
    const first = Host.publish("alpha:mod", "alpha:scripts.main", counting_module, 1);
    const second = Host.publish("beta:mod", "beta:scripts.main", counting_module, 1);

    var manager = try managerFor(.{});
    defer manager.deinit();
    const a = try manager.add(first);
    const b = try manager.add(second);
    manager.activateAll();

    try testing.expectEqual(@as(u32, 2), manager.readyCount());
    try testing.expectEqual(@as(usize, 2), Host.system_count);
    try testing.expectEqual(hashOf("alpha:mod"), Host.systems[0].id);
    try testing.expectEqual(hashOf("beta:mod"), Host.systems[1].id);

    // Separate ledgers, at separate addresses: one package can never see the other's.
    try testing.expect(&a.ledger != &b.ledger);
    try testing.expectEqual(@as(u32, 0), a.ownedCount());
    try testing.expectEqual(@as(u32, 0), b.ownedCount());

    // And one shared budget: every VM this manager runs charges the same account (§8).
    try testing.expect(manager.budget.used > 0);
    try testing.expect(manager.budget.used < manager.budget.limit);
}

test "a package asking for a binding this build does not publish never gets a VM" {
    Host.reset();
    const descriptor = Host.publish("future:mod", "future:scripts.main", counting_module, 2);

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(descriptor);
    manager.activateAll();

    try testing.expectEqual(script.Status.faulted, slot.status);
    try testing.expect(!slot.has_runtime);
    try testing.expectEqual(@as(usize, 0), Host.system_count);
    try testing.expect(Host.logged("binding 2"));
    try testing.expect(Host.logged("unavailable"));
    // Refused before the source was even acquired: nothing was taken to release.
    try testing.expectEqual(@as(i32, 0), Host.sources[0].refs);
}

test "capacity is refused twice: by the manager's slots and by the world's" {
    Host.reset();
    var manager = try managerFor(.{ .packages = 2 });
    defer manager.deinit();

    _ = try manager.add(Host.publish("one:mod", "one:scripts.main", counting_module, 1));
    _ = try manager.add(Host.publish("two:mod", "two:scripts.main", counting_module, 1));
    try testing.expectError(error.Limit, manager.add(
        Host.publish("three:mod", "three:scripts.main", counting_module, 1),
    ));

    // And the world has its own capacity, which the manager reports rather than asserts.
    Host.register_result = c.FOUNDRY_ERR_LIMIT;
    manager.activateAll();
    try testing.expectEqual(@as(u32, 0), manager.readyCount());
    try testing.expectEqual(script.Status.faulted, manager.at(0).?.status);
    try testing.expect(Host.logged("limit"));
    // A refused activation leaves nothing held.
    try testing.expectEqual(@as(i32, 0), Host.sources[0].refs);
    try testing.expect(!manager.at(0).?.has_runtime);
}

test "one script failing leaves the other one ticking" {
    Host.reset();
    const broken =
        \\return {
        \\    state_version = 1,
        \\    init = function() return {} end,
        \\    update = function(state, step)
        \\        if step.tick == 2 then error("the wheels came off") end
        \\        foundry.log_write("info", "broken ok")
        \\    end,
        \\}
    ;
    const bad = Host.publish("broken:mod", "broken:scripts.main", broken, 1);
    const good = Host.publish("healthy:mod", "healthy:scripts.main", counting_module, 1);

    var manager = try managerFor(.{});
    defer manager.deinit();
    const bad_slot = try manager.add(bad);
    const good_slot = try manager.add(good);
    manager.activateAll();
    try testing.expectEqual(@as(u32, 2), manager.readyCount());

    Host.tick(1);
    try testing.expect(Host.logged("broken ok"));
    try testing.expect(Host.logged("tick 1"));

    Host.tick(2);
    try testing.expectEqual(script.Status.faulted, bad_slot.status);
    try testing.expectEqual(script.Status.ready, good_slot.status);
    try testing.expect(Host.logged("the wheels came off"));
    try testing.expect(Host.logged("update, tick 2"));
    // The failure names the script, not the file the host happens to have read it from.
    try testing.expect(Host.logged("broken:scripts.main"));
    try testing.expect(Host.logged("tick 2"));

    // The faulted package keeps its registration and its identity; what it loses is its VM.
    try testing.expect(bad_slot.registered);
    try testing.expect(!bad_slot.has_runtime);
    try testing.expectEqual(@as(usize, 2), Host.system_count);

    // And the healthy one keeps running, which is the whole claim.
    Host.tick(3);
    try testing.expect(Host.logged("tick 3"));
}

test "a module that is not the shape §11 describes is named rather than run" {
    const cases = [_]struct { source: []const u8, needle: []const u8 }{
        .{ .source = "return 7", .needle = "must return a table" },
        .{
            .source = "return { state_version = 1, init = function() return {} end, udpate = function() end }",
            .needle = "no field 'udpate'",
        },
        .{
            .source = "return { init = function() return {} end, update = function() end }",
            .needle = "state_version must be a positive integer",
        },
        .{
            .source = "return { state_version = 0, init = function() return {} end, update = function() end }",
            .needle = "state_version must be between",
        },
        .{
            .source = "return { state_version = 1, init = 4, update = function() end }",
            .needle = "init must be a function",
        },
        .{
            .source = "return { state_version = 1, init = function() return {} end, update = function() end, migrate = 2 }",
            .needle = "migrate must be a function",
        },
        .{
            .source = "return { state_version = 1, init = function() return 5 end, update = function() end }",
            .needle = "init must return a table",
        },
    };

    for (cases) |case| {
        Host.reset();
        var manager = try managerFor(.{});
        defer manager.deinit();
        const slot = try manager.add(Host.publish("shape:mod", "shape:scripts.main", case.source, 1));
        manager.activateAll();

        try testing.expectEqual(script.Status.faulted, slot.status);
        try testing.expectEqual(@as(usize, 0), Host.system_count);
        try testing.expect(Host.logged("contract"));
        try testing.expect(Host.logged(case.needle));
    }
}

test "init's state must be a value tree a reload could copy" {
    const cases = [_]struct { state: []const u8, needle: []const u8 }{
        .{ .state = "local t = {} t.self = t return t", .needle = "same table twice" },
        .{ .state = "local a = {} return { one = a, two = a }", .needle = "same table twice" },
        .{ .state = "return { go = function() end }", .needle = "holds a function" },
        .{ .state = "return { [1.5] = true }", .needle = "keyed by a number" },
        .{ .state = "return { bad = 0/0 }", .needle = "not finite" },
    };

    for (cases) |case| {
        Host.reset();
        var source_buf: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buf,
            \\return {{
            \\    state_version = 1,
            \\    init = function() {s} end,
            \\    update = function() end,
            \\}}
        , .{case.state});

        var manager = try managerFor(.{});
        defer manager.deinit();
        const slot = try manager.add(Host.publish("state:mod", "state:scripts.main", source, 1));
        manager.activateAll();

        try testing.expectEqual(script.Status.faulted, slot.status);
        try testing.expect(Host.logged(case.needle));
        try testing.expectEqual(@as(usize, 0), Host.system_count);
    }
}

test "a deeply nested state is refused at the documented depth" {
    Host.reset();
    const nested =
        \\return {
        \\    state_version = 1,
        \\    init = function()
        \\        local root = {}
        \\        local node = root
        \\        for i = 1, 20 do node.next = {} node = node.next end
        \\        return root
        \\    end,
        \\    update = function() end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("deep:mod", "deep:scripts.main", nested, 1));
    manager.activateAll();

    try testing.expectEqual(script.Status.faulted, slot.status);
    try testing.expect(Host.logged("nests deeper than 16"));
}

test "preparation gets its own instruction budget, and an update still gets the smaller one" {
    Host.reset();
    // Work that comfortably exceeds one update's budget but not one preparation's.
    const heavy =
        \\local total = 0
        \\for i = 1, 40000 do total = total + i end
        \\return {
        \\    state_version = 1,
        \\    init = function() return { total = total } end,
        \\    update = function(state) local n = 0 for i = 1, 40000 do n = n + i end end,
        \\}
    ;
    var manager = try managerFor(.{ .runtime = .{
        .instruction_limit = 20_000,
        .prepare_instruction_limit = 1_000_000,
    } });
    defer manager.deinit();
    const slot = try manager.add(Host.publish("budget:mod", "budget:scripts.main", heavy, 1));
    manager.activateAll();

    try testing.expectEqual(script.Status.ready, slot.status);
    Host.tick(1);
    try testing.expectEqual(script.Status.faulted, slot.status);
    try testing.expect(Host.logged("instruction_limit"));
    try testing.expect(Host.logged("unbounded loop"));
}

test "teardown releases every source reference while the ABI is still bound" {
    Host.reset();
    var manager = try managerFor(.{});
    const first = try manager.add(Host.publish("one:mod", "one:scripts.main", counting_module, 1));
    const second = try manager.add(Host.publish("two:mod", "two:scripts.main", counting_module, 1));
    manager.activateAll();
    try testing.expect(first.has_asset and second.has_asset);
    try testing.expectEqual(@as(i32, 1), Host.sources[0].refs);
    try testing.expectEqual(@as(i32, 1), Host.sources[1].refs);

    manager.deinit();
    try testing.expectEqual(@as(i32, 0), Host.sources[0].refs);
    try testing.expectEqual(@as(i32, 0), Host.sources[1].refs);
}

test "a host with no world, and a host with no version 2, are both refused" {
    Host.reset();
    try testing.expectError(error.UnsupportedApi, script.Manager.init(gpa, &Host.onlyV1, .{}));
    try testing.expectError(error.UnsupportedApi, script.Manager.init(gpa, null, .{}));

    Host.reset();
    Host.publish_world = false;
    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("worldless:mod", "worldless:scripts.main", counting_module, 1));
    manager.activateAll();
    try testing.expectEqual(script.Status.faulted, slot.status);
    try testing.expect(Host.logged("publishes no world"));
    try testing.expectEqual(@as(i32, 0), Host.sources[0].refs);
}

test "the aggregate budget bounds the source a manager will copy" {
    Host.reset();
    var manager = try managerFor(.{ .memory = 16 });
    defer manager.deinit();
    const slot = try manager.add(Host.publish("big:mod", "big:scripts.main", counting_module, 1));
    manager.activateAll();

    try testing.expectEqual(script.Status.faulted, slot.status);
    try testing.expect(Host.logged("memory budget has no room"));
    // Charged before the allocation was attempted, and given back when it was refused.
    try testing.expectEqual(@as(usize, 0), manager.budget.used);
}

test "identical failures are reported, then suppressed" {
    Host.reset();
    var manager = try managerFor(.{});
    defer manager.deinit();

    // One slot failing the same way over and over: the first two say something, the third
    // says it is going quiet, and the fourth says nothing at all.
    const slot = try manager.add(Host.publish("repeat:mod", "repeat:scripts.main",
        \\return { state_version = 1, init = function() return {} end }
    , 1));

    var round: u32 = 0;
    while (round < 4) : (round += 1) manager.activate(slot);

    try testing.expect(Host.logged("update must be a function"));
    try testing.expect(Host.logged("suppressed"));
    try testing.expectEqual(@as(usize, 3), Host.log_count);
}

// -- Replacing the code under a package (scripting.md §12) -------------------------------
//
// The claim these make is one claim seen from several sides: **the package outlives the VM
// running it.** The registration, the identity, the ledger and the state survive; the code
// does not. Everything that can go wrong leaves the last thing that worked in place.

/// A replacement for `counting_module`: same state version, different behaviour, and an
/// `init` that would be obvious if it ran — which it must not (§12).
const resumed_module =
    \\return {
    \\    state_version = 1,
    \\    init = function() return { seen = 100 } end,
    \\    update = function(state, step)
    \\        state.seen = state.seen + 1
    \\        foundry.log_write("info", "resumed at " .. tostring(state.seen))
    \\    end,
    \\}
;

test "new source replaces the code and the state comes across" {
    Host.reset();
    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", counting_module, 1));
    manager.activateAll();

    Host.tick(1);
    Host.tick(2);
    try testing.expect(Host.logged("tick 2"));

    Host.edit("demo:scripts.main", resumed_module);
    const poll = manager.pollReload();
    try testing.expectEqual(script.Reload.reloaded, poll.outcome);
    try testing.expectEqual(@as(?*script.Slot, slot), poll.slot);
    try testing.expectEqual(@as(u32, 1), slot.reloads);
    try testing.expectEqual(script.Status.ready, slot.status);

    // One registration, for the world's lifetime. The world still calls the same slot.
    try testing.expectEqual(@as(usize, 1), Host.system_count);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(slot)), Host.systems[0].ctx);

    Host.tick(3);
    // Three, not a hundred and one: the state crossed and `init` did not run.
    try testing.expect(Host.logged("resumed at 3"));
    try testing.expect(!Host.logged("resumed at 101"));

    // The bytes are not kept once a VM holds the state again.
    try testing.expectEqual(@as(?[]u8, null), slot.retained);
}

test "source that does not compile is refused and the old code keeps running" {
    Host.reset();
    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", counting_module, 1));
    manager.activateAll();
    Host.tick(1);

    Host.edit("demo:scripts.main", "return {");
    try testing.expectEqual(script.Reload.refused, manager.pollReload().outcome);
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(@as(u32, 0), slot.reloads);
    try testing.expect(Host.logged("syntax"));
    // And it says so without claiming the package stopped, because it did not.
    try testing.expect(Host.logged("The last working version is still running"));

    Host.tick(2);
    try testing.expect(Host.logged("tick 2"));

    // Broken text is compiled once, not once a frame: the same revision is not retried.
    Host.log_count = 0;
    try testing.expectEqual(script.Reload.idle, manager.pollReload().outcome);
    try testing.expectEqual(@as(usize, 0), Host.log_count);

    // Fixing it is a new revision, and that one is taken.
    Host.edit("demo:scripts.main", resumed_module);
    try testing.expectEqual(script.Reload.reloaded, manager.pollReload().outcome);
    Host.tick(3);
    try testing.expect(Host.logged("resumed at 3"));
}

test "a changed state version is carried across by the module's own migrate" {
    Host.reset();
    const second_version =
        \\return {
        \\    state_version = 2,
        \\    init = function() return { ticks = 100 } end,
        \\    migrate = function(old, version)
        \\        return { ticks = old.seen * 10 + version - 1 }
        \\    end,
        \\    update = function(state, step)
        \\        state.ticks = state.ticks + 1
        \\        foundry.log_write("info", "v2 at " .. tostring(state.ticks))
        \\    end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", counting_module, 1));
    manager.activateAll();
    try testing.expectEqual(@as(u32, 1), slot.runtime.stateVersion());

    Host.tick(1);
    Host.tick(2);

    Host.edit("demo:scripts.main", second_version);
    try testing.expectEqual(script.Reload.reloaded, manager.pollReload().outcome);
    try testing.expectEqual(@as(u32, 2), slot.runtime.stateVersion());

    Host.tick(3);
    // Two ticks seen, times ten, plus the version it came from, plus this one. Not 101:
    // `init` did not run here either.
    try testing.expect(Host.logged("v2 at 21"));
}

test "migrate is preparation, and preparation may not touch the world or the log" {
    Host.reset();
    const chatty =
        \\return {
        \\    state_version = 2,
        \\    init = function() return { ticks = 0 } end,
        \\    migrate = function(old) foundry.log_write("info", "hello") return { ticks = 0 } end,
        \\    update = function() end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", counting_module, 1));
    manager.activateAll();
    Host.tick(1);

    Host.edit("demo:scripts.main", chatty);
    try testing.expectEqual(script.Reload.refused, manager.pollReload().outcome);
    // The same rule `init` has, in the phase that was added for `migrate` (§11).
    try testing.expect(Host.logged("contract"));
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(@as(u32, 1), slot.runtime.stateVersion());
}

test "a changed state version without a migrate refuses the replacement" {
    Host.reset();
    const second_version =
        \\return {
        \\    state_version = 2,
        \\    init = function() return { ticks = 0 } end,
        \\    update = function(state) foundry.log_write("info", "v2 ran") end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", counting_module, 1));
    manager.activateAll();
    Host.tick(1);

    Host.edit("demo:scripts.main", second_version);
    try testing.expectEqual(script.Reload.refused, manager.pollReload().outcome);
    try testing.expect(Host.logged("migration"));
    try testing.expect(Host.logged("has no migrate"));

    // No implicit reset: the old code and the old state are still the ones running (§12).
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(@as(u32, 1), slot.runtime.stateVersion());
    Host.tick(2);
    try testing.expect(Host.logged("tick 2"));
    try testing.expect(!Host.logged("v2 ran"));
}

test "a faulted package resumes from the state its fault left behind" {
    Host.reset();
    const breaks =
        \\return {
        \\    state_version = 1,
        \\    init = function() return { n = 0 } end,
        \\    update = function(state, step)
        \\        state.n = state.n + 1
        \\        if step.tick == 2 then error("the wheels came off") end
        \\        foundry.log_write("info", "v1 n=" .. tostring(state.n))
        \\    end,
        \\}
    ;
    const fixed =
        \\return {
        \\    state_version = 1,
        \\    init = function() return { n = 500 } end,
        \\    update = function(state, step)
        \\        state.n = state.n + 1
        \\        foundry.log_write("info", "v2 n=" .. tostring(state.n))
        \\    end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", breaks, 1));
    manager.activateAll();

    Host.tick(1);
    Host.tick(2);
    try testing.expectEqual(script.Status.faulted, slot.status);
    try testing.expect(!slot.has_runtime);
    // The VM is gone and the state is not: kept as bytes at the moment it faulted, because
    // afterwards there is nothing left to ask (§12).
    try testing.expect(slot.retained != null);

    Host.edit("demo:scripts.main", fixed);
    try testing.expectEqual(script.Reload.reloaded, manager.pollReload().outcome);
    try testing.expectEqual(script.Status.ready, slot.status);

    Host.tick(3);
    // Two, plus this one. Not 501: a fixed script picks up where the broken one stopped
    // rather than running `init` again over a world it has already changed.
    try testing.expect(Host.logged("v2 n=3"));
    try testing.expectEqual(@as(?[]u8, null), slot.retained);
}

test "state an update corrupted refuses the replacement rather than carrying it" {
    Host.reset();
    const spoils =
        \\return {
        \\    state_version = 1,
        \\    init = function() return { n = 0 } end,
        \\    update = function(state, step)
        \\        state.oops = function() end
        \\        foundry.log_write("info", "v1 ran")
        \\    end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", spoils, 1));
    manager.activateAll();
    Host.tick(1);

    Host.edit("demo:scripts.main", resumed_module);
    try testing.expectEqual(script.Reload.refused, manager.pollReload().outcome);
    try testing.expect(Host.logged("holds a function"));
    // The old code is still the one running, which is all that can be true here: the state
    // it holds is exactly the state that cannot be carried anywhere (§12).
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(@as(u32, 0), slot.reloads);
    try testing.expectEqual(@as(?[]u8, null), slot.retained);
}

test "more reloads than the world has system slots change nothing about the registration" {
    Host.reset();
    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", counting_module, 1));
    manager.activateAll();
    Host.tick(1);

    // Well past `Host.max_systems`, which is what the ABI's own system capacity stands in
    // for here. A reload that registered anything would have run out long ago.
    Host.edit("demo:scripts.main", resumed_module);
    try testing.expectEqual(script.Reload.reloaded, manager.pollReload().outcome);
    const after_first = manager.budget.used;

    var round: u32 = 0;
    while (round < 11) : (round += 1) {
        Host.edit("demo:scripts.main", resumed_module);
        try testing.expectEqual(script.Reload.reloaded, manager.pollReload().outcome);
    }

    try testing.expectEqual(@as(u32, 12), slot.reloads);
    try testing.expectEqual(@as(usize, 1), Host.system_count);
    try testing.expectEqualStrings("demo:mod", Host.systems[0].name);
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(slot)), Host.systems[0].ctx);
    // One reference, held across every one of them.
    try testing.expectEqual(@as(i32, 1), Host.sources[0].refs);
    // And bounded memory: twelve replacements cost what one does, because eleven VMs were
    // closed as the twelfth opened.
    try testing.expectEqual(after_first, manager.budget.used);

    Host.tick(2);
    try testing.expect(Host.logged("resumed at 2"));
}

test "a refused replacement does not undo a content reload" {
    Host.reset();
    const reads_content =
        \\return {
        \\    state_version = 1,
        \\    init = function() return { seen = 0 } end,
        \\    update = function(state, step)
        \\        foundry.log_write("info", "generation " .. tostring(foundry.content_generation()))
        \\    end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", reads_content, 1));
    manager.activateAll();
    Host.tick(1);
    try testing.expect(Host.logged("generation 1"));

    // Content reloaded, and then a script replacement that fails. The two are separate
    // transactions and the failing one does not roll the other back (§12).
    Host.content_generation = 2;
    Host.edit("demo:scripts.main", "return { state_version = 1 }");
    try testing.expectEqual(script.Reload.refused, manager.pollReload().outcome);
    try testing.expectEqual(script.Status.ready, slot.status);

    Host.tick(2);
    // The old script sees the new content, which is the other half of the same rule: it has
    // to cope with records that changed under it.
    try testing.expect(Host.logged("generation 2"));
}

test "two states built in different orders snapshot to the same bytes" {
    Host.reset();
    // The same table, filled in two different orders, then faulted so the bytes are kept.
    // Two runs of one simulation must agree about what its state *is* (I9).
    const sorted =
        \\return {
        \\    state_version = 1,
        \\    init = function() return { zeta = 1, alpha = 2, [10] = 3, [2] = 4 } end,
        \\    update = function() error("stop") end,
        \\}
    ;
    const shuffled =
        \\return {
        \\    state_version = 1,
        \\    init = function()
        \\        local t = {}
        \\        t[2] = 4
        \\        t.zeta = 1
        \\        t[10] = 3
        \\        t.alpha = 2
        \\        return t
        \\    end,
        \\    update = function() error("stop") end,
        \\}
    ;

    var manager = try managerFor(.{});
    defer manager.deinit();
    const a = try manager.add(Host.publish("a:mod", "a:scripts.main", sorted, 1));
    const b = try manager.add(Host.publish("b:mod", "b:scripts.main", shuffled, 1));
    manager.activateAll();
    Host.tick(1);

    try testing.expectEqual(script.Status.faulted, a.status);
    try testing.expectEqual(script.Status.faulted, b.status);
    try testing.expectEqualSlices(u8, a.retained.?, b.retained.?);
}

test "a package that never loaded is retried when its source is fixed" {
    Host.reset();
    var manager = try managerFor(.{});
    defer manager.deinit();
    const slot = try manager.add(Host.publish("demo:mod", "demo:scripts.main", "return 7", 1));
    manager.activateAll();

    try testing.expectEqual(script.Status.faulted, slot.status);
    try testing.expect(!slot.registered);
    try testing.expectEqual(@as(usize, 0), Host.system_count);
    // Nothing was kept: a failed activation released everything it took (§10).
    try testing.expectEqual(@as(i32, 0), Host.sources[0].refs);

    // It has no state to carry and no system to keep, so what a fixed source earns it is
    // the activation that failed — `init` and all, because it has never run.
    Host.edit("demo:scripts.main", counting_module);
    try testing.expectEqual(script.Reload.reloaded, manager.pollReload().outcome);
    try testing.expectEqual(script.Status.ready, slot.status);
    try testing.expectEqual(@as(usize, 1), Host.system_count);

    Host.tick(1);
    try testing.expect(Host.logged("tick 1"));
}

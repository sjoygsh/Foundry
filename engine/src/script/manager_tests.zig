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
        sources = @splat(.{});
        source_count = 0;
        systems = @splat(.{});
        system_count = 0;
        register_result = c.FOUNDRY_OK;
        publish_world = true;
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

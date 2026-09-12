//! Step 7's runtime adversarial matrix. Engine/source integration lives in
//! `engine/tests/script_bindings.zig`; these cases deliberately need only the isolated L6
//! consumer and therefore cannot pass through a forgiving engine implementation.

const std = @import("std");
const script = @import("root.zig");

const testing = std.testing;
const gpa = testing.allocator;

const state_module =
    \\return {
    \\    state_version = 1,
    \\    init = function()
    \\        return { count = 0, nested = { a = 1, b = 2 }, label = "state" }
    \\    end,
    \\    update = function(state) state.count = state.count + 1 end,
    \\}
;

const migration_module =
    \\return {
    \\    state_version = 2,
    \\    init = function() return {} end,
    \\    migrate = function(old, version)
    \\        local copied = {}
    \\        for key, value in pairs(old) do copied[key] = value end
    \\        copied.from = version
    \\        return copied
    \\    end,
    \\    update = function(state) state.count = state.count + 1 end,
    \\}
;

fn loadState(runtime: *script.Runtime, source: []const u8, name: [:0]const u8) !void {
    try runtime.loadModule(source, name);
    try runtime.initState();
}

test "sandbox escape and unbounded native-work attempts are contained" {
    var runtime: script.Runtime = .{};
    try runtime.init(gpa, .{});
    defer runtime.deinit();

    try testing.expectEqual(@as(i64, 1), try runtime.execute(
        \\assert(_G == nil and io == nil and os == nil and package == nil and debug == nil)
        \\assert(coroutine == nil and load == nil and loadfile == nil and dofile == nil)
        \\assert(require == nil and pcall == nil and xpcall == nil and collectgarbage == nil)
        \\assert(next == nil and rawset == nil and getmetatable == nil and setmetatable == nil)
        \\return 1
    ));

    const escape_attempts = [_][]const u8{
        "return pcall(function() while true do end end)",
        "return require('outside')",
        "return ('text'):rep(2)",
        "return tostring({})",
        "return tostring(function() end)",
    };
    for (escape_attempts) |source| {
        try testing.expectError(error.RuntimeFailed, runtime.execute(source));
        try testing.expect(runtime.category() == .runtime or runtime.category() == .invalid_argument);
        try testing.expectEqual(@as(i64, 7), try runtime.execute("return 7"));
    }

    try testing.expectError(error.NativeWorkLimit, runtime.execute(
        \\local values = {}
        \\for i = 1, 1025 do values[i] = i end
        \\for key in pairs(values) do end
        \\return 1
    ));
    try testing.expectEqual(script.Category.native_work_limit, runtime.category());

    const too_many_bytes = "a" ** 257;
    const byte_source = "return string.byte(\"" ++ too_many_bytes ++ "\", 1, 257)";
    try testing.expectError(error.NativeWorkLimit, runtime.execute(byte_source));
    try testing.expectEqual(@as(i64, 8), try runtime.execute("return 8"));
}

test "oversized and non-finite state values are diagnosed without aborting the VM" {
    const cases = [_]struct {
        init_body: []const u8,
        needle: []const u8,
    }{
        .{ .init_body = "local t = {}; for i = 1, 1025 do t[i] = i end; return t", .needle = "more than 1024 entries" },
        .{ .init_body = "return { number = 0/0 }", .needle = "not finite" },
        .{ .init_body = "return { number = 1/0 }", .needle = "not finite" },
        .{ .init_body = "return { number = -1/0 }", .needle = "not finite" },
        .{ .init_body = "return { value = function() end }", .needle = "holds a function" },
    };

    for (cases) |case| {
        var source_buf: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&source_buf,
            \\return {{
            \\  state_version = 1,
            \\  init = function() {s} end,
            \\  update = function() end,
            \\}}
        , .{case.init_body});
        var runtime: script.Runtime = .{};
        try runtime.init(gpa, .{});
        defer runtime.deinit();
        try runtime.loadModule(source, "adversarial:state");
        try testing.expectError(error.ResultFailed, runtime.initState());
        try testing.expectEqual(script.Category.contract, runtime.category());
        try testing.expect(std.mem.indexOf(u8, runtime.diagnostic(), case.needle) != null);
        try testing.expectEqual(@as(i64, 9), try runtime.execute("return 9"));
    }
}

test "snapshot allocation refusal is contained at every allocation point" {
    const sanity_ceiling: usize = 128;
    var fail_index: usize = 0;
    var failures: usize = 0;
    var reached_success = false;
    while (fail_index < sanity_ceiling) : (fail_index += 1) {
        var budget: script.Budget = .{ .limit = 16 * 1024 * 1024, .used = 0, .peak = 0 };
        var runtime: script.Runtime = .{};
        try runtime.init(gpa, .{ .budget = &budget });
        defer runtime.deinit();
        try loadState(&runtime, state_module, "adversarial:snapshot");
        const before = budget.used;

        runtime.failAfterAllocations(fail_index);
        const measured = runtime.stateSize() catch |err| {
            try testing.expectEqual(error.MemoryLimit, err);
            try testing.expectEqual(script.Category.memory_limit, runtime.category());
            runtime.clearAllocationFailure();
            // Lua may collect garbage left by an earlier successful invocation while
            // unwinding. The refusal must never retain a new charge.
            try testing.expect(budget.used <= before);
            try runtime.update(.{ .tick = 1, .delta_ns = 16_666_667 });
            failures += 1;
            continue;
        };
        const bytes = try gpa.alloc(u8, measured);
        defer gpa.free(bytes);
        _ = runtime.snapshotState(bytes) catch |err| {
            try testing.expectEqual(error.MemoryLimit, err);
            try testing.expectEqual(script.Category.memory_limit, runtime.category());
            runtime.clearAllocationFailure();
            try testing.expect(budget.used <= before);
            try runtime.update(.{ .tick = 1, .delta_ns = 16_666_667 });
            failures += 1;
            continue;
        };
        runtime.clearAllocationFailure();
        reached_success = true;
        break;
    }
    try testing.expect(failures > 0);
    try testing.expect(reached_success);
}

test "migration allocation refusal is contained at every allocation point" {
    var old: script.Runtime = .{};
    try old.init(gpa, .{});
    defer old.deinit();
    try loadState(&old, state_module, "adversarial:old");
    try old.update(.{ .tick = 1, .delta_ns = 16_666_667 });
    const needed = try old.stateSize();
    const snapshot = try gpa.alloc(u8, needed);
    defer gpa.free(snapshot);
    _ = try old.snapshotState(snapshot);

    const sanity_ceiling: usize = 128;
    var fail_index: usize = 0;
    var failures: usize = 0;
    var reached_success = false;
    while (fail_index < sanity_ceiling) : (fail_index += 1) {
        var budget: script.Budget = .{ .limit = 16 * 1024 * 1024, .used = 0, .peak = 0 };
        var candidate: script.Runtime = .{};
        try candidate.init(gpa, .{ .budget = &budget });
        defer candidate.deinit();
        try candidate.loadModule(migration_module, "adversarial:new");
        const before = budget.used;

        candidate.failAfterAllocations(fail_index);
        if (candidate.migrateState(snapshot, 1)) |_| {
            candidate.clearAllocationFailure();
            reached_success = true;
            break;
        } else |err| {
            try testing.expectEqual(error.MemoryLimit, err);
            try testing.expectEqual(script.Category.memory_limit, candidate.category());
            candidate.clearAllocationFailure();
            try testing.expect(budget.used <= before);
            // The failed candidate can retry cleanly, and the old package remains healthy.
            try candidate.migrateState(snapshot, 1);
            try candidate.update(.{ .tick = 2, .delta_ns = 16_666_667 });
            try old.update(.{ .tick = 2, .delta_ns = 16_666_667 });
            failures += 1;
        }
    }
    try testing.expect(failures > 0);
    try testing.expect(reached_success);
}

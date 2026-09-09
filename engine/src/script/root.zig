//! M8 step 1 scripting fixture.
//!
//! Every Lua call that can allocate, execute or raise stays inside the private C bridge's
//! protected `lua_pcall`; no Lua non-local exit may cross an active Zig frame. This step
//! intentionally exposes only text execution with one integer result, not gameplay bindings.
//! A host supplies the caller-owned allocator and must deinitialize the Runtime before
//! releasing that allocator. The bridge's allocator context is separately allocated so it
//! remains stable even if the Runtime value moves.

const std = @import("std");
const core = @import("core");
const Allocator = core.mem.Allocator;

const c = @cImport({
    @cInclude("foundry_script.h");
});

const max_alignment = @alignOf(std.c.max_align_t);

fn allocator(ctx: ?*anyopaque, pointer: ?*anyopaque, old_size: usize, new_size: usize) callconv(.c) ?*anyopaque {
    const owner: *Allocator = @ptrCast(@alignCast(ctx orelse return null));
    if (new_size == 0) {
        if (pointer) |value| {
            const old = @as([*]align(max_alignment) u8, @ptrCast(@alignCast(value)))[0..old_size];
            owner.free(old);
        }
        return null;
    }
    const next = owner.alignedAlloc(u8, .fromByteUnits(max_alignment), new_size) catch return null;
    if (pointer) |value| {
        const old = @as([*]align(max_alignment) const u8, @ptrCast(@alignCast(value)))[0..old_size];
        std.mem.copyForwards(u8, next[0..@min(old_size, new_size)], old[0..@min(old_size, new_size)]);
        owner.free(old);
    }
    return next.ptr;
}

pub const Config = struct {
    heap_limit: usize = c.FOUNDRY_SCRIPT_DEFAULT_HEAP_LIMIT,
    instruction_limit: u64 = c.FOUNDRY_SCRIPT_DEFAULT_INSTRUCTION_LIMIT,
    hook_period: u32 = c.FOUNDRY_SCRIPT_DEFAULT_HOOK_PERIOD,
    /// Test-only allocation refusal control; hosts must leave it at its default.
    fail_after_allocations: usize = c.FOUNDRY_SCRIPT_NEVER_FAIL,
    /// Test-only teardown failure control; not script or mod configuration.
    inject_teardown_failure: bool = false,
    /// Test-only result conversion failure control; not script or mod configuration.
    inject_result_failure: bool = false,
    /// Test-only compile failure control; not script or mod configuration.
    inject_compile_failure: bool = false,
};

fn status(value: c.FoundryScriptStatus) c_int {
    return @intCast(value);
}

const AllocatorContext = struct {
    allocator: Allocator,
};

/// A single protected Lua fixture. `init` takes ownership of no allocator; it borrows the
/// caller's allocator until `deinit`. The bridge stores a stable separately allocated context
/// rather than a pointer into this struct, so moving the Runtime value after init is safe.
/// Callers must still call `deinit` before destroying the allocator. `execute` is deliberately
/// fixture-only: it accepts text and returns exactly one Lua integer.
pub const Runtime = struct {
    owner: Allocator = undefined,
    allocator_context: ?*AllocatorContext = null,
    script: ?*c.FoundryScript = null,

    pub fn init(self: *Runtime, owner: Allocator, config: Config) !void {
        if (self.script != null or self.allocator_context != null) return error.AlreadyInitialized;
        self.owner = owner;
        self.allocator_context = null;
        self.script = null;
        const context = owner.create(AllocatorContext) catch return error.BootstrapFailed;
        context.* = .{ .allocator = owner };
        self.allocator_context = context;
        const native_config = c.FoundryScriptConfig{
            .allocator = allocator,
            .allocator_userdata = context,
            .heap_limit = config.heap_limit,
            .instruction_limit = config.instruction_limit,
            .hook_period = config.hook_period,
            .fail_after_allocations = config.fail_after_allocations,
            .inject_teardown_failure = @intFromBool(config.inject_teardown_failure),
            .inject_result_failure = @intFromBool(config.inject_result_failure),
            .inject_compile_failure = @intFromBool(config.inject_compile_failure),
        };
        var script: ?*c.FoundryScript = null;
        if (c.foundry_script_create(&script, &native_config) != c.FOUNDRY_SCRIPT_OK) {
            owner.destroy(context);
            self.allocator_context = null;
            return error.BootstrapFailed;
        }
        self.script = script orelse {
            owner.destroy(context);
            self.allocator_context = null;
            return error.BootstrapFailed;
        };
    }

    /// Releases Lua, bridge storage, and the stable allocator context. This is mandatory
    /// before the caller releases `owner`.
    pub fn deinit(self: *Runtime) void {
        if (self.script) |script| c.foundry_script_destroy(script);
        self.script = null;
        if (self.allocator_context) |context| self.owner.destroy(context);
        self.allocator_context = null;
    }

    /// Executes one source chunk through the C-owned protected invocation.
    pub fn execute(self: *Runtime, source: []const u8) !i64 {
        const script = self.script orelse return error.NotInitialized;
        var result: c.FoundryScriptResult = undefined;
        return switch (status(c.foundry_script_execute(script, source.ptr, source.len, &result))) {
            c.FOUNDRY_SCRIPT_OK => result.integer,
            c.FOUNDRY_SCRIPT_INVALID_ARGUMENT => error.InvalidArgument,
            c.FOUNDRY_SCRIPT_COMPILE_ERROR => error.CompileFailed,
            c.FOUNDRY_SCRIPT_RUNTIME_ERROR => error.RuntimeFailed,
            c.FOUNDRY_SCRIPT_INSTRUCTION_LIMIT => error.InstructionLimit,
            c.FOUNDRY_SCRIPT_MEMORY_LIMIT => error.MemoryLimit,
            c.FOUNDRY_SCRIPT_RESULT_ERROR => error.ResultFailed,
            else => error.ExecutionFailed,
        };
    }

    pub fn failNextAllocation(self: *Runtime) void {
        if (self.script) |script| c.foundry_script_fail_next_allocation(script);
    }

    pub fn clearAllocationFailure(self: *Runtime) void {
        if (self.script) |script| c.foundry_script_clear_allocation_failure(script);
    }

    pub fn injectResultFailure(self: *Runtime, enabled: bool) void {
        if (self.script) |script| c.foundry_script_inject_result_failure(script, @intFromBool(enabled));
    }

    pub fn injectCompileFailure(self: *Runtime, enabled: bool) void {
        if (self.script) |script| c.foundry_script_inject_compile_failure(script, @intFromBool(enabled));
    }

    pub fn teardown(self: *Runtime) !void {
        const script = self.script orelse return error.NotInitialized;
        if (c.foundry_script_teardown(script) != c.FOUNDRY_SCRIPT_OK) return error.TeardownFailed;
        c.foundry_script_destroy(script);
        self.script = null;
    }

    pub fn diagnostic(self: *const Runtime) []const u8 {
        const script = self.script orelse return "";
        var length: usize = 0;
        const text = c.foundry_script_diagnostic(script, &length);
        return text[0..length];
    }
};

pub const Fixture = Runtime;

test "text execution uses only the allowlisted environment" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const source = "return (type(1) == 'number' and type(io) == 'nil' and type(os) == 'nil' and type(package) == 'nil' and type(debug) == 'nil' and type(coroutine) == 'nil' and type(load) == 'nil' and type(require) == 'nil' and type(pcall) == 'nil' and type(xpcall) == 'nil' and type(collectgarbage) == 'nil' and type(next) == 'nil' and type(rawset) == 'nil' and type(getmetatable) == 'nil' and type(setmetatable) == 'nil' and (2 + 3))";
    try std.testing.expectEqual(@as(i64, 5), try runtime.execute(source));
}

test "ipairs walks the supplied table" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const source = "local values = {4, 5}; local total = 0; for _, value in ipairs(values) do total = total + value end return total";
    try std.testing.expectEqual(@as(i64, 9), try runtime.execute(source));
}

test "instruction hook stops runaway text" {
    var config: Config = .{};
    config.instruction_limit = 1000;
    config.hook_period = 10;
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, config);
    defer runtime.deinit();

    const source = "local n = 0 while true do n = n + 1 end return n";
    try std.testing.expectError(error.InstructionLimit, runtime.execute(source));
    try std.testing.expectEqual(@as(i64, 1), try runtime.execute("return 1"));
}

test "recursive text fails inside the protected bridge" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const source = "local function f() return f() end return f()";
    if (runtime.execute(source)) |_| {
        return error.TestExpectedFailure;
    } else |failure| {
        try std.testing.expect(failure == error.RuntimeFailed or failure == error.InstructionLimit);
    }
    try std.testing.expectEqual(@as(i64, 2), try runtime.execute("return 2"));
}

test "bootstrap allocation failure is contained" {
    var config: Config = .{};
    config.fail_after_allocations = 0;
    var runtime: Runtime = .{};
    try std.testing.expectError(error.BootstrapFailed, runtime.init(std.testing.allocator, config));
}

test "source bounds are reported as invalid arguments" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const embedded_nul = [_]u8{ 'r', 'e', 't', 'u', 'r', 'n', ' ', '1', 0 };
    try std.testing.expectError(error.InvalidArgument, runtime.execute(embedded_nul[0..]));
    try std.testing.expectError(error.InvalidArgument, runtime.execute(""));

    const too_large = try std.testing.allocator.alloc(u8, 256 * 1024 + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, ' ');
    try std.testing.expectError(error.InvalidArgument, runtime.execute(too_large));
}

test "hook periods that do not fit Lua's int are refused" {
    var config: Config = .{};
    config.hook_period = @as(u32, @intCast(std.math.maxInt(c_int))) + 1;
    var runtime: Runtime = .{};
    try std.testing.expectError(error.BootstrapFailed, runtime.init(std.testing.allocator, config));
}

test "heap quota rejects a finite allocation and recovers" {
    var config: Config = .{};
    config.heap_limit = 64 * 1024;
    config.instruction_limit = 1_000_000;
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, config);
    defer runtime.deinit();

    const source = "local values = {}; for i = 1, 20000 do values[i] = i end return 1";
    try std.testing.expectError(error.MemoryLimit, runtime.execute(source));
    try std.testing.expectEqual(@as(i64, 2), try runtime.execute("return 2"));
}

test "allocation refusal is contained at every early index" {
    const sanity_ceiling = 4096;
    var fail_index: usize = 0;
    var succeeded = false;
    while (fail_index < sanity_ceiling) : (fail_index += 1) {
        var config: Config = .{};
        config.fail_after_allocations = fail_index;
        var runtime: Runtime = .{};
        if (runtime.init(std.testing.allocator, config)) |_| {
            defer runtime.deinit();
            if (runtime.execute("return 7")) |value| {
                try std.testing.expectEqual(@as(i64, 7), value);
                succeeded = true;
                break;
            } else |failure| {
                try std.testing.expectEqual(error.MemoryLimit, failure);
            }
        } else |failure| {
            try std.testing.expectEqual(error.BootstrapFailed, failure);
        }
    }
    try std.testing.expect(succeeded);
}

test "double initialization is refused without leaking" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();
    try std.testing.expectError(error.AlreadyInitialized, runtime.init(std.testing.allocator, .{}));
}

test "execution allocation failure is contained" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const source = "local value = {}; for i = 1, 100 do value[i] = i end return 1";
    runtime.failNextAllocation();
    try std.testing.expectError(error.MemoryLimit, runtime.execute(source));
    runtime.clearAllocationFailure();
    try std.testing.expectEqual(@as(i64, 9), try runtime.execute("return 9"));
}

test "compile and result failures are reported" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    const bad_source = "return (";
    try std.testing.expectError(error.CompileFailed, runtime.execute(bad_source));
    try std.testing.expectEqual(@as(i64, 2), try runtime.execute("return 2"));
    const bad_result = "return {}";
    try std.testing.expectError(error.ResultFailed, runtime.execute(bad_result));
    try std.testing.expectEqual(@as(i64, 3), try runtime.execute("return 3"));
    runtime.injectResultFailure(true);
    try std.testing.expectError(error.ResultFailed, runtime.execute("return 1"));
    runtime.injectResultFailure(false);
    runtime.injectCompileFailure(true);
    try std.testing.expectError(error.MemoryLimit, runtime.execute("return 1"));
    runtime.injectCompileFailure(false);
    const binary = "\x1bLua";
    try std.testing.expectError(error.CompileFailed, runtime.execute(binary));
}

test "non-string errors have stable diagnostics" {
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, .{});
    defer runtime.deinit();

    try std.testing.expectError(error.RuntimeFailed, runtime.execute("error({})"));
    const diagnostic = runtime.diagnostic();
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "table") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic, "0x") == null);
    try std.testing.expectEqual(@as(i64, 4), try runtime.execute("return 4"));
}

test "teardown failure injection does not cross the host boundary" {
    var config: Config = .{};
    config.inject_teardown_failure = true;
    var runtime: Runtime = .{};
    try runtime.init(std.testing.allocator, config);
    defer runtime.deinit();

    try std.testing.expectError(error.TeardownFailed, runtime.teardown());
}

//! Runtime stress scenarios run in child processes under a host-side deadline.
//!
//! The instruction hook and heap quota are deterministic guards. The deadline is only the
//! test harness's guard against a regression that would otherwise hang `zig build test`.

const std = @import("std");
const script = @import("script");

const Scenario = enum {
    runaway,
    recursion,
    heap,
};

fn child(gpa: std.mem.Allocator, scenario: Scenario) !u8 {
    var config: script.Config = .{};
    switch (scenario) {
        .runaway, .recursion => {
            config.instruction_limit = 10_000;
            config.prepare_instruction_limit = 10_000;
            config.hook_period = 10;
        },
        .heap => {
            config.heap_limit = 64 * 1024;
            config.instruction_limit = 1_000_000;
            config.prepare_instruction_limit = 1_000_000;
        },
    }

    var runtime: script.Runtime = .{};
    try runtime.init(gpa, config);
    defer runtime.deinit();

    switch (scenario) {
        .runaway => {
            if (runtime.execute("local n = 0 while true do n = n + 1 end return n")) |_| {
                return 10;
            } else |err| {
                if (err != error.InstructionLimit or runtime.category() != .instruction_limit) return 11;
            }
        },
        .recursion => {
            if (runtime.execute("local function f() return f() end return f()")) |_| {
                return 10;
            } else |err| {
                if (err != error.RuntimeFailed and err != error.InstructionLimit) return 12;
            }
        },
        .heap => {
            if (runtime.execute("local t = {}; for i = 1, 20000 do t[i] = i end return 1")) |_| {
                return 10;
            } else |err| {
                if (err != error.MemoryLimit or runtime.category() != .memory_limit) return 13;
            }
        },
    }

    // A contained terminal failure must leave the process and VM usable.
    if (try runtime.execute("return 73") != 73) return 14;
    return 0;
}

fn parseScenario(text: []const u8) ?Scenario {
    inline for (std.meta.tags(Scenario)) |tag| {
        if (std.mem.eql(u8, text, @tagName(tag))) return tag;
    }
    return null;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "--child")) {
            const scenario_text = args.next() orelse return 2;
            const scenario = parseScenario(scenario_text) orelse return 3;
            return child(gpa, scenario);
        }
        return 4;
    }

    const executable = try std.process.executablePathAlloc(init.io, gpa);
    defer gpa.free(executable);
    inline for (std.meta.tags(Scenario)) |scenario| {
        const result = try std.process.run(gpa, init.io, .{
            .argv = &.{ executable, "--child", @tagName(scenario) },
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(3) } },
        });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return code,
            else => return 5,
        }
    }
    return 0;
}

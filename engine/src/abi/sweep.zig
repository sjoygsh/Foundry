//! What is true of *every* entry point, checked by walking the table rather than by
//! remembering.
//!
//! Two properties, and both are the kind that decay if they are a list somebody maintains:
//!
//! * **Nothing crashes on garbage.** Every call, with every argument zeroed — null pointers,
//!   null handles, empty strings, zero enumerations — must return an error and must not
//!   fault. That is `public-abi.md` §17's garbage sweep, and it is the same discipline
//!   `.fpk`'s mutate-one-byte test applies to a file: a reader is worth what it does with
//!   input nobody sane would send.
//!
//! * **An absent subsystem answers `unavailable`.** Not a null function pointer, not a
//!   crash, and not `not_found` — which would tell a mod author the content is missing when
//!   the truth is that this host never had a content system (ADR-0026).
//!
//! Both walk `Api_v1`'s fields with `inline for`, so **a capability added to the table
//! without a refusal path fails these tests rather than shipping**. That is the whole reason
//! they are written this way: a hand-written list of forty calls is a list that is wrong
//! within a milestone.
//!
//! The order the checks run in is itself a decision, and it has two halves. **A pointer
//! argument is validated before the host is looked up**, so a null out-parameter is
//! `invalid_argument` even on a host with nothing bound: a null pointer is a mistake in the
//! mod whatever the host has, and answering `unavailable` would send its author looking in
//! the wrong place. **A value argument is validated after**, because whether an id or a
//! handle is meaningful is the subsystem's question and there is no subsystem to ask.

const std = @import("std");
const core = @import("core");

const api = @import("api.zig");
const host_mod = @import("host.zig");
const test_engine = @import("test_engine.zig");
const types = @import("types.zig");

const Api_v1 = api.Api_v1;
const Api_v2 = api.Api_v2;
const Result = types.Result;
const Str = types.Str;
const TestEngine = test_engine.TestEngine;

const Host = host_mod.HostOf(TestEngine);
const table = api.TableOf(Host).v1;
const table_v2 = api.TableOf(Host).v2;

const testing = std.testing;

/// Entry points the sweeps skip, and why. Kept short on purpose: every name here is a
/// property that is *not* being checked mechanically, so each needs a reason.
const exempt = [_][]const u8{
    // Returns a `FoundryStr` rather than a result, because a name is the answer. Its
    // refusal path — an unknown code — is an empty string, and is tested by hand below.
    "result_name",
    // Needs no subsystem by design, and writing a line at the sweep's zeroed level would
    // be an `err` line, which the test runner correctly treats as a failure. Tested by
    // hand below, at every level.
    "log_write",
};

/// Entry points that need no subsystem at all, and therefore have nothing to be unavailable
/// about. They are still swept for garbage; they are only skipped where the question is what
/// an absent subsystem answers.
const no_subsystem = [_][]const u8{"id_from_string"};

fn nameIn(comptime list: []const []const u8, comptime name: []const u8) bool {
    for (list) |e| {
        if (std.mem.eql(u8, e, name)) return true;
    }
    return false;
}

fn isExempt(comptime name: []const u8) bool {
    return nameIn(&exempt, name);
}

/// Whether a table field is a capability at all — `version` and `size` are not.
fn isCall(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    return @typeInfo(info.pointer.child) == .@"fn";
}

fn Signature(comptime T: type) type {
    return @typeInfo(T).pointer.child;
}

/// A zeroed argument of any type the table uses: null for a pointer, an empty string, a null
/// handle, zero for a number.
fn zeroed(comptime T: type) T {
    return std.mem.zeroes(T);
}

/// A *well-formed* argument, for the test that asks what an absent subsystem answers.
///
/// The distinction from `zeroed` is the point: a call refused for a null pointer has told us
/// nothing about whether it knows its subsystem is missing.
fn wellFormed(comptime T: type) T {
    if (T == Str) return .from("abi.sweep");

    return switch (@typeInfo(T)) {
        .int, .float => 0,
        .@"struct" => std.mem.zeroes(T),
        .optional => |opt| blk: {
            const info = @typeInfo(opt.child);
            if (info != .pointer) @compileError("the sweep has no well-formed value for " ++ @typeName(T));
            const ptr = info.pointer;
            // Storage per pointee type, shared across calls: every one of these is written
            // and discarded, so sharing is exactly as safe as it looks.
            const Slot = struct {
                var one: ptr.child = std.mem.zeroes(ptr.child);
                var many: [64]ptr.child = @splat(std.mem.zeroes(ptr.child));
            };
            break :blk switch (ptr.size) {
                .one => &Slot.one,
                .many => @as([*]ptr.child, &Slot.many),
                else => @compileError("the sweep has no well-formed value for " ++ @typeName(T)),
            };
        },
        else => @compileError("the sweep has no well-formed value for " ++ @typeName(T)),
    };
}

fn callWith(comptime field: std.builtin.Type.StructField, comptime argument: anytype) Result {
    const Fn = Signature(field.type);
    var args: std.meta.ArgsTuple(Fn) = undefined;
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |a| {
        @field(args, a.name) = argument(a.type);
    }
    return @call(.auto, @field(table, field.name), args);
}

test "every entry point refuses a zeroed call when nothing is bound" {
    // The table's own length, walked at comptime four times over. Raised rather than
    // reduced: the point of these sweeps is that they grow with the table.
    @setEvalBranchQuota(64 * @typeInfo(Api_v1).@"struct".fields.len);

    Host.unbindAny();

    inline for (@typeInfo(Api_v1).@"struct".fields) |field| {
        if (comptime isCall(field.type) and !isExempt(field.name)) {
            const result = callWith(field, zeroed);
            testing.expect(result.isError()) catch |err| {
                std.debug.print("{s} answered {s} to a zeroed call\n", .{ field.name, result.name() });
                return err;
            };
        }
    }
}

test "every entry point refuses a zeroed call when everything is bound" {
    // The table's own length, walked at comptime four times over. Raised rather than
    // reduced: the point of these sweeps is that they grow with the table.
    @setEvalBranchQuota(64 * @typeInfo(Api_v1).@"struct".fields.len);

    var engine: TestEngine = try .init(testing.allocator);
    defer engine.deinit();
    engine.settle();

    var host: Host = .{ .engine = &engine };
    host.bind();
    defer host.unbind();

    inline for (@typeInfo(Api_v1).@"struct".fields) |field| {
        if (comptime isCall(field.type) and !isExempt(field.name)) {
            const result = callWith(field, zeroed);
            testing.expect(result.isError()) catch |err| {
                std.debug.print("{s} answered {s} to a zeroed call\n", .{ field.name, result.name() });
                return err;
            };
        }
    }
}

test "an absent subsystem answers unavailable, not not_found and not a crash" {
    // The table's own length, walked at comptime four times over. Raised rather than
    // reduced: the point of these sweeps is that they grow with the table.
    @setEvalBranchQuota(64 * @typeInfo(Api_v1).@"struct".fields.len);

    // A host with nothing in it at all: bound, so the table finds it, and empty, so every
    // capability has to say what it says when its subsystem was never supplied.
    var host: Host = .{};
    host.bind();
    defer host.unbind();

    inline for (@typeInfo(Api_v1).@"struct".fields) |field| {
        if (comptime isCall(field.type) and !isExempt(field.name)) {
            if (comptime !nameIn(&no_subsystem, field.name)) {
                const result = callWith(field, wellFormed);
                testing.expectEqual(Result.unavailable, result) catch |err| {
                    std.debug.print("{s} answered {s} on an empty host\n", .{ field.name, result.name() });
                    return err;
                };
            }
        }
    }
}

test "the two calls that need no subsystem work on an empty host" {
    var host: Host = .{};
    host.bind();
    defer host.unbind();

    // Hashing a string is arithmetic; there is nothing to be unavailable.
    var id: types.ContentId = .none;
    try testing.expectEqual(Result.ok, table.id_from_string(.from("mymod:item.lantern"), &id));
    try testing.expectEqual(core.ContentId.fromString("mymod:item.lantern"), id);

    // And a mod refusing itself has to be able to say why, whatever the host has.
    try testing.expectEqual(Result.ok, table.log_write(.none, 2, .from("a mod says something")));
    try testing.expectEqualStrings("FOUNDRY_ERR_UNAVAILABLE", table.result_name(-4).bytes().?);
}

test "the table is one shape: every entry present, none null, and it says its own size" {
    // The table's own length, walked at comptime four times over. Raised rather than
    // reduced: the point of these sweeps is that they grow with the table.
    @setEvalBranchQuota(64 * @typeInfo(Api_v1).@"struct".fields.len);

    try testing.expectEqual(@as(u32, 1), table.version);
    try testing.expectEqual(@as(u32, @sizeOf(Api_v1)), table.size);

    // Not a tautology: the fields are non-optional pointers, so this asserts that the
    // *type* forbids a null entry — which is what makes "a capability whose subsystem is
    // absent is present and answers `unavailable`" enforceable rather than aspirational.
    inline for (@typeInfo(Api_v1).@"struct".fields) |field| {
        if (comptime isCall(field.type)) {
            try testing.expect(@typeInfo(field.type) == .pointer);
            try testing.expect(!@typeInfo(field.type).pointer.is_allowzero);
            try testing.expect(@typeInfo(field.type).pointer.size == .one);
        }
    }
}

test "get_api hands out v1 and v2 side by side and refuses unknown versions" {
    const Table = api.TableOf(Host);

    const v1 = Table.getApi(1) orelse return error.TestUnexpectedResult;
    const typed: *const Api_v1 = @ptrCast(@alignCast(v1));
    try testing.expectEqual(@as(u32, 1), typed.version);

    const v2 = Table.getApi(2) orelse return error.TestUnexpectedResult;
    const typed_v2: *const Api_v2 = @ptrCast(@alignCast(v2));
    try testing.expectEqual(@as(u32, 2), typed_v2.version);
    try testing.expectEqual(@as(u32, @sizeOf(Api_v2)), typed_v2.size);

    // V2 is separate storage rather than a cast, while every common capability reuses the
    // exact implementation and stays in v1's relative order.
    try testing.expect(v1 != v2);
    inline for (@typeInfo(Api_v1).@"struct".fields) |field| {
        if (comptime isCall(field.type)) {
            try testing.expect(@field(table, field.name) == @field(table_v2, field.name));
            try testing.expectEqual(@offsetOf(Api_v1, field.name), @offsetOf(Api_v2, field.name));
        }
    }

    // Refused legibly rather than by crashing, which is the whole reason the entry point
    // takes a query function instead of the table.
    try testing.expectEqual(@as(?*const anyopaque, null), Table.getApi(0));
    try testing.expectEqual(@as(?*const anyopaque, null), Table.getApi(3));
    try testing.expectEqual(@as(?*const anyopaque, null), Table.getApi(std.math.maxInt(u32)));

    // The same pointer every time: the table is static, so a mod may keep it.
    try testing.expectEqual(Table.getApi(1), Table.getApi(1));
    try testing.expectEqual(Table.getApi(2), Table.getApi(2));
}

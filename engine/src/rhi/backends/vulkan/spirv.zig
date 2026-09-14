//! Small, bounded SPIR-V inspection used by the Vulkan shader producer and runtime.
//!
//! This is deliberately not a reflection framework. M13 has four engine-owned stages and
//! needs two things: refuse bytes that are not a SPIR-V module before a driver sees them,
//! and keep the handful of shader-visible locations, descriptor bindings and block offsets
//! in agreement with `docs/design/rhi.md` §9. Content shader reflection remains future
//! material-system work (ADR-0038).

const std = @import("std");

pub const Error = error{
    Misaligned,
    TooShort,
    BadMagic,
    UnsupportedVersion,
    InvalidHeader,
    MalformedInstruction,
    UnterminatedString,
    MissingEntry,
    DecorationMismatch,
};

pub const Stage = enum(u32) {
    vertex = 0,
    fragment = 4,
};

pub const Profile = enum {
    sprite_vertex,
    sprite_fragment,
    quad_vertex,
    quad_fragment,
};

const magic: u32 = 0x0723_0203;
const max_version: u32 = 0x0001_0600;
const header_words: usize = 5;
const max_ids: u32 = 1 << 20;

const Op = struct {
    const name: u16 = 5;
    const entry_point: u16 = 15;
    const type_image: u16 = 25;
    const type_sampler: u16 = 26;
    const type_pointer: u16 = 32;
    const variable: u16 = 59;
    const decorate: u16 = 71;
    const member_decorate: u16 = 72;
};

const Decoration = struct {
    const block: u32 = 2;
    const col_major: u32 = 5;
    const matrix_stride: u32 = 7;
    const location: u32 = 30;
    const binding: u32 = 33;
    const descriptor_set: u32 = 34;
    const offset: u32 = 35;
};

const Storage = struct {
    const uniform_constant: u32 = 0;
    const input: u32 = 1;
    const uniform: u32 = 2;
    const output: u32 = 3;
    const push_constant: u32 = 9;
};

const Instruction = struct {
    at: usize,
    words: usize,
    opcode: u16,
};

fn word(bytes: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
}

fn instruction(bytes: []const u8, at: usize) Error!Instruction {
    const first = word(bytes, at);
    const count: usize = first >> 16;
    if (count == 0 or count > bytes.len / 4 - at) return error.MalformedInstruction;
    return .{ .at = at, .words = count, .opcode = @truncate(first) };
}

/// Checks only the SPIR-V envelope and instruction bounds. Semantic validity remains the
/// pinned `spirv-val` producer's job; this guard keeps malformed caller bytes away from Vulkan.
pub fn validate(bytes: []const u8) Error!void {
    if (bytes.len % 4 != 0) return error.Misaligned;
    if (bytes.len < header_words * 4) return error.TooShort;
    if (word(bytes, 0) != magic) return error.BadMagic;
    const version = word(bytes, 1);
    if (version == 0 or version > max_version) return error.UnsupportedVersion;
    if (word(bytes, 3) == 0 or word(bytes, 3) > max_ids or word(bytes, 4) != 0) {
        return error.InvalidHeader;
    }

    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        at += inst.words;
    }
}

fn stringEquals(bytes: []const u8, first_word: usize, end_word: usize, expected: []const u8) Error!bool {
    var index: usize = 0;
    var at = first_word * 4;
    const end = end_word * 4;
    while (at < end) : (at += 1) {
        const byte = bytes[at];
        if (byte == 0) return index == expected.len;
        if (index >= expected.len or byte != expected[index]) return false;
        index += 1;
    }
    return error.UnterminatedString;
}

pub fn hasEntry(bytes: []const u8, stage: Stage, name: []const u8) Error!bool {
    try validate(bytes);
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.entry_point and inst.words >= 4 and
            word(bytes, at + 1) == @intFromEnum(stage) and
            try stringEquals(bytes, at + 3, at + inst.words, name)) return true;
        at += inst.words;
    }
    return false;
}

fn namedId(bytes: []const u8, name: []const u8) Error!?u32 {
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.name and inst.words >= 3 and
            try stringEquals(bytes, at + 2, at + inst.words, name)) return word(bytes, at + 1);
        at += inst.words;
    }
    return null;
}

fn decorationValue(bytes: []const u8, target: u32, decoration: u32) Error!?u32 {
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.decorate and inst.words >= 4 and
            word(bytes, at + 1) == target and word(bytes, at + 2) == decoration)
        {
            return word(bytes, at + 3);
        }
        at += inst.words;
    }
    return null;
}

fn hasDecoration(bytes: []const u8, target: u32, decoration: u32) Error!bool {
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.decorate and inst.words >= 3 and
            word(bytes, at + 1) == target and word(bytes, at + 2) == decoration) return true;
        at += inst.words;
    }
    return false;
}

fn variableStorage(bytes: []const u8, target: u32) Error!?u32 {
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.variable and inst.words >= 4 and word(bytes, at + 2) == target) {
            return word(bytes, at + 3);
        }
        at += inst.words;
    }
    return null;
}

fn hasLocatedVariable(bytes: []const u8, location: u32, storage: u32) Error!bool {
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.decorate and inst.words >= 4 and
            word(bytes, at + 2) == Decoration.location and word(bytes, at + 3) == location)
        {
            if ((try variableStorage(bytes, word(bytes, at + 1))) == storage) return true;
        }
        at += inst.words;
    }
    return false;
}

fn bindingVariable(bytes: []const u8, set: u32, binding: u32, storage: u32) Error!?u32 {
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.decorate and inst.words >= 4 and
            word(bytes, at + 2) == Decoration.descriptor_set and word(bytes, at + 3) == set)
        {
            const target = word(bytes, at + 1);
            if ((try decorationValue(bytes, target, Decoration.binding)) == binding and
                (try variableStorage(bytes, target)) == storage) return target;
        }
        at += inst.words;
    }
    return null;
}

fn variablePointsTo(bytes: []const u8, variable: u32, storage: u32, pointee: u32) Error!bool {
    var pointer: ?u32 = null;
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.variable and inst.words >= 4 and
            word(bytes, at + 2) == variable and word(bytes, at + 3) == storage)
        {
            pointer = word(bytes, at + 1);
            break;
        }
        at += inst.words;
    }
    const pointer_id = pointer orelse return false;
    at = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.type_pointer and inst.words >= 4 and
            word(bytes, at + 1) == pointer_id and word(bytes, at + 2) == storage and
            word(bytes, at + 3) == pointee) return true;
        at += inst.words;
    }
    return false;
}

fn bindingHasType(bytes: []const u8, set: u32, binding: u32, storage: u32, type_opcode: u16) Error!bool {
    const variable = try bindingVariable(bytes, set, binding, storage) orelse return false;
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == type_opcode and inst.words >= 2 and
            try variablePointsTo(bytes, variable, storage, word(bytes, at + 1))) return true;
        at += inst.words;
    }
    return false;
}

fn hasMemberDecoration(
    bytes: []const u8,
    target: u32,
    member: u32,
    decoration: u32,
    value: ?u32,
) Error!bool {
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.member_decorate and inst.words >= 4 and
            word(bytes, at + 1) == target and word(bytes, at + 2) == member and
            word(bytes, at + 3) == decoration)
        {
            if (value == null) return true;
            if (inst.words >= 5 and word(bytes, at + 4) == value.?) return true;
        }
        at += inst.words;
    }
    return false;
}

fn require(ok: bool) Error!void {
    if (!ok) return error.DecorationMismatch;
}

fn requireConstants(bytes: []const u8, tint: bool) Error!void {
    const id = try namedId(bytes, "Constants") orelse return error.DecorationMismatch;
    try require(try hasDecoration(bytes, id, Decoration.block));
    var has_push_variable = false;
    var at: usize = header_words;
    while (at < bytes.len / 4) {
        const inst = try instruction(bytes, at);
        if (inst.opcode == Op.variable and inst.words >= 4 and word(bytes, at + 3) == Storage.push_constant and
            try variablePointsTo(bytes, word(bytes, at + 2), Storage.push_constant, id))
        {
            has_push_variable = true;
            break;
        }
        at += inst.words;
    }
    try require(has_push_variable);
    try require(try hasMemberDecoration(bytes, id, 0, Decoration.offset, 0));
    try require(try hasMemberDecoration(bytes, id, 0, Decoration.col_major, null));
    try require(try hasMemberDecoration(bytes, id, 0, Decoration.matrix_stride, 16));
    if (tint) try require(try hasMemberDecoration(bytes, id, 1, Decoration.offset, 64));
}

/// The four profiles are the complete M13 shader ABI. Adding a profile belongs to the future
/// material producer rather than growing this into general reflection.
pub fn validateProfile(bytes: []const u8, profile: Profile) Error!void {
    try validate(bytes);
    const stage: Stage = switch (profile) {
        .sprite_vertex, .quad_vertex => .vertex,
        .sprite_fragment, .quad_fragment => .fragment,
    };
    try require(try hasEntry(bytes, stage, "main"));

    switch (profile) {
        .sprite_vertex => {
            inline for (0..3) |location| try require(try hasLocatedVariable(bytes, location, Storage.input));
            inline for (0..2) |location| try require(try hasLocatedVariable(bytes, location, Storage.output));
            try requireConstants(bytes, false);
        },
        .sprite_fragment => {
            inline for (0..2) |location| try require(try hasLocatedVariable(bytes, location, Storage.input));
            try require(try hasLocatedVariable(bytes, 0, Storage.output));
            try require(try bindingHasType(bytes, 0, 0, Storage.uniform_constant, Op.type_image));
            try require(try bindingHasType(bytes, 0, 1, Storage.uniform_constant, Op.type_sampler));
        },
        .quad_vertex => {
            inline for (0..2) |location| try require(try hasLocatedVariable(bytes, location, Storage.input));
            try require(try hasLocatedVariable(bytes, 0, Storage.output));
            try requireConstants(bytes, true);
        },
        .quad_fragment => {
            try require(try hasLocatedVariable(bytes, 0, Storage.input));
            try require(try hasLocatedVariable(bytes, 0, Storage.output));
            try require(try bindingHasType(bytes, 0, 0, Storage.uniform_constant, Op.type_image));
            try require(try bindingHasType(bytes, 0, 1, Storage.uniform_constant, Op.type_sampler));
            try requireConstants(bytes, true);
            const frame = try namedId(bytes, "Frame") orelse return error.DecorationMismatch;
            try require(try hasDecoration(bytes, frame, Decoration.block));
            try require(try hasMemberDecoration(bytes, frame, 0, Decoration.offset, 0));
            const frame_variable = try bindingVariable(bytes, 0, 2, Storage.uniform) orelse return error.DecorationMismatch;
            try require(try variablePointsTo(bytes, frame_variable, Storage.uniform, frame));
        },
    }
}

test "malformed SPIR-V envelopes stop before instruction inspection" {
    const testing = std.testing;
    try testing.expectError(error.Misaligned, validate("not spirv"));
    try testing.expectError(error.TooShort, validate("nope"));

    var header = [_]u32{ magic, 0x0001_0600, 0, 2, 0 };
    try validate(std.mem.asBytes(&header));
    header[0] = 0;
    try testing.expectError(error.BadMagic, validate(std.mem.asBytes(&header)));
    header[0] = magic;
    header[4] = 1;
    try testing.expectError(error.InvalidHeader, validate(std.mem.asBytes(&header)));
}

test "entry selection reads the stage and bounded NUL name" {
    const testing = std.testing;
    const words = [_]u32{
        magic,                                0x0001_0600,                0, 3,           0,
        (@as(u32, 5) << 16) | Op.entry_point, @intFromEnum(Stage.vertex), 1, 0x6e69_616d, 0,
    };
    const bytes = std.mem.asBytes(&words);
    try testing.expect(try hasEntry(bytes, .vertex, "main"));
    try testing.expect(!try hasEntry(bytes, .fragment, "main"));
    try testing.expect(!try hasEntry(bytes, .vertex, "other"));
}

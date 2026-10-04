//! Host-owned selection and explicit installation layout (playable3d.md §8–§9).
const std = @import("std");
const app = @import("app");
const core = @import("core");
const data = @import("data");
const platform = @import("platform");

pub const Selection = struct {
    ids: [64]core.ContentId = undefined,
    len: usize = 0,

    /// Ordered, deduplicated and bounded; malformed bootstrap refuses the entire list.
    pub fn parse(text: []const u8) !Selection {
        var result: Selection = .{};
        var names = std.mem.splitScalar(u8, text, ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            if (name.len == 0) continue;
            const id = data.contentId(name) catch return error.InvalidSelection;
            const duplicate = for (result.ids[0..result.len]) |previous| {
                if (previous.eql(id)) break true;
            } else false;
            if (duplicate) continue;
            if (result.len == result.ids.len) return error.SelectionFull;
            result.ids[result.len] = id;
            result.len += 1;
        }
        return result;
    }
};

/// A bundle never falls back to reading an ambient parent directory.
pub fn contentDir(gpa: std.mem.Allocator, os: *platform.os.Os, bundled: bool) ![]u8 {
    if (!bundled) return app.contentDirOf(gpa, os, null);
    const exe = try os.executableDirAlloc(gpa);
    defer gpa.free(exe);
    return bundleContentDir(gpa, exe);
}

pub fn bundleContentDir(gpa: std.mem.Allocator, exe: []const u8) ![]u8 {
    if (!std.mem.eql(u8, std.fs.path.basename(exe), "MacOS")) return error.ContentUnavailable;
    const contents = std.fs.path.dirname(exe) orelse return error.ContentUnavailable;
    if (!std.mem.eql(u8, std.fs.path.basename(contents), "Contents")) return error.ContentUnavailable;
    return platform.os.joinPath(gpa, &.{ contents, "Resources", "content" });
}

test "court: package selection is ordered, deduplicated, validated and bounded" {
    const t = std.testing;
    const s = try Selection.parse(" noon:content, ,other:content,noon:content ");
    try t.expectEqual(@as(usize, 2), s.len);
    try t.expect(s.ids[0].eql(core.ContentId.fromString("noon:content")));
    try t.expect(s.ids[1].eql(core.ContentId.fromString("other:content")));
    try t.expectEqual(@as(usize, 0), (try Selection.parse(" , ")).len);
    try t.expectError(error.InvalidSelection, Selection.parse("noon:content,not-an-id"));
    var buffer: [2048]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    for (0..65) |i| try stream.print("p:item{d},", .{i});
    try t.expectError(error.SelectionFull, Selection.parse(stream.buffered()));
}

test "court: bundle content layout is explicit and refuses a loose executable" {
    const t = std.testing;
    const dir = try bundleContentDir(t.allocator, "/relocated/Court.app/Contents/MacOS");
    defer t.allocator.free(dir);
    try t.expectEqualStrings("/relocated/Court.app/Contents/Resources/content", dir);
    try t.expectError(error.ContentUnavailable, bundleContentDir(t.allocator, "/relocated/bin"));
    try t.expectError(error.ContentUnavailable, bundleContentDir(t.allocator, "/relocated/Court.app/Contents/notMacOS"));
    try t.expectError(error.ContentUnavailable, bundleContentDir(t.allocator, "/relocated/wrong/MacOS"));
}

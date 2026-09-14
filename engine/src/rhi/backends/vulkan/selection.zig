//! Choosing the Vulkan device, as plain data (`docs/design/vulkan.md` §5.1).
//!
//! Nothing here calls Vulkan or includes its headers. The backend reads each physical device
//! into a `Candidate`, and these functions decide. That keeps the rules testable on a machine
//! with no Vulkan driver at all, and keeps the refusal reasons the backend logs the same ones
//! the tests check.
//!
//! The choice is not simulation state. The same machine makes the same choice, which is all
//! I9's same-binary guarantee asks of it; which GPU a player owns is not an input the
//! simulation sees.

const std = @import("std");

/// Vulkan 1.3, the floor ADR-0037 accepted.
pub const min_api_version: u32 = apiVersion(1, 3);

/// A version packed the way `VK_MAKE_API_VERSION` packs it, with no patch or variant.
pub fn apiVersion(major: u32, minor: u32) u32 {
    return (major << 22) | (minor << 12);
}

pub fn versionMajor(version: u32) u32 {
    return (version >> 22) & 0x7f;
}

pub fn versionMinor(version: u32) u32 {
    return (version >> 12) & 0x3ff;
}

/// Whether `version` reaches the floor. The patch number and the variant bits Vulkan reserves
/// at the top are not part of that question.
pub fn meetsFloor(version: u32) bool {
    const major = versionMajor(version);
    return major > 1 or (major == 1 and versionMinor(version) >= versionMinor(min_api_version));
}

/// Device types, in the order the ranking prefers them.
pub const DeviceType = enum(u8) { discrete, integrated, virtual, cpu, other };

pub const QueueFamily = struct {
    graphics: bool,
    /// Presents to the surface the device is being chosen for. Ignored when nothing presents.
    present: bool = false,
};

pub const Needs = struct {
    /// A surface was provided, so the one queue must present to it and the device must offer
    /// `VK_KHR_swapchain`.
    present: bool = false,
};

/// One physical device, as the backend read it.
pub const Candidate = struct {
    /// Where the driver enumerated it: the last tie-break.
    index: u32,
    device_type: DeviceType,
    vendor_id: u32,
    device_id: u32,
    api_version: u32,
    dynamic_rendering: bool,
    synchronization2: bool,
    timeline_semaphore: bool,
    swapchain: bool,
    /// Whether any queue family supports graphics.
    graphics: bool,
    /// The queue family the device would use, from `queueFamily`, or null.
    queue_family: ?u32,
};

/// What a candidate lacks. A candidate with every field false qualifies.
pub const Unmet = struct {
    vulkan_1_3: bool = false,
    dynamic_rendering: bool = false,
    synchronization2: bool = false,
    timeline_semaphore: bool = false,
    graphics_queue: bool = false,
    present_queue: bool = false,
    swapchain: bool = false,

    pub fn none(self: Unmet) bool {
        return std.meta.eql(self, Unmet{});
    }

    /// The unmet requirements, comma-separated, for a log line. Truncated to `buf`.
    pub fn describe(self: Unmet, buf: []u8) []const u8 {
        var out: std.Io.Writer = .fixed(buf);
        var first = true;
        inline for (@typeInfo(Unmet).@"struct".fields) |field| {
            if (@field(self, field.name)) {
                // A full buffer only shortens the line.
                out.print("{s}{s}", .{ if (first) "" else ", ", @field(labels, field.name) }) catch {};
                first = false;
            }
        }
        return out.buffered();
    }

    /// Named as Vulkan names them, so a log line can be searched for in the specification.
    const labels = .{
        .vulkan_1_3 = "Vulkan 1.3",
        .dynamic_rendering = "dynamicRendering",
        .synchronization2 = "synchronization2",
        .timeline_semaphore = "timelineSemaphore",
        .graphics_queue = "a graphics queue",
        .present_queue = "a graphics queue that presents to the surface",
        .swapchain = "VK_KHR_swapchain",
    };
};

pub fn unmet(candidate: Candidate, needs: Needs) Unmet {
    return .{
        .vulkan_1_3 = !meetsFloor(candidate.api_version),
        .dynamic_rendering = !candidate.dynamic_rendering,
        .synchronization2 = !candidate.synchronization2,
        .timeline_semaphore = !candidate.timeline_semaphore,
        .graphics_queue = !candidate.graphics,
        .present_queue = candidate.graphics and candidate.queue_family == null,
        .swapchain = needs.present and !candidate.swapchain,
    };
}

/// The first queue family that supports graphics and, when presenting, the surface too.
/// One queue does everything in M13 (ADR-0037), so a device whose graphics and presentation
/// live in different families is refused rather than given a second queue.
pub fn queueFamily(families: []const QueueFamily, needs: Needs) ?u32 {
    for (families, 0..) |family, i| {
        if (family.graphics and (!needs.present or family.present)) return @intCast(i);
    }
    return null;
}

/// Which candidate to use: the best-ranked one that qualifies, or null when none does.
///
/// Discrete before integrated before virtual before CPU before anything else; then the lower
/// vendor ID, the lower device ID and the earlier enumeration. The IDs carry no preference of
/// their own. They only make two identical cards resolve the same way on every run.
pub fn choose(candidates: []const Candidate, needs: Needs) ?usize {
    var best: ?usize = null;
    for (candidates, 0..) |candidate, i| {
        if (!unmet(candidate, needs).none()) continue;
        if (best == null or preferred(candidate, candidates[best.?])) best = i;
    }
    return best;
}

fn preferred(a: Candidate, b: Candidate) bool {
    if (a.device_type != b.device_type) return @intFromEnum(a.device_type) < @intFromEnum(b.device_type);
    if (a.vendor_id != b.vendor_id) return a.vendor_id < b.vendor_id;
    if (a.device_id != b.device_id) return a.device_id < b.device_id;
    return a.index < b.index;
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn qualifying(index: u32, device_type: DeviceType) Candidate {
    return .{
        .index = index,
        .device_type = device_type,
        .vendor_id = 0x8086,
        .device_id = 0x56a1,
        .api_version = apiVersion(1, 4),
        .dynamic_rendering = true,
        .synchronization2 = true,
        .timeline_semaphore = true,
        .swapchain = true,
        .graphics = true,
        .queue_family = 0,
    };
}

/// That `candidate` lacks exactly `field` under `needs`, and is therefore never chosen.
fn expectOnlyUnmet(candidate: Candidate, needs: Needs, comptime field: []const u8) !void {
    const lacking = unmet(candidate, needs);
    inline for (@typeInfo(Unmet).@"struct".fields) |f| {
        try testing.expectEqual(comptime std.mem.eql(u8, f.name, field), @field(lacking, f.name));
    }
    try testing.expectEqual(@as(?usize, null), choose(&.{candidate}, needs));
}

test "the floor is Vulkan 1.3, whatever the patch and variant bits say" {
    try testing.expect(meetsFloor(apiVersion(1, 3)));
    try testing.expect(meetsFloor(apiVersion(1, 4) | 356));
    try testing.expect(meetsFloor(apiVersion(2, 0)));
    try testing.expect(!meetsFloor(apiVersion(1, 2) | 0xfff));
    // A variant in the top three bits is not a newer major version.
    try testing.expect(!meetsFloor((1 << 29) | apiVersion(1, 2)));
}

test "a discrete GPU is chosen over the others, wherever the driver listed it" {
    const listed = [_]Candidate{ qualifying(0, .integrated), qualifying(1, .cpu), qualifying(2, .discrete), qualifying(3, .virtual) };
    try testing.expectEqual(@as(?usize, 2), choose(&listed, .{}));
    try testing.expectEqual(@as(?usize, 0), choose(listed[0..2], .{}));
}

test "equally ranked devices resolve by vendor, then device, then enumeration" {
    var a = qualifying(0, .discrete);
    a.vendor_id = 0x10de;
    var b = qualifying(1, .discrete);
    b.vendor_id = 0x1002;
    try testing.expectEqual(@as(?usize, 1), choose(&.{ a, b }, .{}));

    b.vendor_id = a.vendor_id;
    b.device_id = a.device_id + 1;
    try testing.expectEqual(@as(?usize, 0), choose(&.{ a, b }, .{}));

    // Identical cards: the one the driver enumerated first, however the slice is ordered.
    b.device_id = a.device_id;
    try testing.expectEqual(@as(?usize, 0), choose(&.{ a, b }, .{}));
    try testing.expectEqual(@as(?usize, 1), choose(&.{ b, a }, .{}));
}

test "each missing requirement refuses a device and names what it lacks" {
    var old = qualifying(0, .discrete);
    old.api_version = apiVersion(1, 2);
    try expectOnlyUnmet(old, .{}, "vulkan_1_3");

    var no_dynamic = qualifying(0, .discrete);
    no_dynamic.dynamic_rendering = false;
    try expectOnlyUnmet(no_dynamic, .{}, "dynamic_rendering");

    var no_sync2 = qualifying(0, .discrete);
    no_sync2.synchronization2 = false;
    try expectOnlyUnmet(no_sync2, .{}, "synchronization2");

    var no_timeline = qualifying(0, .discrete);
    no_timeline.timeline_semaphore = false;
    try expectOnlyUnmet(no_timeline, .{}, "timeline_semaphore");

    var no_graphics = qualifying(0, .discrete);
    no_graphics.graphics = false;
    no_graphics.queue_family = null;
    try expectOnlyUnmet(no_graphics, .{}, "graphics_queue");
    try expectOnlyUnmet(no_graphics, .{ .present = true }, "graphics_queue");

    var no_present = qualifying(0, .discrete);
    no_present.queue_family = null;
    try expectOnlyUnmet(no_present, .{ .present = true }, "present_queue");

    var no_swapchain = qualifying(0, .discrete);
    no_swapchain.swapchain = false;
    try expectOnlyUnmet(no_swapchain, .{ .present = true }, "swapchain");
    // Offscreen, nothing presents, so a swapchain is not asked for.
    try testing.expectEqual(@as(?usize, 0), choose(&.{no_swapchain}, .{}));
}

test "no qualifying device is null, and the refusal reads as a list" {
    try testing.expectEqual(@as(?usize, null), choose(&.{}, .{}));

    var lacking = qualifying(0, .integrated);
    lacking.dynamic_rendering = false;
    lacking.swapchain = false;
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "dynamicRendering, VK_KHR_swapchain",
        unmet(lacking, .{ .present = true }).describe(&buf),
    );
    var tiny: [8]u8 = undefined;
    try testing.expectEqualStrings("dynamicR", unmet(lacking, .{ .present = true }).describe(&tiny));
}

test "the queue is the first graphics family, and the first that also presents when presenting" {
    const families = [_]QueueFamily{
        .{ .graphics = false, .present = true },
        .{ .graphics = true, .present = false },
        .{ .graphics = true, .present = true },
    };
    try testing.expectEqual(@as(?u32, 1), queueFamily(&families, .{}));
    try testing.expectEqual(@as(?u32, 2), queueFamily(&families, .{ .present = true }));
    // Graphics in one family and presentation in another is not one queue.
    try testing.expectEqual(@as(?u32, null), queueFamily(families[0..2], .{ .present = true }));
    try testing.expectEqual(@as(?u32, null), queueFamily(&.{}, .{}));
}

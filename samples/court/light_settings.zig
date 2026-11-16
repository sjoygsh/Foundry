//! The court's lighting: exposure and ambient from its config, and since M41 its lights as
//! `foundry:light` records the config's list places and a beacon names (`environment.md` §6.4,
//! ADR-0085). Copy bounded values out of the store; refuse an invalid list as a whole.
const std = @import("std");
const core = @import("core");
const data = @import("data");
const asset = @import("asset");
const render3d = @import("render3d");
const Vec3 = core.math.Vec3;
const Quat = core.math.Quat;
const Mat4 = core.math.Mat4;
const Fields = data.fpk.Fields;
const Invalid = error{InvalidLighting};

pub const LightSettings = struct {
    exposure_ev100: ?f32 = null,
    ambient: [3]f32 = .{ 0, 0, 0 },
    lights: [render3d.max_lights]render3d.Light = undefined,
    len: usize = 0,

    /// `fields` is the config's; each list entry's `light` is looked up in `store`. A light that
    /// is missing, not a `foundry:light`, or refused by its record's rules refuses the list.
    pub fn read(store: *const data.Store, fields: Fields) Invalid!LightSettings {
        var out: LightSettings = .{};
        if (index(fields, "exposure_ev100")) |i| {
            out.exposure_ev100 = try number(fields, i);
            const scale = render3d.lighting.exposureScale(out.exposure_ev100);
            if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidLighting;
        }
        if (index(fields, "ambient")) |i| {
            out.ambient = try rgb(fields, i);
            for (out.ambient) |v| if (v < 0) return error.InvalidLighting;
        }
        const i = index(fields, "lights") orelse return out;
        const list = (fields.listAt(i) catch return error.InvalidLighting) orelse return out;
        if (list.len > out.lights.len) return error.InvalidLighting;
        var caster = false;
        for (0..list.len) |n| {
            const entry = (list.nestedAt(@intCast(n)) catch return error.InvalidLighting) orelse return error.InvalidLighting;
            const light_i = index(entry, "light") orelse return error.InvalidLighting;
            const id = (entry.idAt(light_i) catch return error.InvalidLighting) orelse return error.InvalidLighting;
            var light = try lightRecord(store, id);
            const position = try xyz(entry, "position");
            const direction = try xyz(entry, "direction");
            // Direction is not an Euler angle: the authored vector is the light's −Z.
            const rotation = Quat.lookRotation(direction, .up) orelse
                Quat.lookRotation(direction, .right) orelse return error.InvalidLighting;
            light.world = Mat4.trs(position, rotation, .one);
            if (!render3d.lighting.valid(light)) return error.InvalidLighting;
            // Every spot and point light may cast since M40; still one directional caster.
            if (light.casts_shadow and light.kind == .directional) {
                if (caster) return error.InvalidLighting;
                caster = true;
            }
            out.lights[n] = light;
        }
        out.len = list.len;
        return out;
    }
};

/// The light `id` names, at the origin: missing, not a `foundry:light`, or refused by its
/// record's rules is `InvalidLighting`. The caller places it and checks it with its place.
pub fn lightRecord(store: *const data.Store, id: core.ContentId) Invalid!render3d.Light {
    const record = store.lookup(id) orelse return error.InvalidLighting;
    if (!record.schema_id.eql(asset.light.schema.id)) return error.InvalidLighting;
    const value = asset.light.decode(record.fields) catch return error.InvalidLighting;
    return render3d.content.lightOf(value);
}

fn index(fields: Fields, name: []const u8) ?u32 {
    for (fields.fields, 0..) |field, i| if (std.mem.eql(u8, field.name, name)) return @intCast(i);
    return null;
}

fn number(fields: Fields, i: u32) Invalid!f32 {
    const value = (fields.floatAt(i) catch return error.InvalidLighting) orelse return error.InvalidLighting;
    const narrowed: f32 = @floatCast(value);
    if (!std.math.isFinite(narrowed)) return error.InvalidLighting;
    return narrowed;
}

fn namedNumber(fields: Fields, name: []const u8) Invalid!f32 {
    return number(fields, index(fields, name) orelse return error.InvalidLighting);
}

fn rgb(fields: Fields, i: u32) Invalid![3]f32 {
    const nested = (fields.nestedAt(i) catch return error.InvalidLighting) orelse return error.InvalidLighting;
    return .{ try namedNumber(nested, "r"), try namedNumber(nested, "g"), try namedNumber(nested, "b") };
}

fn xyz(fields: Fields, name: []const u8) Invalid!Vec3 {
    const nested = (fields.nestedAt(index(fields, name) orelse return error.InvalidLighting) catch return error.InvalidLighting) orelse return error.InvalidLighting;
    return .init(try namedNumber(nested, "x"), try namedNumber(nested, "y"), try namedNumber(nested, "z"));
}

// Compile ordinary content through data, then read the same fields runtime uses.
fn checkSource(source: []const u8, expected: ?usize) !void {
    const gpa = std.testing.allocator;
    var diags: data.Diagnostics = .init(gpa, .default);
    defer diags.deinit(gpa);
    var schemas: data.Registry = .init(gpa, .default);
    defer schemas.deinit(gpa);
    _ = try schemas.register(gpa, asset.light.schema);
    var doc = try data.parser.parse(gpa, "lighting.fdt", source, .{ .namespace = "court" }, &diags);
    defer doc.deinit(gpa);
    var pkg = try data.check.Package.init(gpa, "court:content", 1, .default);
    defer pkg.deinit(gpa);
    try pkg.addDocument(gpa, &doc, &schemas, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &pkg, &schemas, &bytes);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    _ = try store.add(gpa, "court:content", bytes.items, &schemas, &diags);
    const fields = store.lookup(core.ContentId.fromString("court:config.main")).?.fields;
    if (expected) |len| {
        const settings = try LightSettings.read(&store, fields);
        try std.testing.expectEqual(len, settings.len);
        if (len > 0) {
            try std.testing.expectApproxEqAbs(@as(f32, 300), settings.lights[0].intensity, 1e-6);
            try std.testing.expect(settings.lights[0].casts_shadow);
            try std.testing.expectEqual(@as(f32, 0), settings.lights[0].source_radius);
            // The record says what the light is; the list, where.
            try std.testing.expectEqual(@as(f32, 0.9), settings.lights[0].color[1]);
        }
        if (len == 4) {
            try std.testing.expect(settings.lights[1].casts_shadow and settings.lights[2].casts_shadow);
            try std.testing.expectApproxEqAbs(@as(f32, 0.05), settings.lights[1].source_radius, 1e-6);
            try std.testing.expectEqual(@as(f32, 2), settings.lights[1].world.cols[3][1]);
            try std.testing.expectEqual(@as(f32, 0.3), settings.lights[2].inner_cone);
        }
    } else try std.testing.expectError(error.InvalidLighting, LightSettings.read(&store, fields));
}

const schema =
    \\@schema config {
    \\ exposure_ev100 f32 (default 6)
    \\ ambient { r f32 g f32 b f32 }
    \\ lights [{ light id position { x f32 y f32 z f32 }
    \\ direction { x f32 (default -1) y f32 (default -2) z f32 (default -1) } }]
    \\}
    \\foundry:light court:lights.sun { kind "directional" color { r 1 g 0.9 b 0.8 } intensity 300 casts_shadow true }
    \\foundry:light court:lights.lamp { kind "point" intensity 120 range 8 color { r 1 g 0.7 b 0.4 } casts_shadow true source_radius 0.05 }
    \\foundry:light court:lights.spot { kind "spot" intensity 120 range 8 inner_cone 0.3 outer_cone 0.5 color { r 1 g 1 b 1 } casts_shadow true source_radius 0.05 }
    \\@schema lamp_like { kind string intensity f32 color { r f32 g f32 b f32 } }
    \\lamp_like court:lights.fake { kind "point" intensity 40 color { r 0.5 g 0.5 b 0.5 } }
    \\
;
const sun = "{ light court:lights.sun position { x 0 y 0 z 0 } direction { x -1 y -2 z -1 } }";
const lamp = "{ light court:lights.lamp position { x 1 y 2 z 0 } direction { x -1 y -2 z -1 } }";
const spot = "{ light court:lights.spot position { x 0 y 2 z 2 } direction { x 0 y -1 z -1 } }";

test "lighting content places ordered, bounded light records and refuses unsafe lists" {
    try checkSource(schema ++ "config court:config.main { ambient { r 2 g 3 b 4 } lights [" ++ sun ++ "] }", 1);
    try checkSource(schema ++ "config court:config.main { ambient { r 0 g 0 b 0 } lights [] }", 0);
    // The same record placed twice is two lights; two casting suns are still refused.
    try checkSource(schema ++ "config court:config.main { ambient { r 0 g 0 b 0 } lights [" ++ sun ++ sun ++ "] }", null);
    // Lamps cast beside the sun, each with a size (`shadows-local.md` §12).
    try checkSource(schema ++ "config court:config.main { ambient { r 0 g 0 b 0 } lights [" ++ sun ++ lamp ++ spot ++ lamp ++ "] }", 4);
    try checkSource(schema ++ "config court:config.main { ambient { r -1 g 0 b 0 } lights [] }", null);
    try checkSource(schema ++ "config court:config.main { ambient { r 0 g 0 b 0 } exposure_ev100 -200 lights [] }", null);
    const base = schema ++ "config court:config.main { ambient { r 0 g 0 b 0 } lights [" ++ sun ++ "] }";
    const vertical = try std.mem.replaceOwned(u8, std.testing.allocator, base, "x -1 y -2 z -1", "x 0 y -1 z 0");
    defer std.testing.allocator.free(vertical);
    try checkSource(vertical, 1);
    // Each is the sun's record or its place, made wrong: every one refuses the list.
    const changes = [_][2][]const u8{
        .{ "\"directional\"", "\"unknown\"" },
        .{ "intensity 300", "intensity -1" },
        .{ "intensity 300", "intensity 300 range -1" },
        .{ "r 1 g 0.9", "r 2 g 0.9" },
        .{ "x -1 y -2 z -1", "x 0 y 0 z 0" },
        .{ "intensity 300", "intensity 300 inner_cone 1 outer_cone 0.5" },
        .{ "intensity 300", "intensity 300 source_radius -0.1" },
        .{ "intensity 300", "intensity 300 source_radius 0.5" },
        // A light that names no record, one that names a record of another kind, and one whose
        // record has a light's fields but is not a `foundry:light`.
        .{ "{ light court:lights.sun position", "{ light court:lights.moon position" },
        .{ "{ light court:lights.sun position", "{ light court:config.main position" },
        .{ "{ light court:lights.sun position", "{ light court:lights.fake position" },
    };
    for (changes) |change| {
        const bad = try std.mem.replaceOwned(u8, std.testing.allocator, base, change[0], change[1]);
        defer std.testing.allocator.free(bad);
        try checkSource(bad, null);
    }
    const many = try std.fmt.allocPrint(std.testing.allocator, "{s}config court:config.main {{ ambient {{ r 0 g 0 b 0 }} lights [{s}] }}", .{ schema, lamp ** 17 });
    defer std.testing.allocator.free(many);
    try checkSource(many, null);
}

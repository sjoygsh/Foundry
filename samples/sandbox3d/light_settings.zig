//! Sample-owned lighting content, not an engine light schema (`light.md` §10).
//! Copy bounded values out of the store; refuse an invalid list as a whole.
const std = @import("std");
const core = @import("core");
const data = @import("data");
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

    pub fn read(fields: Fields) Invalid!LightSettings {
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
            const kind_i = index(entry, "kind") orelse return error.InvalidLighting;
            const kind_name = (entry.stringAt(kind_i) catch return error.InvalidLighting) orelse return error.InvalidLighting;
            const kind = std.meta.stringToEnum(@FieldType(render3d.Light, "kind"), kind_name) orelse return error.InvalidLighting;
            const position = try xyz(entry, "position");
            const direction = try xyz(entry, "direction");
            // Direction is not an Euler angle: the authored vector is the light's −Z.
            const rotation = Quat.lookRotation(direction, .up) orelse
                Quat.lookRotation(direction, .right) orelse return error.InvalidLighting;
            const shadow_i = index(entry, "casts_shadow") orelse return error.InvalidLighting;
            const shadow = (entry.boolAt(shadow_i) catch return error.InvalidLighting) orelse false;
            const light: render3d.Light = .{
                .kind = kind,
                .color = try rgb(entry, index(entry, "color") orelse return error.InvalidLighting),
                .intensity = try namedNumber(entry, "intensity"),
                .range = try namedNumber(entry, "range"),
                .inner_cone = try namedNumber(entry, "inner_cone"),
                .outer_cone = try namedNumber(entry, "outer_cone"),
                .casts_shadow = shadow,
                .world = Mat4.trs(position, rotation, .one),
            };
            if (!render3d.lighting.valid(light)) return error.InvalidLighting;
            if (shadow) {
                if (kind != .directional or caster) return error.InvalidLighting;
                caster = true;
            }
            out.lights[n] = light;
        }
        out.len = list.len;
        return out;
    }
};

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
    var doc = try data.parser.parse(gpa, "lighting.fdt", source, .{ .namespace = "sandbox3d" }, &diags);
    defer doc.deinit(gpa);
    var pkg = try data.check.Package.init(gpa, "sandbox3d:content", 1, .default);
    defer pkg.deinit(gpa);
    try pkg.addDocument(gpa, &doc, &schemas, &diags);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    try data.fpk.write(gpa, &pkg, &schemas, &bytes);
    var store: data.Store = .init(gpa, .default);
    defer store.deinit(gpa);
    _ = try store.add(gpa, "sandbox3d:content", bytes.items, &schemas, &diags);
    const fields = store.lookup(core.ContentId.fromString("sandbox3d:config.main")).?.fields;
    if (expected) |len| {
        const settings = try LightSettings.read(fields);
        try std.testing.expectEqual(len, settings.len);
        if (len > 0) {
            try std.testing.expectApproxEqAbs(@as(f32, 300), settings.lights[0].intensity, 1e-6);
            try std.testing.expect(settings.lights[0].casts_shadow);
        }
    } else try std.testing.expectError(error.InvalidLighting, LightSettings.read(fields));
}

const schema =
    \\@schema config {
    \\ exposure_ev100 f32 (default 6)
    \\ ambient { r f32 g f32 b f32 }
    \\ lights [{ kind string color { r f32 (default 1) g f32 (default 1) b f32 (default 1) } intensity f32 (default 300) range f32 (default 0)
    \\ inner_cone f32 (default 0) outer_cone f32 (default 0.785398)
    \\ casts_shadow bool (default false) position { x f32 y f32 z f32 }
    \\ direction { x f32 (default -1) y f32 (default -2) z f32 (default -1) } }]
    \\}
;
const good_light = "{ kind \"directional\" color { r 1 g 0.9 b 0.8 } intensity 300 casts_shadow true position { x 0 y 0 z 0 } direction { x -1 y -2 z -1 } }";

test "lighting content copies ordered bounded photometric values and refuses unsafe lists" {
    try checkSource(schema ++ "config sandbox3d:config.main { ambient { r 2 g 3 b 4 } lights [" ++ good_light ++ "] }", 1);
    try checkSource(schema ++ "config sandbox3d:config.main { ambient { r 0 g 0 b 0 } lights [] }", 0);
    try checkSource(schema ++ "config sandbox3d:config.main { ambient { r 0 g 0 b 0 } lights [" ++ good_light ++ good_light ++ "] }", null);
    try checkSource(schema ++ "config sandbox3d:config.main { ambient { r -1 g 0 b 0 } lights [] }", null);
    try checkSource(schema ++ "config sandbox3d:config.main { ambient { r 0 g 0 b 0 } exposure_ev100 -200 lights [] }", null);
    const base = schema ++ "config sandbox3d:config.main { ambient { r 0 g 0 b 0 } lights [" ++ good_light ++ "] }";
    const vertical = try std.mem.replaceOwned(u8, std.testing.allocator, base, "x -1 y -2 z -1", "x 0 y -1 z 0");
    defer std.testing.allocator.free(vertical);
    try checkSource(vertical, 1);
    const changes = [_][2][]const u8{
        .{ "\"directional\"", "\"unknown\"" },                             .{ "\"directional\"", "\"point\"" },
        .{ "intensity 300", "intensity -1" },                              .{ "intensity 300", "intensity 300 range -1" },
        .{ "r 1 g 0.9", "r 2 g 0.9" },                                     .{ "x -1 y -2 z -1", "x 0 y 0 z 0" },
        .{ "intensity 300", "intensity 300 inner_cone 1 outer_cone 0.5" },
    };
    for (changes) |change| {
        const bad = try std.mem.replaceOwned(u8, std.testing.allocator, base, change[0], change[1]);
        defer std.testing.allocator.free(bad);
        try checkSource(bad, null);
    }
    const many = try std.fmt.allocPrint(std.testing.allocator, "{s}config sandbox3d:config.main {{ ambient {{ r 0 g 0 b 0 }} lights [{s}] }}", .{ schema, good_light ** 17 });
    defer std.testing.allocator.free(many);
    try checkSource(many, null);
}

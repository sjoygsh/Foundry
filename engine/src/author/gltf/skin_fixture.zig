//! Generated, tiny authoring input for M24's import proofs; no external asset or license.
const std = @import("std");
const core = @import("core");
pub const nodes =
    \\{"name":"root","translation":[0,1,0],"children":[1]},
    \\{"name":"bridge","translation":[0,1,0],"children":[2]},
    \\{"name":"tip","translation":[0,1,0]},
    \\{"name":"ancestor","translation":[10,0,0],"children":[0]},
    \\{"name":"mesh","mesh":0,"skin":0,"translation":[900,900,900]}
;
pub const attributes = "\"POSITION\":0,\"JOINTS_0\":2,\"WEIGHTS_0\":3";
pub const skin = "{\"name\":\"Rig\",\"joints\":[2,0],\"inverseBindMatrices\":4}";
pub const animation = "{\"name\":\"walk\",\"samplers\":[{\"input\":5,\"output\":6}],\"channels\":[{\"sampler\":0,\"target\":{\"node\":2,\"path\":\"translation\"}}]}";
pub const accessors =
    \\{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
    \\{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"},
    \\{"bufferView":2,"componentType":5121,"count":3,"type":"VEC4"},
    \\{"bufferView":3,"componentType":5126,"count":3,"type":"VEC4"},
    \\{"bufferView":4,"componentType":5126,"count":2,"type":"MAT4"},
    \\{"bufferView":5,"componentType":5126,"count":2,"type":"SCALAR"},
    \\{"bufferView":6,"componentType":5126,"count":2,"type":"VEC3"}
;
pub const Parts = struct {
    nodes: []const u8 = nodes,
    roots: []const u8 = "3,4",
    skin: []const u8 = skin,
    animation: []const u8 = animation,
    attributes: []const u8 = attributes,
    accessors: []const u8 = accessors,
};
pub fn json(gpa: std.mem.Allocator, p: Parts) ![]u8 {
    return std.fmt.allocPrint(gpa, "{{\"asset\":{{\"version\":\"2.0\"}},\"buffers\":[{{\"uri\":\"rig.bin\",\"byteLength\":264}}]," ++
        "\"bufferViews\":[{{\"buffer\":0,\"byteLength\":36}},{{\"buffer\":0,\"byteOffset\":36,\"byteLength\":6}}," ++
        "{{\"buffer\":0,\"byteOffset\":44,\"byteLength\":12}},{{\"buffer\":0,\"byteOffset\":56,\"byteLength\":48}}," ++
        "{{\"buffer\":0,\"byteOffset\":104,\"byteLength\":128}},{{\"buffer\":0,\"byteOffset\":232,\"byteLength\":8}}," ++
        "{{\"buffer\":0,\"byteOffset\":240,\"byteLength\":24}}],\"accessors\":[{s}]," ++
        "\"meshes\":[{{\"primitives\":[{{\"attributes\":{{{s}}},\"indices\":1,\"material\":0}}]}}]," ++
        "\"materials\":[{{\"extensions\":{{\"KHR_materials_unlit\":{{}}}}}}],\"nodes\":[{s}]," ++
        "\"scenes\":[{{\"nodes\":[{s}]}}],\"skins\":[{s}],\"animations\":[{s}]}}", .{ p.accessors, p.attributes, p.nodes, p.roots, p.skin, p.animation });
}
pub fn putFloat(b: []u8, at: usize, v: f32) void {
    std.mem.writeInt(u32, b[at..][0..4], @bitCast(v), .little);
}
pub fn binary() [264]u8 {
    var b: [264]u8 = @splat(0);
    putFloat(&b, 12, 1);
    putFloat(&b, 28, 1);
    std.mem.writeInt(u16, b[38..40], 1, .little);
    std.mem.writeInt(u16, b[40..42], 2, .little);
    for (0..3) |v| putFloat(&b, 56 + v * 16, 1);
    for (0..2) |j| {
        var m = core.math.Mat4.identity;
        m.cols[3][0] = -10;
        m.cols[3][1] = if (j == 0) -3 else -1;
        for (0..4) |c| for (0..4) |r| {
            putFloat(&b, 104 + j * 64 + (c * 4 + r) * 4, m.cols[c][r]);
        };
    }
    putFloat(&b, 236, 1);
    putFloat(&b, 244, 1);
    putFloat(&b, 252, 2);
    putFloat(&b, 256, 1);
    return b;
}

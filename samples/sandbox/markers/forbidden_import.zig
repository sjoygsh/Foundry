//! Negative build probe: compiled in the markers module's own graph, this must not compile.

const net = @import("net");

pub export fn foundry_markers_forbidden_probe() usize {
    return @sizeOf(net.Service);
}

//! Negative build probe: this file must not compile in the client module graph.

const abi = @import("abi");

pub export fn foundry_editor_forbidden_probe() usize {
    return @sizeOf(abi.Api_v4);
}

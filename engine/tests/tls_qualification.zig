//! M16 Step 1's native provider qualification.
//!
//! The implementation is C because this test exercises Mbed TLS's C boundary
//! directly. No provider type enters an engine module, and no socket exists:
//! the peers exchange records through fixed in-memory BIOs.

const std = @import("std");

extern fn foundry_tls_qualification_run(
    out_peak_bytes: *usize,
    out_wire_peak_bytes: *usize,
    out_handshake_call_peak: *usize,
) c_int;

test "Mbed TLS 3.6.7 qualifies for bounded mutual TLS 1.3" {
    var allocation_peak: usize = 0;
    var wire_peak: usize = 0;
    var handshake_call_peak: usize = 0;
    try std.testing.expectEqual(
        @as(c_int, 0),
        foundry_tls_qualification_run(&allocation_peak, &wire_peak, &handshake_call_peak),
    );
    try std.testing.expect(allocation_peak > 0);
    try std.testing.expect(allocation_peak <= 16 * 1024 * 1024);
    try std.testing.expect(wire_peak > 0);
    try std.testing.expect(wire_peak <= 64 * 1024);
    try std.testing.expect(handshake_call_peak > 0);
    try std.testing.expect(handshake_call_peak <= 64);
}

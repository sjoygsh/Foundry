//! Disposable TLS identities for the M16 proofs, over `tls_identities.c`.
//!
//! Every identity is generated for the run — a fresh P-256 key, fixed validity dates,
//! never written to disk — so no key is committed and a proof that injects a clock
//! reaches the same verdict on every machine (`networking.md` §4.1). The C fixture is
//! linked into test binaries alone; nothing that can issue a certificate reaches
//! `platform`.
//!
//! It calls the provider directly, under the process-wide allocation hooks a
//! `Transport` installs, so a `Transport` must exist while identities are generated.

const std = @import("std");
const platform = @import("platform");

pub const pem_bytes = 4096;

pub const Authority = extern struct {
    name: [128]u8,
    certificate: [pem_bytes]u8,
    private_key: [pem_bytes]u8,
};

pub const Identity = extern struct {
    certificate: [pem_bytes]u8,
    private_key: [pem_bytes]u8,
    key_sha256: [32]u8,

    pub fn key(self: *const Identity) platform.transport.KeyFingerprint {
        return .{ .sha256 = self.key_sha256 };
    }
};

pub extern fn foundry_test_authority_create(out: *Authority, parent: ?*const Authority, name: [*:0]const u8, serial: u8) c_int;
pub extern fn foundry_test_issue(
    out: *Identity,
    authority: *const Authority,
    subject: [*:0]const u8,
    dns_name: ?[*:0]const u8,
    usage: c_int,
    serial: u8,
    not_before: [*:0]const u8,
    not_after: [*:0]const u8,
) c_int;

pub const server_auth = 1;
pub const client_auth = 2;

pub fn ok(result: c_int) !void {
    if (result != 0) {
        std.debug.print("test identity generation failed: -0x{x}\n", .{-result});
        return error.IdentityGenerationFailed;
    }
}

pub fn pem(bytes: []const u8) []const u8 {
    return std.mem.sliceTo(bytes, 0);
}

pub fn join(out: []u8, parts: []const []const u8) usize {
    var length: usize = 0;
    for (parts) |part| {
        @memcpy(out[length..][0..part.len], part);
        length += part.len;
    }
    return length;
}

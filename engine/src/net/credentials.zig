//! The operator's credential file, `foundry-credentials 1` (`networking.md` §8).
//!
//! A host-only text file the operator provisions. It is never content, never crosses the
//! public table, and nothing here logs or reports its paths or keys: a refusal names a line
//! or a part, never a value, because a value may be a path through somebody's home directory
//! or a key.
//!
//! ```
//! foundry-credentials 1
//! role        server | client
//! trust       <PEM roots>            relative paths are the file's own directory's
//! certificate <PEM chain, leaf first>
//! key         <PEM private key>      unencrypted P-256; wiped from memory once loaded
//! server-name <name>                 client only: the name the server certificate carries
//! server-key  <64 hex>               client only: SHA-256 of the server's public key
//! allow       <64 hex> <principal>   server only, repeatable: a client key it admits
//! ```
//!
//! One line, one fact, `#` comments, and the first line says what the file is and which
//! version (I8). A client names its server and allows no one; a server the opposite.
//!
//! **Why `net` owns it.** Every host that runs a session reads this file, and a format each
//! host parsed for itself would be several formats that must agree. It sits here rather
//! than in `platform` because an `allow` line is a `service.Identity` — the allowlist is
//! `net`'s — and it publishes nothing through the ABI: grants are what cross the table,
//! and a host builds them from what this returns.

const std = @import("std");
const platform = @import("platform");
const service = @import("service.zig");

const transport = platform.transport;
const Allocator = std.mem.Allocator;

/// How much a file may ask of the host. The defaults are sized for a server of hundreds of
/// players; a host that knows it needs fewer may say so, and one that needs more may too.
pub const Limits = struct {
    /// The credential file itself.
    file_bytes: usize = 64 * 1024,
    /// Each file it names: the trust roots, the certificate chain and the key.
    part_bytes: usize = 64 * 1024,
    /// `allow` lines.
    allowed: usize = 1024,
};

/// Where a refusal was, so a host can say so without repeating a value.
pub const Diagnostic = struct {
    /// The offending line, from 1, or 0 when the file is whole but not shaped for either
    /// role: a missing header, role, trust, certificate or key, or the other role's lines.
    line: usize = 0,
    /// Which named file could not be read, for `PartUnreadable`.
    part: ?Part = null,
};

pub const Part = enum { trust, certificate, key };

/// A parsed file. Paths and the server name are borrowed from the text it was parsed from;
/// the allowlist is owned.
pub const File = struct {
    role: transport.Role,
    trust: []const u8,
    certificate: []const u8,
    key: []const u8,
    server_name: []const u8 = "",
    server_key: ?transport.KeyFingerprint = null,
    allowed: []service.Identity = &.{},

    pub fn deinit(self: *File, gpa: Allocator) void {
        gpa.free(self.allowed);
        self.* = undefined;
    }
};

pub const ParseError = error{ Malformed, TooManyAllowed, OutOfMemory };

/// Parses a credential file. Every refusal sets `diagnostic.line`.
pub fn parse(gpa: Allocator, text: []const u8, limits: Limits, diagnostic: *Diagnostic) ParseError!File {
    diagnostic.* = .{};
    var role: ?transport.Role = null;
    var trust: []const u8 = "";
    var certificate: []const u8 = "";
    var key: []const u8 = "";
    var server_name: []const u8 = "";
    var server_key: ?transport.KeyFingerprint = null;
    var allowed: std.ArrayList(service.Identity) = .empty;
    errdefer allowed.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    var headed = false;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const word = words.next().?;
        const first = words.next() orelse "";
        const second = words.next() orelse "";
        if (words.next() != null) return malformed(diagnostic, number);
        if (!headed) {
            if (!std.mem.eql(u8, word, "foundry-credentials") or !std.mem.eql(u8, first, "1") or second.len != 0) {
                return malformed(diagnostic, number);
            }
            headed = true;
            continue;
        }
        if (first.len == 0) return malformed(diagnostic, number);
        if (std.mem.eql(u8, word, "allow")) {
            if (allowed.items.len == limits.allowed) {
                diagnostic.line = number;
                return error.TooManyAllowed;
            }
            const principal = std.fmt.parseInt(u32, second, 10) catch return malformed(diagnostic, number);
            if (principal == 0) return malformed(diagnostic, number);
            const fingerprint = parseFingerprint(first) orelse return malformed(diagnostic, number);
            try allowed.append(gpa, .{ .key = fingerprint, .principal = principal });
            continue;
        }
        if (second.len != 0) return malformed(diagnostic, number);
        if (std.mem.eql(u8, word, "role")) {
            role = std.meta.stringToEnum(transport.Role, first) orelse return malformed(diagnostic, number);
        } else if (std.mem.eql(u8, word, "trust")) {
            trust = first;
        } else if (std.mem.eql(u8, word, "certificate")) {
            certificate = first;
        } else if (std.mem.eql(u8, word, "key")) {
            key = first;
        } else if (std.mem.eql(u8, word, "server-name")) {
            server_name = first;
        } else if (std.mem.eql(u8, word, "server-key")) {
            server_key = parseFingerprint(first) orelse return malformed(diagnostic, number);
        } else return malformed(diagnostic, number);
    }
    if (!headed or role == null or trust.len == 0 or certificate.len == 0 or key.len == 0) {
        return malformed(diagnostic, 0);
    }
    const client = role.? == .client;
    if (client != (server_name.len != 0) or client != (server_key != null) or (client and allowed.items.len != 0)) {
        return malformed(diagnostic, 0);
    }
    return .{
        .role = role.?,
        .trust = trust,
        .certificate = certificate,
        .key = key,
        .server_name = server_name,
        .server_key = server_key,
        .allowed = try allowed.toOwnedSlice(gpa),
    };
}

fn malformed(diagnostic: *Diagnostic, line: usize) ParseError {
    diagnostic.line = line;
    return error.Malformed;
}

fn parseFingerprint(hex: []const u8) ?transport.KeyFingerprint {
    if (hex.len != 64) return null;
    var out: transport.KeyFingerprint = .{ .sha256 = undefined };
    _ = std.fmt.hexToBytes(&out.sha256, hex) catch return null;
    return out;
}

/// A credential file and everything it names, read and ready for
/// `Transport.createCredentials` and `service.Config.identities`. Owns all of it; `deinit`
/// wipes the key before freeing it.
pub const Loaded = struct {
    role: transport.Role,
    trust_roots: []u8,
    certificate_chain: []u8,
    private_key: []u8,
    server_name: []u8,
    server_key: ?transport.KeyFingerprint,
    allowed: []service.Identity,

    /// Borrows this value's bytes; valid until `deinit` or `wipeKey`.
    pub fn config(self: *const Loaded) transport.CredentialConfig {
        return .{
            .role = self.role,
            .trust_roots = self.trust_roots,
            .certificate_chain = self.certificate_chain,
            .private_key = self.private_key,
            .server_name = self.server_name,
            .server_key = self.server_key,
        };
    }

    /// Wipes and frees the private key now. `createCredentials` copies the key into the
    /// provider's own zeroized memory, so a host should call this once that returns rather
    /// than keep a second copy for the life of the session.
    pub fn wipeKey(self: *Loaded, gpa: Allocator) void {
        std.crypto.secureZero(u8, self.private_key);
        gpa.free(self.private_key);
        self.private_key = &.{};
    }

    pub fn deinit(self: *Loaded, gpa: Allocator) void {
        self.wipeKey(gpa);
        gpa.free(self.trust_roots);
        gpa.free(self.certificate_chain);
        gpa.free(self.server_name);
        gpa.free(self.allowed);
        self.* = undefined;
    }
};

pub const LoadError = ParseError || error{ FileUnreadable, RoleMismatch, PartUnreadable };

/// Reads and parses the file at `path`, checks it is for `role` when one is given, and reads
/// the files it names, relative ones against the file's own directory.
pub fn load(
    gpa: Allocator,
    os: *platform.os.Os,
    path: []const u8,
    role: ?transport.Role,
    limits: Limits,
    diagnostic: *Diagnostic,
) LoadError!Loaded {
    diagnostic.* = .{};
    const text = os.readFile(gpa, path, limits.file_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.FileUnreadable,
    };
    defer gpa.free(text);
    var file = try parse(gpa, text, limits, diagnostic);
    defer file.deinit(gpa);
    if (role) |expected| if (file.role != expected) return error.RoleMismatch;

    const dir = std.fs.path.dirname(path) orelse ".";
    const trust_roots = try readPart(gpa, os, dir, file.trust, .trust, limits, diagnostic);
    errdefer gpa.free(trust_roots);
    const certificate_chain = try readPart(gpa, os, dir, file.certificate, .certificate, limits, diagnostic);
    errdefer gpa.free(certificate_chain);
    const private_key = try readPart(gpa, os, dir, file.key, .key, limits, diagnostic);
    errdefer {
        std.crypto.secureZero(u8, private_key);
        gpa.free(private_key);
    }
    const server_name = try gpa.dupe(u8, file.server_name);
    errdefer gpa.free(server_name);
    const allowed = file.allowed;
    file.allowed = &.{};
    return .{
        .role = file.role,
        .trust_roots = trust_roots,
        .certificate_chain = certificate_chain,
        .private_key = private_key,
        .server_name = server_name,
        .server_key = file.server_key,
        .allowed = allowed,
    };
}

fn readPart(
    gpa: Allocator,
    os: *platform.os.Os,
    dir: []const u8,
    path: []const u8,
    part: Part,
    limits: Limits,
    diagnostic: *Diagnostic,
) LoadError![]u8 {
    const resolved = if (std.fs.path.isAbsolute(path)) try gpa.dupe(u8, path) else try std.fs.path.join(gpa, &.{ dir, path });
    defer gpa.free(resolved);
    return os.readFile(gpa, resolved, limits.part_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diagnostic.part = part;
            return error.PartUnreadable;
        },
    };
}

// -- tests ---------------------------------------------------------------------------

const testing = std.testing;
const zero_key = "00" ** 32;

fn expectRefused(expected: ParseError, text: []const u8, limits: Limits, line: usize) !void {
    var diagnostic: Diagnostic = .{};
    try testing.expectError(expected, parse(testing.allocator, text, limits, &diagnostic));
    try testing.expectEqual(line, diagnostic.line);
}

test "a credential file is versioned, role-shaped and refused by line" {
    var diagnostic: Diagnostic = .{};
    var server = try parse(testing.allocator, "foundry-credentials 1\n# a comment\nrole server\ntrust r.pem\ncertificate s.pem\nkey s.key\nallow " ++ zero_key ++ " 1\nallow " ++ zero_key ++ " 2\n", .{}, &diagnostic);
    defer server.deinit(testing.allocator);
    try testing.expectEqual(transport.Role.server, server.role);
    try testing.expectEqual(@as(usize, 2), server.allowed.len);
    try testing.expectEqual(@as(u32, 2), server.allowed[1].principal);

    var client = try parse(testing.allocator, "foundry-credentials 1\r\nrole client\r\ntrust r.pem\r\ncertificate p.pem\r\nkey p.key\r\nserver-name s.test\r\nserver-key " ++ zero_key ++ "\r\n", .{}, &diagnostic);
    defer client.deinit(testing.allocator);
    try testing.expectEqualStrings("s.test", client.server_name);
    try testing.expectEqualStrings("p.key", client.key);

    try expectRefused(error.Malformed, "role server\n", .{}, 1);
    try expectRefused(error.Malformed, "foundry-credentials 2\nrole server\n", .{}, 1);
    try expectRefused(error.Malformed, "foundry-credentials 1\nrole server\ntrust r\ncertificate c\nkey k\nserver-key " ++ zero_key ++ "\n", .{}, 0);
    try expectRefused(error.Malformed, "foundry-credentials 1\nrole client\ntrust r\ncertificate c\nkey k\n", .{}, 0);
    try expectRefused(error.Malformed, "foundry-credentials 1\nrole server\ntrust r\ncertificate c\nkey k\nallow abc 1\n", .{}, 6);
    try expectRefused(error.Malformed, "foundry-credentials 1\nrole server\ntrust r\ncertificate c\nkey k\nallow " ++ zero_key ++ " 0\n", .{}, 6);
    try expectRefused(error.Malformed, "foundry-credentials 1\nrole server\ntrust r\ncertificate c\nkey k\nverify off\n", .{}, 6);
    try expectRefused(error.Malformed, "foundry-credentials 1\nrole server extra\n", .{}, 2);
}

test "the allowlist is bounded by the host's limit, not a fixed array" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "foundry-credentials 1\nrole server\ntrust r\ncertificate c\nkey k\n");
    for (1..301) |principal| try text.print(testing.allocator, "allow {s} {d}\n", .{ zero_key, principal });

    var diagnostic: Diagnostic = .{};
    var file = try parse(testing.allocator, text.items, .{}, &diagnostic);
    defer file.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 300), file.allowed.len);

    // Five lines of header, so the 101st allow line is line 106.
    try expectRefused(error.TooManyAllowed, text.items, .{ .allowed = 100 }, 106);
}

test "load reads the named files beside the credential file, and says which one is missing" {
    const os = try platform.os.Os.init(testing.allocator, .{ .app_name = "foundry-test" });
    defer os.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    const path = try std.fs.path.join(testing.allocator, &.{ dir, "client.cred" });
    defer testing.allocator.free(path);
    try os.writeFile(path, "foundry-credentials 1\nrole client\ntrust r.pem\ncertificate c.pem\nkey c.key\nserver-name s.test\nserver-key " ++ zero_key ++ "\n");

    var diagnostic: Diagnostic = .{};
    try testing.expectError(error.RoleMismatch, load(testing.allocator, os, path, .server, .{}, &diagnostic));
    try testing.expectError(error.PartUnreadable, load(testing.allocator, os, path, .client, .{}, &diagnostic));
    try testing.expectEqual(Part.trust, diagnostic.part.?);

    for ([_][]const u8{ "r.pem", "c.pem", "c.key" }, [_][]const u8{ "roots", "chain", "secret" }) |name, bytes| {
        const part = try std.fs.path.join(testing.allocator, &.{ dir, name });
        defer testing.allocator.free(part);
        try os.writeFile(part, bytes);
    }
    var loaded = try load(testing.allocator, os, path, .client, .{}, &diagnostic);
    defer loaded.deinit(testing.allocator);
    const config = loaded.config();
    try testing.expectEqualStrings("roots", config.trust_roots);
    try testing.expectEqualStrings("chain", config.certificate_chain);
    try testing.expectEqualStrings("secret", config.private_key);
    try testing.expectEqualStrings("s.test", config.server_name);
    loaded.wipeKey(testing.allocator);
    try testing.expectEqual(@as(usize, 0), loaded.private_key.len);

    try testing.expectError(error.FileUnreadable, load(testing.allocator, os, "/definitely/not/here.cred", null, .{}, &diagnostic));
}

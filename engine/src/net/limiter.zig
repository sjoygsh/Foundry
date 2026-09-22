//! How often a TLS handshake may start: globally, and per source address
//! (`networking.md` §4, M16 Step 3).
//!
//! Every bucket keeps its credit as time rather than as tokens — a start costs
//! `1 s / rate` of credit and a bucket holds at most `burst` starts' worth — so the
//! arithmetic is integer, exact and needs nothing but the monotonic time a pump is
//! handed. A refused start takes nothing from any bucket.
//!
//! The per-source table is bounded. A source whose bucket has refilled is
//! indistinguishable from one never seen, so its entry is reused first; only when
//! every entry is still recovering does a new source go without one, and then it
//! shares a single overflow bucket at the per-source rate with every other such
//! source. Filling the table therefore makes starts stricter, never unlimited, and
//! never forgets a source that is still being limited.
//!
//! An address is an abuse signal, never an identity: many players behind one NAT
//! share a bucket, and can legitimately meet its limit.

const std = @import("std");
const limits_mod = @import("limits.zig");

const Allocator = std.mem.Allocator;

pub const Verdict = enum {
    allowed,
    /// This source has started too many handshakes recently.
    source_rate,
    /// Every source together has.
    global_rate,
};

const Bucket = struct {
    credit_ns: u64,
    updated_ns: u64,

    fn full(capacity_ns: u64, now: u64) Bucket {
        return .{ .credit_ns = capacity_ns, .updated_ns = now };
    }

    fn refill(self: *Bucket, capacity_ns: u64, now: u64) void {
        if (now > self.updated_ns) {
            self.credit_ns = @min(capacity_ns, self.credit_ns +| (now - self.updated_ns));
            self.updated_ns = now;
        }
    }

    fn isFullAt(self: Bucket, capacity_ns: u64, now: u64) bool {
        const elapsed = if (now > self.updated_ns) now - self.updated_ns else 0;
        return self.credit_ns +| elapsed >= capacity_ns;
    }
};

const Source = struct {
    address: [4]u8,
    bucket: Bucket,
    used: bool = false,
};

const Rate = struct {
    cost_ns: u64,
    capacity_ns: u64,

    fn of(per_second: u16, burst: u16) Rate {
        // Rounded up, so a limit is never looser than stated.
        const cost = (std.time.ns_per_s + @as(u64, per_second) - 1) / per_second;
        return .{ .cost_ns = cost, .capacity_ns = cost * burst };
    }
};

pub const Limiter = struct {
    global_rate: Rate,
    source_rate: Rate,
    global: Bucket,
    overflow: Bucket,
    sources: []Source,
    /// Sources that found no entry and were limited through `overflow`.
    overflowed: u64 = 0,

    pub fn init(gpa: Allocator, limits: limits_mod.Limits) (Allocator.Error || limits_mod.Error)!Limiter {
        try limits.validate();
        const global_rate = Rate.of(limits.handshake_starts_per_second, limits.handshake_start_burst);
        const source_rate = Rate.of(limits.handshake_starts_per_source_per_second, limits.handshake_start_per_source_burst);
        const sources = try gpa.alloc(Source, limits.source_limiter_entries);
        for (sources) |*source| source.* = .{ .address = undefined, .bucket = undefined };
        return .{
            .global_rate = global_rate,
            .source_rate = source_rate,
            .global = .full(global_rate.capacity_ns, 0),
            .overflow = .full(source_rate.capacity_ns, 0),
            .sources = sources,
        };
    }

    pub fn deinit(self: *Limiter, gpa: Allocator) void {
        gpa.free(self.sources);
        self.* = undefined;
    }

    /// Whether a handshake from `address` may start at `now`, charging both buckets
    /// only when it may. The source is judged first, so one noisy address is refused
    /// without spending the credit every other address shares.
    pub fn admit(self: *Limiter, address: [4]u8, now: u64) Verdict {
        self.global.refill(self.global_rate.capacity_ns, now);
        const bucket = self.sourceBucket(address, now);
        bucket.refill(self.source_rate.capacity_ns, now);
        if (bucket.credit_ns < self.source_rate.cost_ns) return .source_rate;
        if (self.global.credit_ns < self.global_rate.cost_ns) return .global_rate;
        bucket.credit_ns -= self.source_rate.cost_ns;
        self.global.credit_ns -= self.global_rate.cost_ns;
        return .allowed;
    }

    fn sourceBucket(self: *Limiter, address: [4]u8, now: u64) *Bucket {
        var reusable: ?*Source = null;
        for (self.sources) |*source| {
            if (!source.used) {
                if (reusable == null) reusable = source;
                continue;
            }
            if (std.mem.eql(u8, &source.address, &address)) return &source.bucket;
            if (reusable == null and source.bucket.isFullAt(self.source_rate.capacity_ns, now)) reusable = source;
        }
        if (reusable) |source| {
            source.* = .{ .address = address, .bucket = .full(self.source_rate.capacity_ns, now), .used = true };
            return &source.bucket;
        }
        self.overflowed += 1;
        return &self.overflow;
    }
};

// -- tests ----------------------------------------------------------------------------

const testing = std.testing;
const ms = std.time.ns_per_ms;

fn limiterWith(limits: limits_mod.Limits) !Limiter {
    return Limiter.init(testing.allocator, limits);
}

test "a source gets its burst, then its rate, and a refusal costs nothing" {
    var limiter = try limiterWith(.{});
    defer limiter.deinit(testing.allocator);
    const a = [4]u8{ 198, 51, 100, 1 };

    try testing.expectEqual(Verdict.allowed, limiter.admit(a, 0));
    try testing.expectEqual(Verdict.allowed, limiter.admit(a, 0));
    try testing.expectEqual(Verdict.source_rate, limiter.admit(a, 0));
    // Refusals take no credit: half a second later exactly one more start is due.
    for (0..100) |_| try testing.expectEqual(Verdict.source_rate, limiter.admit(a, 499 * ms));
    try testing.expectEqual(Verdict.allowed, limiter.admit(a, 500 * ms));
    try testing.expectEqual(Verdict.source_rate, limiter.admit(a, 500 * ms));
    // Credit never exceeds the burst, however long the source was quiet.
    try testing.expectEqual(Verdict.allowed, limiter.admit(a, 3600 * std.time.ns_per_s));
    try testing.expectEqual(Verdict.allowed, limiter.admit(a, 3600 * std.time.ns_per_s));
    try testing.expectEqual(Verdict.source_rate, limiter.admit(a, 3600 * std.time.ns_per_s));
}

test "many sources together meet the global rate" {
    var limiter = try limiterWith(.{});
    defer limiter.deinit(testing.allocator);
    var allowed: usize = 0;
    for (0..32) |index| {
        if (limiter.admit(.{ 203, 0, 113, @intCast(index) }, 0) == .allowed) allowed += 1;
    }
    try testing.expectEqual(@as(usize, 8), allowed);
    try testing.expectEqual(Verdict.global_rate, limiter.admit(.{ 203, 0, 113, 200 }, 0));
    try testing.expectEqual(Verdict.allowed, limiter.admit(.{ 203, 0, 113, 200 }, 125 * ms));
    // Time running backwards grants nothing.
    try testing.expectEqual(Verdict.global_rate, limiter.admit(.{ 203, 0, 113, 201 }, 0));
}

test "a full table reuses recovered entries, and otherwise gets stricter" {
    var limits: limits_mod.Limits = .{};
    limits.source_limiter_entries = 2;
    limits.handshake_starts_per_second = 1000;
    limits.handshake_start_burst = 1000;
    var limiter = try limiterWith(limits);
    defer limiter.deinit(testing.allocator);

    try testing.expectEqual(Verdict.allowed, limiter.admit(.{ 10, 0, 0, 1 }, 0));
    try testing.expectEqual(Verdict.allowed, limiter.admit(.{ 10, 0, 0, 2 }, 0));
    // Both entries are still recovering, so new sources share one overflow bucket at
    // the per-source rate: two starts between all of them, not two each.
    try testing.expectEqual(Verdict.allowed, limiter.admit(.{ 10, 0, 0, 3 }, 0));
    try testing.expectEqual(Verdict.allowed, limiter.admit(.{ 10, 0, 0, 4 }, 0));
    try testing.expectEqual(Verdict.source_rate, limiter.admit(.{ 10, 0, 0, 5 }, 0));
    try testing.expectEqual(@as(u64, 3), limiter.overflowed);
    // The tracked sources were not forgotten to make room.
    try testing.expectEqual(Verdict.allowed, limiter.admit(.{ 10, 0, 0, 1 }, 0));
    try testing.expectEqual(Verdict.source_rate, limiter.admit(.{ 10, 0, 0, 1 }, 0));

    // Once a tracked source has fully recovered its entry carries no information and
    // is reused for a new source.
    try testing.expectEqual(Verdict.allowed, limiter.admit(.{ 10, 0, 0, 6 }, std.time.ns_per_s));
    try testing.expectEqual(@as(u64, 3), limiter.overflowed);
}

//! The script package lifecycle: stable slots, one registered system per package,
//! activation, fault and teardown (scripting.md §10).
//!
//! **A slot outlives the VM inside it.** That is the whole reason this type exists rather
//! than a `Runtime` per package: the system registration, the issued identity and the
//! ownership ledger belong to the *package* and must survive a VM being replaced, which is
//! what step 6's reload does and what a fault already does today. So the callback the world
//! holds points at a slot forever, and what changes underneath it is which VM — or none.
//!
//! Like the rest of `script`, this reaches the engine only through the `FoundryApi_v2` table
//! a host hands it (ADR-0029). It imports no engine module, and every call it makes is one a
//! native mod could make. It is *trusted* — it uses source, asset, system and log calls a
//! script itself cannot reach (§7) — but it is not privileged: there is no private path here.

const std = @import("std");
const core = @import("core");
const root = @import("root.zig");

const c = root.c;
const Allocator = core.mem.Allocator;

/// The binding version this build publishes. A package asking for another one is refused
/// at activation rather than run against a surface it did not expect.
pub const binding_version: u32 = 1;

/// The longest package or entry spelling a slot keeps. Content ids are far shorter; a
/// longer one is truncated for display only and never for identity.
const max_name = 96;
const max_message = 512;

pub const Limits = struct {
    /// Enabled script packages (scripting.md §8). Also bounded by the ABI's own mod and
    /// system capacities, which answer for themselves at registration.
    packages: u32 = 16,
    /// Every VM, every copied source and every snapshot this manager holds at once (§8).
    memory: usize = 160 * 1024 * 1024,
    /// What each VM is created with. `get_api`, `self` and `ledger` are the manager's to
    /// fill and are ignored here.
    runtime: root.Config = .{},
};

/// What the application hands the manager for one package (scripting.md §3).
///
/// Copied, not borrowed: `script` never reads a `mod.Entry` or an asset payload, and the
/// conversion from one to the other belongs to the application that owns both.
pub const Descriptor = struct {
    /// The package's content id, which is its identity (I2) and the system's id.
    package: core.ContentId,
    /// Its spelling, for diagnostics and for the registered system's name.
    package_name: []const u8,
    /// The `foundry:script` asset the manifest named.
    entry: core.ContentId,
    /// The binding version the manifest asked for.
    binding: u32,
    /// The identity the host issued this package through its `abi.Host`. `script` never
    /// issues one: identities are the ABI host's, and a script gets the same kind a native
    /// mod gets.
    self: u64,
};

pub const Status = enum {
    /// Added, not yet activated.
    inert,
    /// A VM is loaded, initialised and registered; ticks reach it.
    ready,
    /// Disabled after a diagnosed failure. The registration and the ledger stay; the VM
    /// does not. What the script already did to the world stays done (§12).
    faulted,
};

pub const Phase = enum {
    load,
    init,
    update,
    teardown,

    fn label(self: Phase) []const u8 {
        return switch (self) {
            .load => "load",
            .init => "init",
            .update => "update",
            .teardown => "teardown",
        };
    }
};

/// One package's stable storage. Its address is the system callback's context and never
/// changes for the world's lifetime.
pub const Slot = struct {
    descriptor: Descriptor = undefined,
    status: Status = .inert,
    /// The api table, copied so a tick needs nothing but the slot.
    api: *const c.FoundryApi_v2 = undefined,
    budget: *root.Budget = undefined,

    /// What this package owns, and therefore all it may destroy. Stable across VM
    /// replacement, which is why it lives here and not in the VM (§11).
    ledger: root.Ledger = std.mem.zeroes(root.Ledger),
    runtime: root.Runtime = .{},
    has_runtime: bool = false,

    /// The held source reference, balanced at teardown or on a failed activation.
    asset: c.FoundryAsset = .{ .bits = 0 },
    has_asset: bool = false,
    source_revision: u64 = 0,
    registered: bool = false,

    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    /// What a diagnostic calls this script: the entry record's own spelling when content
    /// knows it, and the package's when it does not.
    chunk_buf: [max_name + 1]u8 = undefined,
    chunk_len: usize = 0,
    message_buf: [max_message]u8 = undefined,

    /// Bounded repeated-error suppression (§13): the same category on the same line, over
    /// and over, says nothing new after the third time.
    last_category: root.Category = .none,
    last_line: u32 = 0,
    repeats: u32 = 0,

    const repeat_limit: u32 = 3;

    pub fn name(self: *const Slot) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn chunkName(self: *const Slot) [:0]const u8 {
        return self.chunk_buf[0..self.chunk_len :0];
    }

    /// Entities this package spawned and has not removed.
    pub fn ownedCount(self: *const Slot) u32 {
        return self.ledger.count;
    }

    fn setChunkName(self: *Slot, text: []const u8) void {
        const length = @min(text.len, max_name);
        @memcpy(self.chunk_buf[0..length], text[0..length]);
        self.chunk_buf[length] = 0;
        self.chunk_len = length;
    }

    /// One line to the engine's log, tagged with this package's own identity — the same
    /// attributed logging a native mod gets, because that is the only one there is.
    fn write(self: *Slot, level: c.FoundryLogLevel, text: []const u8) void {
        const write_fn = self.api.log_write orelse return;
        _ = write_fn(
            .{ .bits = self.descriptor.self },
            level,
            .{ .ptr = text.ptr, .len = text.len },
        );
    }

    fn resultName(self: *const Slot, result: c.FoundryResult) []const u8 {
        const name_fn = self.api.result_name orelse return "unknown";
        const str = name_fn(result);
        if (str.ptr == null or str.len == 0) return "unknown";
        return str.ptr[0..@intCast(str.len)];
    }

    /// Everything §13 asks a diagnostic to carry: which package, which script, which line,
    /// which phase, which tick, a stable category and the next move.
    fn diagnose(self: *Slot, phase: Phase, at_tick: u64, category: root.Category, detail: []const u8) void {
        const line = if (self.has_runtime) self.runtime.errorLine() else 0;
        if (category == self.last_category and line == self.last_line) {
            self.repeats += 1;
            if (self.repeats == repeat_limit) {
                self.write(c.FOUNDRY_LOG_WARN, "further identical reports from this script are suppressed");
            }
            if (self.repeats >= repeat_limit) return;
        } else {
            self.last_category = category;
            self.last_line = line;
            self.repeats = 1;
        }

        // The line lives in its own buffer: the message is built over `message_buf`, and a
        // slice into what is being written is a slice into something already overwritten.
        var line_buf: [16]u8 = undefined;
        const suffix = if (line == 0)
            ""
        else
            std.fmt.bufPrint(&line_buf, ":{d}", .{line}) catch "";

        const text = std.fmt.bufPrint(
            &self.message_buf,
            "{s} / {s}{s} — {s}, tick {d}: {s} — {s}. Disabled; {s}.",
            .{
                self.name(),
                self.chunkName(),
                suffix,
                phase.label(),
                at_tick,
                category.label(),
                detail,
                category.action(),
            },
        ) catch blk: {
            // A detail too long for one line still has to reach the log with its identity
            // attached, so the identity is what survives the truncation.
            break :blk std.fmt.bufPrint(&self.message_buf, "{s} / {s} — {s}: {s}", .{
                self.name(), self.chunkName(), phase.label(), category.label(),
            }) catch category.label();
        };
        self.write(c.FOUNDRY_LOG_ERROR, text);
    }

    /// Disabled after a diagnosed failure before the package ever ran. Releases the VM and
    /// the source reference; the content the package brought stays loaded (§10).
    fn refuse(self: *Slot, phase: Phase, err: root.Error) void {
        self.status = .faulted;
        self.diagnose(phase, 0, self.runtime.category(), self.detailFor(err));
        self.closeRuntime();
        self.releaseAsset();
    }

    /// Releases the VM, keeping the registration, the identity and the ledger. What the
    /// world holds stays valid; what it points at stops doing anything.
    fn closeRuntime(self: *Slot) void {
        if (!self.has_runtime) return;
        self.runtime.deinit();
        self.has_runtime = false;
    }

    fn releaseAsset(self: *Slot) void {
        if (!self.has_asset) return;
        if (self.api.asset_release) |release| _ = release(self.asset);
        self.has_asset = false;
        self.asset = .{ .bits = 0 };
    }

    /// One fixed step, as the world's schedule reaches it.
    fn tick(self: *Slot, step: c.FoundryStep) void {
        if (self.status != .ready) return;
        self.runtime.update(step) catch |err| {
            const category = self.runtime.category();
            self.status = .faulted;
            self.diagnose(.update, step.tick, category, self.detailFor(err));
            // The VM goes; the ledger, the registration and the identity stay. A faulted
            // script's entities are still its own, and still in the world (§12).
            self.closeRuntime();
        };
    }

    fn detailFor(self: *Slot, err: root.Error) []const u8 {
        if (self.has_runtime) {
            const text = self.runtime.diagnostic();
            if (text.len != 0) return text;
        }
        return @errorName(err);
    }
};

/// What the world calls. It must never let a Lua error out, and it cannot: every path
/// below it ends in the bridge's own protected invocation (§4).
fn systemUpdate(ctx: ?*anyopaque, step: [*c]const c.FoundryStep) callconv(.c) void {
    const slot: *Slot = @ptrCast(@alignCast(ctx orelse return));
    if (step == null) return;
    slot.tick(step.*);
}

pub const Manager = struct {
    gpa: Allocator,
    get_api: c.FoundryGetApi,
    api: *const c.FoundryApi_v2,
    limits: Limits,
    /// Heap-allocated once and never grown, because a VM and a world registration both hold
    /// pointers into it.
    slots: []Slot,
    /// Heap-allocated for the same reason: every VM charges it before it allocates.
    budget: *root.Budget,
    count: u32 = 0,
    torn_down: bool = false,

    pub const InitError = error{ UnsupportedApi, OutOfMemory };

    /// Asks the host for version 2 and checks what it was given, exactly as a native mod
    /// does. A host offering only v1 is refused here, before any slot exists.
    pub fn init(gpa: Allocator, get_api: c.FoundryGetApi, limits: Limits) InitError!Manager {
        const query = get_api orelse return error.UnsupportedApi;
        const table: *const c.FoundryApi_v2 = @ptrCast(@alignCast(query(c.FOUNDRY_API_VERSION_2) orelse
            return error.UnsupportedApi));
        if (table.version != c.FOUNDRY_API_VERSION_2 or table.size < @sizeOf(c.FoundryApi_v2)) {
            return error.UnsupportedApi;
        }

        const slots = try gpa.alloc(Slot, limits.packages);
        errdefer gpa.free(slots);
        for (slots) |*each| each.* = .{};

        const budget = try gpa.create(root.Budget);
        budget.* = .{ .limit = limits.memory, .used = 0 };

        return .{
            .gpa = gpa,
            .get_api = get_api,
            .api = table,
            .limits = limits,
            .slots = slots,
            .budget = budget,
        };
    }

    /// Teardown, in the order §10 requires: stop ticking, then close VMs and release source
    /// references **while the ABI is still bound**, because releasing an asset is a call.
    /// The host unbinds the ABI and destroys the world after this returns.
    pub fn deinit(self: *Manager) void {
        // Idempotent: a host that tears scripts down at a named point in its shutdown and
        // also defers a teardown is doing the right thing twice, not making a mistake.
        if (self.torn_down) return;
        self.torn_down = true;
        for (self.slots[0..self.count]) |*each| {
            each.status = .faulted;
            each.closeRuntime();
            each.releaseAsset();
        }
        self.gpa.free(self.slots);
        self.gpa.destroy(self.budget);
        self.slots = &.{};
        self.count = 0;
    }

    /// Reserves a slot for one package. The slot is inert until `activate`.
    pub fn add(self: *Manager, descriptor: Descriptor) error{Limit}!*Slot {
        if (self.count >= self.slots.len) return error.Limit;
        const reserved = &self.slots[self.count];
        reserved.* = .{};
        reserved.descriptor = descriptor;
        reserved.api = self.api;
        reserved.budget = self.budget;
        const length = @min(descriptor.package_name.len, max_name);
        @memcpy(reserved.name_buf[0..length], descriptor.package_name[0..length]);
        reserved.name_len = length;
        reserved.setChunkName(reserved.name());
        self.count += 1;
        return reserved;
    }

    /// The slot at `index`, in the order packages were added.
    pub fn at(self: *Manager, index: u32) ?*Slot {
        return if (index < self.count) &self.slots[index] else null;
    }

    /// Activates every inert slot in the order they were added, which is the resolved
    /// order the application handed them in (§9). One package failing does not stop the
    /// next: a broken mod beside a working one is the ordinary case, not an exception.
    pub fn activateAll(self: *Manager) void {
        for (self.slots[0..self.count]) |*s| {
            if (s.status == .inert) self.activate(s);
        }
    }

    pub fn readyCount(self: *const Manager) u32 {
        var total: u32 = 0;
        for (self.slots[0..self.count]) |*s| {
            if (s.status == .ready) total += 1;
        }
        return total;
    }

    /// §10 steps 3 through 5: copy the source, prepare a VM, validate the module, run
    /// `init`, and only then publish by registering the system. Every failure releases
    /// everything it took and leaves the package's content loaded.
    pub fn activate(self: *Manager, target: *Slot) void {
        if (target.descriptor.binding != binding_version) {
            target.status = .faulted;
            var buf: [128]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &buf,
                "the package asks for binding {d}; this build publishes binding {d}",
                .{ target.descriptor.binding, binding_version },
            ) catch "the package asks for a binding version this build does not publish";
            target.diagnose(.load, 0, .unavailable, detail);
            return;
        }

        self.nameEntry(target);

        const source = self.copySource(target) orelse {
            target.status = .faulted;
            target.releaseAsset();
            return;
        };
        defer self.releaseSource(source);

        var config = self.limits.runtime;
        config.budget = self.budget;
        config.get_api = self.get_api;
        config.self = target.descriptor.self;
        config.ledger = &target.ledger;
        target.runtime = .{};
        target.runtime.init(self.gpa, config) catch |err| {
            target.status = .faulted;
            target.diagnose(.load, 0, switch (err) {
                error.UnsupportedApi => .unavailable,
                error.InvalidArgument => .contract,
                else => .memory_limit,
            }, @errorName(err));
            target.releaseAsset();
            return;
        };
        target.has_runtime = true;

        target.runtime.loadModule(source, target.chunkName()) catch |err| {
            target.refuse(.load, err);
            return;
        };
        target.runtime.initState() catch |err| {
            target.refuse(.init, err);
            return;
        };

        // Published last. Until the registration succeeds there is nothing for the world to
        // call, and after it fails there must be nothing either.
        var desc: c.FoundrySystemDesc = .{
            .id = .{ .hash = target.descriptor.package.hash },
            .name = .{ .ptr = target.name().ptr, .len = target.name().len },
            .ctx = target,
            .update = &systemUpdate,
        };
        const register = self.api.world_register_system orelse {
            target.status = .faulted;
            target.diagnose(.load, 0, .unavailable, "this host publishes no world");
            target.closeRuntime();
            target.releaseAsset();
            return;
        };
        const result = register(.{ .bits = target.descriptor.self }, &desc);
        if (result != c.FOUNDRY_OK) {
            target.status = .faulted;
            var buf: [160]u8 = undefined;
            const detail = std.fmt.bufPrint(
                &buf,
                "the world refused this package's system: {s}",
                .{target.resultName(result)},
            ) catch "the world refused this package's system";
            target.diagnose(.load, 0, .unavailable, detail);
            target.closeRuntime();
            target.releaseAsset();
            return;
        }
        target.registered = true;
        target.status = .ready;
    }

    /// The entry record's own spelling, read out of content through the same calls a script
    /// reads content with. The package's spelling stands in when content cannot answer —
    /// a content id is a hash, and inventing a name from one would be worse than not having
    /// it.
    fn nameEntry(self: *Manager, target: *Slot) void {
        const find = self.api.content_find orelse return;
        const record_name = self.api.record_name orelse return;
        var record: c.FoundryRecord = .{ .bits = 0 };
        if (find(.{ .hash = target.descriptor.entry.hash }, &record) != c.FOUNDRY_OK) return;
        var str: c.FoundryStr = .{ .ptr = null, .len = 0 };
        if (record_name(record, &str) != c.FOUNDRY_OK) return;
        if (str.ptr == null or str.len == 0) return;
        target.setChunkName(str.ptr[0..@intCast(str.len)]);
    }

    /// Acquires the source asset, sizes it, and copies it into memory this manager has
    /// charged to the aggregate budget **before** allocating it (§8). The asset reference
    /// stays held: it is what a later revision is observed through.
    fn copySource(self: *Manager, target: *Slot) ?[]u8 {
        const acquire = self.api.asset_acquire orelse {
            target.diagnose(.load, 0, .unavailable, "this host publishes no assets");
            return null;
        };
        const copy = self.api.script_source_copy orelse {
            target.diagnose(.load, 0, .unavailable, "this host publishes no script source");
            return null;
        };

        var asset: c.FoundryAsset = .{ .bits = 0 };
        var result = acquire(.{ .hash = target.descriptor.entry.hash }, &asset);
        if (result != c.FOUNDRY_OK) {
            var buf: [160]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "the entry asset could not be acquired: {s}", .{
                target.resultName(result),
            }) catch "the entry asset could not be acquired";
            target.diagnose(.load, 0, .source_rejected, detail);
            return null;
        }
        target.asset = asset;
        target.has_asset = true;

        var needed: u64 = 0;
        var revision: u64 = 0;
        // The sizing probe answers `limit`: zero capacity is too small for any source, and
        // the size and revision are written either way. That is the call's contract, not a
        // refusal — a refusal is any *other* code, or a source with nothing in it.
        result = copy(asset, null, 0, &needed, &revision);
        if ((result != c.FOUNDRY_OK and result != c.FOUNDRY_ERR_LIMIT) or needed == 0) {
            var buf: [160]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "the entry is not readable script source: {s}", .{
                target.resultName(result),
            }) catch "the entry is not readable script source";
            target.diagnose(.load, 0, .source_rejected, detail);
            return null;
        }
        if (needed > std.math.maxInt(usize)) {
            target.diagnose(.load, 0, .memory_limit, "the entry source does not fit in memory");
            return null;
        }

        const size: usize = @intCast(needed);
        if (!self.reserve(size)) {
            target.diagnose(.load, 0, .memory_limit, "the manager's memory budget has no room for this source");
            return null;
        }
        const buffer = self.gpa.alloc(u8, size) catch {
            self.release(size);
            target.diagnose(.load, 0, .memory_limit, "the entry source could not be allocated");
            return null;
        };
        result = copy(asset, buffer.ptr, needed, &needed, &revision);
        if (result != c.FOUNDRY_OK) {
            self.gpa.free(buffer);
            self.release(size);
            var buf: [160]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "the entry source could not be copied: {s}", .{
                target.resultName(result),
            }) catch "the entry source could not be copied";
            target.diagnose(.load, 0, .source_rejected, detail);
            return null;
        }
        target.source_revision = revision;
        return buffer;
    }

    fn releaseSource(self: *Manager, source: []u8) void {
        self.release(source.len);
        self.gpa.free(source);
    }

    /// Charged before the allocation is attempted, so a refusal costs nothing (§8).
    fn reserve(self: *Manager, bytes: usize) bool {
        if (bytes > self.budget.limit - self.budget.used) return false;
        self.budget.used += bytes;
        return true;
    }

    fn release(self: *Manager, bytes: usize) void {
        self.budget.used -= @min(bytes, self.budget.used);
    }
};

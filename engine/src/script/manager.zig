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
    migrate,
    teardown,

    fn label(self: Phase) []const u8 {
        return switch (self) {
            .load => "load",
            .init => "init",
            .update => "update",
            .migrate => "migrate",
            .teardown => "teardown",
        };
    }
};

/// What one `Manager.pollReload` did.
pub const Reload = enum {
    /// No package offered a source revision this manager has not already seen.
    idle,
    /// A package is running new code. Its state and the entities it owns came across.
    reloaded,
    /// A package offered new source and it was refused. The last working version of that
    /// package is still the one running, and its state is untouched (scripting.md §12).
    refused,
};

/// The one package a poll looked at, and what happened to it.
pub const Poll = struct {
    outcome: Reload = .idle,
    slot: ?*Slot = null,
};

/// One package's stable storage. Its address is the system callback's context and never
/// changes for the world's lifetime.
pub const Slot = struct {
    descriptor: Descriptor = undefined,
    status: Status = .inert,
    /// The api table, the allocator and the budget, copied so a tick — or the snapshot a
    /// fault has to take before the VM goes — needs nothing but the slot.
    api: *const c.FoundryApi_v2 = undefined,
    gpa: Allocator = undefined,
    budget: *root.Budget = undefined,

    /// What this package owns, and therefore all it may destroy. Stable across VM
    /// replacement, which is why it lives here and not in the VM (§11).
    ledger: root.Ledger = std.mem.zeroes(root.Ledger),
    runtime: root.Runtime = .{},
    has_runtime: bool = false,

    /// The held source reference, balanced at teardown or on a failed activation.
    asset: c.FoundryAsset = .{ .bits = 0 },
    has_asset: bool = false,
    /// The revision the running VM was built from.
    source_revision: u64 = 0,
    /// The last revision a replacement was *attempted* on, whether or not it worked. Broken
    /// text is compiled once, not once a frame; retrying it is a host action (§12).
    attempted_revision: u64 = 0,
    registered: bool = false,
    /// How many times this package's code has been replaced under the same registration.
    reloads: u32 = 0,

    /// The state a VM left behind, as the bounded tree of §11, and the `state_version` it
    /// was written under. Held only while there is no VM to ask — which is what lets a fixed
    /// script pick up where a faulted one stopped, instead of running `init` again over a
    /// world it has already changed (§12).
    retained: ?[]u8 = null,
    retained_version: u32 = 0,

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

    /// One diagnostic, in the shape §13 asks for: which package, which script, which line,
    /// which phase, which tick, a stable category, what became of the package and the next
    /// move. `fate` and `line` are the two a caller must decide — a refused *replacement*
    /// leaves the package running, and a candidate VM's failure is on the candidate's line
    /// and not on the running VM's.
    const Note = struct {
        phase: Phase,
        category: root.Category,
        detail: []const u8,
        fate: Fate = .disabled,
        tick: u64 = 0,
        line: u32 = 0,
    };

    /// What a failure meant for the package. **A package that is still running is not an
    /// error**, which is `core.log`'s own distinction between the two levels, so the level
    /// follows from the fate rather than being chosen beside it.
    pub const Fate = enum {
        /// The package stops here.
        disabled,
        /// It stops here, and the state it had could not be kept either, so a later
        /// replacement cannot pick up where it left off (scripting.md §12).
        stranded,
        /// A replacement was refused and what was already running still is.
        kept,

        fn label(self: Fate) []const u8 {
            return switch (self) {
                .disabled => "Disabled",
                .stranded => "Disabled, and a replacement cannot resume from where it stopped",
                .kept => "The last working version is still running",
            };
        }

        fn level(self: Fate) c.FoundryLogLevel {
            return switch (self) {
                .disabled, .stranded => c.FOUNDRY_LOG_ERROR,
                .kept => c.FOUNDRY_LOG_WARN,
            };
        }
    };

    fn report(self: *Slot, note: Note) void {
        // Bounded repeated-error suppression (§13): the same category on the same line,
        // over and over, says nothing new after the third time.
        if (note.category == self.last_category and note.line == self.last_line) {
            self.repeats += 1;
            if (self.repeats == repeat_limit) {
                self.write(c.FOUNDRY_LOG_WARN, "further identical reports from this script are suppressed");
            }
            if (self.repeats >= repeat_limit) return;
        } else {
            self.last_category = note.category;
            self.last_line = note.line;
            self.repeats = 1;
        }

        // The line lives in its own buffer: the message is built over `message_buf`, and a
        // slice into what is being written is a slice into something already overwritten.
        var line_buf: [16]u8 = undefined;
        const suffix = if (note.line == 0)
            ""
        else
            std.fmt.bufPrint(&line_buf, ":{d}", .{note.line}) catch "";

        const text = std.fmt.bufPrint(
            &self.message_buf,
            "{s} / {s}{s} — {s}, tick {d}: {s} — {s}. {s}; {s}.",
            .{
                self.name(),
                self.chunkName(),
                suffix,
                note.phase.label(),
                note.tick,
                note.category.label(),
                note.detail,
                note.fate.label(),
                note.category.action(),
            },
        ) catch blk: {
            // A detail too long for one line still has to reach the log with its identity
            // attached, so the identity is what survives the truncation.
            break :blk std.fmt.bufPrint(&self.message_buf, "{s} / {s} — {s}: {s}", .{
                self.name(), self.chunkName(), note.phase.label(), note.category.label(),
            }) catch note.category.label();
        };
        self.write(note.fate.level(), text);
    }

    /// The line the running VM stopped on, when it knew one.
    fn line(self: *const Slot) u32 {
        return if (self.has_runtime) self.runtime.errorLine() else 0;
    }

    /// The package stops here.
    fn diagnose(self: *Slot, phase: Phase, at_tick: u64, category: root.Category, detail: []const u8) void {
        self.report(.{
            .phase = phase,
            .tick = at_tick,
            .category = category,
            .detail = detail,
            .line = self.line(),
        });
    }

    /// A replacement was refused and what was already running still is (§12).
    fn diagnoseKept(self: *Slot, phase: Phase, category: root.Category, detail: []const u8) void {
        self.report(.{
            .phase = phase,
            .category = category,
            .detail = detail,
            .fate = .kept,
        });
    }

    /// A package that is working again forgets what it was complaining about, so the next
    /// thing that goes wrong is reported rather than suppressed as a repeat of something
    /// that has since been fixed.
    fn clearSuppression(self: *Slot) void {
        self.last_category = .none;
        self.last_line = 0;
        self.repeats = 0;
    }

    /// Charged before the allocation is attempted, so a refusal costs nothing (§8).
    fn reserve(self: *Slot, bytes: usize) bool {
        if (bytes > self.budget.limit - self.budget.used) return false;
        self.budget.used += bytes;
        return true;
    }

    fn release(self: *Slot, bytes: usize) void {
        self.budget.used -= @min(bytes, self.budget.used);
    }

    /// Copies the VM's state out as §11's bounded value tree and keeps the bytes.
    ///
    /// **This is also the last check that the state is still state.** An `update` may put a
    /// function, a cycle or a foreign entity into a table `init` handed over clean, and the
    /// walk that writes the tree is the walk that finds out. A state that cannot be written
    /// is a package that cannot be replaced — §12's "explicit host restart" — and saying so
    /// at the moment it happens is more use than saying it later.
    fn retainState(self: *Slot, phase: Phase, fate: Fate) bool {
        self.dropRetained();
        if (!self.has_runtime) return false;
        const version = self.runtime.stateVersion();
        const needed = self.runtime.stateSize() catch |err| {
            self.report(.{
                .phase = phase,
                .category = self.runtime.category(),
                .detail = self.detailFor(err),
                .fate = fate,
                .line = self.line(),
            });
            return false;
        };
        if (needed == 0 or needed > root.max_snapshot) {
            self.report(.{
                .phase = phase,
                .category = .contract,
                .detail = "this script's state cannot be carried across",
                .fate = fate,
            });
            return false;
        }
        if (!self.reserve(needed)) {
            self.report(.{
                .phase = phase,
                .category = .memory_limit,
                .detail = "the manager's memory budget has no room for this state",
                .fate = fate,
            });
            return false;
        }
        const buffer = self.gpa.alloc(u8, needed) catch {
            self.release(needed);
            self.report(.{
                .phase = phase,
                .category = .memory_limit,
                .detail = "this script's state could not be copied out",
                .fate = fate,
            });
            return false;
        };
        const written = self.runtime.snapshotState(buffer) catch |err| {
            self.gpa.free(buffer);
            self.release(needed);
            self.report(.{
                .phase = phase,
                .category = self.runtime.category(),
                .detail = self.detailFor(err),
                .fate = fate,
                .line = self.line(),
            });
            return false;
        };
        if (written != needed) {
            self.gpa.free(buffer);
            self.release(needed);
            self.report(.{
                .phase = phase,
                .category = .contract,
                .detail = "this script's state changed size while it was copied",
                .fate = fate,
            });
            return false;
        }
        self.retained = buffer;
        self.retained_version = version;
        return true;
    }

    fn dropRetained(self: *Slot) void {
        const held = self.retained orelse return;
        self.release(held.len);
        self.gpa.free(held);
        self.retained = null;
        self.retained_version = 0;
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
        if (self.api.asset_release) |give_back| _ = give_back(self.asset);
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
            // Kept before the VM goes, because afterwards there is nothing left to ask.
            // §12 says a faulted package may be replaced on a new revision, and the only
            // honest thing to hand the replacement is the state the fault left behind:
            // `init` would run over a world this package has already changed.
            _ = self.retainState(.update, .stranded);
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
            each.dropRetained();
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
        reserved.gpa = self.gpa;
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

        var revision: u64 = 0;
        const source = self.copySource(target, .disabled, &revision) orelse {
            target.status = .faulted;
            target.releaseAsset();
            return;
        };
        defer self.releaseSource(target, source);
        target.source_revision = revision;

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
        target.clearSuppression();
    }

    /// Looks for one package whose source has been replaced under it, and replaces its code
    /// **without replacing the world** (scripting.md §12).
    ///
    /// **The host decides when.** Nothing here watches a file: a development host reloads
    /// its assets and then calls this, between one world update and the next, with no
    /// callback running and no script value borrowed. A shipped build never calls it.
    ///
    /// At most one package per call, in the order they were added, which is the resolved
    /// order. One candidate VM exists at a time, so a reload's peak cost is one extra VM and
    /// one copied source — not sixteen of each.
    ///
    /// **Content reload is a separate transaction and this one does not undo it.** A package
    /// whose replacement is refused keeps running the code it had, against whatever content
    /// is now loaded; a script must therefore handle a record that has changed or gone, the
    /// same way it must handle one a package after it overrode.
    pub fn pollReload(self: *Manager) Poll {
        for (self.slots[0..self.count]) |*each| {
            if (each.status == .inert) continue;
            const revision = self.observeRevision(each) orelse continue;
            if (revision == each.source_revision or revision == each.attempted_revision) continue;
            // Remembered before the attempt, not after it, so text that does not compile is
            // compiled once rather than once a frame. Retrying is a host action (§12).
            each.attempted_revision = revision;
            // A package that never registered has no state, no owned entities and no system.
            // What it needs is the activation that failed, not a replacement — and running
            // `init` is not "init over an existing world" when the package has never run.
            if (!each.registered) {
                self.activate(each);
                return .{
                    .outcome = if (each.status == .ready) .reloaded else .refused,
                    .slot = each,
                };
            }
            return .{ .outcome = self.replace(each, revision), .slot = each };
        }
        return .{};
    }

    /// The revision the entry's source is at now, or null when there is nothing to ask.
    ///
    /// A running package holds its asset reference and is asked through that. A package
    /// whose activation failed released everything it took (§10), so this acquires, asks and
    /// releases: three calls for a package that is currently broken, and none for one that
    /// is not. The reference is not quietly kept on its behalf, because a failed startup
    /// holding one is the thing §10 says it must not do.
    fn observeRevision(self: *Manager, target: *Slot) ?u64 {
        const copy = self.api.script_source_copy orelse return null;
        var asset = target.asset;
        var borrowed = false;
        if (!target.has_asset) {
            const acquire = self.api.asset_acquire orelse return null;
            if (acquire(.{ .hash = target.descriptor.entry.hash }, &asset) != c.FOUNDRY_OK) return null;
            borrowed = true;
        }
        defer if (borrowed) {
            if (self.api.asset_release) |give_back| _ = give_back(asset);
        };

        var needed: u64 = 0;
        var revision: u64 = 0;
        const result = copy(asset, null, 0, &needed, &revision);
        if (result != c.FOUNDRY_OK and result != c.FOUNDRY_ERR_LIMIT) {
            // A source that has merely gone from disk never reaches here: the asset registry
            // keeps the last payload that worked when a reload fails, by its own rule, so
            // the revision simply does not move. This is the asset no longer answering at
            // all. Reported, and bounded by the same suppression every report is.
            var buf: [160]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "the entry source can no longer be read: {s}", .{
                target.resultName(result),
            }) catch "the entry source can no longer be read";
            target.diagnoseKept(.load, .source_rejected, detail);
            return null;
        }
        return if (revision == 0) null else revision;
    }

    /// A candidate's failure, reported with the **candidate's** own line and message. The
    /// running VM is a different VM and its last error is a different error.
    fn refuseCandidate(target: *Slot, candidate: *root.Runtime, phase: Phase, err: root.Error) void {
        const text = candidate.diagnostic();
        target.report(.{
            .phase = phase,
            .category = candidate.category(),
            .detail = if (text.len != 0) text else @errorName(err),
            .fate = .kept,
            .line = candidate.errorLine(),
        });
    }

    /// §12's transaction, for one package.
    ///
    /// Everything before the commit builds a complete replacement beside the running one and
    /// may fail at any point. **Failing changes nothing**: not the VM, not its state, not the
    /// ledger, not the registration, not the world. The commit allocates nothing and runs no
    /// script code — it moves a `Runtime` value into the slot and closes the old one, and
    /// the next fixed tick runs the replacement.
    fn replace(self: *Manager, target: *Slot, revision: u64) Reload {
        // §12 step 4 asks the binding version to be validated with the module. A manifest
        // cannot change without a host restart, so this can only ever be what activation
        // already accepted — checking it is what says so.
        if (target.descriptor.binding != binding_version) {
            target.diagnoseKept(.load, .unavailable, "this package asks for a binding version this build does not publish");
            return .refused;
        }

        // Whatever happens below, a slot that ends with a VM keeps its state in that VM and
        // has no use for a copy. Only a slot left without one keeps the bytes, for its next
        // attempt. Registered first, so it runs last.
        defer if (target.has_runtime) target.dropRetained();

        // (1) The new source. Nothing has been asked of the running VM yet.
        var copied: u64 = 0;
        const source = self.copySource(target, .kept, &copied) orelse return .refused;
        defer self.releaseSource(target, source);

        // (2) The old state, as bytes. A running package still has a VM to ask; a faulted
        //     one kept the answer from the moment it faulted, because there is nothing left
        //     to ask now. Either way this is the last moment the old state exists.
        if (target.retained == null and !target.retainState(.update, .kept)) return .refused;
        const snapshot = target.retained orelse return .refused;
        const from_version = target.retained_version;

        // (3) The candidate, holding the package's own ledger and identity: those belong to
        //     the slot and not to whichever VM is running its code (§11).
        var config = self.limits.runtime;
        config.budget = self.budget;
        config.get_api = self.get_api;
        config.self = target.descriptor.self;
        config.ledger = &target.ledger;
        var candidate: root.Runtime = .{};
        candidate.init(self.gpa, config) catch |err| {
            target.diagnoseKept(.load, .memory_limit, @errorName(err));
            return .refused;
        };
        var committed = false;
        defer if (!committed) candidate.deinit();

        candidate.loadModule(source, target.chunkName()) catch |err| {
            refuseCandidate(target, &candidate, .load, err);
            return .refused;
        };

        // (4) The state, carried across or migrated. **`init` does not run.** A replacement
        //     whose state version is unchanged never respawns what the first activation
        //     spawned; a changed one must say how to convert, and there is no implicit
        //     reset if it does not (§12).
        if (candidate.stateVersion() == from_version) {
            candidate.restoreState(snapshot) catch |err| {
                refuseCandidate(target, &candidate, .migrate, err);
                return .refused;
            };
        } else {
            candidate.migrateState(snapshot, from_version) catch |err| {
                refuseCandidate(target, &candidate, .migrate, err);
                return .refused;
            };
        }

        // (5) The commit. A `Runtime` is three words, and the bridge's allocator context is
        //     separately allocated precisely so moving one is safe. The registration, the
        //     identity and the ledger are not touched: the world still calls the same slot.
        var previous = target.runtime;
        const had_runtime = target.has_runtime;
        target.runtime = candidate;
        target.has_runtime = true;
        target.source_revision = revision;
        target.reloads += 1;
        target.status = .ready;
        committed = true;
        if (had_runtime) previous.deinit();
        target.clearSuppression();
        return .reloaded;
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

    /// Copies the entry's current source into memory charged to the aggregate budget
    /// **before** it is allocated (§8), and reports the revision it came from.
    ///
    /// The asset reference is acquired once and then **kept**: it is what a later revision
    /// is observed through, and reacquiring it per reload would be a new handle every time
    /// for no reason. `fate` says what a failure means for the package, because the same
    /// copy serves a first activation and a replacement and only one of them disables it.
    fn copySource(self: *Manager, target: *Slot, fate: Slot.Fate, revision: *u64) ?[]u8 {
        const copy = self.api.script_source_copy orelse {
            target.report(.{ .phase = .load, .category = .unavailable, .detail = "this host publishes no script source", .fate = fate });
            return null;
        };

        if (!target.has_asset) {
            const acquire = self.api.asset_acquire orelse {
                target.report(.{ .phase = .load, .category = .unavailable, .detail = "this host publishes no assets", .fate = fate });
                return null;
            };
            var asset: c.FoundryAsset = .{ .bits = 0 };
            const acquired = acquire(.{ .hash = target.descriptor.entry.hash }, &asset);
            if (acquired != c.FOUNDRY_OK) {
                var buf: [160]u8 = undefined;
                const detail = std.fmt.bufPrint(&buf, "the entry asset could not be acquired: {s}", .{
                    target.resultName(acquired),
                }) catch "the entry asset could not be acquired";
                target.report(.{ .phase = .load, .category = .source_rejected, .detail = detail, .fate = fate });
                return null;
            }
            target.asset = asset;
            target.has_asset = true;
        }

        var needed: u64 = 0;
        // The sizing probe answers `limit`: zero capacity is too small for any source, and
        // the size and revision are written either way. That is the call's contract, not a
        // refusal — a refusal is any *other* code, or a source with nothing in it.
        var result = copy(target.asset, null, 0, &needed, revision);
        if ((result != c.FOUNDRY_OK and result != c.FOUNDRY_ERR_LIMIT) or needed == 0) {
            var buf: [160]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "the entry is not readable script source: {s}", .{
                target.resultName(result),
            }) catch "the entry is not readable script source";
            target.report(.{ .phase = .load, .category = .source_rejected, .detail = detail, .fate = fate });
            return null;
        }
        if (needed > std.math.maxInt(usize)) {
            target.report(.{ .phase = .load, .category = .memory_limit, .detail = "the entry source does not fit in memory", .fate = fate });
            return null;
        }

        const size: usize = @intCast(needed);
        if (!target.reserve(size)) {
            target.report(.{ .phase = .load, .category = .memory_limit, .detail = "the manager's memory budget has no room for this source", .fate = fate });
            return null;
        }
        const buffer = self.gpa.alloc(u8, size) catch {
            target.release(size);
            target.report(.{ .phase = .load, .category = .memory_limit, .detail = "the entry source could not be allocated", .fate = fate });
            return null;
        };
        result = copy(target.asset, buffer.ptr, needed, &needed, revision);
        if (result != c.FOUNDRY_OK) {
            self.gpa.free(buffer);
            target.release(size);
            var buf: [160]u8 = undefined;
            const detail = std.fmt.bufPrint(&buf, "the entry source could not be copied: {s}", .{
                target.resultName(result),
            }) catch "the entry source could not be copied";
            target.report(.{ .phase = .load, .category = .source_rejected, .detail = detail, .fate = fate });
            return null;
        }
        return buffer;
    }

    fn releaseSource(self: *Manager, target: *Slot, source: []u8) void {
        target.release(source.len);
        self.gpa.free(source);
    }
};

//! The mod set: what is installed, what the player chose, in what order, and what that
//! order does to the content.
//!
//! **One object for every question** a mod screen, the public ABI and startup ask, so the
//! three can never disagree (`mod-management.md` §4). Beneath it is `mod`, which already
//! computes each answer from files alone; this is where a host's roots, its required
//! packages, a player's profiles and their pending changes meet.
//!
//! **A changed selection applies at the next start** (ADR-0040). `start` resolves the
//! order this session loads, once, and nothing here changes it afterwards. What the player
//! edits is `pending`, whose resolution is `preview` and whose overrides are `conflicts`,
//! each cached until the selection changes again. `apply` writes it to the pending profile
//! for the next start; `revert` throws it away.
//!
//! **Origins are host authority.** The host says which root holds installed content and
//! which the player's own mods; a package cannot say it about itself (ADR-0031). The
//! duplicate rules that follow from it live in `mod.resolve`.
//!
//! **So is native consent.** It is recorded per package version, in the profile, and only
//! through this object, which the public ABI never exposes (ADR-0040 decision 5).
//!
//! **Profiles are optional.** A host that attaches `profiles.Store` starts from its active
//! profile and can create, copy, rename, delete and select them. A host that keeps no
//! profiles restores a selection itself and never applies one.
//!
//! Design: `docs/design/mod-management.md` §§4, 5, 7 and 8.

const std = @import("std");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const engine_mod = @import("engine.zig");
const profiles = @import("profiles.zig");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Diagnostics = data.Diagnostics;
const Os = platform.os.Os;

const log = core.log.scoped(.mods);

pub const Origin = mod.Origin;

/// The directory under an application's user data where a player puts packages
/// (`distribution.md` §7). Players see it, so it is fixed.
pub const user_dir_name = "mods";

/// How many packages a selection may enable, and consents it may hold: a profile's bounds.
pub const max_enabled = profiles.max_enabled;
pub const max_consents = profiles.max_consents;

/// A directory the host grants for discovery, and whose it is.
pub const Root = struct {
    dir: []const u8,
    origin: Origin,
};

pub const Options = struct {
    /// Loaded always, first and in this order, and never part of a selection:
    /// `foundry:core` and the application's own package. A missing or skipped one is fatal.
    required: []const ContentId,
    /// Bounds on each package read. The origin is each root's.
    discover: mod.discover_mod.Options = .{},
};

/// One installed package, as discovery found it.
pub const Installed = struct {
    candidate: mod.Candidate,
    /// Host bootstrap: always loads and is never part of a selection.
    required: bool,
};

/// Permission to load one version of one package's native library.
pub const Consent = struct {
    id: ContentId,
    version: u32,
};

pub const Error = error{
    /// A required package is not a choice.
    Required,
    /// `move` names a package the pending selection does not enable.
    NotEnabled,
    /// An id with no known spelling: nothing installed has it and no profile named it.
    NotInstalled,
    /// A spelling that is not a content id.
    InvalidId,
    /// More than `max_enabled` packages, or `max_consents` consents.
    SelectionFull,
    /// A profile operation on a set with no profiles attached.
    NoProfiles,
    /// No profile has this key.
    UnknownProfile,
    /// The profile's file cannot be used; it is left as it is.
    ProfileUnreadable,
    /// The profile is the one saved for the next start, or the one pending: never deleted.
    ProfileInUse,
    /// Empty, too long, not UTF-8, or holding control characters.
    InvalidName,
    /// All `profiles.max_profiles` keys are taken.
    TooManyProfiles,
} || profiles.WriteError || Allocator.Error;

/// `<user data>/mods`, or null with a warning when this machine has no user-data location.
/// A missing directory is the ordinary first-run state, and discovery reports it as empty.
pub fn userRoot(gpa: Allocator, os: *Os) Allocator.Error!?[]u8 {
    const user_data = os.userDataDirAlloc(gpa) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("user packages are unavailable ({t})", .{err});
            return null;
        },
    };
    defer gpa.free(user_data);
    return platform.os.joinPath(gpa, &.{ user_data, user_dir_name }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.warn("user packages are unavailable ({t})", .{err});
            return null;
        },
    };
}

/// One selection: what it enables in the player's order, and what native code it allows.
const Selection = struct {
    enabled: std.ArrayList(ContentId) = .empty,
    consents: std.ArrayList(Consent) = .empty,

    fn deinit(self: *Selection, gpa: Allocator) void {
        self.enabled.deinit(gpa);
        self.consents.deinit(gpa);
    }

    fn copyFrom(self: *Selection, gpa: Allocator, other: *const Selection) Allocator.Error!void {
        self.enabled.clearRetainingCapacity();
        try self.enabled.appendSlice(gpa, other.enabled.items);
        self.consents.clearRetainingCapacity();
        try self.consents.appendSlice(gpa, other.consents.items);
    }

    fn eql(self: *const Selection, other: *const Selection) bool {
        if (self.enabled.items.len != other.enabled.items.len) return false;
        for (self.enabled.items, other.enabled.items) |a, b| if (!a.eql(b)) return false;
        if (self.consents.items.len != other.consents.items.len) return false;
        for (self.consents.items, other.consents.items) |a, b| {
            if (!a.id.eql(b.id) or a.version != b.version) return false;
        }
        return true;
    }
};

pub const ModSet = struct {
    gpa: Allocator,
    /// Borrowed from the host, which outlives this: conflicts reread package tables.
    os: *Os,
    read_options: mod.discover_mod.Options,
    discoveries: []mod.Discovery = &.{},
    /// Every candidate of every root, in root order.
    candidates: []mod.Candidate = &.{},
    list: []Installed = &.{},
    required: []ContentId = &.{},

    /// Every id's spelling this set has seen, from discovery or a selection. A profile
    /// names packages by spelling, and an uninstalled one still has to be written back.
    spellings: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    /// Owns the spellings discovery does not: those only a selection named.
    strings: core.Arena,

    /// As last saved: what the next start uses if nothing changes.
    saved: Selection = .{},
    /// Being edited, in the player's order.
    edited: Selection = .{},
    /// The pending profile as last read or written: what `apply` compares against, so it
    /// writes only the fields this process changed (`mod-management.md` §6).
    base: Selection = .{},
    /// This session's developer override: after the selection, and never saved.
    extra: std.ArrayList(ContentId) = .empty,

    store: ?profiles.Store = null,
    listing: ?profiles.Listing = null,
    /// The listing, plus the saved profile when it is not on disk yet.
    entries: std.ArrayList(profiles.Entry) = .empty,
    saved_key: ?u32 = null,
    pending_key: ?u32 = null,
    /// The saved profile is a fresh one no file holds yet: the first run, or every
    /// profile unusable. Written by `apply`, `rename` or a copy, never by starting.
    fresh_name: ?[]const u8 = null,

    session: ?mod.Resolution = null,
    preview_cache: ?mod.Resolution = null,
    conflicts_cache: ?mod.Conflicts = null,

    /// Discovers every root. A root that cannot be listed is a diagnostic and contributes
    /// nothing, as it always has for one.
    pub fn init(gpa: Allocator, os: *Os, roots: []const Root, options: Options, diags: *Diagnostics) Allocator.Error!ModSet {
        const required = try gpa.dupe(ContentId, options.required);
        errdefer gpa.free(required);

        var discoveries: std.ArrayList(mod.Discovery) = try .initCapacity(gpa, roots.len);
        errdefer {
            for (discoveries.items) |*d| d.deinit();
            discoveries.deinit(gpa);
        }
        var total: usize = 0;
        for (roots) |root| {
            var read = options.discover;
            read.origin = root.origin;
            discoveries.appendAssumeCapacity(try mod.discover(gpa, os, root.dir, read, diags));
            total += discoveries.items[discoveries.items.len - 1].candidates.len;
        }

        const candidates = try gpa.alloc(mod.Candidate, total);
        errdefer gpa.free(candidates);
        const list = try gpa.alloc(Installed, total);
        errdefer gpa.free(list);
        var spellings: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
        errdefer spellings.deinit(gpa);
        var at: usize = 0;
        for (discoveries.items) |d| {
            for (d.candidates) |c| {
                candidates[at] = c;
                list[at] = .{ .candidate = c, .required = contains(required, c.manifest.id) };
                try spellings.put(gpa, c.manifest.id.hash, c.manifest.id_name);
                at += 1;
            }
        }
        return .{
            .gpa = gpa,
            .os = os,
            .read_options = options.discover,
            .discoveries = try discoveries.toOwnedSlice(gpa),
            .candidates = candidates,
            .list = list,
            .required = required,
            .spellings = spellings,
            .strings = .init(gpa),
        };
    }

    pub fn deinit(self: *ModSet) void {
        const gpa = self.gpa;
        self.invalidate();
        if (self.session) |*s| s.deinit();
        self.entries.deinit(gpa);
        if (self.listing) |*l| l.deinit();
        if (self.store) |*s| s.deinit(gpa);
        self.extra.deinit(gpa);
        self.base.deinit(gpa);
        self.edited.deinit(gpa);
        self.saved.deinit(gpa);
        self.strings.deinit();
        self.spellings.deinit(gpa);
        gpa.free(self.list);
        gpa.free(self.candidates);
        for (self.discoveries) |*d| d.deinit();
        gpa.free(self.discoveries);
        gpa.free(self.required);
        self.* = undefined;
    }

    /// Every package found in every root, duplicates included, with its origin.
    pub fn installed(self: *const ModSet) []const Installed {
        return self.list;
    }

    /// An id's spelling, when anything installed or selected has named it.
    pub fn spelling(self: *const ModSet, id: ContentId) ?[]const u8 {
        return self.spellings.get(id.hash);
    }

    /// Sets the saved selection, and the pending one to it, for a host that keeps no
    /// profiles. The order is the player's: kept as given, first occurrence of a repeat
    /// winning, never sorted (ADR-0040). Required packages are dropped, since they are not
    /// a choice.
    pub fn restore(self: *ModSet, selection: []const []const u8) Error!void {
        try self.fill(&self.saved, .{ .name = "", .enabled = selection });
        try self.revert();
    }

    /// Resolves the order this session loads: the saved selection, then `extra`, the
    /// developer override, which is never saved. Called once, before the engine exists.
    ///
    /// Errors are `mod.resolve`'s fatal ones: a required package missing or skipped, or two
    /// installed packages sharing an id.
    pub fn start(self: *ModSet, extra: []const ContentId, diags: *Diagnostics) mod.resolve_mod.Error!*const mod.Resolution {
        std.debug.assert(self.session == null);
        self.extra.clearRetainingCapacity();
        for (extra) |id| {
            if (self.isRequired(id) or contains(self.saved.enabled.items, id) or contains(self.extra.items, id)) continue;
            try self.extra.append(self.gpa, id);
        }
        self.invalidate();

        const request = try self.gpa.alloc(ContentId, self.saved.enabled.items.len + self.extra.items.len);
        defer self.gpa.free(request);
        @memcpy(request[0..self.saved.enabled.items.len], self.saved.enabled.items);
        @memcpy(request[self.saved.enabled.items.len..], self.extra.items);
        self.session = try mod.resolve(self.gpa, self.candidates, .{ .required = self.required, .enabled = request }, diags);
        return &self.session.?;
    }

    /// What this session loaded, once `start` has run.
    pub fn loaded(self: *const ModSet) ?*const mod.Resolution {
        return if (self.session) |*s| s else null;
    }

    /// The packages the environment enabled for this session alone.
    pub fn environment(self: *const ModSet) []const ContentId {
        return self.extra.items;
    }

    /// The selection the next start will use, in the player's order.
    pub fn pending(self: *const ModSet) []const ContentId {
        return self.edited.enabled.items;
    }

    /// Whether anything pending differs from what is saved: the profile, the order, or a
    /// consent.
    pub fn changed(self: *const ModSet) bool {
        return self.pending_key != self.saved_key or !self.saved.eql(&self.edited);
    }

    pub fn isEnabled(self: *const ModSet, id: ContentId) bool {
        return contains(self.edited.enabled.items, id);
    }

    /// Enables a package at the end of the player's order, or disables it. Either is
    /// idempotent; neither affects this session (ADR-0040).
    pub fn setEnabled(self: *ModSet, id: ContentId, on: bool) Error!void {
        if (self.isRequired(id)) return error.Required;
        const at = indexOf(self.edited.enabled.items, id);
        if (on) {
            if (at != null) return;
            if (self.spelling(id) == null) return error.NotInstalled;
            if (self.edited.enabled.items.len == max_enabled) return error.SelectionFull;
            try self.edited.enabled.append(self.gpa, id);
        } else {
            _ = self.edited.enabled.orderedRemove(at orelse return);
        }
        self.invalidate();
    }

    /// Moves an enabled package to `to` in the player's order, clamped to its end. Any
    /// position is accepted: the resolver keeps dependencies first, and `preview` shows
    /// where the package actually lands (`mod-management.md` §4).
    pub fn move(self: *ModSet, id: ContentId, to: u32) Error!void {
        const enabled = &self.edited.enabled;
        const from = indexOf(enabled.items, id) orelse return error.NotEnabled;
        const target = @min(to, enabled.items.len - 1);
        if (target == from) return;
        _ = enabled.orderedRemove(from);
        enabled.insertAssumeCapacity(target, id);
        self.invalidate();
    }

    /// Whether the pending selection allows this version of this package's native code.
    pub fn consented(self: *const ModSet, id: ContentId, version: u32) bool {
        for (self.edited.consents.items) |c| if (c.id.eql(id) and c.version == version) return true;
        return false;
    }

    /// Gives or withdraws consent for one version, pending like any other change. **The
    /// host's alone**: nothing a mod can reach calls this (ADR-0040 decision 5).
    pub fn setConsent(self: *ModSet, id: ContentId, version: u32, on: bool) Error!void {
        const consents = &self.edited.consents;
        for (consents.items, 0..) |c, i| {
            if (!c.id.eql(id) or c.version != version) continue;
            if (!on) _ = consents.orderedRemove(i);
            return;
        }
        if (!on) return;
        if (self.spelling(id) == null) return error.NotInstalled;
        if (consents.items.len == max_consents) return error.SelectionFull;
        try consents.append(self.gpa, .{ .id = id, .version = version });
    }

    /// Discards every pending change, the profile selected included.
    pub fn revert(self: *ModSet) Allocator.Error!void {
        try self.edited.copyFrom(self.gpa, &self.saved);
        try self.base.copyFrom(self.gpa, &self.saved);
        self.pending_key = self.saved_key;
        self.invalidate();
    }

    /// What the next start would load: the pending selection resolved, with this session's
    /// environment override, which the next start in the same environment applies too.
    ///
    /// Its diagnostics are discarded: they say again what its skips already carry, and
    /// `start` logged them once for the session.
    pub fn preview(self: *ModSet) mod.resolve_mod.Error!*const mod.Resolution {
        if (self.preview_cache) |*cached| return cached;
        var diags: Diagnostics = .init(self.gpa, .default);
        defer diags.deinit(self.gpa);

        const enabled = self.edited.enabled.items;
        const request = try self.gpa.alloc(ContentId, enabled.len + self.extra.items.len);
        defer self.gpa.free(request);
        @memcpy(request[0..enabled.len], enabled);
        var n = enabled.len;
        for (self.extra.items) |id| {
            if (contains(enabled, id)) continue;
            request[n] = id;
            n += 1;
        }
        self.preview_cache = try mod.resolve(self.gpa, self.candidates, .{ .required = self.required, .enabled = request[0..n] }, &diags);
        return &self.preview_cache.?;
    }

    /// Who overrides whom in `preview`'s order, from each package's record table.
    pub fn conflicts(self: *ModSet) mod.resolve_mod.Error!*const mod.Conflicts {
        if (self.conflicts_cache) |*cached| return cached;
        const order = (try self.preview()).order;
        var diags: Diagnostics = .init(self.gpa, .default);
        defer diags.deinit(self.gpa);
        self.conflicts_cache = try mod.conflicts(self.gpa, self.os, order, self.read_options, &diags);
        // Rare, and not carried by the report beyond `readable`: a package gone or damaged
        // since discovery.
        for (diags.items.items) |d| log.warn("{s}", .{d.message});
        return &self.conflicts_cache.?;
    }

    /// This session's load order as `app.Config.content` takes it. The strings are
    /// borrowed from this set, which outlives the call to `Engine.init` that copies them;
    /// the caller frees the slice alone.
    pub fn contentPackages(self: *const ModSet, gpa: Allocator) Allocator.Error![]engine_mod.ContentPackage {
        const order = self.session.?.order;
        const out = try gpa.alloc(engine_mod.ContentPackage, order.len);
        for (out, order) |*p, entry| p.* = .{ .base_dir = entry.base_dir, .file = entry.file, .root = entry.root };
        return out;
    }

    // -- profiles ----------------------------------------------------------------

    /// Takes `store` and starts from profile `active`, the key the host saved.
    ///
    /// A key that is missing or unusable falls back to the first usable profile, then to a
    /// fresh one holding `fresh`, with a warning; a first run with no key and no profiles
    /// takes the fresh one silently (ADR-0040 decision 1). A fresh profile is not written
    /// until the player changes something or the host calls `saveFresh`: starting writes
    /// nothing.
    ///
    /// `fresh` is the host's. Its name is a string a player reads. Its selection is empty,
    /// unless the host is moving a selection out of older settings: then the move happens
    /// only when no profile exists yet, so doing it twice creates nothing twice
    /// (`mod-management.md` §6).
    pub fn attachProfiles(self: *ModSet, store: profiles.Store, active: ?u32, fresh: profiles.Contents) Error!void {
        std.debug.assert(self.store == null);
        // Owned from here, whatever follows: `deinit` closes it.
        self.store = store;
        if (!profiles.validName(fresh.name)) return error.InvalidName;
        try self.refresh();

        var tried: ?u32 = null;
        if (active) |key| {
            tried = key;
            if (try self.useProfile(key)) return;
            log.warn("profile {d} cannot be used; starting from another", .{key});
        }
        for (self.listing.?.entries) |entry| {
            if (entry.problem != null or entry.key == tried) continue;
            if (try self.useProfile(entry.key)) return;
        }

        const key = self.nextKey() orelse return error.TooManyProfiles;
        if (active != null or self.listing.?.entries.len != 0) {
            log.warn("no profile could be used; starting from a fresh one", .{});
        }
        self.fresh_name = try self.strings.allocator().dupe(u8, fresh.name);
        self.saved_key = key;
        try self.fill(&self.saved, fresh);
        try self.revert();
        try self.rebuildEntries();
    }

    /// Whether the saved profile is a fresh one no file holds yet.
    pub fn savedIsFresh(self: *const ModSet) bool {
        return self.fresh_name != null;
    }

    /// Writes the saved profile when it is a fresh one, and does nothing otherwise. A host
    /// that moved a selection into it calls this, so the next start finds it on disk.
    pub fn saveFresh(self: *ModSet) Error!void {
        const name = self.fresh_name orelse return;
        const store = if (self.store) |*s| s else return error.NoProfiles;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        try store.write(self.gpa, self.saved_key.?, try self.contentsOf(arena.allocator(), &self.saved, name), null);
        self.fresh_name = null;
        try self.refresh();
    }

    /// Every profile, by key: the files found, with any problem, and the saved profile
    /// when it is still a fresh one no file holds.
    pub fn profileList(self: *const ModSet) []const profiles.Entry {
        return self.entries.items;
    }

    /// The profile the next start uses, as saved. The host keeps this key in its settings.
    pub fn savedProfile(self: *const ModSet) ?u32 {
        return self.saved_key;
    }

    /// The profile the player has selected, which `apply` saves.
    pub fn pendingProfile(self: *const ModSet) ?u32 {
        return self.pending_key;
    }

    /// Makes profile `key` the pending one, and its selection the pending selection. Edits
    /// not applied are dropped, as switching away from them says; selecting the saved
    /// profile is `revert`.
    pub fn selectProfile(self: *ModSet, key: u32) Error!void {
        _ = self.store orelse return error.NoProfiles;
        if (key == self.saved_key) return self.revert();
        var profile = try self.readProfile(key);
        defer profile.deinit();
        try self.fill(&self.base, profile.contents);
        try self.edited.copyFrom(self.gpa, &self.base);
        self.pending_key = key;
        self.invalidate();
    }

    /// Writes a new profile under the smallest unused key and returns the key: empty, or a
    /// copy of `copy_of` as the player sees it, pending edits included when it is the
    /// pending one. Selects nothing.
    pub fn createProfile(self: *ModSet, name: []const u8, copy_of: ?u32) Error!u32 {
        if (self.store == null) return error.NoProfiles;
        if (!profiles.validName(name)) return error.InvalidName;
        const key = self.nextKey() orelse return error.TooManyProfiles;

        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const contents: profiles.Contents = if (copy_of) |source| blk: {
            if (source == self.pending_key) break :blk try self.contentsOf(arena.allocator(), &self.edited, name);
            if (source == self.saved_key and self.fresh_name != null) break :blk try self.contentsOf(arena.allocator(), &self.saved, name);
            var profile = try self.readProfile(source);
            defer profile.deinit();
            var copied = try copyContents(arena.allocator(), profile.contents);
            copied.name = name;
            break :blk copied;
        } else .{ .name = name };
        try self.store.?.write(self.gpa, key, contents, null);
        try self.refresh();
        return key;
    }

    /// Gives profile `key` a new display name, written at once. A fresh profile is written
    /// for the first time by this.
    pub fn renameProfile(self: *ModSet, key: u32, name: []const u8) Error!void {
        const store = if (self.store) |*s| s else return error.NoProfiles;
        if (!profiles.validName(name)) return error.InvalidName;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();

        if (key == self.saved_key and self.fresh_name != null) {
            try store.write(self.gpa, key, try self.contentsOf(arena.allocator(), &self.saved, name), null);
            self.fresh_name = null;
        } else {
            // Merged over the file: only the name is this process's change.
            var profile = try self.readProfile(key);
            defer profile.deinit();
            var contents = profile.contents;
            contents.name = name;
            try store.write(self.gpa, key, contents, profile.contents);
        }
        try self.refresh();
    }

    /// Deletes profile `key`'s file, unusable ones included. Never the saved profile or the
    /// pending one, so never the last.
    pub fn deleteProfile(self: *ModSet, key: u32) Error!void {
        const store = if (self.store) |*s| s else return error.NoProfiles;
        if (key == self.saved_key or key == self.pending_key) return error.ProfileInUse;
        if (self.listing.?.find(key) == null) return error.UnknownProfile;
        try store.remove(key);
        try self.refresh();
    }

    /// Writes the pending selection to the pending profile, which the next start uses.
    /// This session is unchanged (ADR-0040): `loaded` still says what it started with.
    ///
    /// Merged over the file as it is now: the enabled list and the consents are written
    /// only when this process changed them, and the name never is.
    pub fn apply(self: *ModSet) Error!void {
        const store = if (self.store) |*s| s else return error.NoProfiles;
        const key = self.pending_key.?;
        const name = self.nameOf(key) orelse return error.UnknownProfile;
        const fresh = key == self.saved_key and self.fresh_name != null;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const ours = try self.contentsOf(arena.allocator(), &self.edited, name);
        const baseline = if (fresh) null else try self.contentsOf(arena.allocator(), &self.base, name);
        try store.write(self.gpa, key, ours, baseline);

        if (fresh) self.fresh_name = null;
        self.saved_key = key;
        try self.saved.copyFrom(self.gpa, &self.edited);
        try self.base.copyFrom(self.gpa, &self.edited);
        try self.refresh();
    }

    // -- inside ------------------------------------------------------------------

    fn isRequired(self: *const ModSet, id: ContentId) bool {
        return contains(self.required, id);
    }

    fn invalidate(self: *ModSet) void {
        if (self.conflicts_cache) |*c| c.deinit();
        self.conflicts_cache = null;
        if (self.preview_cache) |*p| p.deinit();
        self.preview_cache = null;
    }

    /// An id for a spelling, remembering the spelling.
    fn learn(self: *ModSet, text: []const u8) Error!ContentId {
        const id = data.contentId(text) catch return error.InvalidId;
        const gop = try self.spellings.getOrPut(self.gpa, id.hash);
        if (!gop.found_existing) gop.value_ptr.* = try self.strings.allocator().dupe(u8, text);
        return id;
    }

    /// Replaces `selection` with `contents`, in its order, without repeats or required ids.
    fn fill(self: *ModSet, selection: *Selection, contents: profiles.Contents) Error!void {
        selection.enabled.clearRetainingCapacity();
        for (contents.enabled) |text| {
            const id = try self.learn(text);
            if (self.isRequired(id) or contains(selection.enabled.items, id)) continue;
            if (selection.enabled.items.len == max_enabled) return error.SelectionFull;
            try selection.enabled.append(self.gpa, id);
        }
        selection.consents.clearRetainingCapacity();
        for (contents.consents) |c| {
            if (selection.consents.items.len == max_consents) return error.SelectionFull;
            try selection.consents.append(self.gpa, .{ .id = try self.learn(c.id), .version = c.version });
        }
    }

    /// A selection as a profile's contents, its strings borrowed from this set.
    fn contentsOf(self: *const ModSet, arena: Allocator, selection: *const Selection, name: []const u8) Allocator.Error!profiles.Contents {
        const enabled = try arena.alloc([]const u8, selection.enabled.items.len);
        for (enabled, selection.enabled.items) |*text, id| text.* = self.spelling(id).?;
        const consents = try arena.alloc(profiles.Consent, selection.consents.items.len);
        for (consents, selection.consents.items) |*out, c| out.* = .{ .id = self.spelling(c.id).?, .version = c.version };
        return .{ .name = name, .enabled = enabled, .consents = consents };
    }

    /// Reads profile `key` and makes it the saved and pending one. False when it cannot be
    /// used.
    fn useProfile(self: *ModSet, key: u32) Error!bool {
        var profile = self.readProfile(key) catch |err| switch (err) {
            error.UnknownProfile, error.ProfileUnreadable => return false,
            else => return err,
        };
        defer profile.deinit();
        self.fill(&self.saved, profile.contents) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        self.saved_key = key;
        try self.revert();
        return true;
    }

    fn readProfile(self: *ModSet, key: u32) Error!profiles.Profile {
        const store = if (self.store) |*s| s else return error.NoProfiles;
        return store.read(self.gpa, key) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Absent => error.UnknownProfile,
            else => error.ProfileUnreadable,
        };
    }

    /// The smallest key neither a file nor a fresh profile holds.
    fn nextKey(self: *const ModSet) ?u32 {
        var key: u32 = 1;
        while (key <= profiles.max_profiles) : (key += 1) {
            if (self.listing.?.find(key) != null) continue;
            if (self.fresh_name != null and key == self.saved_key) continue;
            return key;
        }
        return null;
    }

    fn nameOf(self: *const ModSet, key: u32) ?[]const u8 {
        for (self.entries.items) |e| if (e.key == key and e.problem == null) return e.name;
        return null;
    }

    fn refresh(self: *ModSet) Allocator.Error!void {
        const listing = try self.store.?.list(self.gpa);
        if (self.listing) |*old| old.deinit();
        self.listing = listing;
        try self.rebuildEntries();
    }

    fn rebuildEntries(self: *ModSet) Allocator.Error!void {
        self.entries.clearRetainingCapacity();
        try self.entries.appendSlice(self.gpa, self.listing.?.entries);
        if (self.fresh_name) |name| {
            var at: usize = 0;
            while (at < self.entries.items.len and self.entries.items[at].key < self.saved_key.?) at += 1;
            try self.entries.insert(self.gpa, at, .{ .key = self.saved_key.?, .name = name });
        }
    }
};

fn copyContents(arena: Allocator, contents: profiles.Contents) Allocator.Error!profiles.Contents {
    const enabled = try arena.alloc([]const u8, contents.enabled.len);
    for (enabled, contents.enabled) |*out, text| out.* = try arena.dupe(u8, text);
    const consents = try arena.alloc(profiles.Consent, contents.consents.len);
    for (consents, contents.consents) |*out, c| out.* = .{ .id = try arena.dupe(u8, c.id), .version = c.version };
    return .{ .name = contents.name, .enabled = enabled, .consents = consents };
}

fn indexOf(ids: []const ContentId, id: ContentId) ?usize {
    for (ids, 0..) |each, i| if (each.eql(id)) return i;
    return null;
}

fn contains(ids: []const ContentId, id: ContentId) bool {
    return indexOf(ids, id) != null;
}

// -- tests -------------------------------------------------------------------------

const testing = std.testing;

fn cid(name: []const u8) ContentId {
    return ContentId.fromString(name);
}

/// Two roots on disk, an installation and a player's `mods/`, filled with compiled
/// packages.
const Fixture = struct {
    tmp: testing.TmpDir,
    installed_dir: []u8,
    user_dir: []u8,
    /// The application's user data, where profiles live. Not created until written.
    data_dir: []u8,
    os: *Os,
    registry: data.Registry,
    diags: Diagnostics,

    fn init() !Fixture {
        const gpa = testing.allocator;
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &path_buf);
        const installed_dir = try platform.os.joinPath(gpa, &.{ path_buf[0..len], "install" });
        errdefer gpa.free(installed_dir);
        const user_dir = try platform.os.joinPath(gpa, &.{ path_buf[0..len], "mods" });
        errdefer gpa.free(user_dir);
        const data_dir = try platform.os.joinPath(gpa, &.{ path_buf[0..len], "data" });
        errdefer gpa.free(data_dir);
        const os = try Os.init(gpa, .{});
        errdefer os.deinit();
        try os.createDirPath(installed_dir);
        try os.createDirPath(user_dir);
        var registry: data.Registry = .init(gpa, .default);
        errdefer registry.deinit(gpa);
        try mod.schemas.registerAll(gpa, &registry);
        return .{
            .tmp = tmp,
            .installed_dir = installed_dir,
            .user_dir = user_dir,
            .data_dir = data_dir,
            .os = os,
            .registry = registry,
            .diags = .init(gpa, .default),
        };
    }

    fn deinit(self: *Fixture) void {
        const gpa = testing.allocator;
        self.diags.deinit(gpa);
        self.registry.deinit(gpa);
        self.os.deinit();
        gpa.free(self.data_dir);
        gpa.free(self.user_dir);
        gpa.free(self.installed_dir);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, dir: []const u8, file: []const u8, name: []const u8, source: []const u8) !void {
        const gpa = testing.allocator;
        const colon = std.mem.indexOfScalar(u8, name, ':').?;
        var doc = try data.parser.parse(gpa, "test.fdt", source, .{ .namespace = name[0..colon] }, &self.diags);
        defer doc.deinit(gpa);
        var package = try data.check.Package.init(gpa, name, 1, .default);
        defer package.deinit(gpa);
        try package.addDocument(gpa, &doc, &self.registry, &self.diags);
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try data.fpk.write(gpa, &package, &self.registry, &bytes);
        const path = try platform.os.joinPath(gpa, &.{ dir, file });
        defer gpa.free(path);
        try self.os.writeFile(path, bytes.items);
    }

    /// The game's two required packages installed with a mod of its own, and in `mods/`:
    /// a copy of that mod, two more mods, and one mod twice.
    fn standard(self: *Fixture) !void {
        try self.write(self.installed_dir, "core.fpk", "foundry:core",
            \\foundry:mod foundry:core { name "Core" version 1 license "MIT" }
        );
        try self.write(self.installed_dir, "game.fpk", "game:content",
            \\foundry:mod game:content { name "Game" version 1 license "MIT" requires [ { id foundry:core } ] }
            \\@schema game:thing { v u32 }
            \\game:thing game:lamp { v 1 }
            \\game:thing game:floor { v 2 }
        );
        try self.write(self.installed_dir, "lamps.fpk", "lamps:content",
            \\foundry:mod lamps:content { name "Lamps" version 1 license "MIT" requires [ { id game:content } ] }
            \\game:thing game:lamp { v 10 }
        );
        try self.write(self.user_dir, "lamps.fpk", "lamps:content",
            \\foundry:mod lamps:content { name "Lamps, again" version 1 license "MIT" }
        );
        try self.write(self.user_dir, "night.fpk", "night:content",
            \\foundry:mod night:content { name "Night" version 1 license "MIT" requires [ { id game:content } ] }
            \\game:thing game:lamp { v 20 }
            \\game:thing game:floor { v 21 }
        );
        try self.write(self.user_dir, "rug.fpk", "rug:content",
            \\foundry:mod rug:content { name "Rug" version 1 license "MIT" requires [ { id game:content } ] }
            \\game:thing game:floor { v 30 }
        );
        try self.write(self.user_dir, "twice.fpk", "twice:content",
            \\foundry:mod twice:content { name "Twice" version 1 license "MIT" }
        );
        try self.write(self.user_dir, "twice-copy.fpk", "twice:content",
            \\foundry:mod twice:content { name "Twice" version 1 license "MIT" }
        );
        try testing.expect(!self.diags.failed);
    }

    fn open(self: *Fixture, roots: []const Root) !ModSet {
        return ModSet.init(testing.allocator, self.os, roots, .{
            .required = &.{ cid("foundry:core"), cid("game:content") },
        }, &self.diags);
    }

    fn storeAt(self: *Fixture, persist: bool) !profiles.Store {
        return profiles.Store.open(testing.allocator, self.os, self.data_dir, persist);
    }

    /// A set over both roots, started from profile `active`.
    fn withProfiles(self: *Fixture, active: ?u32, persist: bool) !ModSet {
        const roots = self.grants();
        var set = try self.open(&roots);
        errdefer set.deinit();
        try set.attachProfiles(try self.storeAt(persist), active, .{ .name = "Default" });
        return set;
    }

    fn seed(self: *Fixture, key: u32, contents: profiles.Contents) !void {
        var store = try self.storeAt(true);
        defer store.deinit(testing.allocator);
        try store.write(testing.allocator, key, contents, null);
    }

    fn stored(self: *Fixture, key: u32) !profiles.Profile {
        var store = try self.storeAt(false);
        defer store.deinit(testing.allocator);
        return store.read(testing.allocator, key);
    }

    fn grants(self: *const Fixture) [2]Root {
        return .{
            .{ .dir = self.installed_dir, .origin = .installed },
            .{ .dir = self.user_dir, .origin = .user },
        };
    }
};

fn names(buf: [][]const u8, order: []const mod.Entry) [][]const u8 {
    for (order, 0..) |e, i| buf[i] = e.name;
    return buf[0..order.len];
}

test "two roots keep their origins, and a player's duplicates no longer stop the game" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    const roots = f.grants();
    var set = try f.open(&roots);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 8), set.installed().len);
    var user: usize = 0;
    var required: usize = 0;
    for (set.installed()) |each| {
        if (each.candidate.origin == .user) user += 1;
        if (each.required) required += 1;
    }
    try testing.expectEqual(@as(usize, 5), user);
    try testing.expectEqual(@as(usize, 2), required);

    // A required package in a selection is dropped: it is not a choice.
    try set.restore(&.{ "night:content", "game:content", "lamps:content", "night:content" });
    try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("night:content"), cid("lamps:content") }), set.pending());

    const loaded = try set.start(&.{}, &f.diags);
    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "foundry:core", "game:content", "night:content", "lamps:content" }),
        names(&buf, loaded.order),
    );
    // The installed copy of `lamps` loads; the player's copy and both of `twice` do not,
    // and the game starts anyway.
    try testing.expectEqualStrings(f.installed_dir, loaded.order[3].base_dir);
    try testing.expectEqual(@as(usize, 3), loaded.skipped.len);
    try testing.expect(!f.diags.failed);

    const packages = try set.contentPackages(testing.allocator);
    defer testing.allocator.free(packages);
    try testing.expectEqual(@as(usize, 4), packages.len);
    try testing.expectEqualStrings("night.fpk", packages[2].file);
    try testing.expectEqualStrings(f.user_dir, packages[2].base_dir.?);
}

test "editing the selection changes the preview and the conflicts, never what loaded" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    const roots = f.grants();
    var set = try f.open(&roots);
    defer set.deinit();
    try set.restore(&.{"night:content"});
    _ = try set.start(&.{}, &f.diags);
    try testing.expect(!set.changed());

    var report = try set.conflicts();
    try testing.expectEqual(@as(usize, 2), report.contested.len);

    // `rug` enabled at the end wins the floor; moved to the front, `night` takes it back.
    try set.setEnabled(cid("rug:content"), true);
    try testing.expect(set.changed());
    var preview = try set.preview();
    var buf: [8][]const u8 = undefined;
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "foundry:core", "game:content", "night:content", "rug:content" }),
        names(&buf, preview.order),
    );
    report = try set.conflicts();
    const floor = report.providers(cid("game:floor"));
    try testing.expectEqualStrings("rug:content", preview.order[floor[floor.len - 1]].name);

    try set.move(cid("rug:content"), 0);
    preview = try set.preview();
    report = try set.conflicts();
    const floor_again = report.providers(cid("game:floor"));
    try testing.expectEqualStrings("night:content", preview.order[floor_again[floor_again.len - 1]].name);

    // Past the end is the end.
    try set.move(cid("rug:content"), 99);
    try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("night:content"), cid("rug:content") }), set.pending());

    // What loaded is untouched by any of it.
    try testing.expectEqual(@as(usize, 3), set.loaded().?.order.len);

    try set.revert();
    try testing.expect(!set.changed());
    try testing.expectEqualDeep(@as([]const ContentId, &.{cid("night:content")}), set.pending());

    try testing.expectError(error.Required, set.setEnabled(cid("game:content"), false));
    try testing.expectError(error.NotEnabled, set.move(cid("rug:content"), 0));
    try set.setEnabled(cid("night:content"), false);
    try set.setEnabled(cid("night:content"), false);
    try testing.expectEqual(@as(usize, 0), set.pending().len);
}

test "the environment's packages load for this session, and are never part of the selection" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    const roots = f.grants();
    var set = try f.open(&roots);
    defer set.deinit();
    try set.restore(&.{"night:content"});

    const loaded = try set.start(&.{ cid("rug:content"), cid("night:content"), cid("foundry:core") }, &f.diags);
    try testing.expectEqual(@as(usize, 4), loaded.order.len);
    try testing.expectEqualDeep(@as([]const ContentId, &.{cid("rug:content")}), set.environment());
    try testing.expectEqualDeep(@as([]const ContentId, &.{cid("night:content")}), set.pending());
    // So the preview carries it too, and nothing reads as a pending change.
    try testing.expectEqual(@as(usize, 4), (try set.preview()).order.len);
    try testing.expect(!set.changed());
}

test "roots in either order give byte-identical previews and conflicts" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();

    const forward = f.grants();
    const backward = [_]Root{ forward[1], forward[0] };
    var reference: ?[]u8 = null;
    defer if (reference) |r| testing.allocator.free(r);
    for ([_][]const Root{ &forward, &backward }) |roots| {
        var set = try f.open(roots);
        defer set.deinit();
        try set.restore(&.{ "rug:content", "twice:content", "night:content", "lamps:content" });
        _ = try set.start(&.{}, &f.diags);
        const text = try describe(&set);
        if (reference) |expected| {
            defer testing.allocator.free(text);
            try testing.expectEqualStrings(expected, text);
        } else reference = text;
    }
}

fn describe(set: *ModSet) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    const w = &out.writer;
    const preview = try set.preview();
    for (preview.order) |e| try w.print("load {s} {s}\n", .{ e.name, e.file });
    for (preview.skipped) |s| try w.print("skip {s} {t} {s}\n", .{ s.name, s.reason, s.file });
    const report = try set.conflicts();
    for (report.packages) |p| try w.print("{d} {d} {d}\n", .{ p.provides, p.wins, p.loses });
    for (report.contested) |r| {
        try w.print("{s}:", .{r.name});
        for (r.providers) |p| try w.print(" {s}", .{preview.order[p].name});
        try w.writeByte('\n');
    }
    return out.toOwnedSlice();
}

test "the mod set starts from the active profile, in the player's order, and falls back when it cannot" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    try f.seed(1, .{ .name = "Default", .enabled = &.{"night:content"} });
    try f.seed(2, .{ .name = "Rugs first", .enabled = &.{ "rug:content", "night:content" } });

    {
        var set = try f.withProfiles(2, true);
        defer set.deinit();
        try testing.expectEqual(@as(?u32, 2), set.savedProfile());
        try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("rug:content"), cid("night:content") }), set.pending());
        // The player's order loads, not the alphabet's.
        const loaded = try set.start(&.{}, &f.diags);
        var buf: [8][]const u8 = undefined;
        try testing.expectEqualDeep(
            @as([]const []const u8, &.{ "foundry:core", "game:content", "rug:content", "night:content" }),
            names(&buf, loaded.order),
        );
    }
    {
        // A key whose file is gone falls back to the first profile that can be used.
        var set = try f.withProfiles(7, true);
        defer set.deinit();
        try testing.expectEqual(@as(?u32, 1), set.savedProfile());
        try testing.expectEqualDeep(@as([]const ContentId, &.{cid("night:content")}), set.pending());
    }
    {
        // So does one that cannot be read, which is listed with its problem and left alone.
        const path = try platform.os.joinPath(testing.allocator, &.{ f.data_dir, profiles.dir_name, "3.fset" });
        defer testing.allocator.free(path);
        try f.os.writeFile(path, "FSET, but not really");
        var set = try f.withProfiles(3, true);
        defer set.deinit();
        try testing.expectEqual(@as(?u32, 1), set.savedProfile());
        const list = set.profileList();
        try testing.expectEqual(@as(usize, 3), list.len);
        try testing.expectEqual(@as(?profiles.Problem, .damaged), list[2].problem);
        const after = try f.os.readFile(testing.allocator, path, 1024);
        defer testing.allocator.free(after);
        try testing.expectEqualStrings("FSET, but not really", after);
    }
}

test "a first run starts from a fresh profile, and writes nothing until the player does" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    var set = try f.withProfiles(null, true);
    defer set.deinit();

    try testing.expectEqual(@as(?u32, 1), set.savedProfile());
    try testing.expectEqual(@as(usize, 1), set.profileList().len);
    try testing.expectEqualStrings("Default", set.profileList()[0].name);
    try testing.expectEqual(@as(usize, 0), set.pending().len);
    try testing.expect(!f.os.exists(f.data_dir));

    try set.setEnabled(cid("night:content"), true);
    try set.apply();
    try testing.expect(!set.changed());
    var profile = try f.stored(1);
    defer profile.deinit();
    try testing.expectEqualStrings("Default", profile.contents.name);
    try testing.expectEqual(@as(usize, 1), profile.contents.enabled.len);
    try testing.expectEqual(@as(?profiles.Problem, null), set.profileList()[0].problem);
}

test "selecting, applying and reverting profiles; the order survives a round trip" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    try f.seed(1, .{ .name = "Default", .enabled = &.{"night:content"} });
    try f.seed(2, .{ .name = "Rugs first", .enabled = &.{ "rug:content", "night:content" } });

    {
        var set = try f.withProfiles(1, true);
        defer set.deinit();
        _ = try set.start(&.{}, &f.diags);

        try set.selectProfile(2);
        try testing.expectEqual(@as(?u32, 2), set.pendingProfile());
        try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("rug:content"), cid("night:content") }), set.pending());
        try testing.expect(set.changed());
        try set.revert();
        try testing.expectEqual(@as(?u32, 1), set.pendingProfile());
        try testing.expect(!set.changed());

        try set.selectProfile(2);
        try set.setEnabled(cid("lamps:content"), true);
        try set.move(cid("lamps:content"), 0);
        try set.apply();
        try testing.expectEqual(@as(?u32, 2), set.savedProfile());
        try testing.expect(!set.changed());
        // This session still runs what it started with.
        try testing.expectEqual(@as(usize, 3), set.loaded().?.order.len);
    }

    // Written in the player's order, unsorted, and read back the same way.
    var profile = try f.stored(2);
    defer profile.deinit();
    const want = [_][]const u8{ "lamps:content", "rug:content", "night:content" };
    try testing.expectEqual(want.len, profile.contents.enabled.len);
    for (want, profile.contents.enabled) |a, b| try testing.expectEqualStrings(a, b);
    var untouched = try f.stored(1);
    defer untouched.deinit();
    try testing.expectEqual(@as(usize, 1), untouched.contents.enabled.len);

    var set = try f.withProfiles(2, true);
    defer set.deinit();
    try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("lamps:content"), cid("rug:content"), cid("night:content") }), set.pending());
}

test "profiles are created, copied, renamed and deleted by key, and the ones in use are kept" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    try f.seed(1, .{ .name = "Default", .enabled = &.{"night:content"} });
    var set = try f.withProfiles(1, true);
    defer set.deinit();

    // A copy of the pending profile is what the player sees, edits included.
    try set.setEnabled(cid("rug:content"), true);
    try testing.expectEqual(@as(u32, 2), try set.createProfile("Empty", null));
    try testing.expectEqual(@as(u32, 3), try set.createProfile("Copy", 1));
    var copy = try f.stored(3);
    defer copy.deinit();
    try testing.expectEqual(@as(usize, 2), copy.contents.enabled.len);
    try testing.expectEqualStrings("rug:content", copy.contents.enabled[1]);
    var original = try f.stored(1);
    defer original.deinit();
    try testing.expectEqual(@as(usize, 1), original.contents.enabled.len);

    try set.renameProfile(3, "Renamed");
    try testing.expectEqualStrings("Renamed", set.profileList()[2].name);

    try testing.expectError(error.ProfileInUse, set.deleteProfile(1));
    try set.selectProfile(2);
    try testing.expectError(error.ProfileInUse, set.deleteProfile(2));
    try set.deleteProfile(3);
    try testing.expectEqual(@as(u32, 3), try set.createProfile("Again", null));

    try testing.expectError(error.InvalidName, set.createProfile("", null));
    try testing.expectError(error.InvalidName, set.renameProfile(1, "tab\there"));
    try testing.expectError(error.UnknownProfile, set.createProfile("From nothing", 42));
    try testing.expectError(error.UnknownProfile, set.renameProfile(9, "Nine"));
    try testing.expectError(error.UnknownProfile, set.deleteProfile(9));
}

test "consent is kept per version, and only a set with profiles applies" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    {
        var set = try f.withProfiles(null, true);
        defer set.deinit();
        try set.setConsent(cid("night:content"), 1, true);
        try testing.expect(set.consented(cid("night:content"), 1));
        try testing.expect(!set.consented(cid("night:content"), 2));
        try testing.expect(set.changed());
        try testing.expectError(error.NotInstalled, set.setConsent(cid("never:installed"), 1, true));
        try set.apply();
    }
    {
        var set = try f.withProfiles(1, true);
        defer set.deinit();
        try testing.expect(set.consented(cid("night:content"), 1));
        try testing.expect(!set.consented(cid("night:content"), 2));
        try set.setConsent(cid("night:content"), 1, false);
        try testing.expect(!set.consented(cid("night:content"), 1));
    }

    const roots = f.grants();
    var bare = try f.open(&roots);
    defer bare.deinit();
    try bare.restore(&.{"night:content"});
    try testing.expectError(error.NoProfiles, bare.apply());
    try testing.expectError(error.NoProfiles, bare.createProfile("P", null));
}

test "a run that may not write keeps every change in memory" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    try f.seed(1, .{ .name = "Default", .enabled = &.{"night:content"} });
    var set = try f.withProfiles(1, false);
    defer set.deinit();

    try set.setEnabled(cid("rug:content"), true);
    try testing.expectError(error.ReadOnly, set.apply());
    try testing.expectError(error.ReadOnly, set.createProfile("P", null));
    try testing.expect(set.changed());
    var profile = try f.stored(1);
    defer profile.deinit();
    try testing.expectEqual(@as(usize, 1), profile.contents.enabled.len);
}

test "a selection moved out of older settings becomes the first profile, once" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    const carried: profiles.Contents = .{ .name = "Default", .enabled = &.{ "night:content", "rug:content" } };
    const roots = f.grants();

    {
        var set = try f.open(&roots);
        defer set.deinit();
        try set.attachProfiles(try f.storeAt(true), null, carried);
        try testing.expect(set.savedIsFresh());
        try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("night:content"), cid("rug:content") }), set.pending());
        try set.saveFresh();
        try testing.expect(!set.savedIsFresh());
        try set.saveFresh();
    }
    {
        // The same move again, as a second start before settings were ever saved: the
        // profile exists now, so it is used and nothing is created.
        var set = try f.open(&roots);
        defer set.deinit();
        try set.attachProfiles(try f.storeAt(true), null, carried);
        try testing.expect(!set.savedIsFresh());
        try testing.expectEqual(@as(usize, 1), set.profileList().len);
        try testing.expectEqualDeep(@as([]const ContentId, &.{ cid("night:content"), cid("rug:content") }), set.pending());
    }
}

test "two instances editing one profile keep each other's changes to different fields" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.standard();
    try f.seed(1, .{ .name = "Default", .enabled = &.{"night:content"} });
    var a = try f.withProfiles(1, true);
    defer a.deinit();
    var b = try f.withProfiles(1, true);
    defer b.deinit();

    try a.setEnabled(cid("rug:content"), true);
    try a.apply();
    // `b` read the profile before `a` wrote it, and changes other fields.
    try b.renameProfile(1, "Renamed");
    try b.setConsent(cid("night:content"), 1, true);
    try b.apply();

    var profile = try f.stored(1);
    defer profile.deinit();
    try testing.expectEqualStrings("Renamed", profile.contents.name);
    try testing.expectEqual(@as(usize, 2), profile.contents.enabled.len);
    try testing.expectEqualStrings("rug:content", profile.contents.enabled[1]);
    try testing.expectEqual(@as(usize, 1), profile.contents.consents.len);

    // The same field changed in both is the last writer's.
    try a.setEnabled(cid("lamps:content"), true);
    try a.apply();
    try b.setEnabled(cid("night:content"), false);
    try b.apply();
    var last = try f.stored(1);
    defer last.deinit();
    try testing.expectEqual(@as(usize, 0), last.contents.enabled.len);
}

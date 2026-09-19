//! The v3 mod-management boundary.
//!
//! Reads expose one view of `app.ModSet`; writes are additionally gated by an explicit host
//! grant. Neither filesystem paths nor native-code consent has a public type.
//!
//! Every walk's cursor carries the host's mod generation, which each successful write
//! moves, so a walk begun before an edit is refused rather than resynchronised onto a
//! different list. Borrowed strings follow the same rule: they are the set's own and stay
//! valid until the next successful write.
//!
//! Design: `docs/design/mod-management.md` §9.

const std = @import("std");
const app = @import("app");
const mod = @import("mod");

const mod_types = @import("mod_types.zig");
const types = @import("types.zig");

const Bool = types.Bool;
const ContentId = types.ContentId;
const Cursor = types.Cursor;
const Result = types.Result;
const Str = types.Str;

pub fn Of(comptime H: type) type {
    return struct {
        const Active = struct { host: *H, mods: *app.ModSet };

        fn set() ?Active {
            const host = H.current() orelse return null;
            return .{ .host = host, .mods = host.mod_set orelse return null };
        }

        /// The set, when the host also granted writes.
        fn writable(active: Active) ?Active {
            if (active.host.mods_write == null) return null;
            return active;
        }

        /// One generation per walk and per state of the set: the host's counter, the
        /// length being walked, and a salt naming the walk, so a cursor from one
        /// enumeration is refused by another.
        fn generation(host: *const H, count: usize, salt: u32) u32 {
            var value = host.mods_generation ^ (@as(u32, @truncate(count)) *% 0x9e37_79b9) ^ salt;
            if (value == 0) value = std.math.maxInt(u32);
            return value;
        }

        fn walk(c: *const Cursor, expected: u32, count: usize) ?usize {
            if (!c.isBegin() and c.generation() != expected) return null;
            return @min(c.index(), count);
        }

        fn advance(c: *Cursor, expected: u32, next: usize) void {
            c.* = .at(expected, @intCast(next));
        }

        fn sameCandidate(entry: mod.Entry, installed: app.mods.Installed) bool {
            return entry.id.eql(installed.candidate.manifest.id) and
                std.mem.eql(u8, entry.base_dir, installed.candidate.base_dir) and
                std.mem.eql(u8, entry.file, installed.candidate.file);
        }

        fn positionOf(order: []const mod.Entry, installed: app.mods.Installed) ?u32 {
            for (order, 0..) |entry, index| if (sameCandidate(entry, installed)) return @intCast(index);
            return null;
        }

        /// The skip that names this copy: by file when the skip has one, by id otherwise.
        fn skipOf(skipped: []const mod.Skip, installed: app.mods.Installed) ?mod.Skip {
            for (skipped) |skip| {
                if (!skip.id.eql(installed.candidate.manifest.id)) continue;
                if (skip.base_dir.len != 0 and
                    (!std.mem.eql(u8, skip.base_dir, installed.candidate.base_dir) or
                        !std.mem.eql(u8, skip.file, installed.candidate.file))) continue;
                return skip;
            }
            return null;
        }

        fn indexIn(ids: []const ContentId, id: ContentId) ?u32 {
            for (ids, 0..) |candidate, index| if (candidate.eql(id)) return @intCast(index);
            return null;
        }

        fn isInstalled(mods: *const app.ModSet, id: ContentId) bool {
            for (mods.installed()) |item| if (item.candidate.manifest.id.eql(id)) return true;
            return false;
        }

        /// The copy a question about `id` means: the one the pending order loads, else the
        /// first discovered.
        fn copyOf(mods: *const app.ModSet, order: []const mod.Entry, id: ContentId) ?app.mods.Installed {
            var first: ?app.mods.Installed = null;
            for (mods.installed()) |item| {
                if (!item.candidate.manifest.id.eql(id)) continue;
                if (positionOf(order, item) != null) return item;
                if (first == null) first = item;
            }
            return first;
        }

        fn originOf(origin: mod.Origin) mod_types.Origin {
            return switch (origin) {
                .installed => .installed,
                .user => .user,
            };
        }

        fn skipReasonOf(reason: mod.SkipReason) mod_types.SkipReason {
            return switch (reason) {
                .not_installed => .not_installed,
                .missing_dependency => .missing_dependency,
                .dependency_version => .dependency_version,
                .dependency_skipped => .dependency_skipped,
                .cycle => .cycle,
                .duplicate => .duplicate,
                .shadows_installed => .shadows_installed,
            };
        }

        fn profileProblemOf(problem: ?app.profiles.Problem) mod_types.ProfileProblem {
            const value = problem orelse return .none;
            return switch (value) {
                .damaged => .damaged,
                .other_build => .other_build,
                .refused => .refused,
                .unavailable => .unavailable,
            };
        }

        fn failure(err: app.mods.Error) Result {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                // Well-formed and understood; not something this package or profile may
                // have done to it now.
                error.Required, error.ProfileInUse, error.ProfileUnreadable => .refused,
                error.NotEnabled, error.NotInstalled, error.UnknownProfile => .not_found,
                error.InvalidId, error.InvalidName => .invalid_argument,
                error.SelectionFull, error.TooManyProfiles, error.TooLarge => .limit,
                error.NoProfiles => .unavailable,
                // The store's own refusals: a run that may not write, contents past a
                // bound, and a newer build's file kept.
                error.ReadOnly, error.Refused, error.OtherBuild => .refused,
                // The store has already said which, once, in the log.
                error.WriteFailed => .internal,
            };
        }

        /// The pending order resolves over the candidates this session started from, so
        /// its fatal errors are ones `start` already survived.
        fn resolveFailure(err: mod.resolve_mod.Error) Result {
            return Result.fromError(err);
        }

        // -- reading --------------------------------------------------------------------

        pub fn modsInstalledNext(cursor: ?*Cursor, out: ?*mod_types.Info) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const active = set() orelse return .unavailable;
            const installed = active.mods.installed();
            const walk_generation = generation(active.host, installed.len, 0x4d49_4e53);
            const index = walk(c, walk_generation, installed.len) orelse return .invalid_argument;
            if (index == installed.len) return .end;

            const preview = active.mods.preview() catch |err| return resolveFailure(err);
            const report = active.mods.conflicts() catch |err| return resolveFailure(err);
            const item = installed[index];
            const manifest = item.candidate.manifest;
            const skip = skipOf(preview.skipped, item);
            const position = positionOf(preview.order, item);
            const stats: mod.conflicts_mod.Package = if (position) |p| report.packages[p] else .{ .id = manifest.id };

            var flags: u32 = 0;
            if (item.required) flags |= mod_types.flag_required;
            if (manifest.native != null) flags |= mod_types.flag_native;
            if (manifest.script != null) flags |= mod_types.flag_script;
            if (skip) |s| {
                if (s.reason == .duplicate or s.reason == .shadows_installed) flags |= mod_types.flag_duplicate;
            }
            if (indexIn(active.mods.environment(), manifest.id) != null) flags |= mod_types.flag_environment;
            if (!stats.readable) flags |= mod_types.flag_unreadable;

            const loaded = if (active.mods.loaded()) |session| positionOf(session.order, item) != null else false;
            destination.* = .{
                .id = manifest.id,
                .id_name = .from(manifest.id_name),
                .name = .from(manifest.name),
                .license = .from(manifest.license),
                .version = manifest.version,
                .origin = originOf(item.candidate.origin),
                .flags = flags,
                .pending_index = if (item.required) mod_types.no_position else indexIn(active.mods.pending(), manifest.id) orelse mod_types.no_position,
                .pending_position = position orelse mod_types.no_position,
                .skip_reason = if (skip) |s| skipReasonOf(s.reason) else .none,
                .skip_other = if (skip) |s| s.other else .none,
                .skip_other_name = if (skip) |s| .from(s.other_name) else .empty,
                .provides = stats.provides,
                .wins = stats.wins,
                .loses = stats.loses,
                .loaded = types.boolOut(loaded),
                .pending_enabled = types.boolOut(item.required or active.mods.isEnabled(manifest.id)),
            };
            advance(c, walk_generation, index + 1);
            return .ok;
        }

        pub fn modsPendingNext(cursor: ?*Cursor, out: ?*mod_types.Pending) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const active = set() orelse return .unavailable;
            const pending = active.mods.pending();
            const walk_generation = generation(active.host, pending.len, 0x5045_4e44);
            const index = walk(c, walk_generation, pending.len) orelse return .invalid_argument;
            if (index == pending.len) return .end;

            const id = pending[index];
            destination.* = .{
                .id = id,
                .name = .from(active.mods.spelling(id) orelse ""),
                .installed = types.boolOut(isInstalled(active.mods, id)),
            };
            advance(c, walk_generation, index + 1);
            return .ok;
        }

        pub fn modsRequirementNext(package: ContentId, cursor: ?*Cursor, out: ?*mod_types.Requirement) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const active = set() orelse return .unavailable;
            if (package.isNone()) return .invalid_argument;
            const preview = active.mods.preview() catch |err| return resolveFailure(err);
            const item = copyOf(active.mods, preview.order, package) orelse return .not_found;
            const requires = item.candidate.manifest.requires;
            const walk_generation = generation(active.host, requires.len, 0x5245_5155 ^ @as(u32, @truncate(package.hash)));
            const index = walk(c, walk_generation, requires.len) orelse return .invalid_argument;
            if (index == requires.len) return .end;

            const requirement = requires[index];
            var satisfied = false;
            for (preview.order) |entry| {
                if (entry.id.eql(requirement.id) and requirement.range.accepts(entry.version)) satisfied = true;
            }
            destination.* = .{
                .id = requirement.id,
                .name = .from(active.mods.spelling(requirement.id) orelse ""),
                .min_version = requirement.range.min,
                .max_version = requirement.range.max orelse mod_types.no_position,
                .satisfied = types.boolOut(satisfied),
            };
            advance(c, walk_generation, index + 1);
            return .ok;
        }

        pub fn modsConflictNext(package: ContentId, cursor: ?*Cursor, out: ?*mod_types.Conflict) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const active = set() orelse return .unavailable;
            if (package.isNone()) return .invalid_argument;
            const report = active.mods.conflicts() catch |err| return resolveFailure(err);
            const walk_generation = generation(active.host, report.contested.len, 0x434f_4e46 ^ @as(u32, @truncate(package.hash)));
            var index = walk(c, walk_generation, report.contested.len) orelse return .invalid_argument;
            while (index < report.contested.len) : (index += 1) {
                const conflict = report.contested[index];
                const involved = for (conflict.providers) |provider| {
                    if (report.packages[provider].id.eql(package)) break true;
                } else false;
                if (!involved) continue;
                destination.* = .{
                    .record = conflict.id,
                    .name = .from(conflict.name),
                    .winner = report.packages[conflict.winner()].id,
                    .provider_count = @intCast(conflict.providers.len),
                };
                advance(c, walk_generation, index + 1);
                return .ok;
            }
            advance(c, walk_generation, report.contested.len);
            return .end;
        }

        pub fn modsProviderNext(record: ContentId, cursor: ?*Cursor, out: ?*mod_types.Provider) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const active = set() orelse return .unavailable;
            if (record.isNone()) return .invalid_argument;
            const report = active.mods.conflicts() catch |err| return resolveFailure(err);
            const providers = report.providers(record);
            const walk_generation = generation(active.host, providers.len, 0x5052_4f56 ^ @as(u32, @truncate(record.hash)));
            const index = walk(c, walk_generation, providers.len) orelse return .invalid_argument;
            if (index == providers.len) return .end;
            const position = providers[index];
            destination.* = .{
                .package = report.packages[position].id,
                .position = position,
                .winner = types.boolOut(index + 1 == providers.len),
            };
            advance(c, walk_generation, index + 1);
            return .ok;
        }

        pub fn modsProfileNext(cursor: ?*Cursor, out: ?*mod_types.Profile) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const destination = out orelse return .invalid_argument;
            const active = set() orelse return .unavailable;
            const profiles = active.mods.profileList();
            const walk_generation = generation(active.host, profiles.len, 0x5052_4f46);
            const index = walk(c, walk_generation, profiles.len) orelse return .invalid_argument;
            if (index == profiles.len) return .end;
            const entry = profiles[index];
            destination.* = .{
                .key = entry.key,
                .problem = profileProblemOf(entry.problem),
                .name = .from(entry.name),
                .saved = types.boolOut(active.mods.savedProfile() == entry.key),
                .pending = types.boolOut(active.mods.pendingProfile() == entry.key),
            };
            advance(c, walk_generation, index + 1);
            return .ok;
        }

        pub fn modsProfileActive(out: ?*mod_types.ProfileState) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const active = set() orelse return .unavailable;
            const saved = active.mods.savedProfile();
            const pending = active.mods.pendingProfile();
            destination.* = .{
                .saved = saved orelse 0,
                .pending = pending orelse 0,
                .has_saved = types.boolOut(saved != null),
                .has_pending = types.boolOut(pending != null),
                .changed = types.boolOut(active.mods.changed()),
            };
            return .ok;
        }

        // -- changing the pending selection ------------------------------------------------

        pub fn modsSetEnabled(id: ContentId, enabled: Bool) callconv(.c) Result {
            const present = set() orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;
            const active = writable(present) orelse return .refused;
            active.mods.setEnabled(id, types.boolIn(enabled)) catch |err| return failure(err);
            active.host.changedMods();
            return .ok;
        }

        pub fn modsMove(id: ContentId, to: u32) callconv(.c) Result {
            const present = set() orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;
            const active = writable(present) orelse return .refused;
            active.mods.move(id, to) catch |err| return failure(err);
            active.host.changedMods();
            return .ok;
        }

        pub fn modsRevert() callconv(.c) Result {
            const active = writable(set() orelse return .unavailable) orelse return .refused;
            active.mods.revert() catch |err| return failure(err);
            active.host.changedMods();
            return .ok;
        }

        /// The profile is written first, then the host records which profile the next
        /// start uses. If the second fails the first stands, and the answer says so.
        pub fn modsApply() callconv(.c) Result {
            const active = writable(set() orelse return .unavailable) orelse return .refused;
            active.mods.apply() catch |err| return failure(err);
            active.host.changedMods();
            const key = active.mods.savedProfile().?;
            const grant = active.host.mods_write.?;
            if (!grant.save_active_profile(grant.ctx, key)) return .internal;
            return .ok;
        }

        // -- profiles -------------------------------------------------------------------

        fn profileName(value: Str) ?[]const u8 {
            const name = value.utf8() orelse return null;
            if (!app.profiles.validName(name)) return null;
            return name;
        }

        pub fn modsProfileCreate(name: Str, out: ?*u32) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const present = set() orelse return .unavailable;
            const bytes = profileName(name) orelse return .invalid_argument;
            const active = writable(present) orelse return .refused;
            const key = active.mods.createProfile(bytes, null) catch |err| return failure(err);
            active.host.changedMods();
            destination.* = key;
            return .ok;
        }

        pub fn modsProfileCopy(source: u32, name: Str, out: ?*u32) callconv(.c) Result {
            const destination = out orelse return .invalid_argument;
            const present = set() orelse return .unavailable;
            if (source == 0) return .invalid_argument;
            const bytes = profileName(name) orelse return .invalid_argument;
            const active = writable(present) orelse return .refused;
            const key = active.mods.createProfile(bytes, source) catch |err| return failure(err);
            active.host.changedMods();
            destination.* = key;
            return .ok;
        }

        pub fn modsProfileRename(key: u32, name: Str) callconv(.c) Result {
            const present = set() orelse return .unavailable;
            if (key == 0) return .invalid_argument;
            const bytes = profileName(name) orelse return .invalid_argument;
            const active = writable(present) orelse return .refused;
            active.mods.renameProfile(key, bytes) catch |err| return failure(err);
            active.host.changedMods();
            return .ok;
        }

        pub fn modsProfileDelete(key: u32) callconv(.c) Result {
            const present = set() orelse return .unavailable;
            if (key == 0) return .invalid_argument;
            const active = writable(present) orelse return .refused;
            active.mods.deleteProfile(key) catch |err| return failure(err);
            active.host.changedMods();
            return .ok;
        }

        pub fn modsProfileSelect(key: u32) callconv(.c) Result {
            const present = set() orelse return .unavailable;
            if (key == 0) return .invalid_argument;
            const active = writable(present) orelse return .refused;
            active.mods.selectProfile(key) catch |err| return failure(err);
            active.host.changedMods();
            return .ok;
        }
    };
}

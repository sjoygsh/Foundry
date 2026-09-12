//! What a release contains — decided, checked, and only then copied.
//!
//! Staging is the step where a build tree stops being a checkout. The development install
//! under `zig-out` carries everything a *developer* needs: authoring text, uncompiled grids,
//! a README, the content compiler, the public header. A player needs none of it, and
//! shipping it is not merely untidy — a `.fdt` beside a `.fpk` invites someone to edit the
//! one the game does not read (`distribution.md` §8).
//!
//! So a release is not "the install minus some files". It is built from **explicit inputs**:
//! an executable, a list of packages, and whatever extra runtime files the application
//! declares. Everything else follows from the packages themselves — an asset is staged
//! because a record in a compiled package names it, not because it happened to be sitting in
//! a directory. There is no list of extensions to exclude, because nothing asked for them.
//!
//! **Nothing is copied until the whole plan is known.** Every refusal below — a missing
//! asset, a source escaping its package, a symlink, two inputs writing one destination, a
//! limit exceeded — happens with an empty output directory, so a refused release leaves no
//! half-staged tree for someone to mistake for a finished one.
//!
//! Design: `docs/design/distribution.md` §8.

const std = @import("std");
const asset = @import("asset");
const core = @import("core");
const data = @import("data");
const mod = @import("mod");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const ContentId = core.ContentId;
const Os = platform.os.Os;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// The file that records what was staged.
///
/// Inside the release, because a completeness record that travels separately from what it
/// describes is a completeness record nobody has. It is not authentication and not DRM
/// (§8): it answers "is this copy whole?", and anyone who can change a file can change this
/// one too.
pub const inventory_name = "inventory.txt";

/// The inventory's format, versioned like anything else that crosses a boundary (I8). A
/// reader that does not recognise the number must not guess at the rest.
pub const inventory_version: u32 = 1;

/// Where the executable is staged, relative to the release root.
///
/// The same shape `app.contentDirOf` already looks for — `<exe>/../content` — so a staged
/// tree finds its content by exactly the lookup a development install uses, with no path
/// override and no engine change. The macOS bundle is a different layout and supplies its
/// paths explicitly (§2); that is Step 7's, and a reason to leave this one alone.
pub const bin_dir = "bin";

/// Where packages are staged, relative to the release root.
pub const content_dir = "content";

pub const Limits = struct {
    /// How many files a release may contain, the inventory excluded.
    max_files: u32 = 4096,
    /// How large a release may be in total.
    max_total_bytes: u64 = 2 << 30,
    /// How large one staged file may be.
    max_file_bytes: usize = 512 << 20,
    /// How large a compiled package may be, matching `mod.discover.Options`.
    max_package_bytes: usize = 64 << 20,

    pub const default: Limits = .{};
};

/// One package in the release, named explicitly by the application.
///
/// The closure is not computed here. An application states which packages it ships, and
/// this checks that the statement is complete — every `requires` in every staged manifest
/// must name a package that is also staged. Computing it instead would let a release
/// quietly grow a package nobody decided to ship.
pub const PackageInput = struct {
    /// What it is called under `content/`. A location, never identity (ADR-0021).
    stem: []const u8,
    /// The compiled package.
    fpk: []const u8,
    /// The authored package directory: where an asset's `source` is resolved from.
    source_root: []const u8,
    /// Where the content compiler put the assets it compiled, if this package has any.
    /// Searched first, because a `.fgrid` produced from a `.grid` exists only here.
    generated_root: ?[]const u8 = null,
};

/// A runtime file no package can name: a native library, or an asset whose loader the
/// engine does not define (§8).
pub const ExtraInput = struct {
    /// Where it goes, relative to the release root.
    staged: []const u8,
    /// Where its bytes come from.
    source: []const u8,
};

/// What the application calls itself. None of it comes from the engine: the ABI version is
/// not a product version (§4).
pub const Metadata = struct {
    product: []const u8,
    version: []const u8,
    build: []const u8,
    /// The source revision this was built from, or `local`.
    ///
    /// Never inferred. The build runs no `git` — it has no external tool dependencies
    /// (ADR-0014) — so an unstated revision is recorded as `local` rather than guessed at.
    /// A stage that cannot say where it came from must not be able to claim a clean tag.
    revision: []const u8,
};

pub const Options = struct {
    /// The release root. Must be absent or empty: staging starts fresh.
    out: []const u8,
    executable: []const u8,
    /// What the executable is called in the release, which need not be the artifact's name.
    executable_name: []const u8,
    packages: []const PackageInput,
    extras: []const ExtraInput = &.{},
    metadata: Metadata,
    limits: Limits = .default,
    /// The system the release runs on, which decides what a manifest's `native` names.
    /// Explicit rather than `builtin.os.tag`: this runs on the host and stages for the
    /// target, and on the day those differ a guess would be wrong silently.
    target_os: std.Target.Os.Tag,
};

pub const Result = struct {
    files: u32,
    bytes: u64,
};

pub const Error = error{
    /// Something about the requested release is wrong, and every reason was reported.
    Refused,
    OutOfMemory,
};

/// Where refusals go. Counted as well as written, so a caller whose output is unavailable
/// still knows the release was refused.
pub const Report = struct {
    writer: *std.Io.Writer,
    refusals: u32 = 0,
    warnings: u32 = 0,

    pub fn refuse(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.refusals += 1;
        // Deliberately ignored: a report that cannot be written must not replace the
        // refusal it was reporting. `refusals` is what the caller acts on.
        self.writer.print("fstage: " ++ fmt ++ "\n", args) catch {};
    }

    pub fn warn(self: *Report, comptime fmt: []const u8, args: anytype) void {
        self.warnings += 1;
        self.writer.print("fstage: warning: " ++ fmt ++ "\n", args) catch {};
    }
};

/// Why a file is in the release. Carried so a refusal can say what asked for it.
const Origin = enum { executable, package, asset, generated, extra };

/// One file to copy: where it goes, and the confined pair it comes from.
///
/// A root and a relative path rather than one path, because every read below goes through
/// `readFileConfined` — which traverses without following links, so a symlink anywhere in
/// the relative part is refused by the same primitive that refuses one in a mod's package
/// at runtime. One rule, one implementation.
const Entry = struct {
    staged: []const u8,
    root: []const u8,
    relative: []const u8,
    size: u64,
    /// Preserved from the source rather than decided here. The program has to be
    /// executable or the release does not run, and a copy that drops the bit is a copy
    /// that quietly is not one.
    executable: bool,
    origin: Origin,
    /// What named this file, for a message a person can act on.
    because: []const u8,
};

/// A package whose bytes are staged, by identity.
const StagedPackage = struct {
    id: ContentId,
    name: []const u8,
    version: u32,
    stem: []const u8,
};

/// A package another staged package needs.
const Requirement = struct {
    by: []const u8,
    id: ContentId,
};

/// A file a package refers to that this tool will not resolve on its own.
const Reference = struct {
    staged: []const u8,
    because: []const u8,
};

/// One staged file, as the inventory records it.
const Written = struct {
    staged: []const u8,
    size: usize,
    executable: bool,
    digest: [Sha256.digest_length]u8,
};

pub fn run(gpa: Allocator, os: *Os, options: Options, report: *Report) Error!Result {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var entries: std.ArrayList(Entry) = .empty;
    var packages: std.ArrayList(StagedPackage) = .empty;
    var requirements: std.ArrayList(Requirement) = .empty;
    var references: std.ArrayList(Reference) = .empty;

    // The executable, first and unconditionally. A release with no program in it is not a
    // release.
    try addEntry(arena, &entries, os, report, .{
        .staged = try std.fmt.allocPrint(arena, "{s}/{s}", .{ bin_dir, options.executable_name }),
        .source = options.executable,
        .origin = .executable,
        .because = "the release executable",
        .limits = options.limits,
    });

    for (options.packages) |pkg| {
        if (!isComponent(pkg.stem)) {
            report.refuse("'{s}' is not a usable package directory name", .{pkg.stem});
            continue;
        }

        const fpk_staged = try std.fmt.allocPrint(arena, "{s}/{s}.fpk", .{ content_dir, pkg.stem });
        try addEntry(arena, &entries, os, report, .{
            .staged = fpk_staged,
            .source = pkg.fpk,
            .origin = .package,
            .because = fpk_staged,
            .limits = options.limits,
        });

        const split = splitLeaf(pkg.fpk) orelse {
            report.refuse("package '{s}': '{s}' is not a path to a file", .{ pkg.stem, pkg.fpk });
            continue;
        };
        const read = os.readFileConfined(arena, split.dir, split.leaf, options.limits.max_package_bytes) catch |err| {
            report.refuse("package '{s}' cannot be read from '{s}': {t}", .{ pkg.stem, pkg.fpk, err });
            continue;
        };

        var reader = data.fpk.Reader.open(arena, read.bytes, .default) catch |err| {
            report.refuse("package '{s}' is not a readable package: {t}", .{ pkg.stem, err });
            continue;
        };
        defer reader.deinit();

        const manifest = mod.manifest.read(arena, &reader) catch |err| {
            report.refuse("package '{s}' has no usable manifest: {t}", .{ pkg.stem, err });
            continue;
        };
        try packages.append(arena, .{
            .id = manifest.id,
            .name = manifest.id_name,
            .version = manifest.version,
            .stem = pkg.stem,
        });
        for (manifest.requires) |requirement| {
            try requirements.append(arena, .{ .by = manifest.id_name, .id = requirement.id });
        }

        // A package that names a native library and ships none is a package whose Tier 3
        // half is missing on the player's machine. The library is not derived from content,
        // so it can only arrive as an explicit declaration (§8).
        if (manifest.native) |native| {
            const file = try mod.manifest.libraryFileName(arena, native, options.target_os);
            try references.append(arena, .{
                .staged = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ content_dir, pkg.stem, file }),
                .because = try std.fmt.allocPrint(
                    arena,
                    "'{s}' declares the native library '{s}'",
                    .{ manifest.id_name, native },
                ),
            });
        }

        try planAssets(arena, &entries, &references, os, report, pkg, &reader, manifest, options.limits);
    }

    for (options.extras) |extra| {
        if (!platform.os.isSafeRelativePath(extra.staged)) {
            report.refuse("'{s}' is not a path inside the release", .{extra.staged});
            continue;
        }
        try addEntry(arena, &entries, os, report, .{
            .staged = try arena.dupe(u8, extra.staged),
            .source = extra.source,
            .origin = .extra,
            .because = "an explicit runtime file",
            .limits = options.limits,
        });
    }

    checkRequirements(packages.items, requirements.items, report);
    checkReferences(entries.items, references.items, report);
    try checkDestinations(gpa, entries.items, report);

    // Sorted before anything below reads the list, so neither the limits nor the inventory
    // depends on the order the packages happened to be named in (I9).
    std.mem.sort(Entry, entries.items, {}, lessByStaged);

    var total: u64 = 0;
    for (entries.items) |entry| total += entry.size;
    if (entries.items.len > options.limits.max_files) {
        report.refuse("{d} files is over the limit of {d}", .{ entries.items.len, options.limits.max_files });
    }
    if (total > options.limits.max_total_bytes) {
        report.refuse("{d} bytes is over the limit of {d}", .{ total, options.limits.max_total_bytes });
    }

    // The last point at which nothing has been written.
    if (report.refusals > 0) return error.Refused;

    try startFresh(gpa, os, options.out, report);
    const written = try copyAll(gpa, arena, os, options, entries.items, report);
    try writeInventory(gpa, arena, os, options, packages.items, written, report);

    return .{ .files = @intCast(entries.items.len), .bytes = total };
}

/// Every file the packages themselves name.
///
/// This walks records, not directories: an asset is a record (ADR-0021), and a file no
/// record names is not part of the game whatever directory it is sitting in. That is what
/// keeps `room.fdt`, `hall.grid` and `README.md` out of a release without anyone listing
/// them.
fn planAssets(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    references: *std.ArrayList(Reference),
    os: *Os,
    report: *Report,
    pkg: PackageInput,
    reader: *const data.fpk.Reader,
    manifest: mod.Manifest,
    limits: Limits,
) Error!void {
    var index: u32 = 0;
    while (index < reader.record_count) : (index += 1) {
        const view = reader.record(index) orelse continue;

        // Against the schema this package carries, which is the one its bytes are laid out
        // by — not the engine's, which may have added a field since.
        const schema = reader.schemaFor(view.schema_id) orelse continue;
        const source_index = schema.fieldIndex(asset.schemas.source_field) orelse continue;
        if (schema.fields[source_index].type != .string) continue;

        const fields = reader.fieldsOf(view, schema.*);
        const relative = (fields.stringAt(source_index) catch {
            report.refuse("'{s}' in '{s}' has a malformed source", .{ view.name, manifest.id_name });
            continue;
        }) orelse continue;

        if (!platform.os.isSafeRelativePath(relative)) {
            report.refuse("'{s}' names a source outside its package: '{s}'", .{ view.name, relative });
            continue;
        }

        const staged = try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ content_dir, pkg.stem, relative });

        // An asset kind the engine defines is one this tool can resolve. Anything else is a
        // record claiming a source for a loader that came from somewhere else, and guessing
        // where its bytes live is exactly the assumption §8 forbids. So it is required by
        // name and left to an explicit declaration — required rather than ignored, because
        // a file silently missing from a release fails on the recipient's machine.
        if (asset.schemas.kindForSchema(view.schema_id) == null) {
            try references.append(arena, .{
                .staged = staged,
                .because = try std.fmt.allocPrint(
                    arena,
                    "'{s}' is not an asset kind this tool can resolve and names the source '{s}'",
                    .{ view.name, relative },
                ),
            });
            continue;
        }

        // The compiled form first: a `.fgrid` exists only where the content compiler put
        // it, and the `.grid` it came from is authoring text that must not ship (§8).
        if (pkg.generated_root) |generated| {
            if (os.statFileConfined(generated, relative)) |info| {
                if (info.kind == .file) {
                    try appendEntry(arena, entries, report, .{
                        .staged = staged,
                        .root = generated,
                        .relative = relative,
                        .size = info.size,
                        .executable = info.executable,
                        .origin = .generated,
                        .because = view.name,
                        .limits = limits,
                    });
                    continue;
                }
            } else |_| {}
        }

        try appendConfined(arena, entries, os, report, .{
            .staged = staged,
            .root = pkg.source_root,
            .relative = relative,
            .origin = .asset,
            .because = view.name,
            .limits = limits,
        });
    }
}

const AddOptions = struct {
    staged: []const u8,
    source: []const u8,
    origin: Origin,
    because: []const u8,
    limits: Limits,
};

/// Adds one file named by an ordinary path, confining the read to its own directory.
fn addEntry(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    os: *Os,
    report: *Report,
    options: AddOptions,
) Error!void {
    const split = splitLeaf(options.source) orelse {
        report.refuse("'{s}' is not a path to a file ({s})", .{ options.source, options.because });
        return;
    };
    try appendConfined(arena, entries, os, report, .{
        .staged = options.staged,
        .root = split.dir,
        .relative = split.leaf,
        .origin = options.origin,
        .because = options.because,
        .limits = options.limits,
    });
}

const ConfinedOptions = struct {
    staged: []const u8,
    root: []const u8,
    relative: []const u8,
    origin: Origin,
    because: []const u8,
    limits: Limits,
};

/// Adds one file under a root, refusing anything that is not a regular file reached without
/// following a link.
fn appendConfined(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    os: *Os,
    report: *Report,
    options: ConfinedOptions,
) Error!void {
    const info = os.statFileConfined(options.root, options.relative) catch |err| {
        report.refuse("'{s}' cannot be staged from '{s}/{s}': {t} ({s})", .{
            options.staged, options.root, options.relative, err, options.because,
        });
        return;
    };
    if (info.kind != .file) {
        report.refuse("'{s}' is not a regular file ({s})", .{ options.staged, options.because });
        return;
    }
    try appendEntry(arena, entries, report, .{
        .staged = options.staged,
        .root = options.root,
        .relative = options.relative,
        .size = info.size,
        .executable = info.executable,
        .origin = options.origin,
        .because = options.because,
        .limits = options.limits,
    });
}

const AppendOptions = struct {
    staged: []const u8,
    root: []const u8,
    relative: []const u8,
    size: u64,
    executable: bool,
    origin: Origin,
    because: []const u8,
    limits: Limits,
};

fn appendEntry(
    arena: Allocator,
    entries: *std.ArrayList(Entry),
    report: *Report,
    options: AppendOptions,
) Error!void {
    if (options.size > options.limits.max_file_bytes) {
        report.refuse("'{s}' is {d} bytes, over the per-file limit of {d}", .{
            options.staged, options.size, options.limits.max_file_bytes,
        });
        return;
    }
    try entries.append(arena, .{
        .staged = options.staged,
        .root = try arena.dupe(u8, options.root),
        .relative = try arena.dupe(u8, options.relative),
        .size = options.size,
        .executable = options.executable,
        .origin = options.origin,
        .because = try arena.dupe(u8, options.because),
    });
}

/// Every package a staged manifest requires must itself be staged.
///
/// A release missing a dependency starts and then fails at content load, on the player's
/// machine, with a diagnostic they cannot act on. It is knowable here.
fn checkRequirements(packages: []const StagedPackage, requirements: []const Requirement, report: *Report) void {
    for (requirements) |requirement| {
        for (packages) |package| {
            if (package.id.hash == requirement.id.hash) break;
        } else {
            // The spelling is not in the compiled record — an id field holds the hash — so
            // the hash is what there is to name it by.
            report.refuse("'{s}' requires a package this release does not contain (id 0x{x:0>16})", .{
                requirement.by, requirement.id.hash,
            });
        }
    }
}

/// Every file a package refers to that this tool will not resolve must be staged anyway.
fn checkReferences(entries: []const Entry, references: []const Reference, report: *Report) void {
    for (references) |reference| {
        for (entries) |entry| {
            if (std.mem.eql(u8, entry.staged, reference.staged)) break;
        } else {
            report.refuse("{s}, which is not staged; declare it with --extra {s}=<file>", .{
                reference.because, reference.staged,
            });
        }
    }
}

/// No two inputs may write one destination.
///
/// Compared case-insensitively as well as exactly, because macOS and Windows filesystems
/// usually are: two entries differing only in case stage cleanly on a case-sensitive build
/// machine and silently become one file on the player's. An exact duplicate is a mistake in
/// the release description; a case collision is a mistake that only appears somewhere else,
/// which is worse.
fn checkDestinations(gpa: Allocator, entries: []const Entry, report: *Report) Allocator.Error!void {
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        seen.deinit(gpa);
    }

    for (entries, 0..) |entry, i| {
        const folded = try gpa.alloc(u8, entry.staged.len);
        for (entry.staged, 0..) |c, at| folded[at] = std.ascii.toLower(c);

        const gop = seen.getOrPut(gpa, folded) catch |err| {
            gpa.free(folded);
            return err;
        };
        if (gop.found_existing) {
            gpa.free(folded);
            const first = entries[gop.value_ptr.*];
            if (std.mem.eql(u8, first.staged, entry.staged)) {
                report.refuse("two inputs write '{s}': {s}, and {s}", .{
                    entry.staged, first.because, entry.because,
                });
            } else {
                report.refuse("'{s}' and '{s}' differ only in case and cannot both be staged", .{
                    first.staged, entry.staged,
                });
            }
            continue;
        }
        gop.value_ptr.* = i;
    }
}

/// The release root must be empty — and nothing here deletes anything to make it so.
///
/// The build hands this a fresh output directory every time. A person who points it
/// somewhere else gets a refusal rather than a merge: a release staged over an older one is
/// a release carrying files nothing in this plan accounted for, which is the exact failure
/// the inventory exists to make impossible.
fn startFresh(gpa: Allocator, os: *Os, out: []const u8, report: *Report) Error!void {
    if (os.exists(out)) {
        var listing = os.listDir(gpa, out) catch |err| {
            report.refuse("cannot inspect the release directory '{s}': {t}", .{ out, err });
            return error.Refused;
        };
        defer listing.deinit();
        if (listing.entries.len > 0) {
            report.refuse("the release directory '{s}' is not empty", .{out});
            return error.Refused;
        }
        return;
    }
    os.createDirPath(out) catch |err| {
        report.refuse("cannot create the release directory '{s}': {t}", .{ out, err });
        return error.Refused;
    };
}

fn copyAll(
    gpa: Allocator,
    arena: Allocator,
    os: *Os,
    options: Options,
    entries: []const Entry,
    report: *Report,
) Error![]const Written {
    var written: std.ArrayList(Written) = .empty;
    for (entries) |entry| {
        const read = os.readFileConfined(gpa, entry.root, entry.relative, options.limits.max_file_bytes) catch |err| {
            report.refuse("'{s}' cannot be read: {t} ({s})", .{ entry.staged, err, entry.because });
            return error.Refused;
        };
        defer gpa.free(read.bytes);

        // Checked again against the plan: the plan decided this release fits, and a file
        // that changed since would make that answer stale rather than wrong-by-a-little.
        if (read.bytes.len != entry.size) {
            report.refuse("'{s}' changed while the release was being staged", .{entry.staged});
            return error.Refused;
        }

        const destination = try std.fmt.allocPrint(arena, "{s}/{s}", .{ options.out, entry.staged });
        if (std.fs.path.dirname(destination)) |parent| {
            os.createDirPath(parent) catch |err| {
                report.refuse("cannot create '{s}': {t}", .{ parent, err });
                return error.Refused;
            };
        }
        const mode: platform.os.FileMode = if (entry.executable) .executable else .regular;
        os.writeFileMode(destination, read.bytes, mode) catch |err| {
            report.refuse("cannot write '{s}': {t}", .{ destination, err });
            return error.Refused;
        };

        var digest: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(read.bytes, &digest, .{});
        try written.append(arena, .{
            .staged = entry.staged,
            .size = read.bytes.len,
            .executable = entry.executable,
            .digest = digest,
        });
    }
    return written.items;
}

/// The inventory: what is here, how large it is, and what it hashes to.
///
/// Deterministic by construction — path order, no timestamps, no absolute paths, nothing
/// from the machine that produced it — so two stages of the same inputs produce the same
/// bytes and can be compared without interpreting them (§8).
fn writeInventory(
    gpa: Allocator,
    arena: Allocator,
    os: *Os,
    options: Options,
    packages: []const StagedPackage,
    written: []const Written,
    report: *Report,
) Error!void {
    const sorted = try arena.dupe(StagedPackage, packages);
    std.mem.sort(StagedPackage, sorted, {}, lessByPackageName);

    var total: u64 = 0;
    for (written) |file| total += file.size;

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    writeInventoryText(&text.writer, options, sorted, written, total) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };

    const destination = try std.fmt.allocPrint(arena, "{s}/{s}", .{ options.out, inventory_name });
    os.writeFile(destination, text.written()) catch |err| {
        report.refuse("cannot write '{s}': {t}", .{ destination, err });
        return error.Refused;
    };
}

fn writeInventoryText(
    out: *std.Io.Writer,
    options: Options,
    packages: []const StagedPackage,
    written: []const Written,
    total: u64,
) std.Io.Writer.Error!void {
    try out.print("foundry-release {d}\n", .{inventory_version});
    try out.print("product {s}\n", .{options.metadata.product});
    try out.print("version {s}\n", .{options.metadata.version});
    try out.print("build {s}\n", .{options.metadata.build});
    try out.print("revision {s}\n", .{options.metadata.revision});
    try out.print("target {t}\n", .{options.target_os});
    for (packages) |package| {
        try out.print("package {s} {d} {s}\n", .{ package.name, package.version, package.stem });
    }
    // The inventory does not list itself: a file cannot carry its own hash.
    try out.print("files {d}\n", .{written.len});
    try out.print("bytes {d}\n", .{total});
    // The path is last because it is the only field that may contain a space.
    for (written) |file| {
        const hex = std.fmt.bytesToHex(file.digest, .lower);
        const mode: []const u8 = if (file.executable) "exec" else "file";
        try out.print("{s}  {d}  {s}  {s}\n", .{ hex, file.size, mode, file.staged });
    }
}

fn lessByStaged(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.staged, b.staged);
}

fn lessByPackageName(_: void, a: StagedPackage, b: StagedPackage) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const Leaf = struct { dir: []const u8, leaf: []const u8 };

/// Splits a path into the directory a read is confined to and the name inside it.
///
/// Everything staged is read this way, the executable and the explicit extras included, so
/// the last component is opened without following a link wherever it came from.
fn splitLeaf(path: []const u8) ?Leaf {
    const leaf = std.fs.path.basename(path);
    if (leaf.len == 0) return null;
    const dir = std.fs.path.dirname(path) orelse ".";
    if (dir.len == 0) return null;
    return .{ .dir = dir, .leaf = leaf };
}

fn isComponent(name: []const u8) bool {
    if (!platform.os.isSafeRelativePath(name)) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    return !std.mem.eql(u8, name, ".");
}

// -- tests -------------------------------------------------------------------------------

const testing = std.testing;

/// A package, its files, and somewhere to stage them — on a real filesystem.
///
/// Real rather than simulated, for the same reason `fpack`'s tests are: everything below
/// this tool is already hermetic, and what is left to prove is exactly the part that touches
/// a disk. A symlink that is refused, a directory that is not empty and a file that is
/// executable are not properties a fake filesystem would have.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    root: []u8,
    os: *Os,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();

        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try tmp.dir.realPath(testing.io, &buf);

        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        errdefer arena.deinit();
        const root = try arena.allocator().dupe(u8, buf[0..len]);

        return .{ .tmp = tmp, .arena = arena, .root = root, .os = try Os.init(testing.allocator, .{}) };
    }

    fn deinit(self: *Fixture) void {
        self.os.deinit();
        self.arena.deinit();
        self.tmp.cleanup();
    }

    fn a(self: *Fixture) Allocator {
        return self.arena.allocator();
    }

    fn abs(self: *Fixture, relative: []const u8) ![]u8 {
        return platform.os.joinPath(self.a(), &.{ self.root, relative });
    }

    fn write(self: *Fixture, relative: []const u8, bytes: []const u8) !void {
        return self.writeMode(relative, bytes, .regular);
    }

    /// A stand-in for the release's program: an ordinary file, but executable, because that
    /// is the property the staging is supposed to carry across.
    fn writeProgram(self: *Fixture, relative: []const u8) !void {
        return self.writeMode(relative, "not really a program, but a real file", .executable);
    }

    fn writeMode(self: *Fixture, relative: []const u8, bytes: []const u8, mode: platform.os.FileMode) !void {
        const path = try self.abs(relative);
        if (std.fs.path.dirname(path)) |parent| try self.os.createDirPath(parent);
        try self.os.writeFileMode(path, bytes, mode);
    }

    /// Compiles authoring text into a package, without `fpack` and therefore without path
    /// derivation: a test says exactly which records its package has.
    fn compile(self: *Fixture, name: []const u8, source: []const u8, out: []const u8) !void {
        const gpa = testing.allocator;
        var registry: data.Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        _ = try registry.register(gpa, mod.schemas.manifest);
        try asset.schemas.registerAll(gpa, &registry);

        var diags: data.Diagnostics = .init(gpa, .default);
        defer diags.deinit(gpa);

        const colon = std.mem.indexOfScalar(u8, name, ':').?;
        var doc = try data.parser.parse(gpa, "test.fdt", source, .{ .namespace = name[0..colon] }, &diags);
        defer doc.deinit(gpa);

        var package = try data.check.Package.init(gpa, name, 1, .default);
        defer package.deinit(gpa);
        try package.addDocument(gpa, &doc, &registry, &diags);
        if (diags.failed) {
            var buf: [4096]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            diags.render(&writer) catch {};
            std.debug.print("{s}\n", .{writer.buffered()});
            return error.TestPackageDidNotCompile;
        }

        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try data.fpk.write(gpa, &package, &registry, &bytes);
        try self.write(out, bytes.items);
    }

    /// Every file under `relative`, as paths relative to it, sorted.
    fn staged(self: *Fixture, relative: []const u8) ![]const []const u8 {
        var dir = self.tmp.dir.openDir(testing.io, relative, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close(testing.io);

        var walker = try dir.walk(testing.allocator);
        defer walker.deinit();

        var found: std.ArrayList([]const u8) = .empty;
        while (try walker.next(testing.io)) |entry| {
            if (entry.kind != .file) continue;
            try found.append(self.a(), try self.a().dupe(u8, entry.path));
        }
        const items = found.items;
        std.mem.sort([]const u8, items, {}, lessThanString);
        return items;
    }

    fn read(self: *Fixture, relative: []const u8) ![]u8 {
        return self.os.readFile(self.a(), try self.abs(relative), 1 << 20);
    }

    fn isExecutable(self: *Fixture, relative: []const u8) !bool {
        const info = try self.os.statFile(try self.abs(relative));
        return info.executable;
    }
};

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A package with one texture, one sound, and a manifest naming `foundry:core`.
const demo_package =
    \\foundry:mod demo:pack { name "Demo" version 1 license "MIT" }
    \\foundry:texture demo:sheet { source "textures/sheet.png" }
    \\foundry:sound demo:bump { source "sounds/bump.wav" }
;

const metadata: Metadata = .{
    .product = "Demo",
    .version = "1.0.0",
    .build = "1",
    .revision = "local",
};

/// The usual arrangement: an executable, a package, and the two files it names.
fn plainFixture() !Fixture {
    var fx = try Fixture.init();
    errdefer fx.deinit();
    try fx.writeProgram("build/demo");
    try fx.compile("demo:pack", demo_package, "build/demo.fpk");
    try fx.write("src/textures/sheet.png", "png bytes");
    try fx.write("src/sounds/bump.wav", "wav bytes");
    return fx;
}

fn plainOptions(fx: *Fixture) !Options {
    const packages = try fx.a().alloc(PackageInput, 1);
    packages[0] = .{
        .stem = "demo",
        .fpk = try fx.abs("build/demo.fpk"),
        .source_root = try fx.abs("src"),
        .generated_root = try fx.abs("build/demo-assets"),
    };
    return .{
        .out = try fx.abs("out"),
        .executable = try fx.abs("build/demo"),
        .executable_name = "demo",
        .packages = packages,
        .metadata = metadata,
        .target_os = .macos,
    };
}

fn expectStaged(fx: *Fixture, expected: []const []const u8) !void {
    const found = try fx.staged("out");
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| try testing.expectEqualStrings(want, got);
}

test "a release holds what the packages name, and nothing a developer needed to build them" {
    var fx = try plainFixture();
    defer fx.deinit();

    // Everything a package directory accumulates and a player has no use for. None of it is
    // excluded by name below; it is absent because no record asked for it.
    try fx.write("src/demo.fdt", "the authoring text");
    try fx.write("src/mod.fdt", "the manifest's authoring text");
    try fx.write("src/README.md", "notes to whoever edits this");
    try fx.write("src/grids/hall.grid", "1 2 3");

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var report: Report = .{ .writer = &writer };

    const result = try run(testing.allocator, fx.os, try plainOptions(&fx), &report);
    try testing.expectEqual(@as(u32, 0), report.refusals);
    try testing.expectEqual(@as(u32, 4), result.files);

    try expectStaged(&fx, &.{
        "bin/demo",
        "content/demo.fpk",
        "content/demo/sounds/bump.wav",
        "content/demo/textures/sheet.png",
        "inventory.txt",
    });

    // The program is a program. A release whose executable lost its bit in the copy is a
    // release that does not start, and the failure looks nothing like its cause.
    if (platform.os.FileMode.has_bit) {
        try testing.expect(try fx.isExecutable("out/bin/demo"));
        try testing.expect(!try fx.isExecutable("out/content/demo.fpk"));
    }
}

test "the inventory names every staged file, in path order, with its size and hash" {
    var fx = try plainFixture();
    defer fx.deinit();

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var report: Report = .{ .writer = &writer };
    _ = try run(testing.allocator, fx.os, try plainOptions(&fx), &report);

    const text = try fx.read("out/inventory.txt");
    var lines = std.mem.splitScalar(u8, text, '\n');
    try testing.expectEqualStrings("foundry-release 1", lines.next().?);
    try testing.expectEqualStrings("product Demo", lines.next().?);
    try testing.expectEqualStrings("version 1.0.0", lines.next().?);
    try testing.expectEqualStrings("build 1", lines.next().?);
    try testing.expectEqualStrings("revision local", lines.next().?);
    try testing.expectEqualStrings("target macos", lines.next().?);
    try testing.expectEqualStrings("package demo:pack 1 demo", lines.next().?);
    try testing.expectEqualStrings("files 4", lines.next().?);
    _ = lines.next().?; // bytes

    // The hash is of the staged bytes, and the line is the one a person would check by hand.
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash("wav bytes", &digest, .{});
    const expected = try std.fmt.allocPrint(fx.a(), "{s}  9  file  content/demo/sounds/bump.wav", .{
        std.fmt.bytesToHex(digest, .lower),
    });
    try testing.expect(std.mem.indexOf(u8, text, expected) != null);

    // Path order, so the file reads the same however the release was described.
    const first = std.mem.indexOf(u8, text, "bin/demo").?;
    const last = std.mem.indexOf(u8, text, "textures/sheet.png").?;
    try testing.expect(first < last);
}

test "two stages of one release are the same bytes" {
    var fx = try plainFixture();
    defer fx.deinit();

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var report: Report = .{ .writer = &writer };

    var first = try plainOptions(&fx);
    first.out = try fx.abs("out");
    _ = try run(testing.allocator, fx.os, first, &report);

    var second = try plainOptions(&fx);
    second.out = try fx.abs("again");
    _ = try run(testing.allocator, fx.os, second, &report);
    try testing.expectEqual(@as(u32, 0), report.refusals);

    // Including the inventory, which is the file most likely to pick up a timestamp, a
    // machine name or an absolute path without anyone noticing.
    for (try fx.staged("out")) |relative| {
        const in_first = try platform.os.joinPath(fx.a(), &.{ "out", relative });
        const in_second = try platform.os.joinPath(fx.a(), &.{ "again", relative });
        try testing.expectEqualStrings(try fx.read(in_first), try fx.read(in_second));
    }
}

test "a compiled asset comes from the compiler's output rather than the source beside it" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeProgram("build/demo");
    try fx.compile("demo:pack",
        \\foundry:mod demo:pack { name "Demo" version 1 license "MIT" }
        \\foundry:tilegrid demo:hall { source "grids/hall.fgrid" }
    , "build/demo.fpk");

    // The authoring form, which must not ship, and a stale compiled one beside it — the
    // shape a package has after someone once ran the compiler into their source tree.
    try fx.write("src/grids/hall.grid", "1 2 3");
    try fx.write("src/grids/hall.fgrid", "yesterday");
    try fx.write("build/demo-assets/grids/hall.fgrid", "today");

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var report: Report = .{ .writer = &writer };
    _ = try run(testing.allocator, fx.os, try plainOptions(&fx), &report);

    try expectStaged(&fx, &.{ "bin/demo", "content/demo.fpk", "content/demo/grids/hall.fgrid", "inventory.txt" });
    try testing.expectEqualStrings("today", try fx.read("out/content/demo/grids/hall.fgrid"));
}

test "an asset that is missing, escaping or a symlink refuses the release before it writes" {
    const cases = [_]struct { name: []const u8, source: []const u8, link: bool = false }{
        .{ .name = "missing", .source = "textures/absent.png" },
        .{ .name = "escaping", .source = "../secret.png" },
        .{ .name = "linked", .source = "textures/linked.png", .link = true },
    };

    for (cases) |case| {
        var fx = try Fixture.init();
        defer fx.deinit();

        try fx.writeProgram("build/demo");
        const source = try std.fmt.allocPrint(fx.a(),
            \\foundry:mod demo:pack {{ name "Demo" version 1 license "MIT" }}
            \\foundry:texture demo:sheet {{ source "{s}" }}
        , .{case.source});
        try fx.compile("demo:pack", source, "build/demo.fpk");
        try fx.write("secret.png", "not yours");
        try fx.write("src/textures/real.png", "png bytes");
        if (case.link) {
            try fx.tmp.dir.symLink(testing.io, "real.png", "src/textures/linked.png", .{});
        }

        var buf: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var report: Report = .{ .writer = &writer };
        try testing.expectError(error.Refused, run(testing.allocator, fx.os, try plainOptions(&fx), &report));
        try testing.expect(report.refusals > 0);

        // And nothing was copied. A refused release that left a directory behind is a
        // release somebody will find later and believe.
        try expectStaged(&fx, &.{});
    }
}

test "two inputs cannot write one file, whether or not they are spelled the same" {
    var fx = try plainFixture();
    defer fx.deinit();
    try fx.write("build/other.png", "different bytes");

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    // Exactly the same destination: a mistake in the release description.
    {
        var options = try plainOptions(&fx);
        const extras = try fx.a().alloc(ExtraInput, 1);
        extras[0] = .{ .staged = "content/demo/textures/sheet.png", .source = try fx.abs("build/other.png") };
        options.extras = extras;

        var report: Report = .{ .writer = &writer };
        try testing.expectError(error.Refused, run(testing.allocator, fx.os, options, &report));
        try testing.expect(std.mem.indexOf(u8, writer.buffered(), "two inputs write") != null);
    }

    // Differing only in case: stages cleanly here and becomes one file on the player's
    // machine, which is the failure worth catching on this one.
    {
        writer = .fixed(&buf);
        var options = try plainOptions(&fx);
        const extras = try fx.a().alloc(ExtraInput, 1);
        extras[0] = .{ .staged = "content/demo/Textures/Sheet.png", .source = try fx.abs("build/other.png") };
        options.extras = extras;

        var report: Report = .{ .writer = &writer };
        try testing.expectError(error.Refused, run(testing.allocator, fx.os, options, &report));
        try testing.expect(std.mem.indexOf(u8, writer.buffered(), "differ only in case") != null);
    }

    try expectStaged(&fx, &.{});
}

test "a package the release needs and does not contain is refused" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeProgram("build/demo");
    try fx.compile("demo:pack",
        \\foundry:mod demo:pack { name "Demo" version 1 license "MIT" requires [ { id foundry:core } ] }
    , "build/demo.fpk");

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var report: Report = .{ .writer = &writer };
    try testing.expectError(error.Refused, run(testing.allocator, fx.os, try plainOptions(&fx), &report));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "requires a package this release does not contain") != null);
}

test "a native library and an asset for an unknown loader are both staged only if declared" {
    var fx = try Fixture.init();
    defer fx.deinit();

    try fx.writeProgram("build/demo");
    try fx.compile("demo:pack",
        \\foundry:mod demo:pack { name "Demo" version 1 license "MIT" native "lanterns" }
        \\@schema mesh { source string }
        \\mesh demo:statue { source "meshes/statue.fmesh" }
    , "build/demo.fpk");
    try fx.write("build/liblanterns.dylib", "a library");
    try fx.write("build/statue.fmesh", "a mesh");

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var report: Report = .{ .writer = &writer };
    try testing.expectError(error.Refused, run(testing.allocator, fx.os, try plainOptions(&fx), &report));

    // Both are named, with the exact declaration that would satisfy them: a refusal a
    // person cannot act on is a refusal they will work around.
    const said = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, said, "content/demo/liblanterns.dylib") != null);
    try testing.expect(std.mem.indexOf(u8, said, "content/demo/meshes/statue.fmesh") != null);

    // Declared, and the same release stages.
    writer = .fixed(&buf);
    var options = try plainOptions(&fx);
    const extras = try fx.a().alloc(ExtraInput, 2);
    extras[0] = .{ .staged = "content/demo/liblanterns.dylib", .source = try fx.abs("build/liblanterns.dylib") };
    extras[1] = .{ .staged = "content/demo/meshes/statue.fmesh", .source = try fx.abs("build/statue.fmesh") };
    options.extras = extras;

    var second: Report = .{ .writer = &writer };
    _ = try run(testing.allocator, fx.os, options, &second);
    try expectStaged(&fx, &.{
        "bin/demo",
        "content/demo.fpk",
        "content/demo/liblanterns.dylib",
        "content/demo/meshes/statue.fmesh",
        "inventory.txt",
    });
}

test "a release over its declared bounds is refused before anything is copied" {
    var fx = try plainFixture();
    defer fx.deinit();

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    {
        var options = try plainOptions(&fx);
        options.limits.max_files = 3;
        var report: Report = .{ .writer = &writer };
        try testing.expectError(error.Refused, run(testing.allocator, fx.os, options, &report));
        try testing.expect(std.mem.indexOf(u8, writer.buffered(), "over the limit") != null);
    }

    {
        writer = .fixed(&buf);
        var options = try plainOptions(&fx);
        options.limits.max_total_bytes = 8;
        var report: Report = .{ .writer = &writer };
        try testing.expectError(error.Refused, run(testing.allocator, fx.os, options, &report));
    }

    try expectStaged(&fx, &.{});
}

test "a release is not staged on top of one that is already there" {
    var fx = try plainFixture();
    defer fx.deinit();
    try fx.write("out/leftover", "from an older release");

    var buf: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var report: Report = .{ .writer = &writer };
    try testing.expectError(error.Refused, run(testing.allocator, fx.os, try plainOptions(&fx), &report));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "is not empty") != null);

    // Untouched, because nothing here deletes anything to make room.
    try testing.expectEqualStrings("from an older release", try fx.read("out/leftover"));
}

//! The attribution a release carries, generated from what the repository already records.
//!
//! `THIRD_PARTY_LICENSES/` has been maintained since the first commit, one file per
//! dependency, on the rule that a dependency and its entry land together. This reads that
//! directory and produces the file a player receives. **Generated, never hand-maintained**
//! — a hand-written notice file drifts within two releases, and the whole reason the
//! directory exists is to have one place that cannot.
//!
//! Two rules shape everything below.
//!
//! **A selected entry is reproduced whole.** Not its `## License text` section: the whole
//! file. SDL's entry records a license *election* — which of HIDAPI's three licenses
//! Foundry chose — and that reasoning is part of the attribution, not commentary on it.
//! Scraping one section would drop it, and would drop the fenced text under it too.
//!
//! **The aggregate is a superset, and says so.** Every entry marked `distributed` is
//! included whether or not this particular binary links it — the room links no Lua and
//! carries Lua's notice anyway. Deciding linkage per artifact would mean reading the build
//! graph and being wrong quietly; an aggregate that is too large is correct, and one that is
//! too small is not (`distribution.md` §9).
//!
//! Nothing here reaches the network. The text is in the repository, which is the only place
//! a build may read it from.
//!
//! Design: `docs/design/distribution.md` §9.

const std = @import("std");
const platform = @import("platform");

const Allocator = std.mem.Allocator;
const Os = platform.os.Os;

/// What a release is called, for the head of the generated file.
pub const Product = struct {
    name: []const u8,
    version: []const u8,
};

/// Whether a recorded component reaches a player.
pub const Distribution = enum {
    /// Linked into, or shipped beside, the artifact. Its notice travels with it.
    distributed,
    /// A tool that produced the artifact and is not in it. Recorded, never shipped.
    build_time_only,
};

/// One parsed entry: the fields that had to be there, and the file they were in.
pub const Entry = struct {
    /// The file name, which is also the sort key. Filename order rather than directory
    /// order, so the output does not depend on how a filesystem enumerates (I9).
    file: []const u8,
    name: []const u8,
    version: []const u8,
    upstream: []const u8,
    license: []const u8,
    distribution: Distribution,
    /// The whole file, reproduced verbatim in the output.
    text: []const u8,
};

/// One content package's declared license, and the notice text a release supplies for it.
pub const PackageNotice = struct {
    package: []const u8,
    version: u32,
    /// The SPDX identifier from the package's own `foundry:mod` record.
    license: []const u8,
    /// The declared notice, or null when the package is under the application's own
    /// license and Foundry's `LICENSE` beside it already discharges the obligation.
    text: ?[]const u8 = null,
};

pub const ParseError = error{
    /// The file does not begin with an `# <Name>` heading.
    NoTitle,
    /// A line in the metadata block is neither a field nor a continuation of one.
    UnexpectedMetadata,
    /// A field this convention requires is absent.
    MissingField,
    /// A field appears twice. Always a file edited twice, never a deliberate choice.
    DuplicateField,
    /// `Distribution:` says something other than `distributed` or `build-time only`.
    UnknownDistribution,
    /// There is no `## License text` section, or it holds nothing.
    NoLicenseText,
} || Allocator.Error;

const version_field = "Version";
const upstream_field = "Upstream";
const license_field = "License";
const distribution_field = "Distribution";
const license_text_heading = "## License text";

/// Reads one recorded entry.
///
/// Strict on purpose. This is the one file in a release whose correctness nobody checks by
/// looking at it, so a malformed entry has to be a refusal at build time rather than a
/// paragraph quietly missing from a legal document. `source` is borrowed for the entry's
/// life; `arena` owns nothing but the joined multi-line values.
pub fn parse(arena: Allocator, file: []const u8, source: []const u8) ParseError!Entry {
    var entry: Entry = .{
        .file = file,
        .name = "",
        .version = "",
        .upstream = "",
        .license = "",
        .distribution = .build_time_only,
        .text = source,
    };

    var lines = std.mem.splitScalar(u8, source, '\n');
    var title: ?[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;
        if (!std.mem.startsWith(u8, trimmed, "# ")) return error.NoTitle;
        title = trim(trimmed[2..]);
        break;
    }
    entry.name = title orelse return error.NoTitle;
    if (entry.name.len == 0) return error.NoTitle;

    // The metadata block: everything between the title and the first section heading. Bounded
    // deliberately — a later section may contain a table row or a fenced line that looks like
    // a field, and a parser that scanned the whole file would find it.
    var seen_distribution = false;
    var last: ?*[]const u8 = null;
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (std.mem.startsWith(u8, trimmed, "## ")) break;
        if (trimmed.len == 0) {
            last = null;
            continue;
        }

        if (field(trimmed)) |found| {
            last = null;
            const slot: ?*[]const u8 = if (std.mem.eql(u8, found.key, version_field))
                &entry.version
            else if (std.mem.eql(u8, found.key, upstream_field))
                &entry.upstream
            else if (std.mem.eql(u8, found.key, license_field))
                &entry.license
            else
                null;

            if (slot) |into| {
                if (into.len != 0) return error.DuplicateField;
                if (found.value.len == 0) return error.MissingField;
                into.* = found.value;
                last = into;
            } else if (std.mem.eql(u8, found.key, distribution_field)) {
                if (seen_distribution) return error.DuplicateField;
                entry.distribution = distributionOf(found.value) orelse return error.UnknownDistribution;
                seen_distribution = true;
            }
            // An unrecorded key — `Location in tree`, `Modifications`, or one added later —
            // is carried through verbatim with the rest of the file and needs no slot here.
            continue;
        }

        // A continuation of the field above it, which is how a long version or a paragraph
        // of reasoning is written in these files.
        if (std.mem.startsWith(u8, line, "  ")) {
            if (last) |into| into.* = try std.fmt.allocPrint(arena, "{s} {s}", .{ into.*, trimmed });
            continue;
        }
        return error.UnexpectedMetadata;
    }

    if (!seen_distribution) return error.MissingField;
    if (entry.version.len == 0 or entry.upstream.len == 0 or entry.license.len == 0) {
        return error.MissingField;
    }

    const at = std.mem.indexOf(u8, source, license_text_heading) orelse return error.NoLicenseText;
    const after = source[at + license_text_heading.len ..];
    // Blank lines included: a heading followed by nothing is a file that was truncated
    // mid-edit, and it is the failure that produces a notice looking complete and not being.
    if (std.mem.trim(u8, after, " \t\r\n").len == 0) return error.NoLicenseText;
    return entry;
}

const Field = struct { key: []const u8, value: []const u8 };

/// `- **Key:** value`, and nothing looser. The convention is in
/// `THIRD_PARTY_LICENSES/README.md` and is what these files are written to.
fn field(line: []const u8) ?Field {
    if (!std.mem.startsWith(u8, line, "- **")) return null;
    const rest = line["- **".len..];
    const close = std.mem.indexOf(u8, rest, ":**") orelse return null;
    return .{ .key = rest[0..close], .value = trim(rest[close + ":**".len ..]) };
}

/// `distributed` and `build-time only`, each optionally followed by the explanation these
/// files already carry — SDL's says "distributed — SDL is statically linked into Foundry
/// binaries." A value that merely starts with one of the words is not one of them.
fn distributionOf(value: []const u8) ?Distribution {
    if (isWord(value, "build-time only")) return .build_time_only;
    if (isWord(value, "distributed")) return .distributed;
    return null;
}

fn isWord(value: []const u8, word: []const u8) bool {
    if (!std.mem.startsWith(u8, value, word)) return false;
    if (value.len == word.len) return true;
    return switch (value[word.len]) {
        ' ', '.', ',', ';', ':' => true,
        else => false,
    };
}

fn trim(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

pub const CollectError = error{ Refused, OutOfMemory };

/// Reads every entry in a directory, in filename order.
///
/// `README.md` is the directory's own documentation and is skipped by name; everything else
/// must parse. A file that does not is a refusal rather than an entry left out, because the
/// failure mode this whole mechanism exists to prevent is a notice quietly going missing.
pub fn collect(
    arena: Allocator,
    os: *Os,
    dir: []const u8,
    max_bytes: usize,
    report: anytype,
) CollectError![]const Entry {
    var listing = os.listDir(arena, dir) catch |err| {
        report.refuse("the recorded licenses in '{s}' cannot be read: {t}", .{ dir, err });
        return error.Refused;
    };
    defer listing.deinit();

    const names = try entryNames(arena, listing.entries);

    var entries: std.ArrayList(Entry) = .empty;
    var refused = false;
    for (names) |name| {
        const read = os.readFileConfined(arena, dir, name, max_bytes) catch |err| {
            report.refuse("the recorded license '{s}' cannot be read: {t}", .{ name, err });
            refused = true;
            continue;
        };
        const entry = parse(arena, name, read.bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                report.refuse("the recorded license '{s}' is malformed: {t}", .{ name, err });
                refused = true;
                continue;
            },
        };
        try entries.append(arena, entry);
    }
    if (refused) return error.Refused;
    if (entries.items.len == 0) {
        report.refuse("'{s}' records no licenses at all", .{dir});
        return error.Refused;
    }
    return entries.items;
}

/// Which files in a directory listing are entries, in the order they are read.
///
/// Separated from the reading so that the order is testable without a filesystem: a
/// directory hands its contents back in whatever order it stores them — APFS by hash, ext4
/// by another hash — and a notice file that changed between two machines for that reason
/// would be a notice file nobody could compare (§9, I9).
pub fn entryNames(arena: Allocator, listing: []const platform.os.DirEntry) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (listing) |item| {
        if (item.kind != .file) continue;
        // The directory's own documentation, which describes the convention rather than
        // recording a component.
        if (std.mem.eql(u8, item.name, "README.md")) continue;
        if (!std.mem.endsWith(u8, item.name, ".md")) continue;
        try names.append(arena, try arena.dupe(u8, item.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const rule = "=" ** 78;
const thin_rule = "-" ** 78;

/// Writes the file a player receives.
///
/// Deterministic: filename order, no timestamps, no paths from the machine that produced it.
/// Two releases built from the same repository produce the same bytes, which is what lets a
/// release be compared rather than inspected (§8).
pub fn write(
    out: *std.Io.Writer,
    product: Product,
    entries: []const Entry,
    packages: []const PackageNotice,
) std.Io.Writer.Error!void {
    var distributed: u32 = 0;
    for (entries) |entry| {
        if (entry.distribution == .distributed) distributed += 1;
    }

    try out.print("THIRD-PARTY NOTICES\n{s} {s}\n\n", .{ product.name, product.version });
    try out.print(
        \\This application is distributed with the {d} third-party component(s) listed below.
        \\Each one's recorded entry is reproduced in full, license text included. This file is
        \\generated from the licenses recorded in the source repository and is not written by
        \\hand.
        \\
        \\A component is listed because it may be present in this distribution, not because
        \\every listed component is linked into this particular build. Where a build excludes
        \\one, its notice is kept deliberately: an aggregate that is too large is correct, and
        \\one that is too small is not.
        \\
        \\
    , .{distributed});

    for (entries) |entry| {
        if (entry.distribution != .distributed) continue;
        try out.print("{s}\n {s}\n{s}\n\n", .{ rule, entry.file, rule });
        try out.writeAll(std.mem.trimEnd(u8, entry.text, "\n"));
        try out.writeAll("\n\n");
    }

    if (packages.len == 0) return;

    try out.print("{s}\n CONTENT PACKAGES\n{s}\n\n", .{ rule, rule });
    try out.writeAll(
        \\The content packages in this distribution, and the licenses they declare in their
        \\own manifests. A license identifier is not a license text: where a package needs
        \\one, it is reproduced under this list.
        \\
        \\
    );
    for (packages) |package| {
        try out.print("  {s} {d} — {s}\n", .{ package.package, package.version, package.license });
    }
    try out.writeAll("\n");

    for (packages) |package| {
        const text = package.text orelse continue;
        try out.print("{s}\n {s} — {s}\n{s}\n\n", .{ thin_rule, package.package, package.license, thin_rule });
        try out.writeAll(std.mem.trimEnd(u8, text, "\n"));
        try out.writeAll("\n\n");
    }
}

// -- tests -------------------------------------------------------------------------------

const testing = std.testing;

const widget =
    \\# Widget
    \\
    \\- **Version:** 1.2.3
    \\- **Upstream:** https://example.invalid/widget
    \\- **License:** MIT
    \\- **Distribution:** distributed — linked into the binary.
    \\- **Location in tree:** fetched via build.zig.zon
    \\- **Why we depend on it:** It widgets, which is a thing this needs done and
    \\  would otherwise have to do itself.
    \\- **Modifications:** none
    \\
    \\## Why this one
    \\
    \\Because - **Distribution:** build-time only is a line that appears here, in prose,
    \\and a parser that scanned the whole file would believe it.
    \\
    \\## License text
    \\
    \\Permission is hereby granted, free of charge, to whoever.
;

test "an entry is read whole, and its metadata block is the only place fields are looked for" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const entry = try parse(arena.allocator(), "widget.md", widget);
    try testing.expectEqualStrings("widget.md", entry.file);
    try testing.expectEqualStrings("Widget", entry.name);
    try testing.expectEqualStrings("1.2.3", entry.version);
    try testing.expectEqualStrings("https://example.invalid/widget", entry.upstream);
    try testing.expectEqualStrings("MIT", entry.license);

    // The prose in `## Why this one` says `build-time only`. A parser that read past the
    // metadata block would have taken it, and the component would have vanished from every
    // notice file after that.
    try testing.expectEqual(Distribution.distributed, entry.distribution);

    // The whole file, because SDL's entry records a license *election* that lives outside
    // its `## License text` section and is part of the attribution (§9).
    try testing.expectEqualStrings(widget, entry.text);
}

test "a field may run onto the next line, because the recorded ones do" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const entry = try parse(arena.allocator(), "long.md",
        \\# Long
        \\
        \\- **Version:** 3.4.14, via the Zig port castholm/SDL v0.5.3
        \\  (commit fb2d799c4778832a34ccb3739e40dded700684bd)
        \\- **Upstream:** https://example.invalid
        \\- **License:** Zlib
        \\- **Distribution:** distributed
        \\
        \\## License text
        \\
        \\Do what you like.
    );
    try testing.expectEqualStrings(
        "3.4.14, via the Zig port castholm/SDL v0.5.3 (commit fb2d799c4778832a34ccb3739e40dded700684bd)",
        entry.version,
    );
}

test "a distribution field says one of two things, and a near miss is not one of them" {
    try testing.expectEqual(Distribution.distributed, distributionOf("distributed").?);
    try testing.expectEqual(Distribution.distributed, distributionOf("distributed — and here is why.").?);
    try testing.expectEqual(Distribution.distributed, distributionOf("distributed.").?);
    try testing.expectEqual(Distribution.build_time_only, distributionOf("build-time only").?);
    try testing.expectEqual(Distribution.build_time_only, distributionOf("build-time only, never shipped").?);

    // A value that merely begins with the word is a different claim, and guessing which one
    // would put a component in or out of a legal document by accident.
    try testing.expect(distributionOf("distributed-ish") == null);
    try testing.expect(distributionOf("build-time") == null);
    try testing.expect(distributionOf("maybe") == null);
    try testing.expect(distributionOf("") == null);
}

test "a malformed entry is refused rather than half-read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const good =
        \\# Widget
        \\
        \\- **Version:** 1
        \\- **Upstream:** u
        \\- **License:** MIT
        \\- **Distribution:** distributed
        \\
        \\## License text
        \\
        \\Text.
    ;
    _ = try parse(a, "w.md", good);

    try testing.expectError(error.NoTitle, parse(a, "w.md", "- **Version:** 1\n"));
    try testing.expectError(error.NoTitle, parse(a, "w.md", ""));

    // Each required field, removed.
    for ([_][]const u8{ "- **Version:** 1\n", "- **Upstream:** u\n", "- **License:** MIT\n", "- **Distribution:** distributed\n" }) |line| {
        const without = try std.mem.replaceOwned(u8, a, good, line, "");
        try testing.expectError(error.MissingField, parse(a, "w.md", without));
    }

    // A field with nothing after it is absent, not empty: an entry recording a blank
    // upstream records nothing at all.
    const blank = try std.mem.replaceOwned(u8, a, good, "- **License:** MIT", "- **License:**");
    try testing.expectError(error.MissingField, parse(a, "w.md", blank));

    // Twice is a file that was edited twice and now says two things.
    const twice = try std.mem.replaceOwned(u8, a, good, "- **License:** MIT", "- **License:** MIT\n- **License:** Zlib");
    try testing.expectError(error.DuplicateField, parse(a, "w.md", twice));
    const twice_dist = try std.mem.replaceOwned(u8, a, good, "- **Distribution:** distributed", "- **Distribution:** distributed\n- **Distribution:** build-time only");
    try testing.expectError(error.DuplicateField, parse(a, "w.md", twice_dist));

    const unknown = try std.mem.replaceOwned(u8, a, good, "distributed", "shipped, probably");
    try testing.expectError(error.UnknownDistribution, parse(a, "w.md", unknown));

    // Truncated where the license text should be, which is the failure that produces a
    // notice file that looks complete and is not.
    const truncated = good[0..std.mem.indexOf(u8, good, "Text.").?];
    try testing.expectError(error.NoLicenseText, parse(a, "w.md", truncated));
    const no_section = try std.mem.replaceOwned(u8, a, good, "## License text", "## Notes");
    try testing.expectError(error.NoLicenseText, parse(a, "w.md", no_section));

    // A line in the metadata block that is neither a field nor a continuation. The block is
    // the one part of these files a machine reads, so a stray line there is a file whose
    // shape has drifted and whose other fields cannot be trusted either.
    const stray = try std.mem.replaceOwned(u8, a, good, "- **Upstream:** u", "Upstream: u");
    try testing.expectError(error.UnexpectedMetadata, parse(a, "w.md", stray));
}

test "the aggregate reproduces every distributed entry whole and leaves a build-time one out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shipped = try parse(a, "widget.md", widget);
    const tool = try parse(a, "gadget.md",
        \\# Gadget
        \\
        \\- **Version:** 9
        \\- **Upstream:** https://example.invalid/gadget
        \\- **License:** MIT
        \\- **Distribution:** build-time only
        \\
        \\## License text
        \\
        \\Not shipped, still recorded.
    );

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .name = "Demo", .version = "1.0.0" }, &.{ shipped, tool }, &.{});
    const text = out.written();

    try testing.expect(std.mem.startsWith(u8, text, "THIRD-PARTY NOTICES\nDemo 1.0.0\n"));
    try testing.expect(std.mem.indexOf(u8, text, "distributed with the 1 third-party") != null);

    // Whole, including the section that is not the license text.
    try testing.expect(std.mem.indexOf(u8, text, "## Why this one") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Permission is hereby granted") != null);
    try testing.expect(std.mem.indexOf(u8, text, " widget.md\n") != null);

    // The tool is recorded in the repository and is not in the artifact, which is the whole
    // point of the distinction.
    try testing.expect(std.mem.indexOf(u8, text, "Gadget") == null);
    try testing.expect(std.mem.indexOf(u8, text, "Not shipped") == null);
}

test "a package's declared license is listed, and the notice it needs is reproduced under it" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const shipped = try parse(arena.allocator(), "widget.md", widget);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .name = "Demo", .version = "1" }, &.{shipped}, &.{
        .{ .package = "demo:pack", .version = 1, .license = "Apache-2.0" },
        .{ .package = "demo:art", .version = 2, .license = "CC-BY-4.0", .text = "Art by somebody." },
    });
    const text = out.written();

    // Every package is listed, because what a distribution contains is part of what it has
    // to disclose; only the one that needs a text carries one.
    try testing.expect(std.mem.indexOf(u8, text, "  demo:pack 1 — Apache-2.0\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  demo:art 2 — CC-BY-4.0\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Art by somebody.") != null);
    try testing.expect(std.mem.indexOf(u8, text, " demo:art — CC-BY-4.0\n") != null);
}

test "entries are read in filename order, whatever order the directory hands them back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Deliberately not the order they come out in. A filesystem stores names by hash, so
    // this is the only place the ordering can be checked at all — a test that wrote files
    // and read the directory back would be testing the filesystem's mood.
    const names = try entryNames(arena.allocator(), &.{
        .{ .name = "zebra.md", .kind = .file },
        .{ .name = "README.md", .kind = .file },
        .{ .name = "widget.md", .kind = .file },
        .{ .name = "notes.txt", .kind = .file },
        .{ .name = "alpha.md", .kind = .file },
        .{ .name = "nested", .kind = .directory },
    });

    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("alpha.md", names[0]);
    try testing.expectEqualStrings("widget.md", names[1]);
    try testing.expectEqualStrings("zebra.md", names[2]);
}

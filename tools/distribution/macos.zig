//! Pure macOS release metadata and inspection rules.
//!
//! The platform tools do the platform-specific work: `plutil` parses the generated plist,
//! `otool` reports Mach-O load commands, and `dwarfdump` reports UUIDs. This file checks the
//! answers rather than reimplementing any of those tools. Keeping the checks pure makes a bad
//! bundle identifier, a build-machine dylib path, or mismatched symbols an ordinary unit test
//! instead of something learned only after signing (`distribution.md` §11).

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Metadata = struct {
    product_name: []const u8,
    bundle_id: []const u8,
    product_version: []const u8,
    build_number: []const u8,
    executable_name: []const u8,
    minimum_macos_version: []const u8,
};

pub const MetadataError = error{
    InvalidProductName,
    InvalidBundleId,
    InvalidProductVersion,
    InvalidBuildNumber,
    InvalidExecutableName,
    InvalidMinimumVersion,
};

/// Writes the one source of product metadata as an XML property list.
///
/// Values are validated before the first byte is written. Product and executable names are
/// escaped rather than restricted to ASCII; the fields whose syntax macOS interprets are
/// deliberately ASCII and canonical.
pub fn writePlist(out: *std.Io.Writer, metadata: Metadata) (MetadataError || std.Io.Writer.Error)!void {
    try validateMetadata(metadata);

    try out.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleDevelopmentRegion</key>
        \\  <string>en</string>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>
    );
    try writeXml(out, metadata.product_name);
    try out.writeAll(
        \\</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>
    );
    try writeXml(out, metadata.executable_name);
    try out.writeAll(
        \\</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>
    );
    try writeXml(out, metadata.bundle_id);
    try out.writeAll(
        \\</string>
        \\  <key>CFBundleInfoDictionaryVersion</key>
        \\  <string>6.0</string>
        \\  <key>CFBundleName</key>
        \\  <string>
    );
    try writeXml(out, metadata.product_name);
    try out.writeAll(
        \\</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>
    );
    try writeXml(out, metadata.product_version);
    try out.writeAll(
        \\</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>
    );
    try writeXml(out, metadata.build_number);
    try out.writeAll(
        \\</string>
        \\  <key>LSApplicationCategoryType</key>
        \\  <string>public.app-category.games</string>
        \\  <key>LSMinimumSystemVersion</key>
        \\  <string>
    );
    try writeXml(out, metadata.minimum_macos_version);
    try out.writeAll(
        \\</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\</dict>
        \\</plist>
        \\
    );
}

pub fn validateMetadata(metadata: Metadata) MetadataError!void {
    if (!isDisplayString(metadata.product_name, 128)) return error.InvalidProductName;
    if (!isBundleId(metadata.bundle_id)) return error.InvalidBundleId;
    if (!isNumericVersion(metadata.product_version, 3)) return error.InvalidProductVersion;
    if (!isNumericVersion(metadata.build_number, 3)) return error.InvalidBuildNumber;
    if (!isComponent(metadata.executable_name, 255)) return error.InvalidExecutableName;
    if (!isNumericVersion(metadata.minimum_macos_version, 3)) return error.InvalidMinimumVersion;
}

fn isDisplayString(text: []const u8, limit: usize) bool {
    if (text.len == 0 or text.len > limit or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |c| if (c < 0x20 and c != '\t') return false;
    return true;
}

fn isComponent(text: []const u8, limit: usize) bool {
    if (text.len == 0 or text.len > limit or std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, "..")) return false;
    for (text) |c| {
        if (c < 0x21 or c > 0x7e or c == '/' or c == '\\' or c == ':') return false;
    }
    return true;
}

fn isBundleId(text: []const u8) bool {
    if (text.len == 0 or text.len > 255 or text[0] == '.' or text[text.len - 1] == '.') return false;
    var components: usize = 1;
    var component_len: usize = 0;
    for (text) |c| switch (c) {
        '.' => {
            if (component_len == 0) return false;
            components += 1;
            component_len = 0;
        },
        'a'...'z', 'A'...'Z', '0'...'9', '-' => component_len += 1,
        else => return false,
    };
    return components >= 2 and component_len > 0;
}

fn isNumericVersion(text: []const u8, max_components: usize) bool {
    if (text.len == 0 or text.len > 32) return false;
    var components: usize = 1;
    var digits: usize = 0;
    for (text) |c| switch (c) {
        '.' => {
            if (digits == 0 or components == max_components) return false;
            components += 1;
            digits = 0;
        },
        '0'...'9' => digits += 1,
        else => return false,
    };
    return digits > 0;
}

fn writeXml(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try out.writeAll("&amp;"),
        '<' => try out.writeAll("&lt;"),
        '>' => try out.writeAll("&gt;"),
        '\'' => try out.writeAll("&apos;"),
        '"' => try out.writeAll("&quot;"),
        else => try out.writeByte(c),
    };
}

pub const InspectError = error{
    MalformedDependencyOutput,
    InvalidBundledDependency,
    ForbiddenDependency,
    MalformedUuidOutput,
    SymbolUuidMismatch,
} || Allocator.Error;

/// Checks `otool -L` output against the release's dependency policy.
///
/// System libraries are admitted by their system prefixes. Loader-relative paths are admitted
/// only when the release description named that exact dependency as bundled; `@rpath` is not a
/// promise that the file made it into the app.
pub fn verifyDependencies(output: []const u8, bundled: []const []const u8) InspectError!void {
    for (bundled) |allowed| {
        if (!std.mem.startsWith(u8, allowed, "@loader_path/") and
            !std.mem.startsWith(u8, allowed, "@executable_path/") and
            !std.mem.startsWith(u8, allowed, "@rpath/")) return error.InvalidBundledDependency;
    }

    var lines = std.mem.splitScalar(u8, output, '\n');
    const heading = lines.next() orelse return error.MalformedDependencyOutput;
    if (heading.len == 0 or heading[heading.len - 1] != ':') return error.MalformedDependencyOutput;

    var count: usize = 0;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const suffix = std.mem.indexOf(u8, line, " (compatibility version ") orelse
            return error.MalformedDependencyOutput;
        const dependency = line[0..suffix];
        count += 1;
        if (std.mem.startsWith(u8, dependency, "/usr/lib/") or
            std.mem.startsWith(u8, dependency, "/System/Library/")) continue;
        for (bundled) |allowed| {
            if (std.mem.eql(u8, dependency, allowed)) break;
        } else return error.ForbiddenDependency;
    }
    if (count == 0) return error.MalformedDependencyOutput;
}

const Uuid = struct {
    bytes: [16]u8,
    arch: []const u8,
};

/// Requires the Mach-O and its retained dSYM to report exactly the same UUID/architecture set.
pub fn verifySymbolUuids(gpa: Allocator, binary_output: []const u8, symbols_output: []const u8) InspectError!void {
    const binary = try parseUuids(gpa, binary_output);
    defer gpa.free(binary);
    const symbols = try parseUuids(gpa, symbols_output);
    defer gpa.free(symbols);

    if (binary.len == 0 or binary.len != symbols.len) return error.SymbolUuidMismatch;
    for (binary) |wanted| {
        for (symbols) |got| {
            if (std.mem.eql(u8, &wanted.bytes, &got.bytes) and std.mem.eql(u8, wanted.arch, got.arch)) break;
        } else return error.SymbolUuidMismatch;
    }
}

fn parseUuids(gpa: Allocator, output: []const u8) InspectError![]Uuid {
    var found: std.ArrayList(Uuid) = .empty;
    errdefer found.deinit(gpa);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "UUID: ")) return error.MalformedUuidOutput;
        const open = std.mem.indexOf(u8, line, " (") orelse return error.MalformedUuidOutput;
        const close = std.mem.indexOfPos(u8, line, open + 2, ") ") orelse return error.MalformedUuidOutput;
        const spelling = line[6..open];
        if (spelling.len != 36) return error.MalformedUuidOutput;

        var bytes: [16]u8 = undefined;
        var byte: usize = 0;
        var at: usize = 0;
        while (at < spelling.len) : (at += 1) {
            if (spelling[at] == '-') continue;
            if (at + 1 >= spelling.len or byte == bytes.len) return error.MalformedUuidOutput;
            bytes[byte] = std.fmt.parseInt(u8, spelling[at .. at + 2], 16) catch return error.MalformedUuidOutput;
            byte += 1;
            at += 1;
        }
        if (byte != bytes.len) return error.MalformedUuidOutput;
        const arch = line[open + 2 .. close];
        if (arch.len == 0) return error.MalformedUuidOutput;
        try found.append(gpa, .{ .bytes = bytes, .arch = arch });
    }
    return found.toOwnedSlice(gpa);
}

const testing = std.testing;

test "plist metadata is complete and XML escaped" {
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    try writePlist(&text.writer, .{
        .product_name = "Foundry & Room <local>",
        .bundle_id = "dev.foundry.room",
        .product_version = "0.9.0",
        .build_number = "17",
        .executable_name = "room",
        .minimum_macos_version = "26.0",
    });
    const got = text.written();
    try testing.expect(std.mem.indexOf(u8, got, "Foundry &amp; Room &lt;local&gt;") != null);
    for ([_][]const u8{
        "CFBundleExecutable", "CFBundleIdentifier",  "CFBundleShortVersionString",
        "CFBundleVersion",    "CFBundlePackageType", "LSMinimumSystemVersion",
        "26.0",
    }) |field| try testing.expect(std.mem.indexOf(u8, got, field) != null);
}

test "metadata that macOS would reinterpret is refused before a plist exists" {
    const valid: Metadata = .{
        .product_name = "Room",
        .bundle_id = "dev.foundry.room",
        .product_version = "0.9.0",
        .build_number = "1",
        .executable_name = "room",
        .minimum_macos_version = "26.0",
    };
    try validateMetadata(valid);
    var bad = valid;
    bad.bundle_id = "one-component";
    try testing.expectError(error.InvalidBundleId, validateMetadata(bad));
    bad = valid;
    bad.product_version = "version nine";
    try testing.expectError(error.InvalidProductVersion, validateMetadata(bad));
    bad = valid;
    bad.executable_name = "../room";
    try testing.expectError(error.InvalidExecutableName, validateMetadata(bad));
    bad = valid;
    bad.minimum_macos_version = "26.x";
    try testing.expectError(error.InvalidMinimumVersion, validateMetadata(bad));
}

test "only system or explicitly bundled Mach-O dependencies are admitted" {
    const system =
        "/Applications/Foundry Room.app/Contents/MacOS/room:\n" ++
        "\t/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit (compatibility version 45.0.0, current version 2575.40.3)\n" ++
        "\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)\n";
    try verifyDependencies(system, &.{});

    const relative =
        "room:\n" ++
        "\t@loader_path/../Frameworks/libhelper.dylib (compatibility version 1.0.0, current version 1.0.0)\n";
    try testing.expectError(error.ForbiddenDependency, verifyDependencies(relative, &.{}));
    try verifyDependencies(relative, &.{"@loader_path/../Frameworks/libhelper.dylib"});
    try testing.expectError(error.InvalidBundledDependency, verifyDependencies(relative, &.{"/opt/homebrew/lib/libhelper.dylib"}));

    const leaked =
        "room:\n" ++
        "\t/opt/homebrew/lib/libaccident.dylib (compatibility version 1.0.0, current version 1.0.0)\n";
    try testing.expectError(error.ForbiddenDependency, verifyDependencies(leaked, &.{}));
    try testing.expectError(error.MalformedDependencyOutput, verifyDependencies("not otool output", &.{}));
}

test "retained symbols must name the exact Mach-O UUID and architecture" {
    const binary = "UUID: 12345678-1234-ABCD-9876-0123456789AB (arm64) room\n";
    const symbols = "UUID: 12345678-1234-ABCD-9876-0123456789AB (arm64) Room.app.dSYM/Contents/Resources/DWARF/room\n";
    try verifySymbolUuids(testing.allocator, binary, symbols);

    const wrong = "UUID: 12345678-1234-ABCD-9876-0123456789AC (arm64) room\n";
    try testing.expectError(error.SymbolUuidMismatch, verifySymbolUuids(testing.allocator, binary, wrong));
    try testing.expectError(error.MalformedUuidOutput, verifySymbolUuids(testing.allocator, "UUID: nope\n", symbols));
}

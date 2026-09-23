# Getting started: your first game with Foundry

Foundry is an engine library, not an application you install. A game is its **own
repository** that depends on Foundry, the way it would depend on any Zig package, and
builds one program out of the engine's modules and its own code
([ADR-0017](adr/0017-repository-scope.md)). This page takes you from an empty folder to a
window. Everything below was built and run as an outside project.

What you need:

* **Zig 0.16.0**, exactly: the official tarball from ziglang.org, not a package manager.
* **macOS:** Xcode, and its Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
* **Windows or Linux:** a GPU driver with Vulkan 1.3, and the LunarG Vulkan SDK
  [pinned in AGENTS.md](../AGENTS.md) for the shader tools.

Nothing else. Foundry's own dependencies (SDL3, Lua, Mbed TLS) are fetched by Zig at pinned
hashes.

## 1. The folder

```
my-game/
  build.zig.zon         the package manifest; names Foundry as a dependency
  build.zig             builds the game and compiles its content
  src/main.zig          the game
  content/core/         Foundry's base package, copied from Foundry's content/core
  content/my-game/      your content package
    mod.fdt             its manifest
```

`content/core` is package zero (Invariant I3): every package depends on it. Copy it from the
Foundry tag you depend on and keep the two in step.

## 2. Depend on Foundry

Create `build.zig.zon` with `zig init`, or by hand, then add Foundry at a tag:

```sh
zig fetch --save git+https://github.com/sjoygsh/Foundry#m17
```

That writes a `.foundry` entry with its URL and hash into `.dependencies`. While you work on
the engine and the game side by side, a sibling checkout is simpler:

```zig
.dependencies = .{
    .foundry = .{ .path = "../Foundry" },
},
```

## 3. `build.zig`

```zig
const std = @import("std");
const foundry = @import("foundry");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Foundry, configured for this machine: SDL3 windows, and Metal on macOS or Vulkan
    // on Windows and Linux.
    const engine = b.dependency("foundry", .{
        .target = target,
        .optimize = optimize,
        .platform = .sdl3,
        .rhi = @as([]const u8, if (target.result.os.tag == .macos) "metal" else "vulkan"),
    });

    const game_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    for ([_][]const u8{ "app", "core", "platform", "render2d" }) |name| {
        game_mod.addImport(name, engine.module(name));
    }
    const game = b.addExecutable(.{ .name = "my-game", .root_module = game_mod });
    b.installArtifact(game);

    // Content is compiled by Foundry's own compiler, base package first, and installed
    // beside the executable as `content/<stem>.fpk` plus the package's files.
    const tools = foundry.release.Tools.fromDependency(engine);
    const core = foundry.release.compilePackage(b, tools.fpack, .{ .dir = "content/core", .stem = "core" });
    const mine = foundry.release.compilePackage(b, tools.fpack, .{
        .dir = "content/my-game",
        .stem = "my-game",
        .dependencies = &.{core.fpk},
    });
    for ([_]struct { []const u8, []const u8, foundry.release.Compiled }{
        .{ "core", "content/core", core },
        .{ "my-game", "content/my-game", mine },
    }) |pkg| {
        const stem, const dir, const compiled = pkg;
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(compiled.fpk, .prefix, b.fmt("content/{s}.fpk", .{stem})).step);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = b.path(dir), .install_dir = .prefix, .install_subdir = b.fmt("content/{s}", .{stem}) }).step);
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = compiled.generated, .install_dir = .prefix, .install_subdir = b.fmt("content/{s}", .{stem}) }).step);
    }

    const run = b.addRunArtifact(game);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Build and run the game").dependOn(&run.step);
}
```

Import only the modules the game uses. They are listed in
[CLAUDE.md §4.3](../CLAUDE.md): `app` for the engine loop, `render2d` for drawing, `scene`
for entities, `audio`, `physics2d`, `ui`, and `abi` if the game loads native mods.

## 4. The content package

`content/my-game/mod.fdt`:

```
# The game's own package: its manifest, and everything the game is made of.
foundry:mod  my_game:content {
    name     "My Game"
    version  1
    license  "Apache-2.0"
    summary  "The first thing I made with Foundry."
    requires [ { id foundry:core } ]
}
```

Records, textures, sounds and tilemaps go in the same folder. The format is in
[modding/content-mods.md](modding/content-mods.md), and the editor (below) writes the same
files.

## 5. `src/main.zig`

```zig
const std = @import("std");
const app = @import("app");
const platform = @import("platform");
const render2d = @import("render2d");

pub const std_options = app.std_options;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const env = try app.environment(gpa, init);
    defer gpa.free(env);
    var os = try platform.os.Os.init(gpa, .{ .env = env, .app_name = "my-game" });
    defer os.deinit();

    // `content/` beside `bin/`, where the build installed it.
    const content_dir = try app.contentDirOf(gpa, os, null);
    defer gpa.free(content_dir);
    const packages = [_]app.ContentPackage{
        .{ .file = "core.fpk", .root = "core" },
        .{ .file = "my-game.fpk", .root = "my-game" },
    };

    var engine = try app.Engine.init(gpa, .{
        .env = env,
        .app_name = "my-game",
        .log_level = .info,
        .window = .{
            .title = "My Game",
            .logical_width = 1280,
            .logical_height = 720,
            .surface = app.window_surface,
        },
        .content_dir = content_dir,
        .content = &packages,
    });
    defer engine.deinit();

    var renderer = try render2d.Renderer.init(gpa, engine.gpu, .{ .frames_in_flight = 2, .jobs = engine.jobs() });
    defer renderer.deinit();

    while (!engine.shouldQuit()) {
        engine.beginFrame();
        while (engine.nextEvent()) |_| {}

        const size = if (engine.windowInfo()) |window| window.logical_size else return;
        try renderer.begin(.{ .camera = .{ .viewport = .init(0, 0, @floatFromInt(size.width), @floatFromInt(size.height)) } });
        // Game drawing goes here: renderer.drawSprite, drawText, drawTilemap.

        engine.renderFrame(.{ .label = "game", .clear = .{ 0.10, 0.12, 0.18, 1 } }, &renderer) catch |err| {
            if (!app.Engine.frameSkippable(err)) return err;
        };
        engine.endFrame();
    }
}
```

## 6. Build and run

```sh
zig build run
```

Add `-Doptimize=ReleaseSafe` for a fast build. A window titled "My Game" opens and clears to
blue; the log says which backend it chose.

## 7. Where to go next

* **A real game loop:** [`samples/room/main.zig`](../samples/room/main.zig) is a small
  complete game (a walker, collision, lamps, audio, a HUD, settings and a mod screen), and
  [`samples/sandbox`](../samples/sandbox) shows every capability, scripting and networking
  included. Copy from them; they are written to be copied.
* **Content without code:** the editor. Download `Foundry-Editor` from the
  [releases page](https://github.com/sjoygsh/Foundry/releases), or run `zig build editor`
  in a Foundry checkout. See [modding/editor.md](modding/editor.md).
* **Mods:** [modding/](modding/) documents content, script and native mods, which a game
  gets without extra work.
* **Multiplayer:** [modding/networking.md](modding/networking.md).
* **Shipping:** [shipping/macos.md](shipping/macos.md) and
  [shipping/windows.md](shipping/windows.md) stage a relocatable app and zip with
  `foundry.release`, the same way Foundry's own downloads are made.

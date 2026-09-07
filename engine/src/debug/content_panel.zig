//! The content browser (`debug-overlay.md` §8).
//!
//! Most of this is a list of calls that already existed: the store was built with
//! introspection in it. What it adds is the question a mod author asks first — **who else
//! defines this?** — which the store does not keep and can still answer, because nothing was
//! thrown away.
//!
//! **A hash can be shown as a name.** `.fpk` interns the source spelling of every package,
//! schema and record id, because a package that can only state its own id is a package no
//! diagnostic can name. This panel is the payoff.

const std = @import("std");
const Allocator = std.mem.Allocator;

const data = @import("data");
const ui = @import("ui");

const overlay = @import("overlay.zig");
const View = overlay.View;

/// The most record rows formatted in one frame.
pub const max_rows = 64;

/// How many packages an override chain is walked back through. The load order is short and
/// a chain longer than this is a diagnosis in itself.
pub const max_definitions = 16;

pub const State = struct {
    selected: ?data.store.RecordHandle = null,

    pub fn describe(ctx: ?*anyopaque, view: *View) anyerror!void {
        const self: *State = @ptrCast(@alignCast(ctx.?));

        const store = view.frame.store orelse {
            try view.line("no content store", .{});
            return;
        };

        try view.line("{d} records  {d} packages  generation {d}", .{
            store.count(),
            store.packageCount(),
            view.frame.content_generation,
        });

        // Not introspection and not a back door: this is the call a game already makes on a
        // key press, put under the panel that shows what is loaded, which is where a person
        // looks for it.
        if (view.frame.reload) |reload| {
            if (try ui.button(view.ui, view.ui.childId("reload"), "reload content")) reload.invoke();
        }

        try self.describePackages(view, store);
        try self.describeRecords(view, store);
        try self.describeAssets(view, store);
        try self.describeSchemas(view);
    }

    fn describePackages(_: *State, view: *View, store: *const data.Store) anyerror!void {
        const order = store.loadOrder();
        const header = view.text("packages ({d})", .{order.len});
        if (!try ui.collapsingHeader(view.ui, view.ui.childId("packages"), header)) return;

        // In load order, which is the order overrides resolve in. Package zero is the base
        // game's and it loads through exactly the path a mod's does (I3).
        for (order) |handle| {
            const package = store.package(handle) orelse continue;
            try view.line("    {d} {s} v{d}", .{ package.order, package.name, package.version });
        }
    }

    fn describeRecords(self: *State, view: *View, store: *const data.Store) anyerror!void {
        const total = store.count();
        const header = view.text("records ({d})", .{total});
        if (!try ui.collapsingHeader(view.ui, view.ui.childId("records"), header)) return;

        const row = view.row();
        const remaining = view.ui.region().remaining();
        const list_height = @max(row, remaining.h * 0.4);
        const list_id = view.ui.childId("record.list");
        const window = overlay.windowOf(
            view.ui,
            list_id,
            total,
            @min(max_rows, overlay.rowsIn(list_height, row)),
            row,
        );

        // Reserved from the enclosing region before the scroll opens, so what follows the
        // list lands under it rather than on top of it.
        const area = view.ui.region().take(list_height);
        try ui.beginScroll(view.ui, list_id, area, window.contentHeight());
        ui.spacer(view.ui, window.before());

        var index: usize = 0;
        var records = store.all();
        while (records.next()) |record| : (index += 1) {
            if (index < window.first) continue;
            if (index >= window.first + window.count) break;
            const selected = if (self.selected) |s| s.eql(record.handle) else false;
            const text = view.text("{s}{s}", .{ if (selected) "> " else "  ", record.name });
            if (try ui.button(view.ui, view.ui.childIndex(index), text)) self.selected = record.handle;
        }

        ui.spacer(view.ui, window.after());
        try ui.endScroll(view.ui);

        try self.describeSelection(view, store);
    }

    fn describeSelection(self: *State, view: *View, store: *const data.Store) anyerror!void {
        const handle = self.selected orelse return;
        // Re-resolved every frame: a hot reload can replace the package this came from, and
        // a stale handle is `null` rather than a crash (§12).
        const record = store.get(handle) orelse {
            try view.line("selection is gone", .{});
            return;
        };

        const owner = store.package(record.package);
        try view.line("{s} from {s}", .{ record.name, if (owner) |p| p.name else "?" });

        // **Who else defines this?** A linear walk of each package's record table, on
        // demand, for one id, when somebody clicks — no index and no bookkeeping (§8.1).
        var buffer: [max_definitions]data.store.PackageHandle = undefined;
        const defined_by = store.definitions(record.id, &buffer);
        if (defined_by.len > 1) {
            for (defined_by, 0..) |package_handle, i| {
                const package = store.package(package_handle) orelse continue;
                try view.line("    defined by {s}{s}", .{
                    package.name,
                    if (i + 1 == defined_by.len) " (won)" else " (overridden)",
                });
            }
        }

        // The record as the store reads it, defaults and all — which is what the game sees,
        // and therefore what somebody debugging an override needs, rather than the bytes on
        // disk. A field a newer schema version added is filled from its default.
        const newest: ?data.Schema = blk: {
            const registry = view.frame.schemas orelse break :blk null;
            const schema = registry.lookup(record.schema_id) orelse break :blk null;
            break :blk schema.*;
        };
        const count = if (newest) |s| s.fields.len else record.schema.fields.len;

        for (0..count) |i| {
            const index: u32 = @intCast(i);
            if (index < record.schema.fields.len) {
                const field = record.schema.fields[index];
                const value = record.fields.valueAt(view.arena, index) catch |err| {
                    try view.line("    {s} = {t}", .{ field.name, err });
                    continue;
                } orelse {
                    try view.line("    {s} = absent", .{field.name});
                    continue;
                };
                try view.line("    {s} = {s}", .{
                    field.name,
                    overlay.valueText(view.arena, store, value),
                });
            } else if (newest) |schema| {
                const field = schema.fields[index];
                const value = record.missingDefault(schema, index) orelse {
                    try view.line("    {s} = absent (added in v{d})", .{ field.name, field.since });
                    continue;
                };
                try view.line("    {s} = {s} (default)", .{
                    field.name,
                    overlay.valueText(view.arena, store, value),
                });
            }
        }
    }

    fn describeAssets(_: *State, view: *View, store: *const data.Store) anyerror!void {
        const assets = view.frame.assets orelse return;
        const header = view.text("assets ({d})", .{assets.count()});
        if (!try ui.collapsingHeader(view.ui, view.ui.childId("assets"), header)) return;

        var it = assets.assets();
        while (it.next()) |info| {
            // **Zero references means evictable, not freed**, and nothing evicts on a
            // schedule. This is the first time anybody can see that state, and it is the
            // real answer to "why is this still in memory".
            try view.line("    {s}  {d} ref(s)", .{
                overlay.idText(view.arena, store, info.id),
                info.refs,
            });
        }
    }

    fn describeSchemas(_: *State, view: *View) anyerror!void {
        const registry = view.frame.schemas orelse return;
        const header = view.text("schemas ({d})", .{registry.count()});
        if (!try ui.collapsingHeader(view.ui, view.ui.childId("schemas"), header)) return;

        var it = registry.all();
        while (it.next()) |entry| {
            // A schema knows its id and not its spelling: the spelling lives in the packages
            // that carry it, because that is where somebody wrote it down. So the browser
            // shows the hash unless something loaded names it.
            try view.line("    {x}  v{d}  {d} field(s)", .{
                entry.id.hash,
                entry.version,
                entry.field_count,
            });
        }
    }
};

// -- tests -----------------------------------------------------------------------------

const testing = std.testing;

/// Compiles source into package bytes, the way `fpack` does, and against a registry the
/// caller supplies — so two packages can be compiled independently, which is what a mod is.
fn compile(
    gpa: Allocator,
    name: []const u8,
    source: []const u8,
    registry: *data.Registry,
    diagnostics: *data.Diagnostics,
    out: *std.ArrayList(u8),
) !void {
    var document = try data.parser.parse(gpa, "test.fdt", source, .{
        .namespace = name[0..std.mem.indexOfScalar(u8, name, ':').?],
    }, diagnostics);
    defer document.deinit(gpa);

    var package = try data.check.Package.init(gpa, name, 1, .default);
    defer package.deinit(gpa);
    try package.addDocument(gpa, &document, registry, diagnostics);

    try data.fpk.write(gpa, &package, registry, out);
}

const item_source =
    \\@schema item { name string  weight f32 (default 1.0) }
    \\item foundry:item.torch { name "Torch"  weight 0.5 }
;

const brighter_source =
    \\@schema item { name string  weight f32 (default 1.0) }
    \\item foundry:item.torch { name "Brighter torch"  weight 0.5 }
;

const Harness = struct {
    registry: data.Registry,
    diagnostics: data.Diagnostics,
    store: data.Store,
    arena: std.heap.ArenaAllocator,
    blobs: std.ArrayList(std.ArrayList(u8)) = .empty,

    fn init() Harness {
        const gpa = testing.allocator;
        return .{
            .registry = .init(gpa, .default),
            .diagnostics = .init(gpa, .default),
            .store = .init(gpa, .default),
            .arena = .init(gpa),
        };
    }

    fn deinit(self: *Harness) void {
        const gpa = testing.allocator;
        self.store.deinit(gpa);
        self.registry.deinit(gpa);
        self.diagnostics.deinit(gpa);
        for (self.blobs.items) |*b| b.deinit(gpa);
        self.blobs.deinit(gpa);
        self.arena.deinit();
    }

    /// Compiles against a private registry — two independent packages, the way two authors
    /// who never met would produce them — and loads the result.
    fn add(self: *Harness, name: []const u8, source: []const u8) !void {
        const gpa = testing.allocator;
        var registry: data.Registry = .init(gpa, .default);
        defer registry.deinit(gpa);
        var diagnostics: data.Diagnostics = .init(gpa, .default);
        defer diagnostics.deinit(gpa);

        var bytes: std.ArrayList(u8) = .empty;
        {
            // Ownership moves to `blobs` at the append, so the `errdefer` has to end there
            // — leaving it armed over the load below would free a buffer the harness now
            // owns, and the second free is the crash.
            errdefer bytes.deinit(gpa);
            try compile(gpa, name, source, &registry, &diagnostics, &bytes);
            try self.blobs.append(gpa, bytes);
        }

        _ = try self.store.add(
            gpa,
            name,
            self.blobs.items[self.blobs.items.len - 1].items,
            &self.registry,
            &self.diagnostics,
        );
    }

    fn view(self: *Harness, ctx: *ui.Context) View {
        return .{
            .ui = ctx,
            .arena = self.arena.allocator(),
            .frame = .{ .store = &self.store, .schemas = &self.registry },
            .sources = .{},
        };
    }
};

test "a record is named by its authored spelling, with the values the game sees" {
    var h: Harness = .init();
    defer h.deinit();
    try h.add("foundry:core", item_source);

    var state: State = .{ .selected = h.store.find(try data.contentId("foundry:item.torch")).? };
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 500));
    ctx.stateOf(ui.Id.root.child("records")).open = true;
    ctx.stateOf(ui.Id.root.child("packages")).open = true;
    var v = h.view(&ctx);
    try State.describe(&state, &v);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "1 records  1 packages"));
    try testing.expect(overlay.findText(&ctx, "0 foundry:core v1"));
    try testing.expect(overlay.findText(&ctx, "foundry:item.torch from foundry:core"));
    try testing.expect(overlay.findText(&ctx, "name = \"Torch\""));
    try testing.expect(overlay.findText(&ctx, "weight = 0.5"));
}

test "the browser names every package that defines an id, winner last" {
    var h: Harness = .init();
    defer h.deinit();
    try h.add("foundry:core", item_source);
    try h.add("foundry:brighter", brighter_source);

    var state: State = .{ .selected = h.store.find(try data.contentId("foundry:item.torch")).? };
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 500));
    ctx.stateOf(ui.Id.root.child("records")).open = true;
    var v = h.view(&ctx);
    try State.describe(&state, &v);
    ctx.end();

    // The question a mod author asks first, and the store does not keep the answer — it
    // reconstructs it from package bytes nothing threw away (§8.1).
    try testing.expect(overlay.findText(&ctx, "defined by foundry:core (overridden)"));
    try testing.expect(overlay.findText(&ctx, "defined by foundry:brighter (won)"));
    try testing.expect(overlay.findText(&ctx, "\"Brighter torch\""));
}

test "the schema list shows what is registered, by hash, with its version" {
    var h: Harness = .init();
    defer h.deinit();
    try h.add("foundry:core", item_source);

    var state: State = .{};
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 500));
    ctx.stateOf(ui.Id.root.child("schemas")).open = true;
    var v = h.view(&ctx);
    try State.describe(&state, &v);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "schemas (1)"));
    try testing.expect(overlay.findText(&ctx, "2 field(s)"));
}

test "no store is an answer rather than an absent panel" {
    var test_arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer test_arena.deinit();
    var ctx = ui.Context.init(testing.allocator, overlay.testStyle());
    defer ctx.deinit();
    ctx.begin(.{}, .init(0, 0, 600, 400));
    var state: State = .{};
    var view: View = .{ .ui = &ctx, .arena = test_arena.allocator(), .frame = .{}, .sources = .{} };
    try State.describe(&state, &view);
    ctx.end();

    try testing.expect(overlay.findText(&ctx, "no content store"));
}

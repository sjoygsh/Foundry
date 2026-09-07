//! Content, as the table publishes it: records, packages and schemas.
//!
//! **A record is read through its schema**, never by casting bytes. A mod asks what a field
//! is and calls the matching reader, which is how it reads a record type it has never heard
//! of — including one another mod declared — and it is exactly what the debug overlay's
//! inspector was made to do one milestone before there was a boundary to need it.
//!
//! Three answers are deliberately distinct, and keeping them apart is most of what the
//! validation here is for:
//!
//! * **`invalid_argument`** — the schema has no such field, or the reader does not match the
//!   field's type. A mistake in the mod.
//! * **`not_found`** — the field exists and this record does not carry a value for it. A
//!   fact about the content.
//! * **`invalid_handle`** — the record itself is gone, or was never issued.
//!
//! A record written against an **older version of its schema** answers newer fields with the
//! defaults that version declares. That is what makes a schema able to grow at all, and it is
//! the same fill `data` already does for a game; a boundary that skipped it would give a mod
//! `not_found` where the game two lines away sees a value.
//!
//! Design: `docs/design/public-abi.md` §7 and §9; `docs/design/content-schemas.md` §3 and §6.

const std = @import("std");
const core = @import("core");
const data = @import("data");

const host_mod = @import("host.zig");
const types = @import("types.zig");

const Bool = types.Bool;
const ContentId = types.ContentId;
const Cursor = types.Cursor;
const FieldType = types.FieldType;
const Package = types.Package;
const Record = types.Record;
const Result = types.Result;
const Schema = types.Schema;
const SchemaId = types.SchemaId;
const Str = types.Str;

pub fn Of(comptime H: type) type {
    return struct {
        // -- Content -------------------------------------------------------------------

        pub fn contentGeneration(out: ?*u64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            dst.* = engine.contentGeneration();
            return .ok;
        }

        /// The record a content id names, after every package has been merged and every
        /// override applied — the definition that *won*, which is the one the game sees too.
        pub fn contentFind(id: ContentId, out: ?*Record) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;

            const handle = engine.store.find(id) orelse return .not_found;
            dst.* = .wrap(handle);
            return .ok;
        }

        pub fn contentNext(cursor: ?*Cursor, out: ?*Record) callconv(.c) Result {
            return walkRecords(null, cursor, out);
        }

        pub fn contentNextOfSchema(schema: SchemaId, cursor: ?*Cursor, out: ?*Record) callconv(.c) Result {
            return walkRecords(schema, cursor, out);
        }

        fn walkRecords(schema: ?SchemaId, cursor: ?*Cursor, out: ?*Record) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (schema) |wanted| {
                if (wanted.isNone()) return .invalid_argument;
            }

            const generation = walkGeneration(engine.contentGeneration(), engine.store.count());
            if (!c.isBegin() and c.generation() != generation) return .invalid_argument;

            var it: data.store.Store.Iterator = .{
                .store = &engine.store,
                .schema_id = schema,
                .at = c.index(),
            };
            const record = it.next() orelse return .end;
            dst.* = .wrap(record.handle);
            c.* = .at(generation, it.at);
            return .ok;
        }

        // -- One record ----------------------------------------------------------------

        pub fn recordId(record: Record, out: ?*ContentId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const identity = r.record orelse return .not_found;
            dst.* = identity.id;
            return .ok;
        }

        pub fn recordName(record: Record, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const identity = r.record orelse return .not_found;
            dst.* = .from(identity.name);
            return .ok;
        }

        pub fn recordSchema(record: Record, out: ?*SchemaId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const identity = r.record orelse return .not_found;
            dst.* = identity.schema_id;
            return .ok;
        }

        pub fn recordPackage(record: Record, out: ?*Package) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const identity = r.record orelse return .not_found;
            dst.* = .wrap(identity.package);
            return .ok;
        }

        /// How many fields the record can be asked about.
        ///
        /// The **newest** registered schema's count, not the supplying package's, so a field
        /// added in a later version is visible and answers with its default. A mod compiled
        /// against today's schema does not have to know which package's copy it happened to
        /// be reading.
        pub fn recordFieldCount(record: Record, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            dst.* = @intCast(r.newest.fields.len);
            return .ok;
        }

        pub fn recordFieldIndex(record: Record, name: Str, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const text = name.utf8() orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const index = r.newest.fieldIndex(text) orelse return .not_found;
            dst.* = index;
            return .ok;
        }

        pub fn recordFieldName(record: Record, field: u32, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            if (field >= r.newest.fields.len) return .invalid_argument;
            dst.* = .from(r.newest.fields[field].name);
            return .ok;
        }

        pub fn recordFieldType(record: Record, field: u32, out: ?*FieldType) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            if (field >= r.newest.fields.len) return .invalid_argument;
            dst.* = .fromData(r.newest.fields[field].type);
            return .ok;
        }

        /// Whether the record actually carries a value.
        ///
        /// A missing optional field and a field set to its default are different facts, and
        /// `data` refuses to collapse them for the same reason this does: "this item drops
        /// nothing" and "this item's drop was never specified" must not be the same answer.
        pub fn recordFieldPresent(record: Record, field: u32, out: ?*Bool) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            if (field >= r.newest.fields.len) return .invalid_argument;
            if (field >= r.schema.fields.len) {
                dst.* = types.boolOut(false);
                return .ok;
            }
            dst.* = types.boolOut(r.fields.present(field));
            return .ok;
        }

        // -- Reading a field -----------------------------------------------------------

        pub fn recordGetBool(record: Record, field: u32, out: ?*Bool) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const at = inRange(r, field) orelse return .invalid_argument;

            if (at.own) {
                const value = r.fields.boolAt(field) catch |err| return readFailure(err);
                dst.* = types.boolOut(value orelse return .not_found);
                return .ok;
            }
            const value = defaultOf(r, field) orelse return .not_found;
            if (value != .bool) return .invalid_argument;
            dst.* = types.boolOut(value.bool);
            return .ok;
        }

        pub fn recordGetI64(record: Record, field: u32, out: ?*i64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const at = inRange(r, field) orelse return .invalid_argument;

            const wide = if (at.own) blk: {
                const value = r.fields.intAt(field) catch |err| return readFailure(err);
                break :blk value orelse return .not_found;
            } else blk: {
                const value = defaultOf(r, field) orelse return .not_found;
                if (value != .int) return .invalid_argument;
                break :blk value.int;
            };
            dst.* = std.math.cast(i64, wide) orelse return .limit;
            return .ok;
        }

        pub fn recordGetU64(record: Record, field: u32, out: ?*u64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const at = inRange(r, field) orelse return .invalid_argument;

            const wide = if (at.own) blk: {
                const value = r.fields.intAt(field) catch |err| return readFailure(err);
                break :blk value orelse return .not_found;
            } else blk: {
                const value = defaultOf(r, field) orelse return .not_found;
                if (value != .int) return .invalid_argument;
                break :blk value.int;
            };
            dst.* = std.math.cast(u64, wide) orelse return .limit;
            return .ok;
        }

        /// An `f64` field is narrowed, and that is deliberate rather than an oversight: `f32`
        /// is the precision the simulation computes at (I9), a `double` never crosses this
        /// boundary, and a schema that genuinely needs more than `f32` holds a value the
        /// engine itself could not use.
        pub fn recordGetF32(record: Record, field: u32, out: ?*f32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const at = inRange(r, field) orelse return .invalid_argument;

            const wide = if (at.own) blk: {
                const value = r.fields.floatAt(field) catch |err| return readFailure(err);
                break :blk value orelse return .not_found;
            } else blk: {
                const value = defaultOf(r, field) orelse return .not_found;
                if (value != .float) return .invalid_argument;
                break :blk value.float;
            };
            dst.* = @floatCast(wide);
            return .ok;
        }

        pub fn recordGetString(record: Record, field: u32, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const text = stringIn(r, field) catch |err| return readRefusal(err);
            dst.* = .from(text);
            return .ok;
        }

        pub fn recordCopyString(
            record: Record,
            field: u32,
            buffer: ?[*]u8,
            capacity: u64,
            needed: ?*u64,
        ) callconv(.c) Result {
            const length = needed orelse return .invalid_argument;
            if (capacity > 0 and buffer == null) return .invalid_argument;
            if (capacity > Str.max_bytes) return .invalid_argument;

            const r = resolve(record) catch |err| return refusal(err);
            const text = stringIn(r, field) catch |err| return readRefusal(err);

            length.* = text.len;
            if (text.len > capacity) return .limit;
            if (text.len != 0) @memcpy(buffer.?[0..text.len], text);
            return .ok;
        }

        pub fn recordGetId(record: Record, field: u32, out: ?*ContentId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const at = inRange(r, field) orelse return .invalid_argument;

            if (at.own) {
                const value = r.fields.idAt(field) catch |err| return readFailure(err);
                dst.* = value orelse return .not_found;
                return .ok;
            }
            const value = defaultOf(r, field) orelse return .not_found;
            if (value != .id) return .invalid_argument;
            dst.* = value.id;
            return .ok;
        }

        /// An inline struct, as something that answers the same field calls one level down.
        pub fn recordNested(record: Record, field: u32, out: ?*Record) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const r = resolve(record) catch |err| return refusal(err);

            if (field >= r.schema.fields.len) return .invalid_argument;
            const declared = r.schema.fields[field].type;
            if (declared != .nested) return .invalid_argument;

            const fields = r.fields.nestedAt(field) catch |err| return readFailure(err);
            dst.* = h.openNested(
                engine.contentGeneration(),
                fields orelse return .not_found,
                .{ .id = .none, .version = r.schema.version, .fields = declared.nested },
            );
            return .ok;
        }

        // -- Reading a list ------------------------------------------------------------

        pub fn recordListLen(record: Record, field: u32, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const list = listIn(r, field) catch |err| return readRefusal(err);
            dst.* = list.len;
            return .ok;
        }

        pub fn recordListGetI64(record: Record, field: u32, index: u32, out: ?*i64) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const list = listIn(r, field) catch |err| return readRefusal(err);
            if (index >= list.len) return .invalid_argument;

            const value = list.intAt(index) catch |err| return readFailure(err);
            dst.* = std.math.cast(i64, value orelse return .not_found) orelse return .limit;
            return .ok;
        }

        pub fn recordListGetF32(record: Record, field: u32, index: u32, out: ?*f32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const list = listIn(r, field) catch |err| return readRefusal(err);
            if (index >= list.len) return .invalid_argument;

            const value = list.floatAt(index) catch |err| return readFailure(err);
            dst.* = @floatCast(value orelse return .not_found);
            return .ok;
        }

        /// The one list reader that needs an allocator, because `data` has no allocator-free
        /// form for a string element — and it borrows the frame arena, which is the same
        /// lifetime every other borrow here has.
        pub fn recordListGetString(record: Record, field: u32, index: u32, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const r = resolve(record) catch |err| return refusal(err);
            const list = listIn(r, field) catch |err| return readRefusal(err);
            if (index >= list.len) return .invalid_argument;
            if (list.elem != .string) return .invalid_argument;

            const value = list.valueAt(engine.frameAllocator(), index) catch |err| return switch (err) {
                error.OutOfMemory => .out_of_memory,
                else => readFailure(@errorCast(err)),
            };
            const found = value orelse return .not_found;
            if (found != .string) return .internal;
            dst.* = .from(found.string);
            return .ok;
        }

        pub fn recordListGetId(record: Record, field: u32, index: u32, out: ?*ContentId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const r = resolve(record) catch |err| return refusal(err);
            const list = listIn(r, field) catch |err| return readRefusal(err);
            if (index >= list.len) return .invalid_argument;

            const value = list.idAt(index) catch |err| return readFailure(err);
            dst.* = value orelse return .not_found;
            return .ok;
        }

        pub fn recordListNested(record: Record, field: u32, index: u32, out: ?*Record) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            const r = resolve(record) catch |err| return refusal(err);
            const list = listIn(r, field) catch |err| return readRefusal(err);
            if (index >= list.len) return .invalid_argument;
            if (list.elem != .nested) return .invalid_argument;

            const fields = list.nestedAt(index) catch |err| return readFailure(err);
            dst.* = h.openNested(
                engine.contentGeneration(),
                fields orelse return .not_found,
                .{ .id = .none, .version = r.schema.version, .fields = list.elem.nested },
            );
            return .ok;
        }

        // -- Packages ------------------------------------------------------------------

        pub fn packageCount(out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            dst.* = engine.store.packageCount();
            return .ok;
        }

        /// Every loaded package, **in load order** — the order overrides were applied in, and
        /// therefore the only order worth walking them in.
        pub fn packageNext(cursor: ?*Cursor, out: ?*Package) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            const order = engine.store.loadOrder();
            const generation = walkGeneration(engine.contentGeneration(), @intCast(order.len));
            if (!c.isBegin() and c.generation() != generation) return .invalid_argument;
            if (c.index() >= order.len) return .end;

            dst.* = .wrap(order[c.index()]);
            c.* = .at(generation, c.index() + 1);
            return .ok;
        }

        pub fn packageFind(id: ContentId, out: ?*Package) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;

            const handle = engine.store.findPackage(id) orelse return .not_found;
            dst.* = .wrap(handle);
            return .ok;
        }

        pub fn packageId(package: Package, out: ?*ContentId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const loaded = loadedPackage(package) catch |err| return refusal(err);
            dst.* = loaded.id;
            return .ok;
        }

        pub fn packageName(package: Package, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const loaded = loadedPackage(package) catch |err| return refusal(err);
            dst.* = .from(loaded.name);
            return .ok;
        }

        pub fn packageVersion(package: Package, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const loaded = loadedPackage(package) catch |err| return refusal(err);
            dst.* = loaded.version;
            return .ok;
        }

        pub fn packageOrder(package: Package, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const loaded = loadedPackage(package) catch |err| return refusal(err);
            dst.* = loaded.order;
            return .ok;
        }

        // -- Schemas -------------------------------------------------------------------

        pub fn schemaCount(out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            dst.* = engine.schemas.count();
            return .ok;
        }

        pub fn schemaNext(cursor: ?*Cursor, out: ?*Schema) callconv(.c) Result {
            const c = cursor orelse return .invalid_argument;
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;

            const generation = walkGeneration(engine.contentGeneration(), engine.schemas.count());
            if (!c.isBegin() and c.generation() != generation) return .invalid_argument;

            var it: data.schema.Registry.Iterator = .{ .registry = &engine.schemas, .slot = c.index() };
            const entry = it.next() orelse return .end;
            dst.* = .wrap(entry.handle);
            c.* = .at(generation, it.slot);
            return .ok;
        }

        pub fn schemaFind(id: SchemaId, out: ?*Schema) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const h = H.current() orelse return .unavailable;
            const engine = h.engine orelse return .unavailable;
            if (id.isNone()) return .invalid_argument;

            const handle = engine.schemas.find(id) orelse return .not_found;
            dst.* = .wrap(handle);
            return .ok;
        }

        pub fn schemaId(schema: Schema, out: ?*SchemaId) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const declared = registered(schema) catch |err| return refusal(err);
            dst.* = declared.id;
            return .ok;
        }

        pub fn schemaVersion(schema: Schema, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const declared = registered(schema) catch |err| return refusal(err);
            dst.* = declared.version;
            return .ok;
        }

        pub fn schemaFieldCount(schema: Schema, out: ?*u32) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const declared = registered(schema) catch |err| return refusal(err);
            dst.* = @intCast(declared.fields.len);
            return .ok;
        }

        pub fn schemaFieldName(schema: Schema, field: u32, out: ?*Str) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const declared = registered(schema) catch |err| return refusal(err);
            if (field >= declared.fields.len) return .invalid_argument;
            dst.* = .from(declared.fields[field].name);
            return .ok;
        }

        pub fn schemaFieldType(schema: Schema, field: u32, out: ?*FieldType) callconv(.c) Result {
            const dst = out orelse return .invalid_argument;
            const declared = registered(schema) catch |err| return refusal(err);
            if (field >= declared.fields.len) return .invalid_argument;
            dst.* = .fromData(declared.fields[field].type);
            return .ok;
        }

        // -- internals -----------------------------------------------------------------

        /// A record, whether it is one of the store's or a view into a nested block.
        const Resolved = struct {
            fields: data.fpk.Fields,
            /// The schema **as the supplying package carries it**, which is what `fields` is
            /// laid out against. Its version may be older than the registry's.
            schema: data.Schema,
            /// The newest registered version, which may declare fields this record predates.
            newest: data.Schema,
            /// Null for a nested block, which has no identity of its own.
            record: ?data.store.Record,
        };

        /// `null` means "no host or no engine"; `error.Stale` means the handle did not
        /// resolve. Two different answers, and telling them apart is what stops a mod author
        /// hunting a stale handle on a host that simply has no content system.
        const Refusal = error{Stale};

        fn resolve(handle: Record) Refusal!Resolved {
            const h = H.current() orelse return error.Stale;
            const engine = h.engine orelse return error.Stale;

            if (H.namesNested(handle)) {
                const view = h.nestedView(handle, engine.contentGeneration()) orelse return error.Stale;
                return .{
                    .fields = view.fields,
                    .schema = view.schema,
                    .newest = view.schema,
                    .record = null,
                };
            }

            const record = engine.store.get(handle.unwrap(data.store.RecordHandle)) orelse return error.Stale;
            const newest = engine.schemas.lookup(record.schema_id);
            return .{
                .fields = record.fields,
                .schema = record.schema,
                .newest = if (newest) |s| s.* else record.schema,
                .record = record,
            };
        }

        /// The result a `resolve` failure becomes.
        ///
        /// `unavailable` when there is no content system at all, `invalid_handle` when there
        /// is one and the handle is not its.
        fn refusal(err: Refusal) Result {
            switch (err) {
                error.Stale => {},
            }
            const h = H.current() orelse return .unavailable;
            _ = h.engine orelse return .unavailable;
            return .invalid_handle;
        }

        const FieldPlace = struct {
            /// Whether the record's own package laid this field out, as opposed to it being
            /// a field a newer schema version added.
            own: bool,
        };

        fn inRange(r: Resolved, field: u32) ?FieldPlace {
            if (field >= r.newest.fields.len) return null;
            return .{ .own = field < r.schema.fields.len };
        }

        /// The default a newer schema declares for a field this record's package predates.
        fn defaultOf(r: Resolved, field: u32) ?data.Value {
            const record = r.record orelse return null;
            return record.missingDefault(r.newest, field);
        }

        fn stringIn(r: Resolved, field: u32) ReadRefusal![]const u8 {
            const at = inRange(r, field) orelse return error.NoSuchField;
            if (at.own) {
                const value = try r.fields.stringAt(field);
                return value orelse error.Absent;
            }
            const value = defaultOf(r, field) orelse return error.Absent;
            if (value != .string) return error.WrongType;
            return value.string;
        }

        fn listIn(r: Resolved, field: u32) ReadRefusal!data.fpk.List {
            const at = inRange(r, field) orelse return error.NoSuchField;
            // A list has no default form: `data` has no way to write one into a schema, so a
            // field a record predates is simply absent rather than empty.
            if (!at.own) return error.Absent;
            const value = try r.fields.listAt(field);
            return value orelse error.Absent;
        }

        /// Why a field could not be read, kept apart from the result codes so that the
        /// mapping lives in one place.
        const ReadRefusal = error{
            /// The schema has no field at that index. A mistake in the mod.
            NoSuchField,
            /// The record carries no value for it. A fact about the content.
            Absent,
        } || data.fpk.ReadError;

        fn readRefusal(err: ReadRefusal) Result {
            return switch (err) {
                error.NoSuchField, error.WrongType => .invalid_argument,
                error.Absent => .not_found,
                error.Malformed => .internal,
            };
        }

        fn loadedPackage(package: Package) Refusal!*const data.store.LoadedPackage {
            const h = H.current() orelse return error.Stale;
            const engine = h.engine orelse return error.Stale;
            return engine.store.package(package.unwrap(data.store.PackageHandle)) orelse error.Stale;
        }

        fn registered(schema: Schema) Refusal!data.Schema {
            const h = H.current() orelse return error.Stale;
            const engine = h.engine orelse return error.Stale;
            const found = engine.schemas.get(schema.unwrap(data.SchemaHandle)) orelse return error.Stale;
            return found.*;
        }
    };
}

/// The generation a walk carries.
///
/// The content generation and the container's size, folded into the thirty-two bits a cursor
/// has for one. That detects a reload and a container that grew or shrank, which is every
/// mutation a walk can actually survive into. Two changes that cancel exactly are not
/// distinguishable in thirty-two bits, and saying so is better than implying otherwise.
fn walkGeneration(content_generation: u64, count: u32) u32 {
    const folded = @as(u32, @truncate(content_generation)) ^ (count *% 0x9e37_79b9);
    // Zero is `begin`, so it is the one value a live walk may not have.
    return if (folded == 0) std.math.maxInt(u32) else folded;
}

/// A read that failed because the file disagrees with itself, or because the caller asked
/// for a kind the field is not. The two are worth telling apart: one is a broken package and
/// the other is a mistake in the mod.
fn readFailure(err: data.fpk.ReadError) Result {
    return switch (err) {
        error.WrongType => .invalid_argument,
        error.Malformed => .internal,
    };
}

comptime {
    _ = core;
    _ = host_mod;
}

// == Tests =============================================================================

const testing = std.testing;
const api = @import("api.zig");
const test_engine = @import("test_engine.zig");

const TestEngine = test_engine.TestEngine;
const Host = host_mod.HostOf(TestEngine);
const table = api.TableOf(Host).v1;

/// One package with a field of every kind the boundary can read, which is what makes the
/// readers testable without a second file per shape.
const source =
    \\@schema thing {
    \\    label   string
    \\    count   i32
    \\    weight  f32
    \\    solid   bool
    \\    linked  id
    \\    note    string (optional)
    \\    tags    [string]
    \\    numbers [i32]
    \\    place   { x f32  y f32 }
    \\    parts   [{ name string }]
    \\}
    \\@schema other { n i32 }
    \\
    \\thing mymod:sample {
    \\    label   "a lantern"
    \\    count   3
    \\    weight  0.75
    \\    solid   true
    \\    linked  mymod:elsewhere
    \\    tags    ["warm" "portable"]
    \\    numbers [1 2 3]
    \\    place   { x 1.5  y -2.5 }
    \\    parts   [{ name "wick" } { name "glass" }]
    \\}
    \\other mymod:another { n 7 }
;

const Fixture = struct {
    engine: TestEngine,
    host: Host,
    package: data.store.PackageHandle = .none,

    fn init() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        self.* = .{ .engine = try .init(testing.allocator), .host = .{} };
        self.engine.settle();
        self.host.engine = &self.engine;
        self.host.bind();
        self.package = try self.engine.loadPackage("mymod:content", source);
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.host.unbind();
        self.engine.deinit();
        testing.allocator.destroy(self);
    }

    fn sample(_: *Fixture) !Record {
        var record: Record = .none;
        try testing.expectEqual(Result.ok, table.content_find(
            core.ContentId.fromString("mymod:sample"),
            &record,
        ));
        return record;
    }

    fn field(self: *Fixture, name: []const u8) !u32 {
        var index: u32 = 0;
        try testing.expectEqual(Result.ok, table.record_field_index(try self.sample(), .from(name), &index));
        return index;
    }
};

test "a record says who it is, and a content id nobody declares is not found" {
    const f = try Fixture.init();
    defer f.deinit();

    const record = try f.sample();
    var id: ContentId = .none;
    var name: Str = .empty;
    var schema: SchemaId = .none;
    var package: Package = .none;

    try testing.expectEqual(Result.ok, table.record_id(record, &id));
    try testing.expectEqual(core.ContentId.fromString("mymod:sample"), id);
    try testing.expectEqual(Result.ok, table.record_name(record, &name));
    try testing.expectEqualStrings("mymod:sample", name.bytes().?);
    try testing.expectEqual(Result.ok, table.record_schema(record, &schema));
    try testing.expectEqual(data.SchemaId.fromStringUnchecked("mymod:thing"), schema);
    try testing.expectEqual(Result.ok, table.record_package(record, &package));

    var absent: Record = .none;
    try testing.expectEqual(Result.not_found, table.content_find(core.ContentId.fromString("mymod:nothing"), &absent));
    try testing.expectEqual(Result.invalid_argument, table.content_find(.none, &absent));
    try testing.expect(absent.isNone());
}

test "a record describes its own fields, so a mod can read a type it has never heard of" {
    const f = try Fixture.init();
    defer f.deinit();
    const record = try f.sample();

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_field_count(record, &count));
    try testing.expectEqual(@as(u32, 10), count);

    var name: Str = .empty;
    var kind: FieldType = .bool;
    try testing.expectEqual(Result.ok, table.record_field_name(record, 0, &name));
    try testing.expectEqualStrings("label", name.bytes().?);
    try testing.expectEqual(Result.ok, table.record_field_type(record, 0, &kind));
    try testing.expectEqual(FieldType.string, kind);

    try testing.expectEqual(Result.ok, table.record_field_type(record, try f.field("place"), &kind));
    try testing.expectEqual(FieldType.nested, kind);
    try testing.expectEqual(Result.ok, table.record_field_type(record, try f.field("tags"), &kind));
    try testing.expectEqual(FieldType.list, kind);

    // Past the end of the schema is a mistake in the mod, not a fact about the content.
    try testing.expectEqual(Result.invalid_argument, table.record_field_name(record, count, &name));
    try testing.expectEqual(Result.invalid_argument, table.record_field_type(record, 9999, &kind));

    var index: u32 = 0;
    try testing.expectEqual(Result.not_found, table.record_field_index(record, .from("nosuchfield"), &index));
}

test "every reader reads its own kind and refuses the others" {
    const f = try Fixture.init();
    defer f.deinit();
    const record = try f.sample();

    var text: Str = .empty;
    try testing.expectEqual(Result.ok, table.record_get_string(record, try f.field("label"), &text));
    try testing.expectEqualStrings("a lantern", text.bytes().?);

    var whole: i64 = 0;
    try testing.expectEqual(Result.ok, table.record_get_i64(record, try f.field("count"), &whole));
    try testing.expectEqual(@as(i64, 3), whole);

    var unsigned: u64 = 0;
    try testing.expectEqual(Result.ok, table.record_get_u64(record, try f.field("count"), &unsigned));
    try testing.expectEqual(@as(u64, 3), unsigned);

    var real: f32 = 0;
    try testing.expectEqual(Result.ok, table.record_get_f32(record, try f.field("weight"), &real));
    try testing.expectEqual(@as(f32, 0.75), real);

    var flag: Bool = 0;
    try testing.expectEqual(Result.ok, table.record_get_bool(record, try f.field("solid"), &flag));
    try testing.expect(types.boolIn(flag));

    var linked: ContentId = .none;
    try testing.expectEqual(Result.ok, table.record_get_id(record, try f.field("linked"), &linked));
    try testing.expectEqual(core.ContentId.fromString("mymod:elsewhere"), linked);

    // The wrong reader for the field is a mistake in the mod, and says so.
    try testing.expectEqual(Result.invalid_argument, table.record_get_i64(record, try f.field("label"), &whole));
    try testing.expectEqual(Result.invalid_argument, table.record_get_bool(record, try f.field("count"), &flag));
    try testing.expectEqual(Result.invalid_argument, table.record_get_string(record, try f.field("weight"), &text));
}

test "a field the record does not carry is not found, which is not the same as not existing" {
    const f = try Fixture.init();
    defer f.deinit();
    const record = try f.sample();

    const note = try f.field("note");
    var present: Bool = 1;
    try testing.expectEqual(Result.ok, table.record_field_present(record, note, &present));
    try testing.expect(!types.boolIn(present));

    var text: Str = .from("untouched");
    try testing.expectEqual(Result.not_found, table.record_get_string(record, note, &text));
    // The out-parameter is written only on success, so a caller may initialise once.
    try testing.expectEqualStrings("untouched", text.bytes().?);

    var carried: Bool = 0;
    try testing.expectEqual(Result.ok, table.record_field_present(record, try f.field("label"), &carried));
    try testing.expect(types.boolIn(carried));
}

test "a copied string reports the length it needed rather than truncating" {
    const f = try Fixture.init();
    defer f.deinit();
    const record = try f.sample();
    const label = try f.field("label");

    var buffer: [32]u8 = undefined;
    var needed: u64 = 0;
    try testing.expectEqual(Result.ok, table.record_copy_string(record, label, &buffer, buffer.len, &needed));
    try testing.expectEqual(@as(u64, "a lantern".len), needed);
    try testing.expectEqualStrings("a lantern", buffer[0..needed]);

    needed = 0;
    try testing.expectEqual(Result.limit, table.record_copy_string(record, label, null, 0, &needed));
    try testing.expectEqual(@as(u64, "a lantern".len), needed);
}

test "an inline struct answers the same field calls one level down" {
    const f = try Fixture.init();
    defer f.deinit();
    const record = try f.sample();

    var place: Record = .none;
    try testing.expectEqual(Result.ok, table.record_nested(record, try f.field("place"), &place));

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_field_count(place, &count));
    try testing.expectEqual(@as(u32, 2), count);

    var x: f32 = 0;
    var y: f32 = 0;
    var index: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_field_index(place, .from("x"), &index));
    try testing.expectEqual(Result.ok, table.record_get_f32(place, index, &x));
    try testing.expectEqual(Result.ok, table.record_field_index(place, .from("y"), &index));
    try testing.expectEqual(Result.ok, table.record_get_f32(place, index, &y));
    try testing.expectEqual(@as(f32, 1.5), x);
    try testing.expectEqual(@as(f32, -2.5), y);

    // A nested block has no identity of its own — that is what nested means.
    var id: ContentId = .none;
    try testing.expectEqual(Result.not_found, table.record_id(place, &id));
    var name: Str = .empty;
    try testing.expectEqual(Result.not_found, table.record_name(place, &name));

    // And a field that is not one is refused rather than reinterpreted.
    try testing.expectEqual(Result.invalid_argument, table.record_nested(record, try f.field("label"), &place));
}

test "a list is read one element at a time, and past the end is refused" {
    const f = try Fixture.init();
    defer f.deinit();
    const record = try f.sample();

    const tags = try f.field("tags");
    var len: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_list_len(record, tags, &len));
    try testing.expectEqual(@as(u32, 2), len);

    var text: Str = .empty;
    try testing.expectEqual(Result.ok, table.record_list_get_string(record, tags, 0, &text));
    try testing.expectEqualStrings("warm", text.bytes().?);
    try testing.expectEqual(Result.ok, table.record_list_get_string(record, tags, 1, &text));
    try testing.expectEqualStrings("portable", text.bytes().?);
    try testing.expectEqual(Result.invalid_argument, table.record_list_get_string(record, tags, 2, &text));

    const numbers = try f.field("numbers");
    var value: i64 = 0;
    try testing.expectEqual(Result.ok, table.record_list_len(record, numbers, &len));
    try testing.expectEqual(@as(u32, 3), len);
    try testing.expectEqual(Result.ok, table.record_list_get_i64(record, numbers, 2, &value));
    try testing.expectEqual(@as(i64, 3), value);

    // A list of inline structs, which is the shape a schema author reaches for most.
    const parts = try f.field("parts");
    var part: Record = .none;
    try testing.expectEqual(Result.ok, table.record_list_nested(record, parts, 1, &part));
    var index: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_field_index(part, .from("name"), &index));
    try testing.expectEqual(Result.ok, table.record_get_string(part, index, &text));
    try testing.expectEqualStrings("glass", text.bytes().?);

    // And a field that is not a list at all.
    try testing.expectEqual(Result.invalid_argument, table.record_list_len(record, try f.field("label"), &len));
}

test "a nested view goes stale rather than pointing at freed memory" {
    const f = try Fixture.init();
    defer f.deinit();
    const record = try f.sample();

    var place: Record = .none;
    try testing.expectEqual(Result.ok, table.record_nested(record, try f.field("place"), &place));

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_field_count(place, &count));

    // A reload rebuilds the store and the package bytes underneath, so a view that survived
    // one is pointing at memory that has been freed. It is detected, not dereferenced.
    f.engine.reloadContent();
    try testing.expectEqual(Result.invalid_handle, table.record_field_count(place, &count));

    // So is a view whose slot has been recycled by enough further opens.
    var again: Record = .none;
    try testing.expectEqual(Result.ok, table.record_nested(record, try f.field("place"), &again));
    for (0..host_mod.max_nested_views) |_| {
        var scratch: Record = .none;
        try testing.expectEqual(Result.ok, table.record_nested(record, try f.field("place"), &scratch));
    }
    try testing.expectEqual(Result.invalid_handle, table.record_field_count(again, &count));
}

test "a record handle nobody issued resolves to nothing" {
    const f = try Fixture.init();
    defer f.deinit();

    var count: u32 = 0;
    try testing.expectEqual(Result.invalid_handle, table.record_field_count(.none, &count));
    try testing.expectEqual(Result.invalid_handle, table.record_field_count(.{ .bits = 1 }, &count));
    try testing.expectEqual(
        Result.invalid_handle,
        table.record_field_count(.{ .bits = std.math.maxInt(u64) }, &count),
    );
}

test "content walks every record, and one schema's records on their own" {
    const f = try Fixture.init();
    defer f.deinit();

    var cursor: Cursor = .begin;
    var record: Record = .none;
    var seen: u32 = 0;
    while (table.content_next(&cursor, &record) == .ok) seen += 1;
    try testing.expectEqual(@as(u32, 2), seen);
    try testing.expectEqual(Result.end, table.content_next(&cursor, &record));

    cursor = .begin;
    var of_schema: u32 = 0;
    var name: Str = .empty;
    while (table.content_next_of_schema(
        data.SchemaId.fromStringUnchecked("mymod:other"),
        &cursor,
        &record,
    ) == .ok) {
        of_schema += 1;
        try testing.expectEqual(Result.ok, table.record_name(record, &name));
        try testing.expectEqualStrings("mymod:another", name.bytes().?);
    }
    try testing.expectEqual(@as(u32, 1), of_schema);
}

test "a walk over content that changed underneath it is refused, not resynchronised" {
    const f = try Fixture.init();
    defer f.deinit();

    var cursor: Cursor = .begin;
    var record: Record = .none;
    try testing.expectEqual(Result.ok, table.content_next(&cursor, &record));

    f.engine.reloadContent();
    try testing.expectEqual(Result.invalid_argument, table.content_next(&cursor, &record));

    // An invented cursor is refused the same way, which is what makes the check worth having
    // against a caller who may have made one up.
    var invented: Cursor = .at(12345, 0);
    try testing.expectEqual(Result.invalid_argument, table.content_next(&invented, &record));
}

test "packages walk in load order and say what they are" {
    const f = try Fixture.init();
    defer f.deinit();

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, table.package_count(&count));
    try testing.expectEqual(@as(u32, 1), count);

    var cursor: Cursor = .begin;
    var package: Package = .none;
    try testing.expectEqual(Result.ok, table.package_next(&cursor, &package));
    try testing.expectEqual(Result.end, table.package_next(&cursor, &package));

    var id: ContentId = .none;
    var name: Str = .empty;
    var version: u32 = 0;
    var order: u32 = 99;
    try testing.expectEqual(Result.ok, table.package_id(package, &id));
    try testing.expectEqual(core.ContentId.fromString("mymod:content"), id);
    try testing.expectEqual(Result.ok, table.package_name(package, &name));
    try testing.expectEqualStrings("mymod:content", name.bytes().?);
    try testing.expectEqual(Result.ok, table.package_version(package, &version));
    try testing.expectEqual(@as(u32, 1), version);
    try testing.expectEqual(Result.ok, table.package_order(package, &order));
    try testing.expectEqual(@as(u32, 0), order);

    var found: Package = .none;
    try testing.expectEqual(Result.ok, table.package_find(core.ContentId.fromString("mymod:content"), &found));
    try testing.expectEqual(package.bits, found.bits);
    try testing.expectEqual(Result.not_found, table.package_find(core.ContentId.fromString("mymod:absent"), &found));
    try testing.expectEqual(Result.invalid_handle, table.package_name(.{ .bits = 999 }, &name));
}

test "schemas are readable, so a mod can discover a record type it did not declare" {
    const f = try Fixture.init();
    defer f.deinit();

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, table.schema_count(&count));
    try testing.expect(count >= 2);

    var schema: Schema = .none;
    try testing.expectEqual(Result.ok, table.schema_find(
        data.SchemaId.fromStringUnchecked("mymod:thing"),
        &schema,
    ));

    var id: SchemaId = .none;
    var version: u32 = 0;
    var fields: u32 = 0;
    var name: Str = .empty;
    var kind: FieldType = .bool;
    try testing.expectEqual(Result.ok, table.schema_id(schema, &id));
    try testing.expectEqual(data.SchemaId.fromStringUnchecked("mymod:thing"), id);
    try testing.expectEqual(Result.ok, table.schema_version(schema, &version));
    try testing.expectEqual(@as(u32, 1), version);
    try testing.expectEqual(Result.ok, table.schema_field_count(schema, &fields));
    try testing.expectEqual(@as(u32, 10), fields);
    try testing.expectEqual(Result.ok, table.schema_field_name(schema, 1, &name));
    try testing.expectEqualStrings("count", name.bytes().?);
    try testing.expectEqual(Result.ok, table.schema_field_type(schema, 1, &kind));
    try testing.expectEqual(FieldType.i32, kind);
    try testing.expectEqual(Result.invalid_argument, table.schema_field_name(schema, fields, &name));

    // Every registered schema is reachable by walking, in a documented order.
    var cursor: Cursor = .begin;
    var walked: u32 = 0;
    while (table.schema_next(&cursor, &schema) == .ok) walked += 1;
    try testing.expectEqual(count, walked);

    try testing.expectEqual(Result.not_found, table.schema_find(
        data.SchemaId.fromStringUnchecked("mymod:nothing"),
        &schema,
    ));
    try testing.expectEqual(Result.invalid_handle, table.schema_version(.{ .bits = 777 }, &version));
}

test "a record written against an older schema answers newer fields with their defaults" {
    const f = try Fixture.init();
    defer f.deinit();

    // A second package that declares version 2 of a schema the first package wrote against
    // at version 1. This is exactly the case a growing schema has to survive, and a boundary
    // that skipped the fill would give a mod `not_found` where the game sees a value.
    _ = try f.engine.loadPackage("later:content",
        \\@schema mymod:other { n i32  hue string (since 2) (default "amber") }
        \\mymod:other later:thing { n 1  hue "blue" }
    );

    var record: Record = .none;
    try testing.expectEqual(Result.ok, table.content_find(core.ContentId.fromString("mymod:another"), &record));

    var count: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_field_count(record, &count));
    try testing.expectEqual(@as(u32, 2), count);

    var index: u32 = 0;
    try testing.expectEqual(Result.ok, table.record_field_index(record, .from("hue"), &index));

    // Not carried by the record — and read anyway, as the default its schema declares.
    var present: Bool = 1;
    try testing.expectEqual(Result.ok, table.record_field_present(record, index, &present));
    try testing.expect(!types.boolIn(present));

    var text: Str = .empty;
    try testing.expectEqual(Result.ok, table.record_get_string(record, index, &text));
    try testing.expectEqualStrings("amber", text.bytes().?);
}

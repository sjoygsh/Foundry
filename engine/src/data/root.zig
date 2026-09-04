//! Foundry `data` — layer L1. Schemas, content, packages.
//!
//! Depends on **`core` alone**, and that single line of the layering table (ADR-0007) is
//! the most structurally important fact about this module.
//!
//! **`data` cannot open a file.** The filesystem lives in `platform`, which is L1 beside
//! it, not below it. Everything here operates on byte slices somebody else obtained: the
//! text parser is handed source, the package reader is handed a package's bytes, and
//! `@import` resolves through a caller-supplied callback. `asset` (L2, which has both) is
//! where files become bytes.
//!
//! That was not designed for; it fell out of the layering and turned out to be exactly
//! right. A content pipeline that cannot touch the disk is a pure function — hermetically
//! testable, trivially deterministic (I9), and safe to run on untrusted input without
//! wondering what it might read.
//!
//! Everything this module parses is input from mods, which means **untrusted input**:
//! validated and refused, never asserted (CLAUDE.md §5).
//!
//! Design: `docs/design/content-schemas.md`

pub const check = @import("check.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const fpk = @import("fpk.zig");
pub const id = @import("id.zig");
pub const lexer = @import("lexer.zig");
pub const parser = @import("parser.zig");
pub const limits = @import("limits.zig");
pub const schema = @import("schema.zig");
pub const store = @import("store.zig");
pub const value = @import("value.zig");

// The names reached for most often. These are seen by people we do not control — mod
// authors from M3, compiled mods from M7 — so renaming one is a compatibility decision
// rather than a tidy-up (CLAUDE.md §7).
pub const Diagnostic = diagnostic.Diagnostic;
pub const Diagnostics = diagnostic.Diagnostics;
pub const Document = parser.Document;
pub const Field = schema.Field;
pub const FieldType = schema.FieldType;
pub const Limits = limits.Limits;
pub const NamedValue = value.NamedValue;
pub const Package = check.Package;
pub const Presence = schema.Presence;
pub const Record = check.Record;
pub const Registry = schema.Registry;
pub const Schema = schema.Schema;
pub const SchemaHandle = schema.SchemaHandle;
pub const SchemaId = id.SchemaId;
pub const Store = store.Store;
pub const Value = value.Value;

/// Validates a `namespace:name` string and hashes it to a `core.ContentId`.
pub const contentId = id.contentId;

test {
    _ = check;
    _ = diagnostic;
    _ = fpk;
    _ = id;
    _ = lexer;
    _ = parser;
    _ = limits;
    _ = schema;
    _ = store;
    _ = value;
}

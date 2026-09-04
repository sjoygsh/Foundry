//! Hard bounds on anything that comes out of a file.
//!
//! Every `.fdt` and `.fpk` byte is input from a mod, so CLAUDE.md §5 applies without
//! exception: **validated and refused, never asserted.** These are the numbers that make
//! "refused" possible — a bound is what turns a hostile or merely broken file into an
//! error message instead of an allocation the size of the disk.
//!
//! Shaped after `asset`'s PNG decoder limits, which exist for the same reason and have
//! the same escape hatch: a caller who genuinely needs more passes a different struct.
//!
//! See `docs/design/content-schemas.md` §4.6.

/// Defaults chosen so that no plausible piece of hand-written content hits one, and no
/// implausible one gets far.
pub const Limits = struct {
    /// Content text is not a data dump; binary payloads are assets (ADR-0006).
    max_source_bytes: usize = 16 * 1024 * 1024,

    /// Bounds recursion in the parser, in schema validation and in value cloning. A
    /// struct nested 32 deep is a mistake, not a requirement.
    max_nesting_depth: u32 = 32,

    /// With cycle detection this only catches pathological import trees, but the
    /// recursion still has to terminate on a file that imports itself indirectly through
    /// forty others.
    max_import_depth: u32 = 16,

    /// Matches `id.max_bytes`, so an identifier that fits the grammar fits here too.
    max_identifier_bytes: usize = 255,

    max_fields_per_schema: u32 = 4096,
    max_fields_per_record: u32 = 4096,
    max_list_elements: usize = 1 << 20,

    /// Enough to fix an afternoon's worth of mistakes in one build; not enough for a
    /// binary file fed to the parser by accident to produce a hundred thousand lines.
    max_diagnostics: u32 = 64,

    pub const default: Limits = .{};
};

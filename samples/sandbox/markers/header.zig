//! The shared markers' entire view of Foundry.
//!
//! This module translates the installed public header and nothing else. The markers module
//! that imports it is deliberately granted no engine module at all (`networking.md` §9), so
//! the include path is an explicit build capability rather than a source-relative escape
//! hatch — the same seam as the editor's client.

pub const c = @cImport({
    @cInclude("foundry.h");
});

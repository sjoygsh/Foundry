//! The editor client's entire view of Foundry.
//!
//! This module translates the installed public header and nothing else.  The client module
//! that imports it is deliberately not granted `abi`, `author`, `app`, `data`, a filesystem,
//! or a renderer (`docs/design/editor.md` §3).  Keeping the translation in its own module
//! also makes the include path an explicit build capability rather than a source-relative
//! escape hatch.

pub const c = @cImport({
    @cInclude("foundry.h");
});

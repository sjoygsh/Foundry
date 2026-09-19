//! Foundry `author` — layer L4, beside `app`. Depends on `core`, `data`, `platform`,
//! `asset`, `mod` and `scene`.
//!
//! **Authoring a package: reading it as text, and compiling it.** One package compiler, one
//! workspace, and nothing else. It is the module the editor is built on and the module
//! `fpack` is a shell around, because a tool and an editor that each had their own compiler
//! would be two compilers that must agree ([ADR-0042](../../../docs/adr/0042-authoring-through-the-public-api.md)).
//!
//! **Above `data` and below the host, and it knows neither the ABI nor a window.** No
//! `abi`, no `app`, no `ui`, no renderer: the editor host constructs subsystems and hands
//! this one a granted directory and a list of granted dependency files, and what it gives
//! back is documents, diagnostics and bytes. A workspace therefore unit-tests with no
//! device, no window and no frame.
//!
//! **A grant is a capability, not a search** (`docs/design/editor.md` §4). Nothing here
//! looks for a package, a source or an asset root: what a host names is what this can see,
//! and a dependency nobody granted is unknown rather than found. Every read keeps
//! `platform`'s confined/no-follow rule, including intermediate links, so a package cannot
//! point an editor at a file outside the directory it was given.
//!
//! `editor.md` §3 is the layering; §4 the workspace and its limits; §5 the documents.

pub const compiler = @import("compiler.zig");
pub const dependency = @import("dependency.zig");
pub const workspace = @import("workspace.zig");

// The names reached for most often. A mod author never sees these — a host does, and a host
// is a consumer we do not control either (CLAUDE.md §7).
pub const Identity = compiler.Identity;
pub const SourceRequirement = compiler.SourceRequirement;
pub const compile = compiler.compile;
pub const DependencySet = dependency.Set;
pub const DependencySource = dependency.Source;
pub const Document = workspace.Document;
pub const Workspace = workspace.Workspace;
pub const WorkspaceLimits = workspace.Limits;
pub const WorkspaceOptions = workspace.Options;

test {
    _ = compiler;
    _ = dependency;
    _ = workspace;
}

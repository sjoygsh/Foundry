//! Foundry `abi` — layer L5, a peer of `debug` rather than a layer over `app`.
//!
//! **The one public API surface** (Invariant I4). Native mods today, the scripting host at
//! M8, external tools and the editor after that all arrive through here, and engine code
//! never does — including the editor, which gets no private path
//! ([ADR-0004](../../../docs/adr/0004-public-c-abi.md)).
//!
//! It sits beside `debug` and not above `app` because two facts forbid the alternative
//! ([ADR-0026](../../../docs/adr/0026-abi-module-and-host.md)): `app` cannot see `scene`,
//! `audio` or `physics2d`, and it *owns* no world, renderer, mixer or collision world,
//! because the game does. So the host hands this module the subsystems it has, exactly as it
//! hands `debug.Sources` its own, and a capability whose subsystem is absent answers
//! `unavailable` rather than being a null function pointer.
//!
//! **It may only translate.** Validate, call one subsystem, return a code. A module that can
//! see the whole engine will otherwise accumulate the whole engine, and this one holds no
//! state to accumulate it in.
//!
//! Everything arriving from the other side is untrusted, and untrusted means *validated* —
//! not asserted, not assumed, not documented as a precondition. The boundary never panics
//! and never propagates a Zig error.
//!
//! **What is built:** `Host`, `get_api`, the complete 135-call `FoundryApi_v1`, and
//! `native_loader`'s process-lifetime image and lifecycle work (`public-abi.md` §19).
//!
//! Design: `docs/design/public-abi.md`. The header is `foundry.h`, beside this file, and it
//! is the specification rather than a description of what is here.

pub const api = @import("api.zig");
pub const host = @import("host.zig");
pub const types = @import("types.zig");

const agreement = @import("agreement.zig");
const calls_asset = @import("calls_asset.zig");
const calls_author = @import("calls_author.zig");
const calls_audio = @import("calls_audio.zig");
const calls_content = @import("calls_content.zig");
const calls_engine = @import("calls_engine.zig");
const calls_mods = @import("calls_mods.zig");
const calls_physics = @import("calls_physics.zig");
const calls_render = @import("calls_render.zig");
const calls_scene = @import("calls_scene.zig");
const calls_ui = @import("calls_ui.zig");
const author_types = @import("author_types.zig");
const mod_types = @import("mod_types.zig");
const net_types = @import("net_types.zig");
const native_loader = @import("native_loader.zig");
const physics_types = @import("physics_types.zig");
const render_types = @import("render_types.zig");
const ui_types = @import("ui_types.zig");

// The vocabulary of the boundary. Named here because a host writing a `get_api` and a loader
// reading a mod's symbols both need them, and neither should be reaching into a file.
pub const Bool = types.Bool;
pub const ContentId = types.ContentId;
pub const Cursor = types.Cursor;
pub const Result = types.Result;
pub const Str = types.Str;

pub const boolIn = types.boolIn;
pub const boolOut = types.boolOut;

/// The opaque handles, one type per kind (`public-abi.md` §5).
pub const Asset = types.Asset;
pub const Body = types.Body;
pub const Grid = types.Grid;
pub const ComponentType = types.ComponentType;
pub const Entity = types.Entity;
pub const Mod = types.Mod;
pub const Package = types.Package;
pub const Record = types.Record;
pub const Schema = types.Schema;
pub const Texture = types.Texture;
pub const View = types.View;
pub const Voice = types.Voice;
pub const Theme = types.Theme;

/// `author` — the v4 authoring handles (ADR-0042).
pub const Workspace = types.Workspace;
pub const Document = types.Document;
pub const SourceNode = types.SourceNode;
pub const SchemaNode = types.SchemaNode;
pub const Build = types.Build;

/// The values those handles are described by.  A Zig host writing an editor needs these
/// exactly as a C one needs the structs in `foundry.h`; without them it would have to
/// reach into `abi/author_types.zig` by path, which is the sort of private route the
/// module boundary exists to prevent.
pub const AuthorPresence = author_types.Presence;
pub const AuthorSeverity = author_types.Severity;
pub const AuthorNodeRoot = author_types.NodeRoot;
pub const AuthorPreviewOutcome = author_types.PreviewOutcome;
pub const AuthorSaveOutcome = author_types.SaveOutcome;
pub const AuthorSaveFailure = author_types.SaveFailure;
pub const AuthorExportKind = author_types.ExportKind;
pub const AuthorWorkspaceInfo = author_types.WorkspaceInfo;
pub const AuthorLimits = author_types.Limits;
pub const AuthorDocumentInfo = author_types.DocumentInfo;
pub const AuthorNodeInfo = author_types.NodeInfo;
pub const AuthorSchemaNodeInfo = author_types.SchemaNodeInfo;
pub const AuthorValue = author_types.Value;
pub const AuthorPackageInfo = author_types.PackageInfo;
pub const AuthorEdit = author_types.Edit;
pub const AuthorSaveResult = author_types.SaveResult;
pub const AuthorSaveAll = author_types.SaveAll;
pub const AuthorSaveEntry = author_types.SaveEntry;
pub const AuthorDiagnostic = author_types.Diagnostic;
pub const AuthorBuildInfo = author_types.BuildInfo;
pub const AuthorPreviewInfo = author_types.PreviewInfo;
pub const AuthorExportInfo = author_types.ExportInfo;

/// `net` — the v5 networking handles and the values they are described by
/// (`networking.md` §8), for a Zig host or client exactly as `foundry.h` has them for C.
pub const NetSession = types.NetSession;
pub const NetPeer = types.NetPeer;
pub const net = net_types;

/// What the host hands over, and what it gets back.
///
/// `Host` is the concrete one a game wants; `HostOf` is what makes a test able to bind a
/// fake engine and run every entry point with no window, no device and no frame.
pub const Host = host.HostOf(@import("app").Engine);
pub const HostOf = host.HostOf;
pub const HostWithMixer = host.HostWithMixer;
pub const ModsWriteGrant = host.ModsWriteGrant;

/// The table itself, and the enumerations and structs that cross with it.
pub const Api_v1 = api.Api_v1;
pub const Api_v2 = api.Api_v2;
pub const Api_v3 = api.Api_v3;
pub const Api_v4 = api.Api_v4;
pub const Api_v5 = api.Api_v5;
pub const TableOf = api.TableOf;
pub const FieldType = types.FieldType;
pub const LogLevel = types.LogLevel;
pub const LogRecord = types.LogRecord;
pub const MemoryCounter = types.MemoryCounter;
pub const MemoryStats = types.MemoryStats;
pub const ComponentDesc = types.ComponentDesc;
pub const NativeLoaderOf = native_loader.LoaderOf;
pub const libraryFileNameAlloc = native_loader.libraryFileNameAlloc;
pub const SchemaId = types.SchemaId;
pub const Step = types.Step;
pub const SystemDesc = types.SystemDesc;

pub const RenderVec2 = render_types.Vec2;
pub const RenderRect = render_types.Rect;
pub const RenderColor = render_types.Color;
pub const RenderCamera = render_types.Camera;
pub const RenderSprite = render_types.Sprite;
pub const RenderFont = render_types.Font;
pub const RenderTextOptions = render_types.TextOptions;
pub const RenderViewDesc = render_types.ViewDesc;
pub const RenderStats = render_types.Stats;

pub const UiId = ui_types.Id;
pub const UiVec2 = ui_types.Vec2;
pub const UiRect = ui_types.Rect;
pub const UiColor = ui_types.Color;
pub const UiFontMetrics = ui_types.FontMetrics;
pub const UiStyle = ui_types.Style;
pub const UiPlotOptions = ui_types.PlotOptions;
pub const UiImageSource = ui_types.ImageSource;
pub const UiReorderMove = ui_types.ReorderMove;
pub const UiReorderDirection = ui_types.ReorderDirection;

pub const ModOrigin = mod_types.Origin;
pub const ModSkipReason = mod_types.SkipReason;
pub const ModProfileProblem = mod_types.ProfileProblem;
pub const ModInfo = mod_types.Info;
pub const ModPending = mod_types.Pending;
pub const ModRequirement = mod_types.Requirement;
pub const ModConflict = mod_types.Conflict;
pub const ModProvider = mod_types.Provider;
pub const ModProfile = mod_types.Profile;
pub const ModProfileState = mod_types.ProfileState;
pub const mod_flag_required = mod_types.flag_required;
pub const mod_flag_native = mod_types.flag_native;
pub const mod_flag_script = mod_types.flag_script;
pub const mod_flag_duplicate = mod_types.flag_duplicate;
pub const mod_flag_environment = mod_types.flag_environment;
pub const mod_flag_unreadable = mod_types.flag_unreadable;
pub const mod_no_position = mod_types.no_position;

pub const PhysicsVec2 = physics_types.Vec2;
pub const PhysicsShape = physics_types.Shape;
pub const PhysicsBodyDesc = physics_types.BodyDesc;
pub const PhysicsHit = physics_types.Hit;
pub const PhysicsQueryHit = physics_types.QueryHit;
pub const PhysicsMoveResult = physics_types.MoveResult;

/// What a native mod exports, and the version of the table this build publishes.
pub const GetApi = types.GetApi;
pub const ModInit = types.ModInit;
pub const ModShutdown = types.ModShutdown;
pub const api_version_1 = types.api_version_1;
pub const api_version_2 = types.api_version_2;
pub const api_version_3 = types.api_version_3;
pub const api_version_4 = types.api_version_4;
pub const api_version_5 = types.api_version_5;
pub const init_symbol = types.init_symbol;
pub const shutdown_symbol = types.shutdown_symbol;

test {
    _ = agreement;
    _ = api;
    _ = calls_asset;
    _ = calls_author;
    _ = author_types;
    _ = calls_audio;
    _ = calls_content;
    _ = calls_engine;
    _ = calls_mods;
    _ = calls_physics;
    _ = calls_render;
    _ = calls_scene;
    _ = calls_ui;
    _ = native_loader;
    _ = mod_types;
    _ = net_types;
    _ = host;
    _ = types;
    _ = physics_types;
    _ = render_types;
    _ = ui_types;
    _ = @import("sweep.zig");
}

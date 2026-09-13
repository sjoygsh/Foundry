# AGENTS.md — working on Foundry

For any coding agent working in this repository. It is an **entry point and an operating
manual**, not a second rulebook.

`CLAUDE.md` is the source of truth for what Foundry is, what it may never do, and how it is
architected. Everything in it binds you. This file exists because it does not tell you how to
build the thing, what breaks in this environment, or where the work currently stands — and an
agent that starts cold needs all three.

**If this file and `CLAUDE.md` ever disagree, `CLAUDE.md` wins, and the disagreement is a bug in
this file.** Fix it rather than following it.

---

## 1. Read these first, in this order

1. **`CLAUDE.md`** — the philosophy, the nine invariants (§3), the architecture (§4), the 16
   development rules (§2) and the non-negotiables (§10). Read all of it. It is not long and it
   is the whole point.
2. **`PROJECT_STATE.md`** — where the work actually stands. It changes every session; the top
   of the file is current. This is the only place that says what is done.
3. **`docs/ROADMAP.md`** — the milestones, if the current one is unclear.
4. **The design document for whatever you are about to build**, in `docs/design/`. Every
   subsystem has one and it was written *before* the code. If you are implementing something,
   its design doc is your specification, and its §-numbered sections are what commit messages
   and comments refer to.
5. **`docs/adr/`** — numbered decision records. Read the ones your work touches. §4.1 of
   `CLAUDE.md` is the index.

**Then inspect the actual code before assuming anything about it**, and summarize your
understanding back to the user before you start. That sequence is `CLAUDE.md` §0 and it is
there because agents reliably skip it.

## 2. Where the work stands

Read `PROJECT_STATE.md` for the real answer — this section goes stale and that one does not.

As of 2026-09-10: **M7 (modding) is complete, all seven steps.** `mod` discovers and
dependency-orders content packages; the installed C99/C++ header specifies the 135-call
`FoundryApi_v1`; `abi` validates and publishes the host's subsystems; and the native loader
runs package-local libraries through a refusal-safe lifecycle. `docs/modding/native-mods.md`
was written by building its C mod outside this repository and running its content, registered
component and system through an external proof host.

**M8 is complete, all eight steps (2026-09-12).** Read ADR-0028, ADR-0029 and
`docs/design/scripting.md`; §16 is the eight-step implementation order and every step is
marked done. Restricted Lua 5.5.1, ordinary package script assets, additive ABI v2 source
copying, binding 1's bounded content/world surface, the package lifecycle, candidate-VM
reload, the complete adversarial/determinism proof and the author guide are all in.
**A script package runs and can be edited while it runs**:
`samples/sandbox/content/scripts/encounter.lua` is registered as one system, driven by the
world's own fixed tick, and replaced in place when the file changes — its state and the
entities it owns carry across. `docs/modding/script-mods.md` was written by building a script
package outside this repository and was then rebuilt from its own listings to check it.

**M9 is complete, all eight steps (2026-09-13).** Read ADR-0031, ADR-0032 (which supersedes
ADR-0030) and `docs/design/distribution.md`; §14 is the implementation order and all eight
Resolutions record what implementation settled. Step 1: `engine/src/app/settings.zig` holds
the `settings.fset` envelope over `data`'s field-block layout, and `Os.replaceFileConfined` is
the confined temporary-then-rename write every later step goes through — a file this build does
not understand is preserved rather than replaced. Step 2: both samples resolve a window size
and a master volume from a built-in fallback, a `config` record in their own package, and the
player's file, in that order. **Two rules about when preferences are live, and both matter when
running the bar**: a headless run neither reads nor applies them, and a frame-budgeted run never
writes them — so `FOUNDRY_*_FRAMES` runs touch no settings file. Step 3: installed and user
package discoveries are combined before resolution, and the host-assigned base for each package
survives content/native/script loading and reload without entering either ABI. A headless sample
discovers ambient user mods only when an explicit `FOUNDRY_*_PACKAGES` selection asks for them.
Step 4: `zig build dist` stages a release of a sample from explicit inputs, through
`tools/distribution` — `release.zig` is the build-time description a game outside this
repository uses too, and `fstage` is the packager. **`dist` requires its configuration and will
not invent one**; the command is below. Step 5: a release carries `LICENSE`, `NOTICE` and a
`THIRD_PARTY_NOTICES.txt` generated from `THIRD_PARTY_LICENSES/`. **That directory's entries
are now parsed**, so their shape is load-bearing: a malformed one refuses the release rather
than shipping a gap. Step 6: `app.diagnostics` keeps a bounded session log under the
application's user-data `logs/`, with a marker saying whether the session closed. **A
frame-budgeted or headless run keeps nothing** — the same rule preferences follow — so
`FOUNDRY_*_DIAGNOSTICS=1` is how a scripted run exercises it at all. `zig build
diagnostics-stress` runs the unclean-exit cases in child processes. Step 7: `zig build dist`
now produces an ad-hoc-signed `.app`, matching dSYM and permission-preserving zip; the
separate `dist-developer-id` target is the only route that touches a private signing identity,
notarytool Keychain profile or network. Step 8: `docs/shipping/macos.md` and an outside build
prove exported-helper consumption, checksum-matched HTTP transfer, no-toolchain runtime,
cross-process preferences, relocated read-only user mods and failed-then-clean diagnostics.
Strict ad-hoc integrity passed and Gatekeeper rejection is expected. Actual Developer ID
signing, Apple notarization and a quarantine-preserving launch on a genuinely clean Mac remain
mandatory deferred work for the first public release; the current artifact does not claim it.

**M10 is complete; M11 is under way, 6/9 steps implemented (2026-09-13).** M10 added
Foundry's marks and an application-supplied release icon (ADR-0034); its full verification is
recorded in PROJECT_STATE. For M11 read ADR-0035 and `docs/design/hardening.md`; §12 is the
nine-step order. Step 1 repaired the Metal-selected test graph, and its compile check is now
in the bar below. Step 2 made both RHI backends retain a destroyed resource until the
recordings that could use it finish (`engine/src/rhi/lifetime.zig`); **rule 9 now rejects
recording through a dead handle, not the destroy itself.** Step 3 moved `render2d` onto that
contract: it keeps no retirement of its own, uploads declare a texture's tracked state, and a
failed atlas upload claims no space. Step 4 made declared usage **validation rule 11**: a
resource used, or moved into a state, its usage does not allow is reported. Step 5 split frame
outcomes: **only `SurfaceUnavailable` may be skipped** (`app.Engine.frameSkippable`), and a
failed frame is closed — its recording discarded, the frame finished — before `renderFrame`
returns. Step 6 lets the UI walker draw rectangles from a solid patch in the font's own
texture (`UiDrawOptions.solid`, resolved by `app.uiSolidRegion`), which `foundry:fonts.debug`
now carries in its spare cell. **Next is Step 7, log timestamps.** M12–M17 remain unstarted.

## 3. Building and verifying

The pinned toolchain is **Zig 0.16.0**, and it is not on `PATH`:

```sh
export PATH="$HOME/.local/zig/0.16.0:$PATH"
```

`.toolchain/bin/zig` is a repo-local convenience copy of the same thing. It is gitignored and
must stay that way — it is about 400 MB. The canonical install is the versioned path above
(ADR-0014).

**Never track Zig master or nightly, and never upgrade the pinned toolchain during a
milestone.** (`CLAUDE.md` §10.)

### The bar, before anything is committed

Every one of these, every time. Not a subset.

```sh
zig fmt --check engine tools samples build.zig
zig build test
zig build check
zig build check -Drhi=metal
zig build check -Dtarget=x86_64-linux-gnu   -Dplatform=null -Drhi=null
zig build check -Dtarget=x86_64-windows-gnu -Dplatform=null -Drhi=null
FOUNDRY_SANDBOX_FRAMES=30 zig build run  -Dplatform=null -Drhi=null
FOUNDRY_ROOM_FRAMES=30    zig build room -Dplatform=null -Drhi=null
```

`check` compiles everything without running it, including the cross-compiled targets where
padding and ABI assumptions differ from macOS. `-Drhi=metal` is the macOS configuration's whole
graph, test binaries included — the Metal executables building is not the same evidence: a test
binary under that flag stayed uncompilable for several milestones while every executable built
(`hardening.md` §4). The two samples are the milestone's runnable
result (`CLAUDE.md` §2) — a change that builds and leaves the sandbox broken is not done.

When the ABI surface changed, also compile a C mod against the *installed* header, because the
Zig tests cannot see what a C author cannot express:

```sh
zig build                                    # installs zig-out/include/foundry.h
zig cc  -std=c99 -pedantic -Wall -Wextra -Werror -Izig-out/include -c mod.c -o /dev/null
zig cc  --target=x86_64-linux-gnu   -std=c99 -pedantic -Werror -Izig-out/include -c mod.c -o /dev/null
zig cc  --target=x86_64-windows-gnu -std=c99 -pedantic -Werror -Izig-out/include -c mod.c -o /dev/null
zig c++ -x c++ -std=c++17 -Wall -Wextra -Werror -Izig-out/include -c mod.c -o /dev/null
```

This is not ceremony. Step 4 found three defects this way and none of them by any other route:
a type a C mod had no way to construct, a header that did not compile as C++ at all, and an
agreement that stopped firing.

### Staging a release

`dist` builds exactly one configuration and refuses every other, naming each wrong thing at
once. There is no shorter form; `-Dtarget` is deliberately absent, because stating it produces
a target Zig no longer calls native and the content compiler has to run here:

```sh
zig build dist -Dapp=room -Dplatform=sdl3 -Drhi=metal -Doptimize=ReleaseSafe \
  -Drevision=<commit>
```

`zig build diagnostics-stress` is part of `zig build test` and also runs on its own. It spawns
children that die without closing their session, so **expect stderr noise from a passing
run** — a child that exits 3 on purpose is the test working.

`-Dapp` is `room` (default) or `sandbox`; `-Drevision=<sha>` is recorded in the release's
inventory and is `local` when unstated — the build runs no `git`. The staged tree is
build-owned and fresh. Local output lands in `zig-out/dist/<app>/` as `<Product>.app`, its
separate `<Product>.app.dSYM`, and `<Product>-local.zip`. The application is ad-hoc signed
without a timestamp; this proves the local bundle and relocation, not public notarization.
It is a real artifact, so it takes a real SDL and Metal build: expect minutes on a cold cache,
and expect it to be the slowest thing here. `zig build distribution-test` runs the focused
staging/plist/dependency/symbol policy tests without building the windowed artifacts.

Public signing is an explicit operator action. First store credentials in the operator's
Keychain profile, following `notarytool`'s prompts; do not put passwords, API keys or private
key material in a command, environment variable or repository file. Then state all three
public-release inputs:

```sh
xcrun notarytool store-credentials "<profile>"
zig build dist-developer-id -Dapp=room -Dplatform=sdl3 -Drhi=metal \
  -Doptimize=ReleaseSafe -Drevision=<commit> \
  -Dsigning-identity="Developer ID Application: … (TEAMID)" \
  -Dnotary-profile="<profile>"
```

`dist-developer-id` signs with hardened runtime and Apple's timestamp, submits and waits,
staples and validates the accepted ticket, verifies codesign and Gatekeeper assessment, and
then creates the final zip under `zig-out/dist/<app>-developer-id/`. Never run it without the
owner's authorization to use that identity, Keychain profile and network service.

### Counting tests

`PROJECT_STATE.md` quotes a number. It is `^test "` plus `^test {` across `engine/src`,
`engine/tests` and `tools`, minus the 10 Metal-only tests that do not run headlessly:

```sh
{ grep -rhc '^test "' --include='*.zig' engine/src engine/tests tools;
  grep -rhc '^test {' --include='*.zig' engine/src engine/tests tools; } | paste -sd+ - | bc
```

## 4. Environment gotchas

Each of these cost real time to discover.

* **`failed command:` lines appear in a *passing* build.** They are noise from cached steps.
  Read the exit code, not the output.
* **`zig build test` prints nothing when everything is cached.** `--summary all` shows the
  steps. A silent run is a passing run.
* **`zig build run` and `zig build room` block forever** without `-Dplatform=null -Drhi=null`
  and a frame budget (`FOUNDRY_SANDBOX_FRAMES` / `FOUNDRY_ROOM_FRAMES`).
* **`/tmp` is not writable.** Use the agent scratchpad, and do not assume it survives between
  sessions — it does not.
* **`timeout` is not installed.** `grep` is `ugrep`.
* **Never `rm -rf .zig-cache/o` on its own** — it deletes the build runner and you get
  *"failed to spawn build runner … FileNotFound"*. Remove the whole `.zig-cache`.
* **Zig's test runner fails any test that logs at `err` level.** That rule is correct and is
  not worth opting out of; split the logging from the pure part and test the pure part.
* **In a test binary the root is the test runner**, so `std.log` never reaches `app.log_sink`.
  Seed the ring by calling `app.log_sink.logFn(...)` directly.
* **A C file's object is cached against the C file, not its headers.** Editing a `.h` alone can
  leave the build green. `engine/src/abi/agreement.zig` `@embedFile`s `foundry.h` specifically
  to defeat this; if you add another C translation unit that a header must keep honest, it
  needs the same treatment.

## 5. How to work here

**Design before implementation.** (`CLAUDE.md` §2 rule 1.) A subsystem gets a document in
`docs/design/` before it gets code, and that document is what the code is checked against. If
implementation contradicts the design, the design was wrong and says so in a dated Resolution
section appended to it — that is how every step of M7 has been recorded.

**Never commit code you have not compiled.** Step 4 arrived in this tree with three compile
errors and five more behind them, a resolution section describing behaviour that did not exist,
and three tests where eleven were needed. Run the bar in §3.

**Verify a guard by breaking it.** A test that has never failed is a test you do not know
works. Every agreement check in `engine/src/abi/` has been confirmed by making the mistake it
exists to catch and watching it fail — narrow a struct member, reorder a table entry in each
direction, change a hash constant, use a C++ keyword. Do the same for anything new that claims
to protect something.

**Never `git checkout <file>` on a file with uncommitted work.** It discards it silently.
This ate work three times in one session. Copy first, or use `git stash push -- <paths>`.

**Untrusted input is validated, never asserted.** Anything from a mod, a content package, a
save or a tool. `core.assert` is for programmer error only. When you add an entry point that a
mod can reach, walk the call chain under it and confirm no assertion is reachable with input
the caller controls.

**Finish a unit, persist it, hand back.** Do not chain into the next step because the current
one went well. A step ends with the bar in §3 green, `PROJECT_STATE.md` updated, and a commit.

**When something is genuinely undecided, say so and stop.** Do not resolve a recorded open
question opportunistically while implementing something else. If implementation forces a
decision, document it architecturally — an ADR, or a Resolution section — *before* proceeding.

## 6. Agent execution and bounded verification

The primary agent performs implementation, reasoning, testing, debugging, documentation
updates and review itself by default. Delegation is exceptional, not routine. Use a subagent
only for a concrete technical reason that materially benefits the task, such as genuinely
independent parallel work or a clearly separable investigation.

Do not spawn agents merely to repeat completed work, review work the primary agent can
reasonably review itself, reconfirm successful tests, duplicate architecture or documentation
audits, or provide reassurance after adequate verification has succeeded. Never spawn several
agents that substantially inspect the same work or answer the same verification question.

Foundry still requires rigorous verification. This policy eliminates redundant verification;
it does not lower correctness, security, portability, testing or architectural standards. For
a normal implementation step:

1. Implement the planned work.
2. Run the tests and checks directly relevant to the changed systems.
3. If a check exposes a concrete problem, fix it and rerun the affected checks.
4. Once targeted verification is clean, perform one appropriate final integration/regression
   verification.
5. Perform one documentation consistency pass and make all required documentation updates.
6. Stop when these are clean.

A successful verification remains accepted unless subsequent changes could reasonably have
invalidated what it established. Do not:

* re-audit already-clean work without new evidence;
* verify a verification pass merely for additional reassurance;
* repeatedly perform whole-repository audits answering substantially the same question;
* repeatedly reread or revalidate documentation after it has been confirmed;
* perform chains of "final check", "last check", "sanity check", "one more pass", or
  equivalent checks over unchanged work;
* spawn reviewers simply to reconfirm successful verification; or
* restart the entire verification sequence after a localized fix unless that fix materially
  affects the wider system.

When verification exposes a problem, use the bounded sequence
`problem -> fix -> rerun affected verification -> continue`; do not restart every previous
audit unless the fix materially affects the wider system. Focused executable evidence is
preferable to repeated speculative inspection.

Repository-wide tests, cross-compilation, security tests, integration tests, sample runs,
architecture checks, documentation checks and other expensive verification remain appropriate
when the affected subsystem or established Foundry process requires them. Run them when they
provide distinct evidence, but do not rerun them over unchanged work merely for reassurance.
Additional verification is justified when new changes could invalidate an earlier result; a
failure reveals possible wider consequences; an applicable ADR or design requires it; an
affected security, ABI, determinism, portability, memory-safety or similar boundary requires
distinct evidence; or the final integration check discovers a new concrete concern. Otherwise,
once sufficient evidence is clean, stop.

Treat this repository as authoritative. Follow this file, `CLAUDE.md`, the ADRs, design
documents, `PROJECT_STATE.md`, the roadmap, build-layer rules, tests and established
conventions. Do not redesign established architecture merely because another design appears
preferable. If a milestone exposes a contradiction that prevents correct implementation,
resolve it through Foundry's ADR/design process. Stay strictly within the current milestone
step and do not implement future-step functionality merely because it is convenient.

## 7. Commits

Small, focused, present tense (`CLAUDE.md` §7). The subject line says what the change lets
somebody do, or what it stops being possible; the body says what the design had not settled and
why the answer is what it is. Look at `git log` — the existing messages are the standard.

Commit as the repository's owner:

```sh
git -c user.name="Shrunjoy Ghosh" -c user.email="sjoy.gsh@gmail.com" commit -F <message-file>
```

Do not add a `Co-Authored-By` trailer naming a model you are not. A milestone ends with a
tagged commit and an updated `PROJECT_STATE.md`.

## 8. Standing constraints from the user

These are in force regardless of what any task appears to ask for.

* **No game-specific code, assets or assumptions in this repository.** The game being built on
  Foundry lives in its own repository and always will (ADR-0017). `samples/` demonstrates
  capabilities; when a sample starts wanting features rather than demonstrating them, it has
  outgrown this repo.
* **No secrets, credentials, API keys, personal files or machine-specific configuration**, in
  the tree or in a commit.
* **No CI, release automation, contribution infrastructure or elaborate GitHub configuration**
  unless the current milestone actually requires it.
* **Keep recorded open questions open.** `CLAUDE.md` §9 and each design doc's "open questions"
  section are deliberate. Closing one is a decision that gets discussed and written down, not a
  side effect.
* **Never make a major architectural decision silently.** If a change would violate an
  invariant in `CLAUDE.md` §3, or make modding harder, stop and raise it.

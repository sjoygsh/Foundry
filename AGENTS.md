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

As of 2026-09-09: **M7 (modding) is complete, all seven steps.** `mod` discovers and
dependency-orders content packages; the installed C99/C++ header specifies the 135-call
`FoundryApi_v1`; `abi` validates and publishes the host's subsystems; and the native loader
runs package-local libraries through a refusal-safe lifecycle. `docs/modding/native-mods.md`
was written by building its C mod outside this repository and running its content, registered
component and system through an external proof host.

**M8 is designed; implementation has not begun (0/8 steps).** Read ADR-0028, ADR-0029 and
`docs/design/scripting.md`; §16 is the eight-step implementation order. Restricted Lua 5.5.1,
the public ABI consumer boundary, source assets, resource limits and candidate-VM reload are
specified. The planning session stops before step 1; resume only when the user requests it.

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
zig build check -Dtarget=x86_64-linux-gnu   -Dplatform=null -Drhi=null
zig build check -Dtarget=x86_64-windows-gnu -Dplatform=null -Drhi=null
FOUNDRY_SANDBOX_FRAMES=30 zig build run  -Dplatform=null -Drhi=null
FOUNDRY_ROOM_FRAMES=30    zig build room -Dplatform=null -Drhi=null
```

`check` compiles everything without running it, including the cross-compiled targets where
padding and ABI assumptions differ from macOS. The two samples are the milestone's runnable
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

### Counting tests

`PROJECT_STATE.md` quotes a number. It is `^test "` plus `^test {` across `engine/src`,
`engine/tests` and `tools`, minus the 8 Metal-only tests that do not run headlessly:

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

## 6. Commits

Small, focused, present tense (`CLAUDE.md` §7). The subject line says what the change lets
somebody do, or what it stops being possible; the body says what the design had not settled and
why the answer is what it is. Look at `git log` — the existing messages are the standard.

Commit as the repository's owner:

```sh
git -c user.name="Shrunjoy Ghosh" -c user.email="sjoy.gsh@gmail.com" commit -F <message-file>
```

Do not add a `Co-Authored-By` trailer naming a model you are not. A milestone ends with a
tagged commit and an updated `PROJECT_STATE.md`.

## 7. Standing constraints from the user

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

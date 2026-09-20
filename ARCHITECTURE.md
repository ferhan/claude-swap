# Architecture: one backend, three surfaces

> Status: target design. Parts of this are built, parts are not — see
> [Current state](#current-state) for the honest split.

`cswap` does its work in one place: a headless backend that runs as a launchd
agent. The TUI, the menu bar and the macOS widget are three ways to see it.
None of them does the work itself.

The TUI and the menu bar can also steer it — switch accounts, add and remove
them, turn auto on and off. The widget cannot: it is **view-only**, for sandbox
reasons set out in [The widget is view-only](#the-widget-is-view-only).

```
            ┌─────────────────────────────────┐
            │   backend  (launchd agent)      │
            │   polls · maintains the store   │
            │   publishes the snapshot        │
            │   applies switch policy         │
            └─────────────────────────────────┘
                 ▲            ▲            ▲
                 │            │            │
              TUI          menu bar      widget
```

## Why a backend at all

Before this, whichever surface you happened to be running hosted the
auto-switch engine: the menu bar started one, the TUI's autoview started one,
`cswap auto` started one. Run two surfaces and two engines make independent
switch decisions. Nothing corrupts — switching is `flock`-serialized and the
usage store claims fetches atomically — but the two policies argue, and which
one wins depends on which window you left open.

The backend makes that a single owner. It also means the widget can exist at
all: a WidgetKit extension only wakes to draw, so it can never be the thing
that polls.

## Who runs the ticker

This is the question the design turns on.

**The ticker lives inside the engine.** `AutoSwitchEngine.run_loop()` sleeps
`autoswitch.intervalSeconds` (default 60s) between ticks, and `wake()` cuts the
sleep short. Whoever hosts the engine runs the ticker — and in the target
design that is only ever the backend.

**Displaying data cannot force a switch.** Reads and decisions are separate
code paths:

| Path | What it does | Can it switch? |
|---|---|---|
| `SnapshotSource.take()` | collects/reads measurements for display | no |
| `AutoSwitchEngine.tick()` | evaluates policy, may switch | yes |

A surface repainting every second cannot provoke a switch, and cannot even
provoke network traffic: pacing is **store-governed**. The usage store's
persisted poll plans and its freshness/backoff/claim gates are decided
atomically in `UsageStore.reserve`, so every surface is capped at the same
per-account cadence no matter how often it asks. The menu bar goes further and
reads `store_only=True` whenever an engine is running, so the display adds no
fetches at all.

So: the backend ticks. Surfaces look.

### Nudging the backend

`AutoSwitchEngine.wake()` exists to tick immediately rather than waiting out
the sleep — today the TUI calls it when you change the threshold, so you see a
decision at the new value at once. That is an **in-process** call.

Once the engine lives in a separate process, a surface that wants to nudge it
needs a cross-process path: a signal to the launchd process, or a file the loop
watches. This needs designing deliberately rather than falling out of the
refactor by accident. **Open.**

## Exactly one engine

Two engines ticking at once is the failure this design exists to prevent. They
would not corrupt anything — switching is `flock`-serialized and fetches are
claimed atomically — but they would reach switch decisions independently, and
which one won would depend on which window you happened to have open.

So the engine takes an **exclusive file lock** at startup, reusing the existing
`locking.FileLock` (`flock`, already used on the switch path). A process that
cannot acquire it does not start an engine, and says which process holds it.

This is stronger than asking launchd whether a label is loaded, because it also
catches an engine nobody registered:

| Case | Lock catches it? |
|---|---|
| backend service running | yes |
| someone ran `cswap auto` in a terminal | yes |
| a menu bar or TUI from this version | yes |
| a surface from an older version (pre-lock) | **no** |

The last row is honest and unavoidable: a build that predates the lock does not
take it. Mixed-version machines — a global `uv tool install` alongside a dev
checkout, which is a real configuration here — can still end up with two
engines. The lock removes the common case, not the pathological one.

## How the pieces talk

Through files that already exist. There is no socket, no RPC, no protocol to
version, and none should be added.

| Channel | Carries | Written by | Read by |
|---|---|---|---|
| usage store | measured state, atomic fetch claims | backend | all |
| `settings.json` | policy (`autoswitch.*`) | any surface | backend |
| `snapshot.json` | display projection | backend | widget |
| JSONL event stream | engine activity | backend | TUI, menu bar |

This is deliberate. Files survive a crash on either side, need no handshake,
and let a surface start and stop freely while the backend keeps running.

### The backend is not a broker

Surfaces do not send it requests, and most of what `cswap` does never touches
it. `cswap switch`, `cswap add`, `cswap remove`, `cswap map`, `cswap alias` all
act **directly** on the shared state, in the calling process, exactly as they
did before — the locks that already guard that state are what make it safe, not
the backend.

What the backend owns is narrower and specific: **it is the only thing running
a clock.** Polling, measurement, snapshot publishing and switch policy are its
job because they need a ticker. Everything else stays where it was.

So "the surfaces talk to the service" is more precisely: *the surfaces share
state with the service, which is the only participant with a timer.*

### The snapshot is a public contract

`~/.claude-swap-backup/snapshot.json` is read by a **separately distributed**
macOS widget, sandboxed with an entitlement scoped to exactly that one path.
The path cannot move without breaking every installed widget. It is spelled
once, in `snapshot_json.default_snapshot_path()`.

`~/.claude/` was rejected for this: it is Claude Code's directory, it relocates
wholesale under `CLAUDE_CONFIG_DIR` (which a widget looking by absolute path
cannot follow), Claude Code prunes it, and pointing a sandbox exception into
the directory holding `.credentials.json` reads badly.

The schema is pinned by a golden fixture, `tests/fixtures/snapshot_golden.json`,
asserted from both sides — a Python test against the producer and a Swift test
against the decoder. A field renamed on either side fails both.

## How surfaces stay current

A change can originate anywhere: you type `cswap switch` in a terminal, you add
an account, the backend switches on its own, or you toggle auto in the menu bar.
Every open surface has to reflect it without being told.

**The rule: detection, not notification.** Nothing pushes. Each surface watches
for change and re-reads. This is deliberate — it works no matter which process
made the change, it survives either side crashing, there is no subscription to
leak and no protocol to version.

The mechanism already exists in the menu bar and generalizes:

1. tick on a short timer (1s)
2. `stat()` the relevant files — cheap, no parsing
3. if an mtime moved, re-read that file
4. if the value actually changed, re-render

Step 4 matters: `~/.claude.json` is rewritten constantly by Claude Code for
unrelated reasons, so mtime alone is far too noisy to drive a repaint.

### Two classes of change, two latencies

Conflating these is what makes a UI feel either sluggish or hyperactive.

| | Examples | Cost to read | Target latency |
|---|---|---|---|
| **State** | active account, account added/removed, auto on/off, threshold, alias, mapping | cheap local file read — no Keychain, no network | **~1s** |
| **Measurement** | usage percentages, reset times, pace | network, and paced by the store | **poll interval** (60s) |

State is cheap, so surfaces check it every second. Measurements are paced by
`UsageStore.reserve` no matter who asks, so checking more often changes
nothing — a surface that repaints every second still sees new numbers only when
the store allows a fetch.

### Per surface

| Surface | Detects via | State latency | Measurement latency |
|---|---|---|---|
| TUI | 1s stat tick feeding Textual reactive state | ~1s | store-paced |
| menu bar | its existing 1s sync tick (already does this for the active account) | ~1s | `refresh_interval`, 60s |
| widget | WidgetKit timeline only | 60s requested | 60s requested |

### The widget cannot be pushed to

This is a platform constraint, not a gap to close later. A WidgetKit extension
runs only when the system wakes it, on the schedule its timeline requested.
`WidgetCenter.reloadTimelines()` can force a reload, but only from the owning
app or extension — a Python CLI has no way to call it. So nothing `cswap` does
can make the widget redraw sooner.

Two things soften it:

- **Countdowns do not need a reload.** Reset times render with
  `Text(date:style:)`, which WidgetKit ticks locally from the absolute
  `resetsAt`. A visibly-live countdown costs no refreshes.
- **Percentages are as fresh as the last timeline entry.** The policy requests
  60s, matching the backend's own poll interval — asking for less would only
  re-read a file that cannot have changed. WidgetKit budgets reloads and may
  serve them less often, so 60s is a ceiling, not a guarantee.
- **A refresh intent is the user's escape hatch.** One button, no extra
  entitlement, and the only way to beat the timeline without a resident helper.

If instant widget updates ever matter enough, the only route is a resident
helper in the widget's own app that watches the snapshot file and calls
`WidgetCenter.reloadTimelines()`. That means shipping a background process, so
it is not in scope now — but it is the shape of the answer, and it is the
reason the host app stub exists rather than being deleted.

## Auto-switching is policy, not identity

The backend is not "the auto-switcher". It is the thing that does the work;
auto-switching is one policy it may apply, governed by `autoswitch.enabled`,
**default false**.

- `enabled = false` — polls, maintains the store, publishes the snapshot,
  evaluates, emits events, reports what it *would* do. Never switches.
- `enabled = true` — the same, and acts on its decisions.

Installing the backend is therefore not opting into automatic switching.
Manual switching (`cswap switch`, `cswap run`, the menu bar's account list)
always works; the engine has explicit handling for a switch that happened
underneath it, and persists cooldown timestamps across processes so it cannot
ping-pong against you.

`enabled = false` is deliberately **not** the same as `--dry-run`. Dry-run
writes nothing at all, because it is previewing someone else's run — so it
suppresses quarantine release. A poll-only backend is still the process
maintaining this machine's state, and a stale quarantine keeps a re-added
account out of the polling plan, degrading the very measurements the backend
exists to produce. So `enabled = false` means precisely *collect and evaluate,
never switch*.

## Command surface

```
cswap service install     install and start the backend launchd agent
cswap service uninstall   stop it and remove the plist
cswap service status      is it running, and which build is launchd holding
cswap service logs        tail the event stream

cswap                     TUI
cswap menubar             menu bar
cswap widget install      build and install the widget locally
```

`cswap auto` remains the foreground / `--once` engine for cron and debugging.
It is no longer the thing you install.

`cswap service status` prints the resolved program path. Both labels
(`com.cswap.auto`, `com.cswap.menubar`) can be overwritten by either a dev
checkout or a global `uv tool install` — the status output makes that visible,
it does not prevent it.

## The widget

A WidgetKit extension in `widget/`, built with XcodeGen (`project.yml`; the
`.xcodeproj` is generated and gitignored, because `project.pbxproj` conflicts
badly and hides changes in review).

Constraints that shaped it, all verified rather than assumed:

- **The extension must be sandboxed.** `pkd` refuses to load an unsandboxed
  one — *"plug-ins must be sandboxed"* — and this is PlugInKit, not App Store
  review, so it applies to Developer ID distribution identically.
- **App Groups don't work here.** The container is reachable by a signed
  reader, but the *writer* is the user's own `cswap`, installed from PyPI. A
  Python process carries no signature and therefore no entitlement, and
  `containermanagerd` denies it. The container is also namespaced by the
  signer's Team ID, so a widget built by one person could never be fed by
  another person's cswap.
- **So: one file-scoped read exception.** Sandbox on, plus
  `temporary-exception.files.home-relative-path.read-only` scoped to the single
  snapshot path — no trailing slash, so nothing else in that directory is
  reachable.
### The widget is view-only

**It cannot change any cswap state.** Not switching, not adding or removing an
account, not aliases or mappings. All of those need to write `~/.claude.json`,
reach the Keychain and take file locks, and a sandboxed extension holding one
read-only exception can do none of it. It also cannot exec `cswap`.

This is a correction to the original plan, which had the widget offering
"switch-best / rotate" buttons. The display half survives; the buttons half
does not.

WidgetKit's own interactivity ceiling is separate and looser — it allows
`Button(intent:)` and `Toggle(isOn:intent:)`, and an intent runs in the
extension's process, which always has read-write access to **its own**
container. So an intent can change what the widget *shows*, just not what cswap
*does*:

| Intent | Effect | Permitted |
|---|---|---|
| cycle displayed account | small family shows one account; page through them | yes |
| switch window shown | 5h ⇄ 7d ⇄ per-model | yes |
| refresh now | `reloadTimelines()`, re-read the snapshot | yes |
| switch account | — | **no** |
| add / remove account | — | **no** |

Seeing every account's limits needs no button: the medium family already
renders one row per account, with per-window percentages, markers, dimmed
disabled rows and sentinel rows showing their status. The small family shows
only the active account, which is where a cycle button would earn its place.

The refresh intent is worth more than it looks — it is the only way a user can
beat the 60s timeline, and the only relief from "another surface switched and
the widget hasn't noticed yet" that does not require shipping a resident
helper.

Everything that mutates state stays in the TUI, the menu bar and the CLI. Do
**not** grow the stub host app into a second front end — it exists only because
an extension cannot ship standalone.

#### If widget-initiated switching is ever wanted

It is additive, not a redesign, and it costs three things: a read-**write**
exception on a small command file, a command protocol, and the backend watching
for it. The switch would also be two-step — WidgetKit reloads the timeline when
the intent completes, which is *before* the backend has acted, so the widget
would show the old account for one tick and the new one after. Achievable, not
instant. Not in scope now.

### Distribution

A notarized DMG signed with a Developer ID Application certificate. Note that a
plain `xcodebuild build` injects `com.apple.security.get-task-allow`, which is
an automatic notarization rejection — the DMG must come from `archive` +
`-exportArchive`.

## Current state

Built and verified:

- `cswap snapshot` and the snapshot schema, with the golden fixture and drift
  tests on both sides
- the widget: decoder, views, golden decode test, entitlements, signed build
- the backend as `cswap service`, `autoswitch.enabled`, per-tick settings
  reload, snapshot published each tick
- the **singleton engine lock**, and both surfaces deciding from it rather
  than from the launchd label — this surface owns the engine / the backend
  owns it / something else does are three distinct, separately rendered states
- **generalized change detection** (`state_watch.StateWatcher`): `~/.claude.json`,
  `sequence.json` and `settings.json`, mtime-gated and value-compared, on both
  surfaces' 1s tick
- the TUI and menu bar reading the backend's JSONL event stream from its
  launchd stdout log (`autoswitch.BackendEventLog`)

Not built:

- `mappings.json` is not watched — no surface renders directory mappings, so
  a `cswap map` has nothing to repaint. One line in `state_watch` the day one does.
- a surface cannot read a *foreign* engine's events: only the backend has a
  log path anyone else knows. A hand-run `cswap auto` shows as EXTERNAL, and
  its decisions stay in its own terminal.
- `cswap widget install` — no install path exists; the widget is built by hand
- cross-process `wake()`

Untested:

- the launchd install end to end
- whether `temporary-exception` passes real notarization (the reasoning is
  sound — it is not profile-gated, and notarization is automated scanning
  rather than the human review that scrutinizes these — but it is unproven
  until a DMG is actually submitted)

## Definition of done

`cswap service install`, and then the TUI, the menu bar and the widget all show
the same live data with nothing else required.

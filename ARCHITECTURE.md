# Architecture: one backend, three surfaces

> Status: target design. Parts of this are built, parts are not — see
> [Current state](#current-state) for the honest split.

`cswap` does its work in one place: a headless backend that runs as a launchd
agent. The TUI, the menu bar and the macOS widget are three ways to see it.
None of them does the work itself.

The TUI and the menu bar can also steer it — switch accounts, add and remove
them, turn auto on and off. The widget is **view-only**, for sandbox reasons
set out in [The widget is view-only](#the-widget-is-view-only), with two
narrow exceptions — turning auto on and off, and switching the active account —
both carried as request files the backend applies (see
[Widget requests](#widget-requests)).

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
| `widget-requests/` | auto on/off and switch requests from the widget | widget | backend |
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

**The one exception is the widget's switch request.** The sandboxed widget
cannot run `cswap switch` itself, so the backend runs it on the widget's
behalf: the same `switch_to` call, in-process, under the same locks — not a
second implementation. It is the only user request the backend acts on, and
it stays that narrow: nothing else is brokered, and every other surface keeps
switching directly.

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

**Published on a timer, not on the tick.** The engine republishes every 60s
(`autoswitch.SNAPSHOT_PUBLISH_INTERVAL_S`) from a thread of its own, and a
tick asks that thread for an extra publish so a switch still lands
immediately. A tick is not a heartbeat: the loop sleeps up to `MAX_SLEEP_S`
when the fleet is blocked, `NO_RESET_FALLBACK_S` on an idle hold, and
`autoswitch.intervalSeconds` may be set as high as an hour — while the widget
reads a snapshot older than 180s as a stopped backend and offers to start the
one that is already running. The thread is the file's only writer while it
runs, its pass is store-only (it re-serializes what the engine collected and
generates no network traffic of its own), and it stops with the loop. Any
looping engine with a snapshot path does this, `--backend` or hand-run;
`--no-snapshot`, and the in-process engines the TUI and menu bar host, start
no thread and write nothing.

**`usage.scoped[]` is grouped by model family** in this payload, and only in
this payload (`snapshot_json._collapse_scoped_by_family`; `--list --json`
serves the raw windows). The API reports per-model weekly windows under
their full display names, so "Claude Opus 4.8" and "Opus 5" arrive as two
rows for what a display should show as one line: Opus. Rows whose name
contains `opus`, `sonnet`, `haiku` or `fable` collapse onto that word; a name
matching none passes through unchanged; order of first appearance is kept.
When several windows merge, `pct` is the **max** across the group (the
binding constraint) and `maxed` is true if any of them is maxed, while
`resetsAt`, the countdown and the pace fields all come from whichever window
carries that max — a tie keeping the first seen — since that is the window
actually gating.

Changes are additive only; `schemaVersion` stays 1 while old readers keep
decoding. Three additions are backend-sourced:

- `accounts[].usage.fiveHour.history` — `[{t, pct}]`, 24h, oldest first, at
  most one point per 5 minutes. Kept in `usage_history.json` (backup dir,
  0600, own file lock), which the engine appends to whenever a new 5h
  measurement is in the store; it survives backend restarts. `cswap snapshot`
  reads it too.
- top-level `autoswitch` — `enabled`, the effective `threshold`,
  `nextCandidateNumber` (the engine's own `_rank` asked "who if you had to
  switch now", from where the tick left off) and 24h of real `switches`
  (`{at, from, to}`, same history file). Engine state, so only the
  engine-published file carries it; the one-shot `cswap snapshot` omits it.
  `switches` records the engine's own switches only; a manual one (CLI, menu
  bar, widget) is not in it, and the history has no field to tell them apart.
- top-level `cswapCommand` — the argv prefix that runs this cswap, exactly
  what `launch_agent.resolve_program()` returns and the backend plist runs
  (e.g. `["/Users/me/.local/bin/cswap"]`, or `[python, "-m", "claude_swap"]`
  without a console script). The widget's host app runs `cswapCommand +
  ["service", "start"]` for its "Start backend" button. Engine file only,
  like `autoswitch`.

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
underneath it, persists cooldown timestamps across processes so it cannot
ping-pong against you, and starts that same cooldown for a manual switch (see
[Widget requests](#widget-requests)) so it does not undo your pick.

`enabled = false` is deliberately **not** the same as `--dry-run`. Dry-run
writes nothing at all, because it is previewing someone else's run — so it
suppresses quarantine release. A poll-only backend is still the process
maintaining this machine's state, and a stale quarantine keeps a re-added
account out of the polling plan, degrading the very measurements the backend
exists to produce. So `enabled = false` means precisely *collect and evaluate,
never switch*.

## Command surface

`cswap` is the only entry point. Nobody installs the backend; the surfaces
start it.

```
cswap                     TUI (also `cswap tui`, `cswap watch`)
cswap menubar             install + start the menu bar agent, return the prompt
cswap service status      is the backend running, and which build is launchd holding
cswap service logs        tail the event stream
cswap service start       ensure the backend is running, without a surface
```

The widget has no `cswap` subcommand: it is built and installed by
`./widget/build-widget` (see "Not built", below).

`cswap auto` remains the foreground / `--once` engine for cron and debugging.
It is no longer the thing you install. (`cswap auto --install-service` still
works as a hidden, deprecated alias; its backend lacks `--backend`, so it does
not retire, until the next surface replaces it with one that does.)

The menu bar agent runs `cswap menubar --foreground` (hidden flag); the backend
agent runs `cswap auto --json --backend`.

### Backend lifetime

The backend runs exactly while some surface is open, or a widget is placed.

1. A surface (TUI, or the menu bar app itself) takes the **lifecycle lock**
   (`<backup>/.lifecycle.lock`), registers itself — a lock file
   `<backup>/.surfaces/<kind>-<pid>.lock` held for its whole life — and
   ensures the backend: reinstall if it isn't running, if the plist's
   `ProgramArguments` differ from this build's (**newest caller wins**), or
   if the plist's `CSWAP_VERSION` (an `EnvironmentVariables` entry recording
   the release that wrote it) differs from this process's version. An
   upgrade keeps the console script's path, so only the version shows the
   running agent is old code; the reinstall's bootout + bootstrap restarts it.
   Then it releases the lifecycle lock. If launchd fails, the surface still
   opens and falls back to hosting its own engine.
2. The backend (only when started with `--backend`) checks every 5s, after a
   30s startup grace, under the same lifecycle lock (try-acquire; skip the
   round if busy): if no surface lock is held, it **announces the retirement**
   (writes `<backup>/.backend-retiring`), deletes its own plist and stops its
   engine; the process exits 0, which `KeepAlive: {SuccessfulExit: false}`
   does not restart. Liveness is try-acquire, so a crashed surface counts as
   gone.

   The announcement exists because the process does not exit here — it
   finishes the tick it is in first, seconds to tens of seconds, and through
   that window it is a live pid with matching argv and version, which is
   exactly what `needs_install` calls "running". A surface opening then used
   to be told the backend was fine and end up with `managed=True`, no engine
   and no plist to bring one back. `open_surface` now treats the
   announcement as *not running* and reinstalls unconditionally (the
   bootout ends the old process), clearing the flag only once a backend is
   really back. Both halves run under the lifecycle lock, so the
   announcement and the plist removal are one decision and reading them is
   another. A backend clears any stale flag as it starts.
3. It does not `bootout` itself — that would have launchd SIGTERM the process
   waiting on `launchctl`. The job's record stays loaded but idle until
   logout, or until the next surface's install boots it out and bootstraps.

4. **A placed widget counts as a viewer.** It cannot hold a surface lock —
   WidgetKit wakes the extension only to draw — so when no surface is live
   the backend asks the widget's host app: `ClaudeSwap.app/Contents/MacOS/
   ClaudeSwap --placed-widgets` prints `{"count": N}` and exits 0
   (`launch_agent.PlacedWidgets`). It is looked for in `~/Applications`
   (where `build-widget install` puts it) and then `/Applications` (where
   dragging it out of the .dmg puts it), first one that exists winning;
   `CSWAP_WIDGET_APP` names an `.app` anywhere else and overrides both. The
   list is spelled once, in `widget_host_candidates`. `count > 0` keeps the
   backend **and its plist**. Missing app, timeout (10s), non-zero exit or unparsable output
   read as 0, so it retires exactly as before; each distinct answer is logged
   once to `com.cswap.auto.err`. The answer is cached for 5 minutes, so
   removing the last widget retires the backend within ~5 minutes, and the
   app is spawned at most once per 5 minutes. It is asked outside the
   lifecycle lock (it can take seconds; opening surfaces wait on that lock),
   and the surfaces are re-checked under the lock before the plist goes.
5. **Consequence: a placed widget brings the backend back at login.** The
   plist stays, and it carries `RunAtLoad: true`, so launchd starts it at the
   next login with no surface involved. After the 30s grace it asks the app
   again; if the widget is still placed it stays. If the app cannot answer
   that early in the session, the answer is unknown, read as 0, and the
   backend retires — the next surface brings it back.

Races: registration and the retire check are serialized by the lifecycle
lock. A surface that registers after a retire sees no plist and reinstalls;
a retire that runs after a registration sees the surface and stays. The grace
covers `cswap menubar`, which ensures the backend and exits before the menu
bar app registers (the app ensures the backend again itself, which is also
what brings it back at login).

A backend that finds the engine lock held (a hand-run `cswap auto`) logs it
to stderr and exits 0, not 1: under `KeepAlive: {SuccessfulExit: false}` a
failure would be relaunched every ~10s for as long as that loop runs. The
next surface to open sees it not running and starts it again. A hand-run
`cswap auto` refused the same way still exits 1.

#### The backend trims its own logs

The plist points `StandardOutPath`/`StandardErrorPath` at
`~/Library/Logs/com.cswap.auto.{log,err}`, and the stdout one is the event
stream surfaces tail. Nothing rotated them, which mattered once a placed
widget could keep the backend up around the clock.

launchd opens those files and holds the descriptors for the process's whole
life, so nothing outside the process can roll them over — a rename would
leave every further line going to a file nobody can find. The backend checks
them every 5 minutes and, past 8 MB (`launch_agent.LOG_MAX_BYTES`), copies
the content to `<path>.1` and truncates the original **in place**, keeping
the inode. It sets `O_APPEND` on fds 1 and 2 at startup first: without it the
next write would land at the descriptor's stale offset and leave a hole of
NULs as long as the old log, reclaiming nothing.

The log is emptied rather than tail-preserved because `BackendEventLog`
rewinds to 0 when the file it follows shrinks — any tail left behind would
come back as new events, and the menu bar would notify on yesterday's
switches. `tail -f`, what `cswap service logs -f` runs, reports the
truncation and keeps following. One generation is kept, and the handful of
lines written between the copy and the truncation are lost.

#### Widget requests

The widget's one write path is `<backup>/widget-requests/` (the sandbox
grants a read-write exception on that directory only). It drops
`autoswitch-<epochMillis>.json` — temp file then rename, temps start with
`.` — containing `{"autoswitch": {"enabled": bool}, "at": "<ISO8601>"}`.

The backend (`--backend` only; `widget_requests.py`) creates the directory
0700 at startup, since the sandboxed widget cannot, and polls it every 1s on
its own thread — not per tick, because the engine can sleep for minutes or
hours. Per pass it applies the **newest** valid request (largest
`epochMillis`) through `settings.set_setting`, the writer behind `cswap
config set autoswitch.enabled`, deletes every non-dot file it looked at,
valid or not, and ignores dotfiles. The newest must also be **fresh** —
within 15 minutes (`AUTOSWITCH_MAX_AGE_S`) — or it is dropped with a log
line, as a stale switch request is; otherwise a tap made this morning would
flip the setting tonight, when the backend next happened to come back. A
change is logged as one line to
`com.cswap.auto.err` and followed by `engine.wake()`: the tick re-reads
settings and republishes the snapshot, so the widget's optimistic state
converges within the tick's duration (seconds; longer if a tick is already
mid-fetch). A request matching the current setting is consumed silently.
Requests made while no backend runs wait in the directory and are applied at
startup, before the first tick.

**Switch requests** share the directory: `switch-<epochMillis>.json`, same
temp-and-rename, containing `{"switch": {"to": <account number>}, "at":
"<ISO8601>"}`. Same 1s pass, same thread. Every `switch-*.json` is deleted
before anything runs, so a failing switch is never retried; of the valid
ones only the newest is considered, and only if it is **fresh** — its
`epochMillis` within 60s of now. Older ones are dropped unapplied with one
log line each (`widget: ignored stale switch request to N (age …)`).

The two freshness windows differ by an order of magnitude on purpose. A
toggle is a setting: applying it a little late still gives the state the user
asked for, so 15 minutes comfortably covers a backend restart. A switch is an
act: a click made while the backend was down, applied when it next starts —
possibly at the next login, hours later — would move the active account out
from under whatever the user is doing by then. 60s covers a backend busy in
a tick; anything older is a click the user has moved on from.

The switch itself is `ClaudeAccountSwitcher.switch_to(N, json_output=True)`
on a fresh switcher, exactly what `cswap switch N` runs, so validation and
locking are the CLI's: an unknown account, or the switch path refusing, is
logged as `widget: refused switch request to N: <reason>`; the active
account is a logged no-op. One deliberate difference: a **disabled** account
is refused, where `cswap switch N` accepts it — a tap on a dimmed row is far
likelier a slip than an intent. An applied switch logs one line (`widget:
Switched to Account-N (email), from Account-M (requested …)`) and wakes the
engine, which republishes the snapshot with the new `activeAccountNumber`
within about a second.

It gets the same engine treatment as `cswap switch`, which is **the
cooldown**: every manual switch — CLI, menu bar, TUI, widget request — writes
`lastSwitchAt` into `autoswitch_state.json`, so the engine leaves the pick
alone for `cooldown_seconds` (default 300) the way it leaves its own switches
alone. The recording lives in `ClaudeAccountSwitcher._perform_switch`, the one
path every surface's switch goes through, and runs after that path's locks are
released (lock order is state lock, then switch lock); the engine passes
`manual=False` because it writes its own bookkeeping under the state lock it
already holds. It waits up to 60s for the state lock, not `FileLock`'s 10s
default, because the engine holds that lock across a whole `switch_to`
(freshen, keychain, file work); giving up warns on stderr as well as in the
log, since the switch already happened and the engine may move off it on the
next tick. Only `lastSwitchAt` is written: `lastSwitchTo`/`lastSwitchFrom`
stay the engine's, so a hand switch still *disarms* the no-return bar instead
of tripping it, and the switch does not enter `autoswitch.switches` history —
those chart markers mean auto-switches. The cooldown gates the `proactive` and
`consume-first` triggers only, so `at-limit` and `failover` still move off an
account that is exhausted or unreadable. A no-op switch (already on that
account) records nothing.

The menu bar agent is a surface, not the backend, and outlives Quit: its plist
stays, so it returns at login. *Open at Login* in its menu deletes or rewrites
that plist without touching launchd (a self-`bootout` would SIGTERM the app
mid-call), so the current session keeps running. `cswap menubar
--uninstall-service` is the stop-now path: bootout + delete, from outside the
app.

Both labels (`com.cswap.auto`, `com.cswap.menubar`) can be overwritten by
either a dev checkout or a global `uv tool install`; `cswap service status`
prints the program launchd holds.

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
| switch account | request file, applied by the backend | yes (see [Widget requests](#widget-requests)) |
| add / remove account | — | **no** |

Seeing every account's limits needs no button: the medium family already
renders one row per account, with per-window percentages, markers, dimmed
disabled rows and sentinel rows showing their status. The small family shows
only the active account, which is where a cycle button would earn its place.

The refresh intent is worth more than it looks — it is the only way a user can
beat the 60s timeline, and the only relief from "another surface switched and
the widget hasn't noticed yet" that does not require shipping a resident
helper.

Two exceptions exist, both request files the backend applies (see
[Widget requests](#widget-requests)): the auto-switch toggle, which flips one
policy boolean, and the switch request, which the backend runs through the
CLI's own switch path. The widget itself still touches no account, no
Keychain item and not `~/.claude.json`.

Everything else that mutates state stays in the TUI, the menu bar and the CLI. Do
**not** grow the stub host app into a second front end — it exists only because
an extension cannot ship standalone.

#### Widget-initiated switching

Built as predicted: additive, on the read-write request directory the toggle
already had, with the backend watching it. The switch is two-step — WidgetKit
reloads the timeline when the intent completes, which is *before* the backend
has acted, so the widget shows the old account until the next reload after the
backend's republish. Achievable, not instant.

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
- the backend, started by the surfaces and retired by itself when the last
  one closes (observed live against launchd: `service inactive` in the
  unified log ~30s after a surface-less start); `autoswitch.enabled`,
  per-tick settings reload, snapshot published on its own 60s timer
- **live against the real host app and widget**: self-retirement, the widget
  toggle round trip (three requests applied), and `--placed-widgets`
  answering a real count (4)
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

- five paths against the real host app and widget, each unit-tested with the
  subprocess, launchd and files stubbed (TESTING.md has runnable steps for
  all five): the host app's **Start backend** URL tap, a **switch tap** on a
  widget row, an **upgrade-triggered reinstall** (`CSWAP_VERSION` differing),
  **Open at Login**, and **retire/return across a logout** with a widget
  placed
- whether `temporary-exception` passes real notarization (the reasoning is
  sound — it is not profile-gated, and notarization is automated scanning
  rather than the human review that scrutinizes these — but it is unproven
  until a DMG is actually submitted)

## Definition of done

`cswap` or `cswap menubar`, and then the TUI, the menu bar and the widget all
show the same live data with nothing else required.

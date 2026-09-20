# Testing the backend + surfaces

Hand-off notes for testing what was built. Read `ARCHITECTURE.md` first for the
design; this is the runbook.

Everything below uses **`.venv/bin/cswap`** — the dev checkout, v0.27.0b1. Your
global `~/.local/bin/cswap` is v0.26.0 and predates all of this.

---

## 0. Clear the decks

The one real hazard is the **mixed-version machine**. v0.26.0 does not take the
engine lock, so it can host a second engine that the new code cannot see or
refuse. Close it before testing anything.

```bash
# the v0.26.0 TUI you had open on ttys008
pkill -f '\.local/bin/cswap' || true

# nothing should be left
ps aux | grep '[c]swap'
launchctl list | grep -i cswap || echo "no services loaded"
ls ~/Library/LaunchAgents/ | grep -i cswap || echo "no plists"
```

Optionally remove the global install entirely for the duration:
`uv tool uninstall claude-swap`. Reinstall later if you want it back.

---

## 1. Install the backend

```bash
cd ~/src/claude-swap
./src/start-service              # no argument = the backend
.venv/bin/cswap service status
```

Expect the service loaded, a pid, and two lines that did not exist before:

- `program:` — the resolved binary launchd is actually holding. This is the
  dev-checkout-vs-global-install collision made visible. It must point at
  `.venv/bin/cswap`, not `~/.local/bin/cswap`.
- `engine:` — the lock holder.

**This path has never been run live.** The harness blocked `launchctl
bootstrap` for every agent, so `service install`/`uninstall` are covered only by
unit tests with a stubbed `launch_agent`. If something is broken, it is most
likely here.

### Confirm it is actually ticking

```bash
.venv/bin/cswap service logs -n 20
.venv/bin/cswap service logs -f          # ctrl-c to stop
ls -l ~/.claude-swap-backup/snapshot.json
```

The service runs `cswap auto --json`, so the raw log is JSONL; `service logs`
renders the `human` field back for you. The snapshot should be rewritten each
tick (default 60s) at `0600`.

---

## 2. The singleton lock

This is the core invariant. With the backend running:

```bash
.venv/bin/cswap auto --once ; echo "exit=$?"
```

Expect a refusal naming the holder, and **exit 1**:

```
error: another cswap engine already owns this machine's accounts:
pid NNNNN (/Users/ferhan/src/claude-swap/.venv/bin/cswap auto)
— not starting a second one
```

Then stop the service and confirm the same command now ticks normally:

```bash
./src/stop-service
.venv/bin/cswap auto --once ; echo "exit=$?"     # exit 2 = no switch needed
```

Kill the backend uncleanly (`kill -9` its pid) and check the lock releases —
`flock` dies with the process, so a stale `.engine.lock.owner` sidecar must not
fool anything:

```bash
.venv/bin/cswap service status                    # engine: should read not held
```

---

## 3. Surfaces as clients

Start the backend again, then open each surface and check the **engine
ownership** display. Three states must be distinguishable:

| Situation | TUI badge | Menu bar (Settings submenu) |
|---|---|---|
| backend running | `BACKEND` | `Engine: backend service` |
| hand-run `cswap auto` in a terminal | `EXTERNAL` | `Engine: pid N (…)` |
| nothing else running | `LIVE` / `DRY-RUN` | `Engine: this menu bar` |
| nothing at all | — | `Engine: not running` |

The bug this fixes: previously a surface read only the launchd label, so a
*hand-run* engine made the TUI claim `DRY-RUN` and log "engine started" before
logging the lock refusal. If you see that, it regressed.

```bash
.venv/bin/cswap                       # TUI, then open the auto screen
./src/start-service menubar           # menu bar, separately
```

With the backend running, the surfaces must show its events rather than
producing their own — switches and quarantines from the backend should appear
in the TUI auto screen and as menu bar notifications.

**Self-hosting must still work.** With no backend and nothing holding the lock,
each surface starts its own engine exactly as before. This did not become
"requires the service".

---

## 4. Change detection

State changes from anywhere should reach an open surface in about a second.
With the TUI or menu bar open, in another terminal:

```bash
.venv/bin/cswap switch                # active account changes
.venv/bin/cswap alias 1 work          # alias changes
.venv/bin/cswap config set autoswitch.enabled true
.venv/bin/cswap config set autoswitch.enabled false
```

Each should repaint the open surface within ~1s, with no usage fetch triggered.

Watched files, and the value compared in each:

| File | Compared on |
|---|---|
| `~/.claude.json` | `oauthAccount` only — the other 71 keys churn constantly |
| `<backup>/sequence.json` | parsed dict **minus `lastUpdated`**, which bumps on silent back-fills |
| `<backup>/settings.json` | whole dict |

`mappings.json` is deliberately **not** watched — neither surface renders
directory mappings, so a repaint would show nothing new. Pinned by a test so
the omission reads as a decision.

---

## 5. Auto on/off across processes

The point of `autoswitch.enabled` living in shared settings is that a toggle
from any surface reaches the backend without restarting it.

```bash
.venv/bin/cswap config get autoswitch.enabled      # false by default
```

Toggle it from the menu bar's "Auto-switch accounts" item, then check the
backend picked it up on its next tick via `service logs -f`. It re-reads
settings from disk every tick, so no restart should be needed.

**Default is false.** Installing the backend does not opt you into switching —
it polls, measures, publishes the snapshot and reports what it *would* do.

---

## 6. The widget

Already installed at `~/Applications/CswapWidgetHost.app` and registered:

```bash
pluginkit -m -v | grep -i cswap
```

Add it from the widget gallery: right-click the desktop → Edit Widgets → search
"cswap". Small shows the active account; medium shows one row per account.

What to check:

- countdowns tick live, second by second, without the widget reloading
- percentages refresh on the 60s timeline (a **request** — WidgetKit budgets
  reloads and may serve fewer)
- it is **view-only**: no switching, adding or removing. That is a sandbox
  consequence, not an omission.
- with the backend stopped, the snapshot goes stale and the widget shows old
  data. That is expected — only the backend publishes it.

Rebuild / remove:

```bash
./widget/build-widget install
./widget/build-widget uninstall
```

**If the widget stops appearing in the gallery**, the cause is almost certainly
two registered copies of the same bundle id — not the install location, which
does not matter. Check with `pluginkit -m -v | grep -i cswap` and unregister
strays with `pluginkit -r <path>`.

---

## Known gaps — expect these, they are not regressions

- **launchd install/uninstall was never run live.** Highest-risk area.
- **Every rumps-bound menu bar path is untested.** `MenuBarApp` is defined
  inside `run()` and needs a live NSApp, so there is no harness. The pure
  helpers it composes are tested; the wiring is reviewed, not executed.
- **`backend_pid()` against a real loaded agent** — the pid-match branch is
  tested only with a patched function.
- **The DMG / notarization path is entirely unrun.** No Developer ID
  Application certificate exists yet, so `./widget/build-widget release` has
  only ever reached its certificate gate.
- **Cross-process `wake()` does not exist.** Changing the threshold no longer
  produces an immediate decision when the backend owns the engine; you wait for
  the next tick.
- **A foreign engine's events cannot be read** — only the backend has a log
  path anyone else knows. `EXTERNAL` shows who holds the lock, not what it is
  doing.

## Teardown

```bash
./src/stop-service                    # backend
./src/stop-service menubar            # menu bar, if installed
./widget/build-widget uninstall       # widget
```

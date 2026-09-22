# Testing the backend + surfaces

Hand-off notes for testing what was built. Read `ARCHITECTURE.md` first for the
design; this is the runbook.

Everything below uses **`.venv/bin/cswap`** — the dev checkout, v0.27.0b1. Your
global `~/.local/bin/cswap` is v0.26.0 and predates all of this.

One-time setup: `uv sync --extra menubar`. After that there is nothing to
install by hand — `cswap` is the only entry point, and the TUI and the menu bar
start the backend themselves.

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

## 1. Start the backend by opening a surface

```bash
cd ~/src/claude-swap
.venv/bin/cswap tui              # leave it open; in another terminal:
.venv/bin/cswap service status
```

Expect the service loaded, a pid, and two lines that did not exist before:

- `program:` — the resolved binary launchd is actually holding. This is the
  dev-checkout-vs-global-install collision made visible. It must point at
  `.venv/bin/cswap`, not `~/.local/bin/cswap`.
- `engine:` — the lock holder.
- the plist's program ends in `auto --json --backend`.

`ls ~/.claude-swap-backup/.surfaces/` shows one `tui-<pid>.lock` per open
surface.

### Last one out

Close the TUI. Within ~5s (30s if the backend started less than 30s ago) the
backend should delete `~/Library/LaunchAgents/com.cswap.auto.plist` and exit 0;
`service status` then shows it not running. It does this whatever
`autoswitch.enabled` says. Kill a TUI with `kill -9` instead and the result
must be the same — a dead surface's lock is released by the kernel.

Self-retirement has been observed live: the unified log shows launchd's
`service inactive: com.cswap.auto` ~30s after a start with no surface open:

```bash
/usr/bin/log show --last 1h --predicate 'eventMessage CONTAINS "com.cswap.auto"' --style compact
```

(`/usr/bin/log`, not `log` — zsh has a builtin of that name.) A placed widget
changes this; see §6.

### Confirm it is actually ticking

```bash
.venv/bin/cswap service logs -n 20
.venv/bin/cswap service logs -f          # ctrl-c to stop
ls -l ~/.claude-swap-backup/snapshot.json
```

The service runs `cswap auto --json`, so the raw log is JSONL; `service logs`
renders the `human` field back for you. The snapshot is rewritten **every 60s
on its own timer** (not per tick) at `0600`, plus once at the end of each
tick. Check it keeps moving even when the engine is asleep for a long time:

```bash
# Put the engine on a long sleep, then watch the snapshot anyway.
.venv/bin/cswap config set autoswitch.intervalSeconds 3600
for i in 1 2 3; do stat -f '%Sm %N' ~/.claude-swap-backup/snapshot.json; sleep 70; done
.venv/bin/cswap config set autoswitch.intervalSeconds 60
```

The mtime should advance every ~60s across all three lines. (It has to: the
widget calls a snapshot older than 180s a stopped backend.)

### Its logs stay bounded

```bash
ls -lh ~/Library/Logs/com.cswap.auto.{log,err} ~/Library/Logs/com.cswap.auto.*.1 2>/dev/null
```

Past 8 MB the backend copies the file to `<path>.1` and truncates it in
place, within 5 minutes. To force it, append ~9 MB to the log
(`dd if=/dev/zero bs=1m count=9 | tr '\0' 'x' >> ~/Library/Logs/com.cswap.auto.log`)
and wait: the `.log` drops to a few hundred bytes, `.log.1` holds the old
content, the inode is unchanged (`stat -f %i`), and an open `service logs -f`
keeps printing new lines. A TUI open across the truncation must **not**
replay old switches as new events.

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

The reverse must not loop: with a hand-run `cswap auto` holding the lock, a
backend started by a surface logs "another cswap engine holds the engine lock;
exiting cleanly" to `~/Library/Logs/com.cswap.auto.err` and exits 0 — launchd
does not restart it (`cswap service status` shows it not running, no pid
churn). Stop the hand-run loop and reopen a surface: the backend starts again.

Then close every surface, wait for the backend to retire, and confirm the same
command now ticks normally:

```bash
.venv/bin/cswap service status                   # not running
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

Open each surface (which starts the backend) and check the **engine
ownership** display. Three states must be distinguishable:

| Situation | TUI badge | Menu bar (Settings submenu) |
|---|---|---|
| backend running | `BACKEND` (`BACKEND · LIVE` with `autoswitch.enabled`) | `Engine: backend service` |
| hand-run `cswap auto` in a terminal | `EXTERNAL` | `Engine: pid N (…)` |
| nothing else running | `LIVE` / `DRY-RUN` | `Engine: this menu bar` |
| nothing at all | — | `Engine: not running` |

The bug this fixes: previously a surface read only the launchd label, so a
*hand-run* engine made the TUI claim `DRY-RUN` and log "engine started" before
logging the lock refusal. If you see that, it regressed.

```bash
.venv/bin/cswap                       # TUI, then open the auto screen
.venv/bin/cswap menubar               # installs the menu bar agent and returns
```

In the TUI's auto screen with the backend owning the engine, `l` toggles
`autoswitch.enabled` (confirmed when going live) instead of restarting a local
engine. Menu bar *Quit* is a clean exit: the plist stays, so it returns at the
next login, and the backend retires if no TUI is open. Unticking *Open at
Login* deletes the plist but leaves the app running; *Quit* after it and the
menu bar stays gone. Ticking it writes the plist back.

After an upgrade (or any version bump), opening a surface restarts the backend
on the new code: `cswap service status` shows the new `version:` and a new pid.
`cswap menubar` does the same for the menu bar agent.

With the backend running, the surfaces must show its events rather than
producing their own — switches and quarantines from the backend should appear
in the TUI auto screen and as menu bar notifications.

**Self-hosting is now the fallback only.** On macOS a surface hosts its own
engine only if starting the backend failed (the auto screen says why). Off
macOS there is no backend and the TUI hosts its engine as before.

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

Already installed at `~/Applications/ClaudeSwap.app` (or `/Applications` — the
backend looks in both, and `CSWAP_WIDGET_APP` names an `.app` anywhere else)
and registered:

```bash
pluginkit -m -v | grep -i cswap
```

Exactly one line, id `com.cswap.widget.claudeswap`. The extension id and the
widget kind changed to escape a chronod descriptor cache that kept the gallery
saying "cswap"; widgets placed before that change are dead and must be removed
and re-added.

Add it from the widget gallery: right-click the desktop → Edit Widgets → search
"ClaudeSwap". Small, medium and large page with ‹ ›. Extra-large is
master-detail: tap an account on the left to show its pace, details and trend
on the right; ▲/▼ appear when the list overflows.

What to check:

- countdowns tick live, second by second, without the widget reloading
- percentages refresh on the 60s timeline (a **request** — WidgetKit budgets
  reloads and may serve fewer)
- it is **view-only** apart from the auto toggle and switching (both request
  files, below): no adding or removing. That is a sandbox consequence, not an
  omission.
- with the backend stopped, the snapshot goes stale and the widget shows old
  data. That is expected — only the backend publishes it. A placed widget
  now keeps the backend up (next section), so this should only happen when
  no widget is placed or the host app cannot answer.

### A placed widget keeps the backend alive

Run live: self-retirement observed, and `--placed-widgets` answered a real
count (4).

```bash
~/Applications/ClaudeSwap.app/Contents/MacOS/ClaudeSwap --placed-widgets   # {"count": N}
```

1. Place a widget. Close every TUI and quit the menu bar.
2. After ~35s: `.venv/bin/cswap service status` still shows it running, the
   plist is still in `~/Library/LaunchAgents/`, and
   `~/Library/Logs/com.cswap.auto.err` has one line
   `backend: 1 widget(s) placed; staying up without a surface`.
3. `snapshot.json` keeps being rewritten every ~60s (`ls -l`).
4. Remove the widget. Within ~5 minutes (the answer is cached) the backend
   retires; the `.err` log gains `backend: no widgets placed`.
5. Login: with a widget placed, log out and in (no surface opened). The
   backend should be running (`RunAtLoad`), and stay past the 30s grace. If
   it retired instead, the `.err` line says whether the app answered
   "unknown" that early in the session.

Without the app installed, `.err` shows `no widget host app at …` once and
the backend retires as before.

### The auto-switch toggle

Run live: the round trip from the widget applied three requests.

The widget drops `autoswitch-<epochMillis>.json` in
`~/.claude-swap-backup/widget-requests/` (created 0700 by the backend, which
also corrects the mode of a directory that is already there). To test the
backend half without the widget:

```bash
d=~/.claude-swap-backup/widget-requests
printf '{"autoswitch":{"enabled":true},"at":"%s"}' "$(date -u +%FT%TZ)" > "$d/.tmp"
mv "$d/.tmp" "$d/autoswitch-$(($(date +%s)*1000)).json"
```

Within ~1s the file is gone, `cswap config get autoswitch.enabled` is
`true`, `.err` has `widget: autoswitch.enabled -> true (requested …)`, and
`snapshot.json`'s `autoswitch.enabled` follows within a tick's duration.
Also check: two files at once → the larger `epochMillis` wins and the other
logs `ignored superseded autoswitch request`; a garbage file is deleted and
changes nothing; a dotfile is left alone. With the backend stopped, a dropped
file waits and is applied when it next starts — **while it is under 15
minutes old**. Past that:

```bash
d=~/.claude-swap-backup/widget-requests
printf '{"autoswitch":{"enabled":true},"at":"old"}' > "$d/.tmp"
mv "$d/.tmp" "$d/autoswitch-$((($(date +%s)-1200)*1000)).json"
```

→ deleted, setting unchanged, `.err` has `widget: ignored stale autoswitch
request (true, age 1200s, requested old)`.

### Switching from the widget

The widget drops `switch-<epochMillis>.json` in the same directory. Backend
half without the widget (pick `N` = a managed, enabled, non-active account):

```bash
d=~/.claude-swap-backup/widget-requests; N=2
printf '{"switch":{"to":%s},"at":"%s"}' "$N" "$(date -u +%FT%TZ)" > "$d/.tmp"
mv "$d/.tmp" "$d/switch-$(($(date +%s)*1000)).json"
```

Within ~1s the file is gone, `cswap status` shows Account-N, `.err` has
`widget: Switched to Account-N (…), from Account-M (requested …)`, and
`snapshot.json`'s `activeAccountNumber` is N within a second or two (the
engine is woken). Then, from the widget itself: tap a row, and the widget
shows the new active account after its next reload.

Also check:

- **stale is dropped**: name the file 2 minutes back
  (`switch-$((($(date +%s)-120)*1000)).json`) → deleted, no switch, `.err`
  has `widget: ignored stale switch request to N (age 120s, …)`.
- **stale at startup**: stop the backend (close every surface, remove the
  widget, wait for it to retire), drop a fresh request, wait 70s, start the
  backend (`cswap service start`) → the file is deleted and the active
  account does **not** change.
- two fresh files → only the larger `epochMillis` runs; the other logs
  `ignored superseded`.
- unknown `N` (e.g. 99) → `widget: refused switch request to 99: No account
  found …`; a disabled account → `refused … is disabled`; the active account
  → `switch request to N: Already on Account-N …`. The file is deleted every
  time.
- with auto on and the target at or above the threshold, the engine does
  **not** move off it on the woken tick: the manual switch started the
  cooldown (default 300s). Expected: `jq .lastSwitchAt
  ~/.claude-swap-backup/autoswitch_state.json` is the switch's timestamp, the
  backend log shows `no switch: cooldown`, and after the cooldown lapses the
  next tick switches (see ARCHITECTURE, Widget requests). An account at 100%
  still moves at once (`at-limit`).

### Start backend (`cswap service start`)

The widget host app's "Start backend" runs `snapshot.json`'s `cswapCommand`
plus `["service", "start"]`. By hand:

```bash
jq -c .cswapCommand ~/.claude-swap-backup/snapshot.json   # e.g. ["/Users/me/.local/bin/cswap"]
.venv/bin/cswap service start; echo $?
```

1. Backend stopped: prints the `service status` summary with `running (pid …)`,
   exit 0; `launchctl print gui/$UID/com.cswap.auto` shows the plist's
   program is this build.
2. Run it again: same summary, same pid (already running this build — no
   reinstall).
3. Run the global install's `cswap service start` after the dev one: the
   program line flips to the global path (newest caller wins).
4. No surface, no widget placed: the backend retires after the ~30s grace.
   With a widget placed it stays.
5. Failure path: hard to force live; unit-tested (exit 1, `Backend not
   started: …`).

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

## 7. Not yet run live

Everything below is unit-tested with the subprocess, launchd and the files
stubbed, and has never been exercised against the real app. Work through it
in order; each step says what to expect.

- [ ] **Start backend, from the widget.** Stop the backend (close every
      surface, remove every widget, wait for it to retire — `cswap service
      status` says not running). Place a widget again; after ~3 minutes it
      draws stale and offers *Start backend*. Tap it.
      → the host app launches, runs `snapshot.json`'s `cswapCommand` plus
      `["service", "start"]`, and `cswap service status` shows `running (pid
      …)` within a few seconds. `snapshot.json`'s mtime starts advancing
      every ~60s and the widget redraws live on its next reload. Nothing in
      `~/Library/Logs/com.cswap.auto.err` beyond the usual startup lines.

- [ ] **Switch from a widget tap.** With the backend running and at least two
      managed, enabled accounts, tap a non-active account row.
      → within ~1s `cswap status` shows that account; `.err` has `widget:
      Switched to Account-N (email), from Account-M (requested …)`; the
      request file is gone from `~/.claude-swap-backup/widget-requests/`;
      `jq .lastSwitchAt ~/.claude-swap-backup/autoswitch_state.json` is the
      switch's timestamp (the manual cooldown); the widget shows the new
      active account on its next reload. Tapping a **dimmed** (disabled) row
      must log `refused switch request to N: Account-N is disabled` and
      change nothing.

- [ ] **Upgrade-triggered reinstall.** With the backend running, note its pid
      (`cswap service status`). Bump the version (`uv tool upgrade cswap`, or
      edit `__version__` and reinstall the dev build), then open a TUI.
      → `needs_install` sees the plist's `CSWAP_VERSION` differ, boots the
      job out and bootstraps afresh: a **new pid**, and `launchctl print
      gui/$UID/com.cswap.auto` shows `CSWAP_VERSION` equal to the new
      version. The TUI reports the backend as the engine owner, not itself.

- [ ] **Open at Login.** In the menu bar, toggle *Open at Login* off.
      → `~/Library/LaunchAgents/com.cswap.menubar.plist` is deleted (or
      rewritten with `RunAtLoad: false`); log out and in and the menu bar
      does not come back. Toggle it on again → the plist returns with
      `RunAtLoad: true`, and the menu bar is there after the next login.
      Note *Quit* is not this: it leaves the plist alone on purpose.

- [ ] **Retire and return across a logout.** Place a widget, close every
      surface, and confirm the backend stays up (`backend: 1 widget(s)
      placed` in `.err`) with its plist still in `~/Library/LaunchAgents/`.
      Log out and back in without opening anything.
      → `RunAtLoad` starts it; after the 30s grace it asks the app again and
      stays (`service status` shows running, `snapshot.json` keeps
      advancing). Then remove the widget and wait ~5 minutes → `backend: no
      widgets placed`, `.backend-retiring` appears briefly in
      `~/.claude-swap-backup/`, the plist is deleted, the process exits 0,
      and the flag is gone the next time a surface opens. If the app could
      not answer that early in the session, `.err` says
      `placed widgets unknown (…)` and the backend retires — the next
      surface brings it back.

---

## Known gaps — expect these, they are not regressions

- **Five paths have not been run against the real widget/host app** — unit
  tests stub the subprocess, launchd and the files. Runnable steps for each
  are in §7, above: the Start backend URL tap, a switch tap
  on a widget row, an upgrade-triggered reinstall, *Open at Login*, and
  retire/return across a logout. (Placed-widget keep-alive, the request
  directory and `--placed-widgets` **have** been run live — see §6.)
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

Close the TUI and remove the menu bar; the backend retires on its own. (*Quit*
alone keeps the menu bar plist, so it returns at login.)

```bash
.venv/bin/cswap menubar --uninstall-service   # bootout + delete the plist
./widget/build-widget uninstall               # widget
```

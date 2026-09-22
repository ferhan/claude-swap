# cswap widget (macOS)

A WidgetKit widget that shows Claude account usage at a glance on the desktop.

It reads the JSON document `cswap snapshot` produces (see
`src/claude_swap/snapshot_json.py`) from `~/.claude-swap-backup/snapshot.json`.
That schema, and that path, are the entire contract between the Python and the
Swift, which is why the widget lives in this repo rather than its own.

**This is a display surface, not a second front end.** It cannot add or remove
accounts or change `cswap` state itself. Its two actions -- the auto-switch
toggle and "Switch to this account" -- only *ask*: each drops a request file
that the backend applies (see "Auto-switch toggle" and "Switch to this
account" below). "Start backend" hands off to the host app (see "Start
backend"). A sandboxed extension cannot
write `~/.claude.json` or `settings.json`, reach the Keychain, take the switch
locks, or exec `cswap`. All of that stays in the CLI, the TUI and the menu bar.

WidgetKit's own ceiling is separate and looser: it allows `Button(intent:)` and
`Toggle(isOn:intent:)` — no text fields, scrolling, selection or sheets — and
an intent runs in the extension's process, which always has read-write access
to *its own* container. So an intent can change what the widget **shows**
(cycle the displayed account, switch which window is shown, force a refresh),
not what `cswap` **does** -- except by dropping a request into the one
directory it may write, for the backend to apply.

The host app here is a stub whose job is to be the container the widget
extension ships inside (WidgetKit extensions cannot be installed standalone),
and to run `cswap service start` when the widget's Start control asks.

## Prerequisites

- Xcode 16 or later (developed against Xcode 27, macOS 27.0 SDK)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`
- Optional: `brew install swiftlint` — `swiftlint` from this directory
- An Apple Developer account. The extension is sandboxed and signing is
  automatic, so a Team ID is needed to build.

## Build

The `.xcodeproj` is generated and gitignored, so generate it first:

```bash
cd widget
cp Signing.xcconfig.example Signing.xcconfig   # once
xcodegen generate
```

Then open `CswapWidget.xcodeproj`, or build from the command line:

```bash
xcodebuild -scheme CswapWidgetHost -configuration Debug build
```

Re-run `xcodegen generate` after adding, removing or renaming a source file, or
after editing `project.yml`.

## Install

```bash
./build-widget install     # build it signed and register the extension
./build-widget uninstall   # deregister it and remove the app
```

`install` runs the preflight checks below, regenerates the project, builds
Debug into `build/` (gitignored), copies the host app to
`~/Applications/ClaudeSwap.app` and registers it with `lsregister`. Then
add the widget from the gallery: right-click the desktop, Edit Widgets, and
look for **ClaudeSwap**. Nothing is launched — an extension is registered by being
on disk in a known app, not by running one.

Earlier builds installed as `~/Applications/CswapWidgetHost.app` and then
`~/Applications/cswap.app`; `install` and `uninstall` both deregister and
delete either one if it is still there.

Preflight refuses early, with the fix rather than a stack of xcodebuild noise:
no usable `xcodebuild`, no `xcodegen`, no `Signing.xcconfig`, an empty
`DEVELOPMENT_TEAM`, or no matching certificate in the keychain.

`~/Applications` is a choice, not a requirement. pkd registers the extension
from wherever the app happens to sit — verified from a build directory under
`/private/tmp`, from `/Applications` and from a dotfile directory in `$HOME`.
What settles it is that the app has to outlive the build directory, and that
`~/Applications` needs no admin write.

What does break registration is **two registered copies of one extension
bundle id**: pkd keeps whichever LaunchServices saw last and the other
disappears from `pluginkit` entirely. `xcodebuild` registers every app it
builds, so `install` unregisters its own build-directory copy before
registering the installed one. A build from Xcode.app steals it back; re-run
`./build-widget install`, or unregister that copy by hand:

```bash
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister -u <the other .app>
```

What is registered right now:

```bash
pluginkit -m -v -i com.cswap.widget.claudeswap
```

The extension was `com.cswap.widget.extension` until the app was renamed to
ClaudeSwap. chronod caches a widget's descriptor — the gallery's display name
included — keyed on the extension bundle id and the widget `kind`, in a store
under `~/Library/Group Containers` that is TCC-protected, so no script can
clear it; the gallery went on saying "cswap" after every reinstall. The escape
is a new identity: bundle id `com.cswap.widget.claudeswap`, `kind`
`ClaudeSwapWidget`. `install` and `uninstall` deregister anything still held
under the old id. Placed widgets do not survive that change — the old ones
vanish from the desktop and have to be added again.

## Signing: the one step

Set your 10-character Team ID in `Signing.xcconfig` (gitignored, so it is
per-developer):

```
DEVELOPMENT_TEAM = ABCDE12345
```

Find it at <https://developer.apple.com/account> under Membership details.
Without it the build fails with:

```
error: "CswapWidgetHost" has entitlements that require signing with a
development certificate.
```

That failure is signing only — the project configuration itself is fine, which
you can confirm with `xcodebuild ... CODE_SIGNING_ALLOWED=NO build`.

## Entitlements

The extension is sandboxed; the host app is not (see "Start backend" for why).
The extension additionally carries two exceptions:

```xml
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/.claude-swap-backup/snapshot.json</string></array>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
<array><string>/.claude-swap-backup/widget-requests/</string></array>
```

The read-write one is the request drop directory (auto-switch toggle, switch
requests, and reading the host's start marker) and nothing else; see below.

No App Group. The snapshot is written by the user's own `cswap`, installed from
PyPI — a python3 process, with no code signature and so no entitlement, which
`containermanagerd` denies on a group container. The container works fine for a
signed *reader*; it is the writer that cannot get in. So the contract is an
ordinary absolute path plus the narrowest sandbox exception that opens it.

The exception has no trailing slash, so it grants exactly that one file: a
sandboxed reader with it reads `snapshot.json` and gets `EPERM` on
`settings.json` sitting next to it. Nothing else in the backup root —
`credentials/`, `configs/` — is reachable.

Turning the extension's sandbox off instead is not an option. `pkd` refuses to
register an unsandboxed extension at all:

```
pkd: [com.apple.PlugInKit:discovery] rejecting; Ignoring mis-configured
plugin at [.../CswapWidgetExtension.appex]: plug-ins must be sandboxed
```

`Widget/SnapshotFile.url` / `.requestsDirectory` and these entitlements are the
same decisions written twice. They move together or the extension gets `EPERM`.

## Auto-switch toggle

Large and extra-large put a `Toggle(isOn:intent:)` labeled "Auto-switch" on the
auto-switch line, bound to the snapshot's `autoswitch.enabled`. It is drawn by
a custom `ToggleStyle` -- a capsule holding the label, a filled state dot
(green on, red off) and the state in words (`at 85%` / `Off`). Not
`.toggleStyle(.switch)`: AppKit's switch is not one of the controls a widget's
out-of-process renderer can draw, and came out as the yellow "unsupported
view" placeholder.

Dot, words and pending mark all come from one resolved value
(`ToggleResolution`), never from the `Toggle`'s own binding: WidgetKit flips
that binding optimistically on tap, which showed a green dot beside a label
still reading "Off" whenever no backend ever confirmed. With the snapshot
stale the chip is drawn inert and tapping it writes nothing -- the header's
"Start backend" is the action that matters then.

Tapping it runs
`SetAutoswitchIntent` in the extension, which writes
`~/.claude-swap-backup/widget-requests/autoswitch-<epochMillis>.json`
(as `.autoswitch-<epochMillis>.tmp`, then renamed; mode 0600):

```json
{"at": "2026-09-22T05:20:03Z", "autoswitch": {"enabled": false}}
```

The backend creates the directory (0700), applies the newest request to
`settings.json` and republishes the snapshot. The widget never creates the
directory: if it is missing or the write fails, the toggle does not flip and
the line says "backend not running" (while the snapshot is still fresh; once
it is stale the header says "Backend stopped" instead). After a successful write the widget keeps
`{desired, at}` in its own defaults and draws the asked-for state marked
"applying…" until the snapshot agrees, or for 30s, after which the snapshot's
value wins again. Logic: `Shared/AutoswitchToggle.swift`.

## Switch to this account

The selected account's detail -- the extra-large right column, the large
detail view, the medium right column -- carries a "Switch to this account"
chip (`Switch` where narrow), beside "‹ Back" on large. Medium draws it at the
small type scale (`compact`), which is what lets the full wording fit 147pt. The active account shows "Active" instead, and an account whose slot
holds no stored backup (`switchable: false`) shows "Not switchable": the same
rule `cswap switch N` applies. A disabled slot stays switchable (disabled only
leaves automatic rotation), and `kind` is not checked.

Tapping it runs `SwitchAccountIntent` in the extension, which writes
`~/.claude-swap-backup/widget-requests/switch-<epochMillis>.json` (via
`.switch-<epochMillis>.tmp`, mode 0600):

```json
{"at": "2026-09-22T05:20:03Z", "switch": {"to": 3}}
```

The backend applies a request under 60s old through the same path as
`cswap switch 3` and republishes the snapshot. The widget keeps
`{target, at, delivered}` in its own defaults and shows "Switching…" until the
snapshot's `activeAccountNumber` is the target, or for 30s; then "Switch not
applied" with a Retry chip for 30s more. With the snapshot stale the intent
does not write at all -- and the chip is not drawn: "Start backend" takes its
place. Logic: `Shared/AccountSwitch.swift`.

## Start backend

When the snapshot is more than 3 minutes old the header reads "Backend
stopped" (shortened to an icon where tight) followed by a "Start backend"
chip (`Start` where tight).

A widget cannot run a process, and an `AppIntent` in a widget runs in the
sandboxed extension, which cannot exec `cswap`. So the chip is a `Link` to
`claudeswap://start-backend`, a scheme the host app registers in
`CFBundleURLTypes`. A `Link` is the documented way for a macOS 14+ widget to
hand a tap to its app. An intent with `openAppWhenRun` would need the intent
compiled into the host and runs its `perform` in whichever process the system
picks; `OpenURLIntent` is macOS 15+. It is the only `Link` in the widget --
the stray-tap catcher behind everything is still a `RefreshIntent` button, so
a tap that misses every control still does not open the app.

The host app (`App/HostMain.swift`) is `LSUIElement`, so it never shows a Dock
icon unless the user opens it directly (then it switches to a regular app for
as long as its info window is up). On the start URL it:

1. drops `widget-requests/.backend-starting` (`{"at": ...}`; a dotfile, which
   the backend leaves alone), creating the directory 0700 if it is missing,
   and reloads the widget, which then shows "Starting…" while the marker is
   under 30s old and the snapshot still stale;
2. finds cswap: the snapshot's `cswapCommand` argv prefix, else the first
   executable of `~/.local/bin/cswap`, `/opt/homebrew/bin/cswap`,
   `/usr/local/bin/cswap`;
3. runs `<cswap> service start` (20s timeout; PATH extended with those
   directories, since a LaunchServices launch gets launchd's bare PATH);
4. on success waits up to 5s for a snapshot newer than the click, reloads the
   widget and quits; on failure removes the marker and shows an `NSAlert`
   with the exit status and the last lines of output, then quits.

An alert rather than a notification: a notification needs permission granted
beforehand -- the permission prompt would be the first thing the user sees --
and can be silenced, while a failed start is rare and needs acting on.

The host is unsandboxed for this. A sandboxed parent cannot read the snapshot
without an exception, and whatever it execs inherits its sandbox, so `cswap`
could reach neither `~/.claude-swap-backup` nor `launchctl`. pkd's sandbox
requirement applies to plug-ins only; the host of a Developer ID app outside
the App Store does not need one, and hardened runtime stays on.

## Placed-widget query

```bash
~/Applications/ClaudeSwap.app/Contents/MacOS/ClaudeSwap --placed-widgets
{"count": 4}
```

One JSON line with the number of placed ClaudeSwap widgets
(`WidgetCenter.getCurrentConfigurations`), exit 0; on failure a message on
stderr and exit 1 (including a 10s timeout). The argument is handled in
`App/HostMain.swift` before any `NSApplication` exists, so no window opens and
no Dock icon appears. The backend uses it to treat a placed widget as an open
surface. Each placed widget counts once, whatever its size.

Right after chronod restarts (every `./build-widget install` runs
`killall chronod`) it answers `{"count": 0}` for a few seconds. So the backend
never retires on one 0: zero answers (and errors, and a missing app) must hold
across consecutive checks at least 15s apart. A positive count is cached for
five minutes; a 0 is never cached.

## Distribution

The widget ships as a notarized `.dmg` signed with a Developer ID Application
certificate; hardened runtime is on (`ENABLE_HARDENED_RUNTIME: YES`) because
notarization requires it. Users install that — they are not expected to build
from source, and they keep using whatever `cswap` they already have from PyPI.

```bash
xcrun notarytool store-credentials cswap-notary \
    --apple-id you@example.com --team-id ABCDE12345 \
    --password <app-specific password>            # once
./build-widget release
```

`release` archives, exports with `method: developer-id`, builds the DMG, signs
it, notarizes, staples, and prints the path. `ExportOptions.plist` is generated
into `build/` rather than committed, because it carries the Team ID. Set
`NOTARY_PROFILE` if the keychain profile is named something other than
`cswap-notary`.

The export is not interchangeable with a plain `xcodebuild build`: that injects
`com.apple.security.get-task-allow`, which notarization rejects outright. So
`release` proves the exported extension is clean before spending a submission
on it, and stops if it is not:

```bash
codesign -d --entitlements - --xml \
  build/export/ClaudeSwap.app/Contents/PlugIns/CswapWidgetExtension.appex \
  | plutil -p -
```

**`release` is untested.** There is no Developer ID Application certificate on
this machine, so it has only ever been run as far as its certificate check.
Archive, export, DMG, notarization and stapling are written but unrun.

## Layout

```
project.yml                              XcodeGen spec — the real project definition
build-widget                             install / uninstall / release
Signing.xcconfig.example                 template for the gitignored Team ID file
App/HostMain.swift                       entry point; `--placed-widgets`; claudeswap://start-backend
App/CswapWidgetHostApp.swift             stub info window (plain launches only)
App/CswapWidgetHost.entitlements         no sandbox (see "Start backend")
Shared/Snapshot.swift                    schema-v1 decoding (shared with the tests)
Shared/Display.swift                     pure display logic: ramp, severity, formatting, small's paging
Shared/Trend.swift                       24h trend: samples in range, time axis, switch markers
Shared/Navigation.swift                  selection state: select, neighbor, back, scroll, resolve
Shared/AutoswitchToggle.swift            toggle request file + pending-state resolution
Shared/AccountSwitch.swift               switch request file, eligibility, pending-state resolution
Shared/BackendStart.swift                start URL, start marker, "Starting…", finding cswap
Shared/RequestDrop.swift                 atomic dot-temp + rename writes into the drop directory
Widget/CswapWidgetBundle.swift           @main WidgetBundle
Widget/CswapWidget.swift                 provider, Appearance override, widget definition
Widget/Intents.swift                     Appearance config intent, ‹ › page, select, details,
                                         back, scroll, refresh and auto-switch intents,
                                         page/nav/toggle stores
Widget/Components.swift                  ring, bar, badges, window row, pager
Widget/Pages.swift                       small; medium's hero, right column and ‹ › selection pager
Widget/LargePages.swift                  large: list/detail routing, the list, the trend panel
Widget/AutoStatusLine.swift              the auto-switch chip and its state line
Widget/ActionControls.swift              Switch to this account, Start backend
Widget/ExtraLargePage.swift              extra-large master-detail: rows, pace, model usage
Widget/DetailPages.swift                 per-account detail: small's parts, the facts grid, the large view
Widget/SnapshotFile.swift                the only place the snapshot and request paths are decided
Widget/CswapWidgetExtension.entitlements sandbox + snapshot read + request-drop write exceptions
Tests/SnapshotGoldenTests.swift          decodes ../tests/fixtures/snapshot_golden.json
Tests/AutoswitchFixtureTests.swift       decodes Tests/Fixtures/snapshot_autoswitch.json
Tests/DisplayTests.swift                 Shared/Display.swift
Tests/AutoswitchToggleTests.swift        Shared/AutoswitchToggle.swift
Tests/AccountSwitchTests.swift           Shared/AccountSwitch.swift
Tests/BackendStartTests.swift            Shared/BackendStart.swift
```

`CswapWidget.xcodeproj`, `Signing.xcconfig`, `build/` and both generated
`Info.plist` files are gitignored.

## Where the snapshot is read from

```bash
cswap snapshot --out ~/.claude-swap-backup/snapshot.json
```

`~/.claude-swap-backup/` is the directory cswap owns — `settings.json`,
`menubar_settings.json`, `sequence.json`, `configs/`, `credentials/` all live
there. `~/.claude/` is Claude Code's: it prunes that directory itself and
relocates it when `CLAUDE_CONFIG_DIR` is set, neither of which a widget looking
by absolute path can survive.

`write_snapshot` publishes the file 0600 by atomic rename, so a polling reader
never sees it half-written.

## Status

All four sizes (small, medium, large, extra-large), a per-widget Appearance
setting (System/Light/Dark, from Edit Widget), and an auto-switch line with a
toggle on large and extra-large, and "Switch to this account" in the
selected account's detail. When the snapshot is more than 3 minutes old the
header says "Backend stopped · updated 13m ago" instead of the time, with a
"Start backend" chip (both shortened where tight). Small is the one size that
still pages with ‹ ›, alternating a hero and a detail page per account.

Medium, large and extra-large all keep a selection in one `NavState`
(mode, selection, list offset) per size; only large has a detail mode.

Medium is master-detail for one account at a time, at 344×164. The left column
is the compact hero -- initials, name, subtitle, the 5h ring with its ticking
countdown, the weekly bar with its percent and `3d 11h` -- at a fixed 150pt.
The 147pt right column is the same account's detail, and repeats none of it:
‹ 2/6 › and the auto-switch badge on the top line, the email across the full
width below it (10.5pt, scaling to 0.75 before it truncates at the tail), then
the facts grid in its compact form -- org, alias, `kind`/`updated` sharing a
row, status -- at 10pt, and the switch control on the bottom line. "BY MODEL"
is what does not fit in the remaining ~13pt and is the one thing extra-large's
right column has that medium's does not; the trend and the pace strip are the
others.

The ‹ › move the **selection**, not a page: they run the same
`SelectAccountIntent` a row tap runs on the larger sizes, on the account
`Navigation.neighbor` returns, wrapping at both ends. So medium has no detail
page and no `PageStore` entry at all -- selection is its whole navigation.
The auto-switch badge is read-only here (the toggle needs the room large and
extra-large have) and shortens to `⇄ 85%` before it is dropped.

Large and extra-large are master-detail with no pager. The account list is the
same on both: three rows per window at 344pt, each a three-line button that selects it
(default: the active account) -- the name, alias and email both, on a line of
its own, then a `5H` and a `7D` line, each with its bar, percent and countdown
(the 5h one ticking, the weekly one as `3d 11h`). When the list overflows,
▲/▼ move it a window at a time -- widgets cannot scroll.

What differs is where the selection is shown. Extra-large has the room for a
right column beside the list: the account's details, the weekly figures the
rows do not carry (pace against expectation, when the week runs out, spend),
the per-model weekly limits -- the one place Opus/Sonnet/Haiku/Fable appear --
and the 5h trend with its line emphasized.

Large stacks the same thing behind a drill-down. Selecting stays a row tap;
the selected row then grows a "Details ›" button, a second tap that swaps
the list for the detail view -- "‹ Back" and the switch control on one line,
then the account, the facts grid, the per-model rows and a compact 5h trend
(46pt of chart, one axis hint each side, no legend). "Details ›" is an
overlay on the row rather than a button nested in one, which has no defined
winner, and it sits on the name line, where a name can give up width, rather
than beside the bars, which cannot. Two things are left out to fit at
344×344: the pace strip, and the 5h/7d bars -- the list row the tap came from
carries those.

On every size, a tap that misses every control reloads the widget
(`RefreshIntent`) rather than launching the stub host app. The catcher sits
behind the whole widget rect -- content margins are disabled, so that includes
the padding ring -- because there is no `widgetURL` and WidgetKit's default
for an uncaught tap is to open the container app, whose only window says it
is a container. The one `Link`, "Start backend", opens the host on purpose.

The trend's time axis spans the history actually held: from the oldest sample
or auto-switch (at most 24h back) to now, never narrower than an hour, with
the caption and axis hints following it (`last 40m`, `last 6h`, `last 24h`).
Switches older than 24h are not drawn.

Large and extra-large use a legible type scale (the `largeType` environment
flag): nothing under 11pt, percents and countdowns 13-14pt in the primary
color, `.secondary` only for field labels and subtitles. Under System
appearance the container background is the window background at 88% opacity:
a lighter fill let Liquid Glass wash the text out on a light desktop.

The `autoswitch` block and 5h `history` are additive and optional: without them
the threshold defaults to 90%, next-up is omitted and the extra-large trend
panel says so. `Tests/Fixtures/snapshot_autoswitch.json` is a hand-written
fixture for those fields until the Python producer emits them and the golden
fixture can cover them.

Page and navigation state live in the extension's own defaults, keyed by size:
WidgetKit gives no identifier for a placed widget, so two widgets of the same
size page, select and scroll together.

Tests:

```bash
xcodebuild -scheme CswapWidgetTests -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

`Tests/SnapshotGoldenTests.swift` decodes `tests/fixtures/snapshot_golden.json`
— the same committed file `tests/test_snapshot_json.py` asserts the Python
producer against. It is bundled as a test resource from its repo path, never
copied. The two halves move together or the widget silently fails to decode a
shipped snapshot.

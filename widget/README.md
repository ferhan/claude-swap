# cswap widget (macOS)

A WidgetKit widget that shows Claude account usage at a glance on the desktop.

It reads the JSON document `cswap snapshot` produces (see
`src/claude_swap/snapshot_json.py`) from `~/.claude-swap-backup/snapshot.json`.
That schema, and that path, are the entire contract between the Python and the
Swift, which is why the widget lives in this repo rather than its own.

**This is a display surface, not a second front end.** It cannot switch
accounts, add or remove them, or change `cswap` state — with one exception,
the auto-switch toggle, which only *asks*: it drops a request file that the
backend applies (see "Auto-switch toggle" below). A sandboxed extension cannot
write `~/.claude.json` or `settings.json`, reach the Keychain, take the switch
locks, or exec `cswap`. All of that stays in the CLI, the TUI and the menu bar.

WidgetKit's own ceiling is separate and looser: it allows `Button(intent:)` and
`Toggle(isOn:intent:)` — no text fields, scrolling, selection or sheets — and
an intent runs in the extension's process, which always has read-write access
to *its own* container. So an intent can change what the widget **shows**
(cycle the displayed account, switch which window is shown, force a refresh),
not what `cswap` **does** -- except by dropping a request into the one
directory it may write, for the backend to apply.

The host app here is a stub whose only job is to be the container the widget
extension ships inside; WidgetKit extensions cannot be installed standalone.

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

Both targets are sandboxed. The extension additionally carries two exceptions:

```xml
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/.claude-swap-backup/snapshot.json</string></array>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-write</key>
<array><string>/.claude-swap-backup/widget-requests/</string></array>
```

The read-write one is the auto-switch toggle's drop directory and nothing
else; see below.

No App Group. The snapshot is written by the user's own `cswap`, installed from
PyPI — a python3 process, with no code signature and so no entitlement, which
`containermanagerd` denies on a group container. The container works fine for a
signed *reader*; it is the writer that cannot get in. So the contract is an
ordinary absolute path plus the narrowest sandbox exception that opens it.

The exception has no trailing slash, so it grants exactly that one file: a
sandboxed reader with it reads `snapshot.json` and gets `EPERM` on
`settings.json` sitting next to it. Nothing else in the backup root —
`credentials/`, `configs/` — is reachable.

Turning the sandbox off instead is not an option. `pkd` refuses to register an
unsandboxed extension at all:

```
pkd: [com.apple.PlugInKit:discovery] rejecting; Ignoring mis-configured
plugin at [.../CswapWidgetExtension.appex]: plug-ins must be sandboxed
```

`Widget/SnapshotFile.url` / `.requestsDirectory` and these entitlements are the
same decisions written twice. They move together or the extension gets `EPERM`.

## Auto-switch toggle

Large and extra-large put a native, regular-size `Toggle(isOn:intent:)`
labeled "Auto-switch" with a symbol on the auto-switch line, bound to the snapshot's `autoswitch.enabled`. Tapping it runs
`SetAutoswitchIntent` in the extension, which writes
`~/.claude-swap-backup/widget-requests/autoswitch-<epochMillis>.json`
(as `.autoswitch-<epochMillis>.tmp`, then renamed; mode 0600):

```json
{"at": "2026-09-22T05:20:03Z", "autoswitch": {"enabled": false}}
```

The backend creates the directory (0700), applies the newest request to
`settings.json` and republishes the snapshot. The widget never creates the
directory: if it is missing or the write fails, the toggle does not flip and
the line says "backend not running". After a successful write the widget keeps
`{desired, at}` in its own defaults and draws the asked-for state marked
"applying…" until the snapshot agrees, or for 30s, after which the snapshot's
value wins again. Logic: `Shared/AutoswitchToggle.swift`.

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
App/HostMain.swift                       entry point; `--placed-widgets` CLI mode
App/CswapWidgetHostApp.swift             stub host window
App/CswapWidgetHost.entitlements         sandbox, no exceptions
Shared/Snapshot.swift                    schema-v1 decoding (shared with the tests)
Shared/Display.swift                     pure display logic: ramp, severity, paging, trend
Shared/Navigation.swift                  list navigation state: select, back, scroll, resolve
Shared/AutoswitchToggle.swift            toggle request file + pending-state resolution
Widget/CswapWidgetBundle.swift           @main WidgetBundle
Widget/CswapWidget.swift                 provider, Appearance override, widget definition
Widget/Intents.swift                     Appearance config intent, ‹ › page, select, scroll,
                                         refresh and auto-switch intents, page/nav/toggle stores
Widget/Components.swift                  ring, bar, badges, window row, pager
Widget/Pages.swift                       small and medium layouts
Widget/LargePages.swift                  large layout, pace + trend panels
Widget/ExtraLargePage.swift              extra-large master-detail
Widget/DetailPages.swift                 per-account detail page
Widget/SnapshotFile.swift                the only place the snapshot and request paths are decided
Widget/CswapWidgetExtension.entitlements sandbox + snapshot read + request-drop write exceptions
Tests/SnapshotGoldenTests.swift          decodes ../tests/fixtures/snapshot_golden.json
Tests/AutoswitchFixtureTests.swift       decodes Tests/Fixtures/snapshot_autoswitch.json
Tests/DisplayTests.swift                 Shared/Display.swift
Tests/AutoswitchToggleTests.swift        Shared/AutoswitchToggle.swift
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
toggle on large and extra-large. When the snapshot is more than 3 minutes old
the header says "Backend not running · updated 13m ago" instead of the time
(shortened to fit beside the large pager). Small, medium and large page with ‹ ›, with a detail page per
account.

Extra-large is master-detail with no pager. The left column lists the
accounts, four per window; each row is a two-line button that selects it
(default: the active account): name and subtitle on the left, and each
window's percent over its reset on the right (the 5h one ticking, the weekly
one as `3d 11h`). When the list overflows, ▲/▼ move it a
window at a time -- widgets cannot scroll. The right column shows the selected account's weekly pace, its details
and windows, and the 5h trend with its line emphasized. A tap that misses every
control reloads the widget rather than opening the stub host app.

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

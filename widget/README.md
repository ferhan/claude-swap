# cswap widget (macOS)

A WidgetKit widget that shows Claude account usage at a glance on the desktop.

It reads the JSON document `cswap snapshot` produces (see
`src/claude_swap/snapshot_json.py`) from `~/.claude-swap-backup/snapshot.json`.
That schema, and that path, are the entire contract between the Python and the
Swift, which is why the widget lives in this repo rather than its own.

**This is a display surface, not a second front end — and it is view-only.**
It cannot switch accounts, add or remove them, or change any other `cswap`
state. A sandboxed extension holding a single read-only file exception cannot
write `~/.claude.json`, reach the Keychain, take the switch locks, or exec
`cswap`. All of that stays in the CLI, the TUI and the menu bar.

WidgetKit's own ceiling is separate and looser: it allows `Button(intent:)` and
`Toggle(isOn:intent:)` — no text fields, scrolling, selection or sheets — and
an intent runs in the extension's process, which always has read-write access
to *its own* container. So an intent can change what the widget **shows**
(cycle the displayed account, switch which window is shown, force a refresh),
just not what `cswap` **does**.

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
`~/Applications/cswap.app` and registers it with `lsregister`. Then
add the widget from the gallery: right-click the desktop, Edit Widgets, and
look for **cswap**. Nothing is launched — an extension is registered by being
on disk in a known app, not by running one.

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
pluginkit -m -v -i com.cswap.widget.extension
```

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

Both targets are sandboxed. The extension additionally carries one exception:

```xml
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array><string>/.claude-swap-backup/snapshot.json</string></array>
```

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

`Widget/SnapshotFile.url` and this entitlement are the same decision written
twice. They move together or the extension gets `EPERM`.

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
  build/export/cswap.app/Contents/PlugIns/CswapWidgetExtension.appex \
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
App/CswapWidgetHostApp.swift             stub host window
App/CswapWidgetHost.entitlements         sandbox, no exceptions
Shared/Snapshot.swift                    schema-v1 decoding (shared with the tests)
Shared/Display.swift                     pure display logic: ramp, severity, paging, trend
Widget/CswapWidgetBundle.swift           @main WidgetBundle
Widget/CswapWidget.swift                 provider, Appearance override, widget definition
Widget/Intents.swift                     Appearance config intent, ‹ › page intent + store
Widget/Components.swift                  ring, bar, badges, window row, pager
Widget/Pages.swift                       small and medium layouts
Widget/LargePages.swift                  large layout, extra-large pace + trend panels
Widget/DetailPages.swift                 per-account detail page
Widget/SnapshotFile.swift                the only place the snapshot path is decided
Widget/CswapWidgetExtension.entitlements sandbox + the one snapshot read exception
Tests/SnapshotGoldenTests.swift          decodes ../tests/fixtures/snapshot_golden.json
Tests/AutoswitchFixtureTests.swift       decodes Tests/Fixtures/snapshot_autoswitch.json
Tests/DisplayTests.swift                 Shared/Display.swift
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

All four sizes (small, medium, large, extra-large), ‹ › paging with a detail
page per account, a per-widget Appearance setting (System/Light/Dark, from Edit
Widget), and a read-only auto-switch status line.

The `autoswitch` block and 5h `history` are additive and optional: without them
the threshold defaults to 90%, next-up is omitted and the extra-large trend
panel says so. `Tests/Fixtures/snapshot_autoswitch.json` is a hand-written
fixture for those fields until the Python producer emits them and the golden
fixture can cover them.

Page state lives in the extension's own defaults, keyed by size: WidgetKit
gives no identifier for a placed widget, so two widgets of the same size page
together.

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

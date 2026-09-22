"""``cswap snapshot`` — the whole display state as one JSON document.

A one-shot projection of ``AccountsSnapshot`` (the aggregate the TUI and the
menu bar render) for non-Python shells that must not re-implement any of this:
it carries ``switchable``/``kind``, which ``--list --json`` drops, and every
value the menu bar derives at render time is precomputed here.

Two deliberate differences from the ``--list --json`` row:

* **Display-grade, not decision-grade usage.** ``--list`` serves
  ``UsageEntry.decision_value()`` (last-good only while recent enough to act
  on), because a script keying on ``usageStatus == "ok"`` may switch accounts.
  A display shows what the menu bar shows — the last-good measurement, however
  old — annotated with ``usageFetchedAt``/``usageAgeSeconds`` so the consumer
  can grey it out. Do not drive a switch off this payload.
* **Weekly windows are rolled forward** (see ``pace.rolled_weekly_window``): a
  weekly window whose reset has passed is reported zeroed, not stale, exactly
  as the menu bar draws it.
* **``usage.scoped[]`` is grouped by model family** (see
  ``_collapse_scoped_by_family``). The API names per-model weekly windows by
  full display name, so "Claude Opus 4.8" and "Opus 5" arrive as two rows for
  what a display should show as one line. Here they collapse onto the family
  word; ``--list --json`` still serves the raw windows.

Raw ``resetsAt`` survives every projection, so a widget counts down live
without calling back in.

Additive fields (no schema bump; old readers ignore them):

* ``usage.fiveHour.history`` — 24h of 5h-window samples from the backend's
  ``usage_history`` store, present whenever the payload was built with history
  (the engine's file and ``cswap snapshot`` both are).
* top-level ``autoswitch`` — engine state (enabled, effective threshold, next
  candidate, 24h of switches). Only the engine can answer it, so only the
  engine-published file carries it; ``cswap snapshot`` omits the key.
* top-level ``cswapCommand`` — the argv prefix that runs this cswap
  (``launch_agent.resolve_program()``, what the backend plist runs), so the
  widget's host app can run ``cswapCommand + ["service", "start"]``. Engine
  file only, like ``autoswitch``.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

from claude_swap import pace, paths
from claude_swap.exceptions import ClaudeSwitchError
from claude_swap.fsutil import replace_with_retry
from claude_swap.json_output import (
    SCHEMA_VERSION,
    iso_timestamp,
    usage_fields,
    usage_freshness_fields,
)
from claude_swap.models import AccountSnapshot, AccountsSnapshot
from claude_swap.snapshot_source import SnapshotSource
from claude_swap.switcher import ClaudeAccountSwitcher
from claude_swap.usage_history import UsageHistory


SNAPSHOT_FILENAME = "snapshot.json"


def default_snapshot_path() -> Path:
    """Where ``cswap auto`` publishes the snapshot for other processes.

    A PUBLIC CONTRACT, spelled here only: the separately-distributed macOS
    widget is sandboxed with a file-scoped entitlement for this exact
    absolute path, so moving the file blinds an app that cannot be shipped a
    new path in the same release.
    """
    return paths.get_backup_root() / SNAPSHOT_FILENAME


def _rolled_usage(usage: dict, now: float) -> dict:
    """A copy of the internal usage dict with every weekly window rolled forward.

    The 5h window is untouched: it has no fixed cadence to roll to, and it is
    refetched far more often than it could go stale by a whole cycle.
    """
    out = dict(usage)
    if "seven_day" in usage:
        out["seven_day"] = pace.rolled_weekly_window(usage["seven_day"], now)
    if usage.get("scoped"):
        out["scoped"] = [
            pace.rolled_weekly_window(window, now) for window in usage["scoped"]
        ]
    return out


# The model families the display layer collapses ``usage.scoped[]`` rows into.
# Matched as a standalone word against the API's display name, case-insensitive
# (e.g. "Claude Opus 4.8", "Opus 5", "opus" all match "Opus"); a name matching
# none of these passes through unchanged, under its own (unmodified) name.
_FAMILY_PATTERN = re.compile(r"\b(opus|sonnet|haiku|fable)\b", re.IGNORECASE)


def _model_family(name: str) -> str | None:
    """The canonical family word in a scoped window's display name, or
    ``None`` when it matches no known family."""
    match = _FAMILY_PATTERN.search(name)
    return match.group(1).capitalize() if match else None


def _collapse_scoped_by_family(scoped: list[dict]) -> list[dict]:
    """Group ``usage.scoped[]`` rows by model family so versions (e.g. "Claude
    Opus 4.8" vs "Opus 5") never appear as separate rows in a display. Names
    matching no family pass through unchanged. Order of first appearance
    (by family, or by row for a pass-through name) is preserved.

    Merge rule when several windows collapse into one family: ``pct`` is the
    max across the group (the binding constraint); ``maxed`` is true if any
    window in the group is maxed; every other field — ``resetsAt``,
    ``countdown``/``clock``, the pace fields — is taken from whichever window
    carries that max ``pct`` (a tie keeps the first one seen), since that's
    the window actually gating and its reset/pace are the ones that matter.
    """
    groups: list[tuple[str | None, list[dict]]] = []
    family_index: dict[str, int] = {}
    for window in scoped:
        family = _model_family(window["name"])
        if family is None:
            groups.append((None, [window]))
            continue
        idx = family_index.get(family)
        if idx is None:
            family_index[family] = len(groups)
            groups.append((family, [window]))
        else:
            groups[idx][1].append(window)

    out = []
    for family, windows in groups:
        if family is None:
            out.append(windows[0])
            continue
        binding = max(windows, key=lambda w: w["pct"])
        merged = dict(binding)
        merged["name"] = family
        merged["maxed"] = any(w.get("maxed") for w in windows)
        out.append(merged)
    return out


def _account_row(
    acc: AccountSnapshot, now: float, history: list | None = None
) -> dict:
    """One account's row: the aggregate's fields plus its projected usage."""
    entry = acc.usage
    value = entry.sentinel if entry.sentinel else entry.last_good
    if isinstance(value, dict):
        value = _rolled_usage(value, now)
    status, usage = usage_fields(value, entry.fetched_at)
    if usage is not None:
        for window in usage.get("scoped", ()):
            # The menu bar's "(!)" marker — a maxed per-model limit is the usual
            # reason to switch, and it outranks the ahead-of-pace marker.
            window["maxed"] = window["pct"] >= 100
        if usage.get("scoped"):
            usage["scoped"] = _collapse_scoped_by_family(usage["scoped"])
        if history is not None and "fiveHour" in usage:
            usage["fiveHour"]["history"] = [
                {"t": iso_timestamp(t), "pct": pct} for t, pct in history
            ]
    row = {
        "number": int(acc.number),
        "email": acc.email,
        "organizationName": acc.org_name,
        "organizationUuid": acc.org_uuid,
        "isOrganization": bool(acc.org_uuid),
        "active": acc.is_active,
        "kind": acc.kind,
        "switchable": acc.switchable,
        "usageStatus": status,
        "usage": usage,
    }
    if acc.alias:
        row["alias"] = acc.alias
    if acc.disabled:
        row["disabled"] = True
    if usage is not None:
        row.update(usage_freshness_fields(entry.fetched_at, entry.age_s))
    return row


def snapshot_payload(
    snap: AccountsSnapshot,
    *,
    history: dict[str, list] | None = None,
    autoswitch: dict | None = None,
    cswap_command: list[str] | None = None,
) -> dict:
    """Project an ``AccountsSnapshot`` to the schema-v1 snapshot payload.

    Pure: ``snap.taken_at`` is the only clock, so the roll-forward and the
    payload's own ``takenAt`` can never disagree. ``history`` is
    ``{number: [(t, pct), ...]}`` (see ``UsageHistory.five_hour``); when given,
    every ``fiveHour`` window carries a ``history`` list (empty if the account
    has none). ``autoswitch`` is the engine's block and ``cswap_command``
    its argv prefix, both emitted verbatim.
    """
    now = snap.taken_at
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "takenAt": iso_timestamp(now),
        "activeAccountNumber": (
            int(snap.active_number) if snap.active_number is not None else None
        ),
        "accounts": [
            _account_row(
                acc,
                now,
                None if history is None else history.get(acc.number, []),
            )
            for acc in snap.accounts
        ],
    }
    if autoswitch is not None:
        payload["autoswitch"] = autoswitch
    if cswap_command is not None:
        payload["cswapCommand"] = list(cswap_command)
    return payload


def history_for(backup_dir: Path, snap: AccountsSnapshot) -> dict[str, list]:
    """The stored 5h history for the accounts in ``snap`` (read-only)."""
    return UsageHistory(backup_dir).five_hour(
        {acc.number: acc.email for acc in snap.accounts}, snap.taken_at
    )


def take_snapshot(switcher: ClaudeAccountSwitcher) -> dict:
    """One paced pass through the shared read path, serialized.

    Goes through ``SnapshotSource`` rather than ``accounts_snapshot`` directly
    so this command is subject to the same store-governed pacing, serve TTL and
    backoff as the menu bar — a widget polling every few seconds must not be
    able to produce network traffic the menu bar could not. Blocking (file
    locks, keychain, network).
    """
    snap = SnapshotSource(switcher).take()
    return snapshot_payload(snap, history=history_for(switcher.backup_dir, snap))


def write_snapshot(path: Path, payload: dict) -> None:
    """Atomically write ``payload`` to ``path`` at 0600.

    The reader is another process that may poll while we write, so the file is
    published by rename and is never observed half-written. ``mkstemp`` (0600
    from creation, umask-independent) rather than write-then-chmod: the payload
    carries emails and organization UUIDs, and a write-then-chmod sequence
    leaves the temp file world-readable for the window in between. Same pattern
    as ``transfer.py``/``settings.py``.

    Only the target file is hardened — the parent directory is the caller's
    (``--out`` can point anywhere) and is left at whatever mode it has.

    **Writes THROUGH a symlink, never over it**, exactly as
    ``settings.atomic_write_json`` does and for the same reason (#192/#193): a
    rename swaps a directory entry without following links, so renaming onto a
    symlinked path detaches the link — the write succeeds, the content is
    right, and the target silently stops being updated. That is a live
    possibility here: ``--out`` points wherever the caller says, and the
    default path is one a widget reads by absolute path. The temp file is
    created beside the RESOLVED target so the rename stays on one filesystem,
    and a dangling link still writes where it points.
    """
    if path.is_dir():
        raise ClaudeSwitchError(
            f"--out must be a file path, not a directory: {path}"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    target = Path(os.path.realpath(path)) if path.is_symlink() else path
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(target.parent), suffix=".tmp")
    try:
        os.write(fd, json.dumps(payload, indent=2).encode("utf-8"))
        os.close(fd)
        fd = -1
        replace_with_retry(tmp_path, str(target))
        if sys.platform != "win32":
            os.chmod(str(target), 0o600)
    except BaseException:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

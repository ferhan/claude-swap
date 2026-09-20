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

Raw ``resetsAt`` survives every projection, so a widget counts down live
without calling back in.
"""

from __future__ import annotations

import json
import os
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


def _account_row(acc: AccountSnapshot, now: float) -> dict:
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


def snapshot_payload(snap: AccountsSnapshot) -> dict:
    """Project an ``AccountsSnapshot`` to the schema-v1 snapshot payload.

    Pure: ``snap.taken_at`` is the only clock, so the roll-forward and the
    payload's own ``takenAt`` can never disagree.
    """
    now = snap.taken_at
    return {
        "schemaVersion": SCHEMA_VERSION,
        "takenAt": iso_timestamp(now),
        "activeAccountNumber": (
            int(snap.active_number) if snap.active_number is not None else None
        ),
        "accounts": [_account_row(acc, now) for acc in snap.accounts],
    }


def take_snapshot(switcher: ClaudeAccountSwitcher) -> dict:
    """One paced pass through the shared read path, serialized.

    Goes through ``SnapshotSource`` rather than ``accounts_snapshot`` directly
    so this command is subject to the same store-governed pacing, serve TTL and
    backoff as the menu bar — a widget polling every few seconds must not be
    able to produce network traffic the menu bar could not. Blocking (file
    locks, keychain, network).
    """
    return snapshot_payload(SnapshotSource(switcher).take())


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
    """
    if path.is_dir():
        raise ClaudeSwitchError(
            f"--out must be a file path, not a directory: {path}"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), suffix=".tmp")
    try:
        os.write(fd, json.dumps(payload, indent=2).encode("utf-8"))
        os.close(fd)
        fd = -1
        replace_with_retry(tmp_path, str(path))
        if sys.platform != "win32":
            os.chmod(str(path), 0o600)
    except BaseException:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

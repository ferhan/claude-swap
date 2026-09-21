"""24h display history for the snapshot: 5h-window samples and auto-switches.

Backend-owned, display-grade state in ``<backup_root>/usage_history.json``.
Only the engine writes it (samples in ``_write_snapshot``, switches in
``_perform``, never under ``--dry-run``); ``cswap snapshot`` only reads it.
Read-modify-write under its own file lock, published by
``settings.atomic_write_json`` (atomic rename, 0600) like
``autoswitch_state.json`` beside it.

Samples are keyed by account number and tagged with the slot's email, so a
slot re-used by another login starts a fresh series instead of inheriting one.
A sample is the measurement's own ``fetched_at`` and 5h ``pct``: a tick that
fetched nothing appends nothing. Downsampled to one point per 5-minute bucket
(the latest wins) and pruned to 24h, so a series never exceeds 288 points.
Nothing here is decision input.
"""

from __future__ import annotations

import json
from pathlib import Path

from claude_swap.locking import FileLock
from claude_swap.settings import atomic_write_json

HISTORY_FILENAME = "usage_history.json"
HISTORY_SCHEMA_VERSION = 1
WINDOW_S = 24 * 3600.0
BUCKET_S = 300.0
MAX_POINTS = int(WINDOW_S // BUCKET_S)  # 288


class UsageHistory:
    def __init__(self, backup_dir: Path) -> None:
        self.path = backup_dir / HISTORY_FILENAME
        self._lock_path = backup_dir / ".usage_history.lock"

    # -- read -------------------------------------------------------------------

    def _read(self) -> dict:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError, UnicodeDecodeError):
            return {}
        return raw if isinstance(raw, dict) else {}

    def five_hour(self, emails: dict[str, str], now: float) -> dict[str, list]:
        """``{number: [(t, pct), ...]}`` within 24h, oldest first.

        ``emails`` is the current roster (number -> email): a series recorded
        under a different email belongs to a previous occupant of the slot
        and is not served.
        """
        series = self._read().get("fiveHour")
        if not isinstance(series, dict):
            return {}
        out: dict[str, list] = {}
        for number, email in emails.items():
            row = series.get(number)
            if not isinstance(row, dict) or row.get("email") != email:
                continue
            out[number] = _prune(_valid_samples(row.get("samples")), now)
        return out

    def switches(self, now: float) -> list[dict]:
        """Auto-switch events within 24h, oldest first."""
        return _prune_switches(self._read().get("switches"), now)

    # -- write (engine only) ----------------------------------------------------

    def record_samples(
        self, samples: dict[str, tuple[str, float, float]], now: float
    ) -> None:
        """Add ``{number: (email, fetched_at, pct)}``; writes only on change.

        A sample no newer than the series' last point is the measurement
        already recorded and is dropped, so calling this every tick with the
        store's current rows is idempotent.
        """
        with FileLock(self._lock_path):
            data = self._read()
            series = data.get("fiveHour")
            if not isinstance(series, dict):
                series = {}
            changed = False
            for number, (email, t, pct) in samples.items():
                row = series.get(number)
                if not isinstance(row, dict) or row.get("email") != email:
                    row = {"email": email, "samples": []}
                    series[number] = row
                    changed = True
                points = _valid_samples(row.get("samples"))
                if points and t <= points[-1][0]:
                    continue
                if points and t // BUCKET_S == points[-1][0] // BUCKET_S:
                    points[-1] = [t, pct]
                else:
                    points.append([t, pct])
                row["samples"] = _prune(points, now)
                changed = True
            if not changed:
                return
            data["schemaVersion"] = HISTORY_SCHEMA_VERSION
            data["fiveHour"] = series
            data["switches"] = _prune_switches(data.get("switches"), now)
            atomic_write_json(self.path, data)

    def record_switch(self, at: float, from_number: int, to_number: int) -> None:
        with FileLock(self._lock_path):
            data = self._read()
            switches = _prune_switches(data.get("switches"), at)
            switches.append({"at": at, "from": from_number, "to": to_number})
            data["schemaVersion"] = HISTORY_SCHEMA_VERSION
            data["switches"] = switches
            atomic_write_json(self.path, data)


def _valid_samples(raw) -> list[list[float]]:
    if not isinstance(raw, list):
        return []
    return [
        [float(p[0]), float(p[1])]
        for p in raw
        if isinstance(p, list)
        and len(p) == 2
        and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in p)
    ]


def _prune(points: list[list[float]], now: float) -> list[list[float]]:
    return [p for p in points if p[0] >= now - WINDOW_S][-MAX_POINTS:]


def _prune_switches(raw, now: float) -> list[dict]:
    if not isinstance(raw, list):
        return []
    return [
        s
        for s in raw
        if isinstance(s, dict)
        and isinstance(s.get("at"), (int, float))
        and isinstance(s.get("from"), int)
        and isinstance(s.get("to"), int)
        and s["at"] >= now - WINDOW_S
    ]

"""Notice state changes made anywhere, without being told about them.

Detection, not notification (ARCHITECTURE.md, "How surfaces stay current").
Nothing pushes: a surface ``stat()``s the files that hold state on the 1s tick
it already runs, re-reads only the ones whose mtime moved, and reports a
change only when the value it actually cares about differs. That works no
matter which process made the change -- ``cswap switch`` in a terminal, the
backend, another open surface -- survives either side crashing, and leaves no
subscription to leak.

The value comparison is not belt-and-braces. ``~/.claude.json`` is Claude
Code's own file and it is rewritten constantly for reasons that have nothing
to do with which account is logged in (project history, tips, onboarding
flags), so an mtime gate alone would repaint every second. Extracting the part
cswap reflects and comparing *that* makes a no-op rewrite cost one stat and
one parse, and no repaint.

Only STATE lives here -- the active login, the account list, aliases, disabled
flags, and the ``autoswitch.*`` / ``ui.*`` policy. All of it is a cheap local
file read: no Keychain, no network, no usage API. That is what makes a
per-second cadence affordable, and it is why measurements (usage percentages)
are deliberately NOT triggered from here: ``UsageStore.reserve`` paces those
identically whoever asks, so checking them more often would change nothing but
the cost.

``mappings.json`` (``cswap map``) is deliberately not watched: neither the TUI
nor the menu bar renders directory mappings, so there is nothing for a change
to repaint. It is named here so adding it is one line the day a surface shows
them.
"""

from __future__ import annotations

import json
from pathlib import Path

# The three kinds of state, and where each is persisted.
ACTIVE = "active"  # ~/.claude.json (paths.get_global_config_path) -- active login
ACCOUNTS = "accounts"  # <backup>/sequence.json -- slots, aliases, disabled flags
SETTINGS = "settings"  # <backup>/settings.json -- autoswitch.* and ui.*


def _read_json(path: Path):
    """The file's parsed contents, or None if it is absent or unreadable."""
    try:
        data = json.loads(path.read_bytes())
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _active_identity(path: Path):
    """The only part of Claude Code's config that cswap reflects."""
    data = _read_json(path)
    return None if data is None else data.get("oauthAccount")


def _accounts_value(path: Path):
    """``sequence.json`` minus its save timestamp.

    ``lastUpdated`` moves on every write, including writes that only back-fill
    an account uuid behind the user's back -- so it has to be excluded or those
    become phantom changes and a repaint nobody asked for.
    """
    data = _read_json(path)
    if data is None:
        return None
    return {key: value for key, value in data.items() if key != "lastUpdated"}


class StateWatcher:
    """One mtime-gated, value-compared watch per state file.

    Construct it with the surface's config path and backup root; call
    :meth:`poll` on the surface's 1s tick and act on the names it returns.
    Construction primes the marks from the files as they are now, so the first
    poll reports what changed since the surface started -- not "everything".
    """

    def __init__(self, config_path: Path, backup_dir: Path) -> None:
        backup = Path(backup_dir)
        self._sources = {
            ACTIVE: (Path(config_path), _active_identity),
            ACCOUNTS: (backup / "sequence.json", _accounts_value),
            SETTINGS: (backup / "settings.json", _read_json),
        }
        self._marks: dict[str, tuple[float, object]] = {}
        for name in self._sources:
            self._marks[name] = self._sample(name)

    def _sample(self, name: str) -> tuple[float, object]:
        path, reader = self._sources[name]
        try:
            mtime = path.stat().st_mtime
        except OSError:
            return (0.0, None)  # absent files compare equal to each other
        previous = self._marks.get(name)
        if previous is not None and previous[0] == mtime:
            return previous  # the mtime gate: nothing moved, so don't parse
        return (mtime, reader(path))

    def poll(self) -> set[str]:
        """Which state files changed *value* since the last poll."""
        changed = set()
        for name in self._sources:
            sample = self._sample(name)
            if sample[1] != self._marks[name][1]:
                changed.add(name)
            self._marks[name] = sample
        return changed

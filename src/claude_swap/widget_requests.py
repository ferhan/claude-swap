"""The widget's one write path: auto-switch on/off requests in a drop directory.

The sandboxed widget holds a read-write file exception on exactly
``<backup>/widget-requests/`` and nothing else, so it cannot run ``cswap`` or
touch ``settings.json``. It drops ``autoswitch-<epochMillis>.json`` files there
(temp + rename; temps start with ``.``), each
``{"autoswitch": {"enabled": bool}, "at": "<ISO8601>"}``. The backend picks
them up, applies the newest through the same writer as ``cswap config set``,
and deletes every file it looked at. The widget cannot create the directory
itself, so the backend does, at startup.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from claude_swap.settings import load_settings, set_setting

REQUESTS_DIRNAME = "widget-requests"
_REQUEST_NAME = re.compile(r"^autoswitch-(\d+)\.json$")


def requests_dir(backup_dir: Path) -> Path:
    return Path(backup_dir) / REQUESTS_DIRNAME


def ensure_requests_dir(backup_dir: Path) -> Path:
    """Create the drop directory (0700) if it is missing."""
    path = requests_dir(backup_dir)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    return path


def _parse(path: Path) -> tuple[bool, str] | None:
    """``(enabled, at)`` from a request file, or None if it is not one."""
    try:
        data = json.loads(path.read_text())
        enabled = data["autoswitch"]["enabled"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not isinstance(enabled, bool):
        return None
    at = data.get("at")
    return enabled, at if isinstance(at, str) else "?"


def apply_pending(backup_dir: Path) -> bool:
    """Apply the newest valid request and delete every non-dot file.

    Returns True when ``autoswitch.enabled`` actually changed. Newest is the
    largest ``epochMillis`` in the name; the ``at`` field is for the log only.
    Dotfiles are the widget's in-flight temps and are left alone.
    """
    try:
        entries = [p for p in requests_dir(backup_dir).iterdir()
                   if not p.name.startswith(".") and p.is_file()]
    except OSError:
        return False
    if not entries:
        return False
    newest: tuple[int, str, bool, str] | None = None
    for path in entries:
        match = _REQUEST_NAME.match(path.name)
        parsed = _parse(path) if match else None
        if parsed is not None:
            key = (int(match.group(1)), path.name, *parsed)
            if newest is None or key[:2] > newest[:2]:
                newest = key
        path.unlink(missing_ok=True)
    if newest is None:
        return False
    _, _, enabled, at = newest
    if load_settings(Path(backup_dir)).enabled == enabled:
        return False
    set_setting(Path(backup_dir), "autoswitch.enabled", "true" if enabled else "false")
    print(
        f"widget: autoswitch.enabled -> {str(enabled).lower()} (requested {at})",
        file=sys.stderr,
        flush=True,
    )
    return True

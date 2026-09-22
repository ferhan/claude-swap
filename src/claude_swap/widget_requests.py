"""The widget's one write path: requests in a drop directory.

The sandboxed widget holds a read-write file exception on exactly
``<backup>/widget-requests/`` and nothing else, so it cannot run ``cswap`` or
touch ``settings.json``. It drops two kinds of file there (temp + rename;
temps start with ``.``):

* ``autoswitch-<epochMillis>.json`` — ``{"autoswitch": {"enabled": bool},
  "at": "<ISO8601>"}``. The newest is applied through the same writer as
  ``cswap config set``, however long it waited.
* ``switch-<epochMillis>.json`` — ``{"switch": {"to": int}, "at": ...}``. The
  newest is applied through ``switch_to``, the path behind ``cswap switch
  <N>``, but only while fresh (``SWITCH_MAX_AGE_S``): a click made while no
  backend ran must not move the active account minutes or hours later.

Every file looked at is deleted, applied or not. The widget cannot create the
directory itself, so the backend does, at startup.
"""

from __future__ import annotations

import json
import re
import sys
import time
from collections.abc import Callable
from pathlib import Path

from claude_swap.exceptions import ClaudeSwitchError
from claude_swap.settings import load_settings, set_setting

REQUESTS_DIRNAME = "widget-requests"
_REQUEST_NAME = re.compile(r"^autoswitch-(\d+)\.json$")
_SWITCH_NAME = re.compile(r"^switch-(\d+)\.json$")

# A switch request older than this is dropped unapplied. Long enough for a
# backend busy in a tick's fetch to get to it; short enough that a click the
# user has forgotten about never fires.
SWITCH_MAX_AGE_S = 60.0


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
    Dotfiles are the widget's in-flight temps and are left alone, and switch
    requests belong to ``apply_switch_request``.
    """
    try:
        entries = [p for p in requests_dir(backup_dir).iterdir()
                   if not p.name.startswith(".") and p.is_file()
                   and not _SWITCH_NAME.match(p.name)]
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


def _log(message: str) -> None:
    print(f"widget: {message}", file=sys.stderr, flush=True)


def _parse_switch(path: Path) -> tuple[int, str] | None:
    """``(to, at)`` from a switch request file, or None if it is not one."""
    try:
        data = json.loads(path.read_text())
        to = data["switch"]["to"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if not isinstance(to, int) or isinstance(to, bool) or to < 1:
        return None
    at = data.get("at")
    return to, at if isinstance(at, str) else "?"


def apply_switch_request(
    backup_dir: Path,
    make_switcher: Callable[[], object],
    now: float | None = None,
) -> bool:
    """Apply the newest fresh switch request; delete every switch file.

    Returns True when the active account actually changed. Age comes from
    the name's ``epochMillis`` (the widget's clock is this machine's clock).
    Every file is deleted before the switch runs, so a switch that fails —
    or crashes — is never retried. ``make_switcher`` is only called when
    there is something to apply, and must return a ``ClaudeAccountSwitcher``
    of its own: the switch is ``switch_to``, exactly as ``cswap switch <N>``
    runs it, under the same locks.
    """
    try:
        entries = [p for p in requests_dir(backup_dir).iterdir()
                   if _SWITCH_NAME.match(p.name) and p.is_file()]
    except OSError:
        return False
    if not entries:
        return False
    now = time.time() if now is None else now
    requests = []
    for path in entries:
        parsed = _parse_switch(path)
        if parsed is not None:
            millis = int(_SWITCH_NAME.match(path.name).group(1))
            requests.append((millis, path.name, *parsed))
        path.unlink(missing_ok=True)
    if not requests:
        return False
    requests.sort(reverse=True)
    newest = None
    for millis, _, to, at in requests:
        age = now - millis / 1000.0
        if newest is None and abs(age) <= SWITCH_MAX_AGE_S:
            newest = (to, at)
        elif newest is None:
            _log(f"ignored stale switch request to {to} (age {age:.0f}s, requested {at})")
        else:
            _log(f"ignored superseded switch request to {to} (requested {at})")
    if newest is None:
        return False
    to, at = newest
    switcher = make_switcher()
    try:
        if switcher.is_account_disabled(str(to)):
            # `cswap switch N` accepts a disabled slot; the widget does not —
            # a tap on a dimmed row is far likelier a slip than an intent.
            _log(f"refused switch request to {to}: Account-{to} is disabled")
            return False
        result = switcher.switch_to(str(to), json_output=True)
    except ClaudeSwitchError as e:
        _log(f"refused switch request to {to}: {e}")
        return False
    if not result or not result.get("switched"):
        _log(f"switch request to {to}: {(result or {}).get('message', 'nothing to do')}")
        return False
    came_from = (result.get("from") or {}).get("number")
    _log(f"{result['message']}, from Account-{came_from} (requested {at})")
    return True

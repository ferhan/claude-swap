"""File locking for concurrent access protection."""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import IO

# Platform-specific imports for file locking
if sys.platform == "win32":
    import msvcrt
else:
    import fcntl

from claude_swap.exceptions import LockError


class FileLock:
    """Cross-process file lock using platform-specific APIs."""

    def __init__(self, lock_path: Path, timeout: float = 10.0):
        self.lock_path = lock_path
        self.timeout = timeout
        self._lock_file: IO | None = None
        self._locked = False

    def acquire(self, timeout: float | None = None) -> bool:
        """Acquire exclusive lock with timeout.

        Args:
            timeout: Maximum seconds to wait for lock. Defaults to the
                timeout given at construction.

        Returns:
            True if lock acquired, False if timeout.
        """
        if timeout is None:
            timeout = self.timeout
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock_file = open(self.lock_path, "w")

        start = time.monotonic()
        while True:
            try:
                if sys.platform == "win32":
                    # Windows: use msvcrt for file locking
                    msvcrt.locking(self._lock_file.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    # POSIX: use fcntl for file locking
                    fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                self._locked = True
                return True
            except (BlockingIOError, OSError):
                if time.monotonic() - start > timeout:
                    self._lock_file.close()
                    self._lock_file = None
                    return False
                time.sleep(0.1)

    def release(self) -> None:
        """Release the lock."""
        if self._lock_file and self._locked:
            if sys.platform == "win32":
                # Windows: unlock using msvcrt
                try:
                    msvcrt.locking(self._lock_file.fileno(), msvcrt.LK_UNLCK, 1)
                except OSError:
                    pass  # File may already be unlocked
            else:
                # POSIX: unlock using fcntl
                fcntl.flock(self._lock_file.fileno(), fcntl.LOCK_UN)
            self._lock_file.close()
            self._lock_file = None
            self._locked = False

    def __enter__(self) -> FileLock:
        if not self.acquire():
            raise LockError("Failed to acquire lock - another instance may be running")
        return self

    def __exit__(self, *args) -> None:
        self.release()


# -- singleton engine lock ---------------------------------------------------

ENGINE_LOCK_NAME = ".engine.lock"


def engine_lock_path(backup_dir: Path) -> Path:
    """Where the singleton auto-switch engine lock lives (backup root)."""
    return backup_dir / ENGINE_LOCK_NAME


def _owner_path(lock_path: Path) -> Path:
    """Sidecar holding the current owner's identity.

    Deliberately NOT the lock file itself: ``FileLock.acquire`` opens the path
    ``"w"`` *before* trying ``flock``, so a contender that FAILS to acquire
    still truncates it — holder info written there would be erased by the very
    process that needs to read it. Only the holder writes this sidecar, so
    while the lock is held its contents are consistent; when nobody holds the
    lock it is meaningless (see :func:`engine_lock_holder`).
    """
    return lock_path.with_name(lock_path.name + ".owner")


def _describe_self() -> str:
    """This process's argv, program path resolved. Best-effort.

    Resolved, unlike the plist's program (which pins the symlink on purpose):
    here the question is *which build* is holding the lock, and a
    ``uv tool install`` symlink answers that only once followed.
    """
    argv = list(sys.argv) or ["?"]
    try:
        program = Path(argv[0])
        # Only if it names a real file: argv[0] is "-c" for `python -c` and
        # resolving that invents a path under the cwd.
        if program.exists():
            argv[0] = str(program.resolve())
    except (OSError, ValueError):
        pass
    return " ".join(argv)


class EngineLock:
    """Exclusive right to RUN an auto-switch engine on this machine.

    Two engines corrupt nothing — switching is ``flock``-serialized and
    fetches are claimed atomically — but they reach switch decisions
    independently, so which one wins depends on which window happens to be
    open. This makes that impossible for every current-build engine: the
    launchd backend, a hand-run ``cswap auto``, the menu bar's engine and the
    TUI's all contend for the same file.

    Honest limitation: a build that predates this lock does not take it. A
    global ``uv tool install`` alongside a dev checkout — a real configuration
    — can therefore still end up with two engines. This removes the common
    case, not the pathological one.
    """

    def __init__(self, lock_path: Path):
        self.lock_path = lock_path
        # timeout 0: an engine that loses does not wait for the winner to
        # finish — it declines to be an engine at all.
        self._lock = FileLock(lock_path, timeout=0.0)
        self._held = False

    def acquire(self) -> bool:
        """Take the lock. True if this process may now run an engine."""
        if self._held:
            return True
        if not self._lock.acquire():
            return False
        self._held = True
        try:
            _owner_path(self.lock_path).write_text(
                json.dumps({"pid": os.getpid(), "program": _describe_self()}),
                encoding="utf-8",
            )
        except OSError:
            pass  # the lock is what enforces exclusivity; the name is a courtesy
        return True

    def release(self) -> None:
        """Drop the lock. A crash releases it too — ``flock`` dies with the
        process — so this is the clean-exit path, not the only one."""
        if not self._held:
            return
        try:
            _owner_path(self.lock_path).unlink(missing_ok=True)
        except OSError:
            pass
        self._lock.release()
        self._held = False


def engine_lock_holder(lock_path: Path) -> dict | None:
    """Who is running an engine, or None if nobody is.

    Probing by acquisition is the only reliable liveness test: ``flock`` is
    released by the kernel when the holder dies, so a leftover owner sidecar
    proves nothing on its own. Returns an empty dict when the lock is held but
    the holder could not be named (pre-lock build, unwritable sidecar, or a
    release racing this read).
    """
    probe = FileLock(lock_path, timeout=0.0)
    if probe.acquire():
        probe.release()
        return None
    try:
        raw = json.loads(_owner_path(lock_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return {}
    return raw if isinstance(raw, dict) else {}


def describe_engine_holder(holder: dict) -> str:
    """Render :func:`engine_lock_holder`'s dict for a human, e.g.
    ``pid 421 (/usr/local/bin/cswap auto)``."""
    pid = holder.get("pid")
    program = holder.get("program")
    if pid and program:
        return f"pid {pid} ({program})"
    if pid:
        return f"pid {pid}"
    return str(program) if program else "an unidentified process"

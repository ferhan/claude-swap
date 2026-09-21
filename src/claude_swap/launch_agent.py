"""Run a cswap subcommand as a launchd LaunchAgent, not a foreground process.

``cswap menubar`` and ``cswap auto`` both block the terminal that started
them, so they die with that terminal — and never come back after a logout or
reboot. launchd is the native macOS answer: a per-user LaunchAgent starts
them at login, restarts them if they crash, and needs no ``.app`` bundle.
Everything here is parameterized by label and argv, so the two services are
the same code with different names.

Two decisions here are worth stating, because both differ from the obvious
approach:

*The plist pins the console script, not ``sys.executable``.* A LaunchAgent
outlives upgrades, and the two paths age differently: ``uv tool upgrade`` (and
``cswap upgrade``) rebuilds the tool's virtualenv — ``sys.executable`` points
inside that virtualenv and can be replaced — while the console script keeps its
path across upgrades. Pinning the script means an upgraded cswap needs a
``launchctl kickstart``, not a reinstalled service. ``sys.executable -m
claude_swap`` stays as the fallback for installs that expose no console script.

*Logs go to ``~/Library/Logs``, not ``/tmp``.* ``/tmp`` is world-writable and
periodically purged, so a crash log can vanish before anyone reads it, and a
predictable world-writable path is a poor place to point a long-lived writer.

Everything here is macOS-only; callers guard on ``sys.platform`` and the public
functions refuse rather than half-work elsewhere.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path

from claude_swap.exceptions import ClaudeSwitchError

LABEL = "com.cswap.menubar"
# The headless backend: one process owning the auto-switch engine, which the
# menu bar and the TUI check for before hosting an engine of their own.
AUTO_LABEL = "com.cswap.auto"

# What each agent's ProgramArguments carry after the program. The menu bar
# agent runs the foreground app (plain `cswap menubar` installs the agent and
# returns). The backend logs JSONL — its stdout log is the event stream the
# surfaces tail (see autoswitch.BackendEventLog) — and `--backend` is what
# lets it retire once no surface is open; a hand-run `cswap auto` never does.
MENUBAR_ARGS = ("menubar", "--foreground")
BACKEND_ARGS = ("auto", "--json", "--backend")

# launchd's default PATH is /usr/bin:/bin:/usr/sbin:/sbin, which covers
# `security` (Keychain reads) but not a Homebrew or ~/.local/bin `claude`. The
# menu bar shells out to detect running sessions, so seed a PATH that finds it.
_EXTRA_PATH_DIRS = ("~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin")
_BASE_PATH_DIRS = ("/usr/bin", "/bin", "/usr/sbin", "/sbin")

# `launchctl bootout` can return before launchd has finished tearing the
# job down, and a `bootstrap` inside that window fails with "Operation
# already in progress". Poll until the job is really gone instead of
# assuming bootout was synchronous (Homebrew's services code does the same).
_UNLOAD_TIMEOUT_SECONDS = 5.0
_UNLOAD_POLL_SECONDS = 0.1
# How long a lifecycle decision waits for another one in flight: long enough
# to cover an install's bootout wait, so two surfaces opening together
# serialize instead of the second one falling back to hosting an engine.
_LIFECYCLE_TIMEOUT_SECONDS = _UNLOAD_TIMEOUT_SECONDS + 10.0


def _require_macos() -> None:
    if sys.platform != "darwin":
        raise ClaudeSwitchError(
            "The menu bar service is only available on macOS."
        )


def plist_path(label: str = LABEL, home: Path | None = None) -> Path:
    """Absolute path of the LaunchAgent plist for ``label``."""
    return (home or Path.home()) / "Library" / "LaunchAgents" / f"{label}.plist"


def log_paths(label: str = LABEL, home: Path | None = None) -> tuple[Path, Path]:
    """``(stdout, stderr)`` log destinations for ``label``."""
    logs = (home or Path.home()) / "Library" / "Logs"
    return logs / f"{label}.log", logs / f"{label}.err"


def service_target(label: str = LABEL, uid: int | None = None) -> str:
    """launchd service target, e.g. ``gui/501/com.cswap.menubar``."""
    return f"gui/{os.getuid() if uid is None else uid}/{label}"


def domain_target(uid: int | None = None) -> str:
    """launchd domain target, e.g. ``gui/501``."""
    return f"gui/{os.getuid() if uid is None else uid}"


def resolve_program() -> list[str]:
    """Argv prefix that launchd should run, minus the subcommand.

    Prefers the installed console script (stable across upgrades, see the
    module docstring) and falls back to running the package through the
    interpreter that is executing right now.

    The path is made absolute but deliberately NOT resolved: a `uv tool
    install` puts a symlink at ``~/.local/bin/cswap`` pointing into the tool's
    virtualenv, and resolving it would write that virtualenv-internal path
    into the plist — the very path this module avoids pinning, since a
    reinstall recreates the virtualenv while the symlink keeps its name.
    """
    candidate = sys.argv[0] if sys.argv and sys.argv[0] else None
    if candidate is not None:
        absolute = Path(os.path.abspath(candidate))
        if absolute.name == "cswap" and absolute.is_file():
            return [str(absolute)]

    which = shutil.which("cswap")
    if which:
        return [str(Path(os.path.abspath(which)))]

    return [sys.executable, "-m", "claude_swap"]


def _path_env(program: list[str]) -> str:
    """PATH for the agent, with the program's own directory first."""
    dirs: list[str] = []
    first = Path(program[0]).parent
    if str(first) not in ("", "."):
        dirs.append(str(first))
    for extra in (*_EXTRA_PATH_DIRS, *_BASE_PATH_DIRS):
        expanded = os.path.expanduser(extra)
        if expanded not in dirs:
            dirs.append(expanded)
    return ":".join(dirs)


def build_plist(
    program: list[str] | None = None,
    label: str = LABEL,
    home: Path | None = None,
    args: Sequence[str] = MENUBAR_ARGS,
) -> bytes:
    """Serialize the LaunchAgent plist.

    Built with :mod:`plistlib` rather than a formatted XML string so paths
    containing ``&`` or ``<`` cannot produce a plist launchd refuses to parse.
    """
    program = program or resolve_program()
    out_log, err_log = log_paths(label, home)
    return plistlib.dumps(
        {
            "Label": label,
            "ProgramArguments": [*program, *args],
            "RunAtLoad": True,
            # Restart a crash, but respect a deliberate Quit. The menu bar's
            # quit handler calls rumps.quit_application(), a clean exit(0);
            # under a bare `KeepAlive: True` launchd would relaunch it at once
            # and the Quit item would do nothing the user can see.
            "KeepAlive": {"SuccessfulExit": False},
            # A menu bar owner is a UI process; Background would have launchd
            # apply throttled I/O and CPU bands to it.
            "ProcessType": "Interactive",
            "EnvironmentVariables": {"PATH": _path_env(program)},
            "StandardOutPath": str(out_log),
            "StandardErrorPath": str(err_log),
        }
    )


def _launchctl(*args: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            ["launchctl", *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as e:  # pragma: no cover - launchctl is in the base OS
        raise ClaudeSwitchError("launchctl not found; is this macOS?") from e


def _wait_until_unloaded(
    label: str = LABEL,
    uid: int | None = None,
    timeout: float = _UNLOAD_TIMEOUT_SECONDS,
) -> bool:
    """Block until launchd has dropped the job. True if it went away in time."""
    deadline = time.monotonic() + timeout
    while is_loaded(label, uid):
        if time.monotonic() >= deadline:
            return False
        time.sleep(_UNLOAD_POLL_SECONDS)
    return True


def is_loaded(label: str = LABEL, uid: int | None = None) -> bool:
    """Whether launchd currently knows about the service."""
    return _launchctl("print", service_target(label, uid)).returncode == 0


def backend_is_loaded() -> bool:
    """Whether the headless backend LaunchAgent is running.

    The menu bar and the TUI both ask before starting an engine: two engines
    make independent policy decisions about one set of accounts. A negative
    answer is not a claim of exclusivity — an engine hosted by another
    surface, or by an older build that never checked, is still possible and
    is handled the same way it always was, by the switch path's file locks.
    Off macOS there are no LaunchAgents, so there is no backend to defer to.
    """
    return sys.platform == "darwin" and is_loaded(AUTO_LABEL)


# -- who is actually running an engine ---------------------------------------

ENGINE_NONE = "none"  # nobody holds the lock
ENGINE_SELF = "self"  # this process's own engine holds it
ENGINE_BACKEND = "backend"  # the headless LaunchAgent holds it
ENGINE_OTHER = "other"  # a hand-run `cswap auto`, or another surface


def backend_pid() -> int | None:
    """The backend LaunchAgent's pid, or None when it isn't running."""
    if sys.platform != "darwin":
        return None
    return status(AUTO_LABEL).get("pid")


def engine_owner(backup_dir: Path) -> tuple[str, str]:
    """Who is running an engine right now, as ``(state, description)``.

    A surface must not answer this from :func:`backend_is_loaded` alone.
    That asks launchd whether a label is loaded, which is a different
    question from "is anything ticking": a hand-run ``cswap auto``, or a
    second TUI, reads as "nothing running", so the surface starts an engine,
    that engine loses the lock on its first tick, and the badge is left
    claiming a mode the surface never entered. The lock is the machine-wide
    answer; the holder's pid says which of the three cases it is.
    """
    from claude_swap import locking

    lock = locking.engine_lock_path(Path(backup_dir))
    # Probing takes the lock, and taking it creates the file (FileLock opens
    # "w"): a machine where no engine has ever run must not grow one just by
    # being looked at.
    holder = locking.engine_lock_holder(lock) if lock.exists() else None
    if holder is None:
        return (ENGINE_NONE, "")
    detail = locking.describe_engine_holder(holder)
    pid = holder.get("pid")
    if pid == os.getpid():
        return (ENGINE_SELF, detail)
    if pid is not None and pid == backend_pid():
        return (ENGINE_BACKEND, detail)
    return (ENGINE_OTHER, detail)


def status(label: str = LABEL, uid: int | None = None, home: Path | None = None) -> dict:
    """Installed / loaded / running state, plus the pid when there is one."""
    _require_macos()
    target_plist = plist_path(label, home)
    printed = _launchctl("print", service_target(label, uid))
    loaded = printed.returncode == 0
    state: str | None = None
    pid: int | None = None
    if loaded:
        for line in printed.stdout.splitlines():
            # `launchctl print` nests sub-dictionaries — pid-local endpoints,
            # inherited environment — and those repeat keys the job itself
            # uses, `state` among them. The job's own fields are the ones at a
            # single tab, so anything deeper is a different object's field.
            if not line.startswith("\t") or line.startswith("\t\t"):
                continue
            stripped = line.strip()
            if state is None and stripped.startswith("state = "):
                state = stripped.removeprefix("state = ").strip()
            elif pid is None and stripped.startswith("pid = "):
                raw = stripped.removeprefix("pid = ").strip()
                if raw.isdigit():
                    pid = int(raw)
    return {
        "label": label,
        "installed": target_plist.exists(),
        "loaded": loaded,
        "state": state,
        "pid": pid,
        "plist": str(target_plist),
        # One label, two possible owners: a `uv tool install` and a dev
        # checkout both install under the same name, and whichever opened a
        # surface last owns it. Report the argv the plist
        # on disk actually carries so which build is installed is visible
        # instead of guessed.
        "program": _plist_program(target_plist),
    }


def _plist_program(target_plist: Path) -> list[str] | None:
    """ProgramArguments of the installed plist, or None if unreadable."""
    try:
        parsed = plistlib.loads(target_plist.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        return None
    program = parsed.get("ProgramArguments") if isinstance(parsed, dict) else None
    return program if isinstance(program, list) else None


def install(
    label: str = LABEL,
    home: Path | None = None,
    program: list[str] | None = None,
    uid: int | None = None,
    args: Sequence[str] = MENUBAR_ARGS,
) -> dict:
    """Write the plist and hand the service to launchd.

    Idempotent: an already-loaded service is booted out first, so running this
    after an upgrade re-reads the plist instead of failing with launchd's
    "service already loaded" (EEXIST, code 5).
    """
    _require_macos()
    program = program or resolve_program()
    target_plist = plist_path(label, home)
    out_log, err_log = log_paths(label, home)

    target_plist.parent.mkdir(parents=True, exist_ok=True)
    out_log.parent.mkdir(parents=True, exist_ok=True)
    target_plist.write_bytes(build_plist(program, label, home, args))

    settled = True
    if is_loaded(label, uid):
        _launchctl("bootout", service_target(label, uid))
        settled = _wait_until_unloaded(label, uid)

    booted = _launchctl("bootstrap", domain_target(uid), str(target_plist))
    if booted.returncode != 0:
        detail = (booted.stderr or booted.stdout or "").strip()
        if not settled:
            detail = f"{detail}; the previous instance was still shutting down".lstrip("; ")
        raise ClaudeSwitchError(
            f"launchctl bootstrap failed (exit {booted.returncode})"
            + (f": {detail}" if detail else "")
        )

    return {
        "label": label,
        "plist": str(target_plist),
        "program": [*program, *args],
        "stdout_log": str(out_log),
        "stderr_log": str(err_log),
    }


def uninstall(
    label: str = LABEL,
    home: Path | None = None,
    uid: int | None = None,
) -> dict:
    """Stop the service and delete its plist.

    Tolerates every partial state — loaded without a plist, a plist that was
    never bootstrapped, neither — because the point of an uninstall is to
    arrive at "gone", not to insist on the path taken to get there.
    """
    _require_macos()
    target_plist = plist_path(label, home)
    was_loaded = is_loaded(label, uid)
    if was_loaded:
        booted_out = _launchctl("bootout", service_target(label, uid))
        if booted_out.returncode != 0 and is_loaded(label, uid):
            detail = (booted_out.stderr or booted_out.stdout or "").strip()
            raise ClaudeSwitchError(
                f"launchctl bootout failed (exit {booted_out.returncode})"
                + (f": {detail}" if detail else "")
            )

    existed = target_plist.exists()
    if existed:
        target_plist.unlink()

    return {"label": label, "was_loaded": was_loaded, "removed_plist": existed}


# -- surfaces and the backend's lifetime --------------------------------------
#
# The backend runs exactly while some surface is open. A surface registers
# itself, then makes sure the backend is up; the backend, on its own timer,
# retires once no surface is left. Both decisions are taken under the one
# lifecycle lock (see ``locking.lifecycle_lock``), so neither can act on a
# picture the other is halfway through changing.


def needs_install(
    label: str,
    args: Sequence[str],
    home: Path | None = None,
    uid: int | None = None,
) -> bool:
    """Whether ``label`` must be (re)installed for this build to own it.

    True when it isn't running, or when the plist on disk carries a different
    argv — another checkout or install put it there, and the newest caller
    wins, so the build the user just ran is the one launchd holds.
    """
    current = status(label, uid, home)
    return current["pid"] is None or current["program"] != [*resolve_program(), *args]


def ensure_running(
    label: str,
    args: Sequence[str],
    home: Path | None = None,
    uid: int | None = None,
) -> bool:
    """Install ``label`` unless it is already running this build. True if
    it had to be (re)installed."""
    if not needs_install(label, args, home, uid):
        return False
    install(label=label, home=home, uid=uid, args=args)
    return True


def open_surface(backup_dir: Path, kind: str | None, home: Path | None = None):
    """Register this process as an open surface and make sure the backend runs.

    Returns ``(registration, managed, error)``. Keep ``registration`` alive
    for the life of the surface; it is None off macOS, where there is no
    backend and surfaces host their own engine as they always have.
    ``managed`` is True when the backend is up and owns the engine; when it
    is False, ``error`` says why and the caller carries on without it — a
    surface that cannot reach launchd must still open.

    Register first, then ensure: by the time the backend can first look for
    surfaces, the one that started it is already there to be found. ``kind``
    None ensures without registering, for ``cswap menubar``, which only
    launches the menu bar agent and exits.
    """
    from claude_swap import locking

    if sys.platform != "darwin":
        return None, False, None
    backup_dir = Path(backup_dir)
    lifecycle = locking.lifecycle_lock(backup_dir, timeout=_LIFECYCLE_TIMEOUT_SECONDS)
    if not lifecycle.acquire():
        return None, False, "another cswap is starting or stopping the backend"
    try:
        registration = (
            locking.register_surface(backup_dir, kind) if kind is not None else None
        )
        try:
            ensure_running(AUTO_LABEL, BACKEND_ARGS, home)
        except (ClaudeSwitchError, OSError) as e:
            return registration, False, str(e)
        return registration, True, None
    finally:
        lifecycle.release()


def retire_backend_if_idle(backup_dir: Path, home: Path | None = None) -> bool:
    """The backend's own check: True when no surface is open and it should go.

    Removes the backend's plist before answering, so it is not started again
    at login. The caller then exits 0, which ``KeepAlive: {SuccessfulExit:
    false}`` reads as "done" — launchd does not restart it. Deliberately not
    a self-``bootout``: that has launchd SIGTERM the very process waiting on
    ``launchctl``. The job's record stays loaded, idle, until logout or the
    next surface's install boots it out and bootstraps afresh.

    A lifecycle decision already in flight means a surface is opening: skip
    this round rather than wait on it.
    """
    from claude_swap import locking

    backup_dir = Path(backup_dir)
    lifecycle = locking.lifecycle_lock(backup_dir, timeout=0.0)
    if not lifecycle.acquire():
        return False
    try:
        if locking.live_surfaces(backup_dir):
            return False
        plist_path(AUTO_LABEL, home).unlink(missing_ok=True)
        return True
    finally:
        lifecycle.release()

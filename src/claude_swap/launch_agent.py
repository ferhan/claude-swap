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
path across upgrades. Pinning the script means the plist stays valid after an
upgrade; the running process is still the old code, which is why the plist
also records the version that wrote it (see ``needs_install``). ``sys.executable -m
claude_swap`` stays as the fallback for installs that expose no console script.

*Logs go to ``~/Library/Logs``, not ``/tmp``.* ``/tmp`` is world-writable and
periodically purged, so a crash log can vanish before anyone reads it, and a
predictable world-writable path is a poor place to point a long-lived writer.

Everything here is macOS-only; callers guard on ``sys.platform`` and the public
functions refuse rather than half-work elsewhere.
"""

from __future__ import annotations

import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from collections.abc import Sequence
from pathlib import Path

from claude_swap import __version__
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
            # CSWAP_VERSION is read by nobody at runtime. It records which
            # release wrote the plist, because an upgrade keeps the console
            # script's path and so leaves ProgramArguments unchanged: without
            # it, needs_install could not tell the running agent is old code.
            "EnvironmentVariables": {
                "PATH": _path_env(program),
                "CSWAP_VERSION": __version__,
            },
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
        "version": _plist_version(target_plist),
    }


def _read_plist(target_plist: Path) -> dict:
    """The installed plist as a dict; empty if missing or unreadable."""
    try:
        parsed = plistlib.loads(target_plist.read_bytes())
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _plist_program(target_plist: Path) -> list[str] | None:
    """ProgramArguments of the installed plist, or None if unreadable."""
    program = _read_plist(target_plist).get("ProgramArguments")
    return program if isinstance(program, list) else None


def _plist_version(target_plist: Path) -> str | None:
    """The cswap version that wrote the plist, or None (pre-dates the tag)."""
    env = _read_plist(target_plist).get("EnvironmentVariables")
    version = env.get("CSWAP_VERSION") if isinstance(env, dict) else None
    return version if isinstance(version, str) else None


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


def opens_at_login(home: Path | None = None) -> bool:
    """Whether the menu bar starts at login: its plist is on disk."""
    return plist_path(LABEL, home).exists()


def set_open_at_login(enabled: bool, home: Path | None = None) -> None:
    """The menu bar's "Open at Login" item: write or delete its plist only.

    No ``launchctl`` either way. Called from inside the running menu bar, and
    a self-``bootout`` would have launchd SIGTERM the very process waiting on
    it. The loaded job is left alone, so the app keeps running this session:
    turning it off takes effect at the next login (or when Quit exits it for
    good); turning it on writes the plist launchd reads at login. The
    CLI's ``cswap menubar --uninstall-service`` is the stop-it-now path.
    """
    _require_macos()
    target = plist_path(LABEL, home)
    if not enabled:
        target.unlink(missing_ok=True)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(build_plist(label=LABEL, home=home, args=MENUBAR_ARGS))


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

    Also true when the plist was written by another cswap version. An upgrade
    (``cswap upgrade``, ``uv tool upgrade``) keeps the console script's path,
    so the argv still matches while the running agent is the old code; the
    reinstall's bootout + bootstrap is what restarts it on the new code.
    """
    current = status(label, uid, home)
    return (
        current["pid"] is None
        or current["program"] != [*resolve_program(), *args]
        or current["version"] != __version__
    )


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


# -- placed widgets ------------------------------------------------------------
#
# A widget on the desktop is a viewer too, but it cannot hold a surface lock:
# WidgetKit wakes the extension only to draw. So the backend asks the widget's
# host app, which alone can call WidgetCenter, how many are placed. The app
# answers `{"count": N}` on stdout and exits 0; anything else is "unknown".

# Where `cswap widget install` puts the host app. Spelled once.
WIDGET_HOST_APP = Path("Applications") / "ClaudeSwap.app"
_PLACED_WIDGETS_TIMEOUT_S = 10.0
# The retire check runs every 5s; widgets are placed and removed by hand, so
# a few minutes of lag is fine and saves spawning the app 60 times a minute.
_PLACED_WIDGETS_CACHE_S = 300.0
# Right after chronod restarts (every widget install runs `killall chronod`)
# the host app answers {"count": 0} for a few seconds. So "none placed" must
# hold across answers at least this far apart before the backend retires...
_PLACED_WIDGETS_CONFIRM_S = 15.0
# ...and those answers must be consecutive checks: a zero from before a
# surface was open (no checks run meanwhile) does not vouch for a new one.
_PLACED_WIDGETS_STREAK_GAP_S = 60.0


def widget_host_executable(home: Path | None = None) -> Path:
    """The host app's binary, which answers ``--placed-widgets``."""
    return (home or Path.home()) / WIDGET_HOST_APP / "Contents" / "MacOS" / "ClaudeSwap"


class PlacedWidgets:
    """How many cswap widgets are placed; a positive answer is cached for a
    few minutes.

    Unknown (no app, timeout, bad exit, unparsable output) reads as 0. A 0 is
    never cached and never taken on one answer: :meth:`none_placed` wants it
    confirmed (see ``_PLACED_WIDGETS_CONFIRM_S``) before the backend retires.
    Each distinct answer is logged once to stderr (the backend's ``.err``
    log), so a missing app is one line, not one every check.
    """

    def __init__(self, clock=time.monotonic) -> None:
        self._clock = clock
        self._cached: tuple[float, int] | None = None
        self._last_logged: str | None = None
        # When the current run of zero answers began, and the latest of them.
        self._zero_since: float | None = None
        self._zero_last: float | None = None

    def count(self, home: Path | None = None) -> int:
        now = self._clock()
        if self._cached is not None and now - self._cached[0] < _PLACED_WIDGETS_CACHE_S:
            return self._cached[1]
        count, note = self._query(home)
        if count:
            self._cached = (now, count)
            self._zero_since = self._zero_last = None
        else:
            self._cached = None
            if self._zero_last is None or now - self._zero_last > _PLACED_WIDGETS_STREAK_GAP_S:
                self._zero_since = now
            self._zero_last = now
        if note != self._last_logged:
            self._last_logged = note
            print(f"backend: {note}", file=sys.stderr, flush=True)
        return count

    def none_placed(self, home: Path | None = None) -> bool:
        """True once consecutive answers of 0 span ``_PLACED_WIDGETS_CONFIRM_S``."""
        if self.count(home) > 0:
            return False
        return self._clock() - self._zero_since >= _PLACED_WIDGETS_CONFIRM_S

    @staticmethod
    def _query(home: Path | None) -> tuple[int, str]:
        exe = widget_host_executable(home)
        if not exe.is_file():
            return 0, f"no widget host app at {exe}; placed widgets count as 0"
        try:
            done = subprocess.run(
                [str(exe), "--placed-widgets"],
                capture_output=True,
                text=True,
                timeout=_PLACED_WIDGETS_TIMEOUT_S,
                check=False,
            )
            if done.returncode != 0:
                raise ValueError(f"exit {done.returncode}")
            count = json.loads(done.stdout.strip().splitlines()[-1])["count"]
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                raise ValueError(f"bad count {count!r}")
        except (OSError, subprocess.SubprocessError, ValueError, KeyError,
                IndexError, TypeError) as e:
            return 0, f"placed widgets unknown ({e}); counting 0"
        if count:
            return count, f"{count} widget(s) placed; staying up without a surface"
        return 0, "no widgets placed"


_placed_widgets = PlacedWidgets()


def retire_backend_if_idle(
    backup_dir: Path,
    home: Path | None = None,
    widgets: PlacedWidgets | None = None,
) -> bool:
    """The backend's own check: True when no surface is open and it should go.

    Removes the backend's plist before answering, so it is not started again
    at login. The caller then exits 0, which ``KeepAlive: {SuccessfulExit:
    false}`` reads as "done" — launchd does not restart it. Deliberately not
    a self-``bootout``: that has launchd SIGTERM the very process waiting on
    ``launchctl``. The job's record stays loaded, idle, until logout or the
    next surface's install boots it out and bootstraps afresh.

    A lifecycle decision already in flight means a surface is opening: skip
    this round rather than wait on it.

    A placed widget also keeps it (see :class:`PlacedWidgets`), and "no
    widget placed" counts only once confirmed across checks at least
    ``_PLACED_WIDGETS_CONFIRM_S`` apart. The plist then stays too, so
    ``RunAtLoad`` brings the backend back at login for the widget. The host app is asked outside the lifecycle lock — it can
    take seconds, and surfaces opening wait on that lock — and the surfaces
    are checked again under it before the plist goes.
    """
    from claude_swap import locking

    backup_dir = Path(backup_dir)

    def idle(retire: bool) -> bool:
        lifecycle = locking.lifecycle_lock(backup_dir, timeout=0.0)
        if not lifecycle.acquire():
            return False
        try:
            if locking.live_surfaces(backup_dir):
                return False
            if retire:
                plist_path(AUTO_LABEL, home).unlink(missing_ok=True)
            return True
        finally:
            lifecycle.release()

    if not idle(retire=False):
        return False
    if not (widgets or _placed_widgets).none_placed(home):
        return False
    return idle(retire=True)

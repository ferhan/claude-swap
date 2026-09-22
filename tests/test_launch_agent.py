"""Tests for the launchd LaunchAgent that keeps ``cswap menubar`` alive.

``subprocess.run`` is patched throughout so the real ``launchctl`` is never
driven: these assert the argv this module *shapes* and how it reads launchctl's
replies, not launchd's behaviour. Every test pins ``home`` to a tmp path and
passes an explicit ``uid``, so nothing here depends on the machine it runs on
or writes outside the temp directory.
"""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

from claude_swap import __version__, launch_agent
from claude_swap.exceptions import ClaudeSwitchError

PROGRAM = ["/Users/x/.local/bin/cswap"]
UID = 501


@pytest.fixture(autouse=True)
def _on_macos():
    """The module refuses off-darwin; these tests exercise the darwin path."""
    with patch.object(launch_agent.sys, "platform", "darwin"):
        yield


def _completed(returncode: int = 0, stdout: str = "", stderr: str = ""):
    return subprocess.CompletedProcess(
        args=["launchctl"], returncode=returncode, stdout=stdout, stderr=stderr
    )


def _router(responses: dict[str, subprocess.CompletedProcess]):
    """Answer per launchctl subcommand, defaulting to success."""

    def run(argv, **kwargs):
        return responses.get(argv[1], _completed(0))

    return run


# --- plist shape -----------------------------------------------------------


def test_build_plist_is_parseable_and_runs_the_foreground_menubar(tmp_path):
    # --foreground: plain `cswap menubar` installs this agent and returns, so
    # launchd must be handed the spelling that actually runs the app.
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=tmp_path))
    assert parsed["Label"] == launch_agent.LABEL
    assert parsed["ProgramArguments"] == [*PROGRAM, "menubar", "--foreground"]
    assert parsed["RunAtLoad"] is True


def test_build_plist_keepalive_restarts_a_crash_but_respects_a_quit(tmp_path):
    """A bare `KeepAlive: True` would make the menu bar's Quit item a no-op.

    menubar.py's quit handler calls rumps.quit_application() — a clean exit(0)
    — so unconditional KeepAlive relaunches it immediately and the user has no
    way to stop the menu bar short of `launchctl bootout`.
    """
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=tmp_path))
    assert parsed["KeepAlive"] == {"SuccessfulExit": False}


def test_build_plist_marks_the_agent_interactive_not_background(tmp_path):
    # Background would have launchd throttle a process that owns UI.
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=tmp_path))
    assert parsed["ProcessType"] == "Interactive"


def test_build_plist_survives_paths_that_would_break_hand_written_xml(tmp_path):
    odd = tmp_path / "home & <co>"
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=odd))
    assert parsed["StandardErrorPath"] == str(odd / "Library/Logs" / f"{launch_agent.LABEL}.err")


@pytest.mark.skipif(
    sys.platform == "win32",
    reason="asserts POSIX path shapes; the agent only ever runs on macOS",
)
def test_build_plist_path_env_leads_with_the_programs_own_directory(tmp_path):
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=tmp_path))
    assert parsed["EnvironmentVariables"]["PATH"].split(":")[0] == "/Users/x/.local/bin"


@pytest.mark.skipif(
    sys.platform == "win32",
    reason="asserts POSIX path shapes; the agent only ever runs on macOS",
)
def test_build_plist_path_env_includes_the_user_bin_dir(tmp_path):
    # A uv tool install puts cswap's siblings in ~/.local/bin; launchd's own
    # default PATH does not include it.
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=tmp_path))
    entries = parsed["EnvironmentVariables"]["PATH"].split(":")
    assert os.path.expanduser("~/.local/bin") in entries


def test_build_plist_path_env_keeps_the_launchd_defaults(tmp_path):
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=tmp_path))
    entries = parsed["EnvironmentVariables"]["PATH"].split(":")
    assert {"/usr/bin", "/bin", "/usr/sbin", "/sbin"} <= set(entries)


def test_build_plist_runs_whatever_subcommand_it_is_given(tmp_path):
    # The backend service is this module with a different label and argv.
    parsed = plistlib.loads(
        launch_agent.build_plist(
            PROGRAM, launch_agent.AUTO_LABEL, tmp_path, args=("auto",)
        )
    )
    assert parsed["Label"] == "com.cswap.auto"
    assert parsed["ProgramArguments"] == [*PROGRAM, "auto"]
    assert parsed["StandardErrorPath"] == str(
        tmp_path / "Library/Logs" / "com.cswap.auto.err"
    )


# --- program resolution ----------------------------------------------------


def test_resolve_program_prefers_the_console_script(tmp_path):
    script = tmp_path / "cswap"
    script.write_text("#!/bin/sh\n")
    with patch.object(launch_agent.sys, "argv", [str(script)]):
        assert launch_agent.resolve_program() == [str(script)]


def test_resolve_program_keeps_the_symlink_and_does_not_follow_it(tmp_path):
    """`uv tool install` links ~/.local/bin/cswap into the tool's virtualenv.

    Resolving that symlink would pin the virtualenv-internal path, which a
    reinstall recreates — exactly the path this module exists to avoid.
    """
    venv_bin = tmp_path / "venv" / "bin"
    venv_bin.mkdir(parents=True)
    real = venv_bin / "cswap"
    real.write_text("#!/bin/sh\n")
    link_dir = tmp_path / "local" / "bin"
    link_dir.mkdir(parents=True)
    link = link_dir / "cswap"
    link.symlink_to(real)

    with patch.object(launch_agent.sys, "argv", [str(link)]):
        assert launch_agent.resolve_program() == [str(link)]


def test_resolve_program_makes_a_relative_argv0_absolute(tmp_path, monkeypatch):
    script = tmp_path / "cswap"
    script.write_text("#!/bin/sh\n")
    monkeypatch.chdir(tmp_path)
    with patch.object(launch_agent.sys, "argv", ["./cswap"]):
        result = launch_agent.resolve_program()
    assert result == [str(script)]
    assert Path(result[0]).is_absolute()


def test_resolve_program_falls_back_to_the_interpreter_without_a_script(tmp_path):
    with patch.object(launch_agent.sys, "argv", [str(tmp_path / "gone")]):
        with patch.object(launch_agent.shutil, "which", return_value=None):
            assert launch_agent.resolve_program() == [sys.executable, "-m", "claude_swap"]


def test_resolve_program_ignores_an_argv0_that_is_not_cswap(tmp_path):
    # Running through pytest, argv[0] is the test runner — not a thing launchd
    # should be pointed at.
    other = tmp_path / "pytest"
    other.write_text("#!/bin/sh\n")
    found = tmp_path / "cswap"
    found.write_text("#!/bin/sh\n")
    with patch.object(launch_agent.sys, "argv", [str(other)]):
        with patch.object(launch_agent.shutil, "which", return_value=str(found)):
            assert launch_agent.resolve_program() == [str(found)]


# --- install ---------------------------------------------------------------


def test_install_writes_the_plist_and_bootstraps_it(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)

    written = Path(result["plist"])
    assert written.exists()
    calls = [c.args[0] for c in run.call_args_list]
    assert ["launchctl", "bootstrap", f"gui/{UID}", str(written)] in calls


def test_install_creates_the_log_directory(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)
    assert Path(result["stderr_log"]).parent.is_dir()


def test_install_boots_out_first_when_already_loaded(tmp_path):
    # Without this, launchd refuses a reinstall with "service already loaded".
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0)})
        launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)

    subcommands = [c.args[0][1] for c in run.call_args_list]
    assert subcommands.index("bootout") < subcommands.index("bootstrap")


def test_install_does_not_boot_out_when_nothing_is_loaded(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)

    assert "bootout" not in [c.args[0][1] for c in run.call_args_list]


def test_install_waits_for_the_old_job_to_go_away_before_bootstrapping(tmp_path):
    """`bootout` can return before launchd has finished the teardown.

    A `bootstrap` inside that window fails with "Operation already in
    progress", so install polls until the job is actually gone.
    """
    prints = {"n": 0}

    def run(argv, **kwargs):
        if argv[1] == "print":
            prints["n"] += 1
            return _completed(0 if prints["n"] <= 3 else 1)
        return _completed(0)

    with patch.object(launch_agent.time, "sleep") as slept:
        with patch.object(launch_agent.subprocess, "run", side_effect=run) as ran:
            launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)

    assert slept.called, "did not wait for the old job at all"
    subcommands = [c.args[0][1] for c in ran.call_args_list]
    # every liveness check sits between the bootout and the bootstrap
    assert subcommands.index("bootout") < subcommands.index("bootstrap")
    assert subcommands.count("print") > 2


def test_wait_until_unloaded_gives_up_after_the_timeout(tmp_path):
    with patch.object(launch_agent.time, "sleep"):
        with patch.object(launch_agent.subprocess, "run") as run:
            run.side_effect = _router({"print": _completed(0)})
            assert launch_agent._wait_until_unloaded(uid=UID, timeout=0.0) is False


def test_install_names_the_lingering_predecessor_when_bootstrap_fails(tmp_path):
    with patch.object(launch_agent, "_wait_until_unloaded", return_value=False):
        with patch.object(launch_agent.subprocess, "run") as run:
            run.side_effect = _router(
                {"print": _completed(0), "bootstrap": _completed(5, stderr="Operation already in progress")}
            )
            with pytest.raises(ClaudeSwitchError, match="still shutting down"):
                launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)


def test_install_raises_with_launchctl_detail_when_bootstrap_fails(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router(
            {"print": _completed(1), "bootstrap": _completed(5, stderr="Input/output error")}
        )
        with pytest.raises(ClaudeSwitchError, match="Input/output error"):
            launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)


def test_install_refuses_off_macos(tmp_path):
    with patch.object(launch_agent.sys, "platform", "linux"):
        with pytest.raises(ClaudeSwitchError, match="only available on macOS"):
            launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)


def test_install_hands_launchd_the_subcommand_it_was_given(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.install(
            launch_agent.AUTO_LABEL, tmp_path, PROGRAM, UID, args=("auto",)
        )

    assert result["program"] == [*PROGRAM, "auto"]
    parsed = plistlib.loads(Path(result["plist"]).read_bytes())
    assert parsed["ProgramArguments"] == [*PROGRAM, "auto"]


# --- uninstall -------------------------------------------------------------


def test_uninstall_boots_out_and_removes_the_plist(tmp_path):
    target = launch_agent.plist_path(home=tmp_path)
    target.parent.mkdir(parents=True)
    target.write_bytes(b"x")

    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0)})
        result = launch_agent.uninstall(home=tmp_path, uid=UID)

    assert result == {"label": launch_agent.LABEL, "was_loaded": True, "removed_plist": True}
    assert not target.exists()
    assert ["launchctl", "bootout", f"gui/{UID}/{launch_agent.LABEL}"] in [
        c.args[0] for c in run.call_args_list
    ]


def test_uninstall_is_quiet_when_nothing_is_installed(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.uninstall(home=tmp_path, uid=UID)
    assert result["was_loaded"] is False and result["removed_plist"] is False


def test_uninstall_removes_a_plist_that_was_never_bootstrapped(tmp_path):
    target = launch_agent.plist_path(home=tmp_path)
    target.parent.mkdir(parents=True)
    target.write_bytes(b"x")
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.uninstall(home=tmp_path, uid=UID)
    assert result["removed_plist"] is True and not target.exists()


def test_uninstall_raises_when_bootout_fails_and_the_service_stays_loaded(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0), "bootout": _completed(3, stderr="in use")})
        with pytest.raises(ClaudeSwitchError, match="in use"):
            launch_agent.uninstall(home=tmp_path, uid=UID)


def test_uninstall_tolerates_a_bootout_race_that_already_unloaded_it(tmp_path):
    # bootout returns non-zero because the job went away underneath it; the
    # follow-up print shows it gone, which is the outcome uninstall wants.
    calls = {"print": 0}

    def run(argv, **kwargs):
        if argv[1] == "print":
            calls["print"] += 1
            return _completed(0) if calls["print"] == 1 else _completed(1)
        if argv[1] == "bootout":
            return _completed(3, stderr="No such process")
        return _completed(0)

    with patch.object(launch_agent.subprocess, "run", side_effect=run):
        result = launch_agent.uninstall(home=tmp_path, uid=UID)
    assert result["was_loaded"] is True


# --- status ----------------------------------------------------------------


def test_status_reads_state_and_pid_from_launchctl_print(tmp_path):
    printed = "\tstate = running\n\tpid = 25026\n\tlast exit code = (never exited)\n"
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0, stdout=printed)})
        result = launch_agent.status(home=tmp_path, uid=UID)

    assert result["loaded"] is True
    assert result["state"] == "running"
    assert result["pid"] == 25026


def test_status_reports_not_loaded_without_inventing_a_pid(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.status(home=tmp_path, uid=UID)
    assert result["loaded"] is False
    assert result["pid"] is None and result["state"] is None


def test_status_separates_installed_from_loaded(tmp_path):
    # A plist on disk that launchd has not been given is a real state, and the
    # difference is what tells a user to run --install-service again.
    target = launch_agent.plist_path(home=tmp_path)
    target.parent.mkdir(parents=True)
    target.write_bytes(b"x")
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.status(home=tmp_path, uid=UID)
    assert result["installed"] is True and result["loaded"] is False


def test_status_reads_the_jobs_own_state_not_a_nested_blocks(tmp_path):
    """Regression: real `launchctl print` repeats `state` inside sub-dicts.

    Observed on macOS 25.5.0 — the job prints `state = running`, then a
    `pid-local endpoints` block prints `state = active`. Taking the last match
    reported the endpoint's state as the service's.
    """
    printed = (
        "gui/501/com.cswap.menubar = {\n"
        "\tactive count = 1\n"
        "\tstate = running\n"
        "\tpid = 25026\n"
        "\tpid-local endpoints = {\n"
        "\t\tstate = active\n"
        "\t\tpid = 999\n"
        "\t}\n"
        "}\n"
    )
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0, stdout=printed)})
        result = launch_agent.status(home=tmp_path, uid=UID)

    assert result["state"] == "running"
    assert result["pid"] == 25026


def test_status_keeps_multi_word_launchd_states(tmp_path):
    # Before the process spawns, launchd reports "spawn scheduled".
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0, stdout="\tstate = spawn scheduled\n")})
        result = launch_agent.status(home=tmp_path, uid=UID)
    assert result["state"] == "spawn scheduled"


def test_status_ignores_a_non_numeric_pid_line(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0, stdout="\tpid = (none)\n")})
        result = launch_agent.status(home=tmp_path, uid=UID)
    assert result["pid"] is None


def test_status_names_the_program_the_installed_plist_runs(tmp_path):
    """One label, two possible owners.

    A dev checkout and a `uv tool install` install under the SAME label, and
    whichever opened a surface last owns it. Reporting the argv the plist on
    disk actually carries is what makes that visible.
    """
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)
        result = launch_agent.status(home=tmp_path, uid=UID)

    assert result["program"] == [*PROGRAM, "menubar", "--foreground"]


def test_status_program_is_none_when_no_plist_is_installed(tmp_path):
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        result = launch_agent.status(home=tmp_path, uid=UID)
    assert result["program"] is None


# --- backend detection -----------------------------------------------------


def test_backend_is_loaded_asks_launchd_about_the_auto_label():
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(0)})
        assert launch_agent.backend_is_loaded() is True
    printed = [c.args[0] for c in run.call_args_list if c.args[0][1] == "print"]
    assert printed and printed[0][2].endswith("/com.cswap.auto")


def test_backend_is_loaded_is_false_when_launchd_does_not_know_it():
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        assert launch_agent.backend_is_loaded() is False


def test_backend_is_loaded_never_shells_out_off_macos():
    # The TUI runs on Linux, where there are no LaunchAgents to defer to.
    with patch.object(launch_agent.sys, "platform", "linux"), \
         patch.object(launch_agent.subprocess, "run") as run:
        assert launch_agent.backend_is_loaded() is False
    run.assert_not_called()


# --- who is actually running an engine --------------------------------------
#
# The surfaces' badge bug lived here: `backend_is_loaded` answers "is the
# label loaded", which is not "is something ticking".


def test_engine_owner_reports_nobody_without_touching_the_lock_file(tmp_path):
    """Asking must not create the lock: FileLock opens "w", so a probe on a
    machine where no engine ever ran would leave one behind."""
    with patch.object(launch_agent.subprocess, "run") as run:
        assert launch_agent.engine_owner(tmp_path) == (launch_agent.ENGINE_NONE, "")
    run.assert_not_called()
    assert not (tmp_path / ".engine.lock").exists()


def test_engine_owner_reports_nobody_when_the_lock_is_free(tmp_path):
    from claude_swap.locking import EngineLock, engine_lock_path

    lock = EngineLock(engine_lock_path(tmp_path))
    assert lock.acquire() is True
    lock.release()  # file now exists but is unheld
    assert launch_agent.engine_owner(tmp_path) == (launch_agent.ENGINE_NONE, "")


def test_engine_owner_recognises_this_process_holding_it(tmp_path):
    from claude_swap.locking import EngineLock, engine_lock_path

    lock = EngineLock(engine_lock_path(tmp_path))
    assert lock.acquire() is True
    try:
        state, detail = launch_agent.engine_owner(tmp_path)
    finally:
        lock.release()
    assert state == launch_agent.ENGINE_SELF
    assert str(os.getpid()) in detail


def test_engine_owner_names_the_backend_when_the_pids_match(tmp_path):
    _seed_owner(tmp_path, pid=4242, program="/tmp/cswap auto --json")
    with patch.object(launch_agent, "backend_pid", lambda: 4242):
        state, detail = _owner_while_held(tmp_path)
    assert state == launch_agent.ENGINE_BACKEND
    assert "4242" in detail


def test_engine_owner_calls_a_foreign_holder_what_it_is(tmp_path):
    """A hand-run `cswap auto` is neither us nor the service. A surface that
    called this "backend" would be as wrong as one that called it "ours"."""
    _seed_owner(tmp_path, pid=4242, program="/usr/local/bin/cswap auto")
    with patch.object(launch_agent, "backend_pid", lambda: None):
        state, detail = _owner_while_held(tmp_path)
    assert state == launch_agent.ENGINE_OTHER
    assert detail == "pid 4242 (/usr/local/bin/cswap auto)"


def _seed_owner(backup_dir: Path, *, pid: int, program: str) -> None:
    import json

    from claude_swap.locking import engine_lock_path

    path = engine_lock_path(backup_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.with_name(path.name + ".owner").write_text(
        json.dumps({"pid": pid, "program": program}), encoding="utf-8"
    )


def _owner_while_held(backup_dir: Path):
    """``engine_owner`` with the lock genuinely held while the sidecar names
    someone else.

    Held from this process with a bare ``FileLock`` — a second fd conflicts
    under flock exactly as another process would — so the lock says "held"
    and the sidecar says by whom, which is the split the real thing relies on.
    """
    from claude_swap.locking import FileLock, engine_lock_path

    holder = FileLock(engine_lock_path(backup_dir), timeout=0.0)
    assert holder.acquire() is True
    try:
        return launch_agent.engine_owner(backup_dir)
    finally:
        holder.release()


def test_backend_pid_never_shells_out_off_macos():
    with patch.object(launch_agent.sys, "platform", "linux"), \
         patch.object(launch_agent.subprocess, "run") as run:
        assert launch_agent.backend_pid() is None
    run.assert_not_called()


# --- surfaces and the backend's lifetime -------------------------------------


def _install_plist(
    home: Path, label: str, argv: list[str], version: str | None = __version__
) -> None:
    target = launch_agent.plist_path(label, home)
    target.parent.mkdir(parents=True, exist_ok=True)
    body = {"Label": label, "ProgramArguments": argv}
    if version is not None:
        body["EnvironmentVariables"] = {"CSWAP_VERSION": version}
    target.write_bytes(plistlib.dumps(body))


def _running(pid: int = 4242):
    return _router({"print": _completed(0, stdout=f"\tstate = running\n\tpid = {pid}\n")})


class TestNeedsInstall:
    """Newest caller wins: the build the user just ran is the one launchd holds."""

    ARGS = launch_agent.BACKEND_ARGS

    def test_running_this_build_needs_nothing(self, tmp_path):
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, *self.ARGS])
        with patch.object(launch_agent, "resolve_program", return_value=PROGRAM):
            with patch.object(launch_agent.subprocess, "run", side_effect=_running()):
                assert not launch_agent.needs_install(
                    launch_agent.AUTO_LABEL, self.ARGS, tmp_path, UID
                )

    def test_another_build_in_the_plist_is_replaced(self, tmp_path):
        _install_plist(
            tmp_path, launch_agent.AUTO_LABEL, ["/elsewhere/cswap", *self.ARGS]
        )
        with patch.object(launch_agent, "resolve_program", return_value=PROGRAM):
            with patch.object(launch_agent.subprocess, "run", side_effect=_running()):
                assert launch_agent.needs_install(
                    launch_agent.AUTO_LABEL, self.ARGS, tmp_path, UID
                )

    def test_a_backend_installed_without_retirement_is_replaced(self, tmp_path):
        # The deprecated `auto --install-service` writes `auto --json`: a
        # backend that never retires. A surface converts it.
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto", "--json"])
        with patch.object(launch_agent, "resolve_program", return_value=PROGRAM):
            with patch.object(launch_agent.subprocess, "run", side_effect=_running()):
                assert launch_agent.needs_install(
                    launch_agent.AUTO_LABEL, self.ARGS, tmp_path, UID
                )

    def test_an_upgrade_is_picked_up(self, tmp_path):
        # `cswap upgrade` keeps the console script's path, so the argv still
        # matches; only the version the plist was written by gives it away.
        _install_plist(
            tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, *self.ARGS], version="0.0.1"
        )
        with patch.object(launch_agent, "resolve_program", return_value=PROGRAM):
            with patch.object(launch_agent.subprocess, "run", side_effect=_running()):
                assert launch_agent.needs_install(
                    launch_agent.AUTO_LABEL, self.ARGS, tmp_path, UID
                )

    def test_a_plist_from_before_the_version_tag_is_replaced(self, tmp_path):
        _install_plist(
            tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, *self.ARGS], version=None
        )
        with patch.object(launch_agent, "resolve_program", return_value=PROGRAM):
            with patch.object(launch_agent.subprocess, "run", side_effect=_running()):
                assert launch_agent.needs_install(
                    launch_agent.AUTO_LABEL, self.ARGS, tmp_path, UID
                )

    def test_install_writes_the_version_status_reads_back(self, tmp_path):
        # The reinstall is what restarts the agent: bootout, then bootstrap.
        calls = []

        def run(argv, **kwargs):
            calls.append(argv[1])
            return _completed(0)

        with patch.object(launch_agent, "_wait_until_unloaded", return_value=True), \
             patch.object(launch_agent.subprocess, "run", side_effect=run):
            launch_agent.install(
                launch_agent.AUTO_LABEL, tmp_path, PROGRAM, UID, self.ARGS
            )
            assert "bootout" in calls and calls[-1] == "bootstrap"
            result = launch_agent.status(launch_agent.AUTO_LABEL, UID, tmp_path)
        assert result["version"] == __version__

    def test_loaded_but_not_running_is_restarted(self, tmp_path):
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, *self.ARGS])
        idle = _router({"print": _completed(0, stdout="\tstate = not running\n")})
        with patch.object(launch_agent, "resolve_program", return_value=PROGRAM):
            with patch.object(launch_agent.subprocess, "run", side_effect=idle):
                assert launch_agent.needs_install(
                    launch_agent.AUTO_LABEL, self.ARGS, tmp_path, UID
                )

    def test_ensure_running_installs_only_when_needed(self, tmp_path):
        with patch.object(launch_agent, "needs_install", return_value=False), \
             patch.object(launch_agent, "install") as install:
            assert launch_agent.ensure_running("x", ("a",), tmp_path, UID) is False
        install.assert_not_called()
        with patch.object(launch_agent, "needs_install", return_value=True), \
             patch.object(launch_agent, "install") as install:
            assert launch_agent.ensure_running("x", ("a",), tmp_path, UID) is True
        install.assert_called_once_with(label="x", home=tmp_path, uid=UID, args=("a",))


class TestOpenAtLogin:
    """The menu bar's "Open at Login" item: the plist, and only the plist."""

    def test_off_removes_the_plist_without_touching_launchd(self, tmp_path):
        _install_plist(tmp_path, launch_agent.LABEL, [*PROGRAM, *launch_agent.MENUBAR_ARGS])
        assert launch_agent.opens_at_login(tmp_path)
        with patch.object(launch_agent.subprocess, "run") as run:
            launch_agent.set_open_at_login(False, tmp_path)
            launch_agent.set_open_at_login(False, tmp_path)  # idempotent
        # A self-bootout would SIGTERM the menu bar mid-call.
        run.assert_not_called()
        assert not launch_agent.opens_at_login(tmp_path)

    def test_on_writes_the_menubar_plist(self, tmp_path):
        with patch.object(launch_agent, "resolve_program", return_value=PROGRAM), \
             patch.object(launch_agent.subprocess, "run") as run:
            launch_agent.set_open_at_login(True, tmp_path)
        run.assert_not_called()
        parsed = plistlib.loads(launch_agent.plist_path(launch_agent.LABEL, tmp_path).read_bytes())
        assert parsed["ProgramArguments"] == [*PROGRAM, *launch_agent.MENUBAR_ARGS]
        assert parsed["EnvironmentVariables"]["CSWAP_VERSION"] == __version__
        assert launch_agent.opens_at_login(tmp_path)


class TestOpenSurface:
    def test_registers_then_ensures_the_backend(self, tmp_path):
        from claude_swap import locking

        seen = {}

        def _ensure(label, args, home=None, uid=None):
            # Registration comes first, so the backend's first look for
            # surfaces always finds the one that started it.
            seen["live"] = locking.live_surfaces(tmp_path)
            seen["call"] = (label, tuple(args))
            return True

        with patch.object(launch_agent, "ensure_running", side_effect=_ensure):
            registration, managed, error = launch_agent.open_surface(tmp_path, "tui")
        try:
            assert managed is True and error is None
            assert seen["live"] == [f"tui-{os.getpid()}"]
            assert seen["call"] == (launch_agent.AUTO_LABEL, launch_agent.BACKEND_ARGS)
        finally:
            registration.release()

    def test_a_launchd_failure_still_opens_the_surface(self, tmp_path):
        with patch.object(
            launch_agent, "ensure_running", side_effect=ClaudeSwitchError("exit 5")
        ):
            registration, managed, error = launch_agent.open_surface(tmp_path, "tui")
        try:
            assert managed is False
            assert error == "exit 5"
            assert registration is not None  # still counted as open
        finally:
            registration.release()

    def test_off_macos_there_is_no_backend(self, tmp_path):
        with patch.object(launch_agent.sys, "platform", "linux"), \
             patch.object(launch_agent, "ensure_running") as ensure:
            assert launch_agent.open_surface(tmp_path, "tui") == (None, False, None)
        ensure.assert_not_called()
        assert not (tmp_path / ".surfaces").exists()

    def test_no_kind_ensures_without_registering(self, tmp_path):
        with patch.object(launch_agent, "ensure_running", return_value=False):
            registration, managed, _ = launch_agent.open_surface(tmp_path, None)
        assert registration is None and managed is True
        assert not (tmp_path / ".surfaces").exists()


class TestRetireBackendIfIdle:
    """Last one out stops the backend, whatever autoswitch.enabled says."""

    @staticmethod
    def _no_widgets(home: Path) -> "launch_agent.PlacedWidgets":
        """A probe whose "none placed" (no host app) is already confirmed."""
        now = [0.0]
        widgets = launch_agent.PlacedWidgets(clock=lambda: now[0])
        widgets.count(home)
        now[0] = launch_agent._PLACED_WIDGETS_CONFIRM_S
        return widgets

    def test_retires_and_removes_its_plist_when_no_surface_is_open(self, tmp_path):
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto"])
        assert launch_agent.retire_backend_if_idle(
            tmp_path, home=tmp_path, widgets=self._no_widgets(tmp_path)
        ) is True
        # Gone from disk, so it is not started again at login.
        assert not launch_agent.plist_path(launch_agent.AUTO_LABEL, tmp_path).exists()

    def test_stays_while_a_surface_is_open(self, tmp_path):
        from claude_swap import locking

        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto"])
        surface = locking.register_surface(tmp_path, "menubar")
        try:
            assert launch_agent.retire_backend_if_idle(tmp_path, home=tmp_path) is False
        finally:
            surface.release()
        assert launch_agent.plist_path(launch_agent.AUTO_LABEL, tmp_path).exists()

    def test_a_crashed_surface_does_not_keep_it_alive(self, tmp_path):
        # A leftover file nobody holds is a surface whose process is gone.
        from claude_swap import locking

        stale = locking.surfaces_dir(tmp_path) / "tui-99999.lock"
        stale.parent.mkdir(parents=True)
        stale.touch()
        assert launch_agent.retire_backend_if_idle(
            tmp_path, home=tmp_path, widgets=self._no_widgets(tmp_path)
        ) is True
        assert not stale.exists()

    def test_defers_while_a_surface_is_mid_decision(self, tmp_path):
        from claude_swap import locking

        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto"])
        busy = locking.lifecycle_lock(tmp_path, timeout=0.0)
        assert busy.acquire()
        try:
            assert launch_agent.retire_backend_if_idle(tmp_path, home=tmp_path) is False
        finally:
            busy.release()
        assert launch_agent.plist_path(launch_agent.AUTO_LABEL, tmp_path).exists()


class TestPlacedWidgetsKeepTheBackend:
    """A widget on the desktop is a viewer the surface locks cannot see."""

    def _app(self, home: Path) -> Path:
        exe = launch_agent.widget_host_executable(home)
        exe.parent.mkdir(parents=True)
        exe.write_text("#!/bin/sh\n")
        return exe

    def _probe(self, answers, clock=lambda: 0.0):
        """A PlacedWidgets whose host app answers from ``answers`` in turn."""
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            answer = next(answers)
            if isinstance(answer, BaseException):
                raise answer
            return answer

        return launch_agent.PlacedWidgets(clock=clock), run, calls

    def _done(self, stdout: str, returncode: int = 0):
        return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr="")

    def test_a_placed_widget_keeps_the_backend_and_its_plist(self, tmp_path):
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto"])
        exe = self._app(tmp_path)
        widgets, run, calls = self._probe(iter([self._done('{"count": 2}\n')]))
        with patch.object(launch_agent.subprocess, "run", run):
            assert launch_agent.retire_backend_if_idle(
                tmp_path, home=tmp_path, widgets=widgets
            ) is False
        assert calls == [[str(exe), "--placed-widgets"]]
        # The plist stays, so RunAtLoad brings it back at login for the widget.
        assert launch_agent.plist_path(launch_agent.AUTO_LABEL, tmp_path).exists()

    def _retire(self, tmp_path, widgets) -> bool:
        return launch_agent.retire_backend_if_idle(tmp_path, home=tmp_path, widgets=widgets)

    def test_no_placed_widget_retires_once_confirmed(self, tmp_path):
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto"])
        self._app(tmp_path)
        now = [0.0]
        widgets, run, calls = self._probe(
            iter([self._done('{"count": 0}')] * 2), clock=lambda: now[0]
        )
        with patch.object(launch_agent.subprocess, "run", run):
            assert self._retire(tmp_path, widgets) is False
            assert launch_agent.plist_path(launch_agent.AUTO_LABEL, tmp_path).exists()
            now[0] = launch_agent._PLACED_WIDGETS_CONFIRM_S
            assert self._retire(tmp_path, widgets) is True
        assert len(calls) == 2  # a zero is asked again, never cached
        assert not launch_agent.plist_path(launch_agent.AUTO_LABEL, tmp_path).exists()

    def test_a_zero_right_after_chronod_restarts_does_not_retire(self, tmp_path):
        # chronod answers 0 for a few seconds after a restart, then the truth.
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto"])
        self._app(tmp_path)
        now = [0.0]
        widgets, run, calls = self._probe(
            iter([self._done('{"count": 0}'), self._done('{"count": 4}')]),
            clock=lambda: now[0],
        )
        with patch.object(launch_agent.subprocess, "run", run):
            assert self._retire(tmp_path, widgets) is False
            now[0] = launch_agent._PLACED_WIDGETS_CONFIRM_S
            assert self._retire(tmp_path, widgets) is False
            # The 4 is cached, and it reset the zero streak.
            now[0] = 2 * launch_agent._PLACED_WIDGETS_CONFIRM_S
            assert self._retire(tmp_path, widgets) is False
        assert len(calls) == 2
        assert launch_agent.plist_path(launch_agent.AUTO_LABEL, tmp_path).exists()

    def test_zeros_closer_than_the_confirm_window_do_not_retire(self, tmp_path):
        self._app(tmp_path)
        now = [0.0]
        widgets, run, _ = self._probe(
            iter([self._done('{"count": 0}')] * 3), clock=lambda: now[0]
        )
        with patch.object(launch_agent.subprocess, "run", run):
            assert widgets.none_placed(tmp_path) is False
            now[0] = 5.0
            assert widgets.none_placed(tmp_path) is False
            now[0] = launch_agent._PLACED_WIDGETS_CONFIRM_S - 0.1
            assert widgets.none_placed(tmp_path) is False

    def test_a_stale_zero_does_not_confirm_a_new_one(self, tmp_path):
        # No checks ran in between (a surface was open): the streak restarts.
        self._app(tmp_path)
        now = [0.0]
        widgets, run, _ = self._probe(
            iter([self._done('{"count": 0}')] * 3), clock=lambda: now[0]
        )
        with patch.object(launch_agent.subprocess, "run", run):
            assert widgets.none_placed(tmp_path) is False
            now[0] = 3600.0
            assert widgets.none_placed(tmp_path) is False
            now[0] += launch_agent._PLACED_WIDGETS_CONFIRM_S
            assert widgets.none_placed(tmp_path) is True

    @pytest.mark.parametrize(
        "answer",
        [
            subprocess.CompletedProcess([], 1, stdout='{"count": 3}', stderr=""),
            subprocess.CompletedProcess([], 0, stdout="not json", stderr=""),
            subprocess.CompletedProcess([], 0, stdout='{"count": "3"}', stderr=""),
            subprocess.CompletedProcess([], 0, stdout="", stderr=""),
            subprocess.TimeoutExpired(["ClaudeSwap"], 10),
            OSError("exec format error"),
        ],
    )
    def test_an_unknown_answer_counts_as_none_and_retires_once_confirmed(
        self, tmp_path, answer, capsys
    ):
        _install_plist(tmp_path, launch_agent.AUTO_LABEL, [*PROGRAM, "auto"])
        self._app(tmp_path)
        now = [0.0]
        widgets, run, _ = self._probe(iter([answer, answer]), clock=lambda: now[0])
        with patch.object(launch_agent.subprocess, "run", run):
            assert self._retire(tmp_path, widgets) is False
            now[0] = launch_agent._PLACED_WIDGETS_CONFIRM_S
            assert self._retire(tmp_path, widgets) is True
        assert "unknown" in capsys.readouterr().err

    def test_a_missing_app_retires_without_spawning(self, tmp_path, capsys):
        now = [0.0]
        widgets, run, calls = self._probe(iter([]), clock=lambda: now[0])
        with patch.object(launch_agent.subprocess, "run", run):
            assert widgets.count(tmp_path) == 0
            assert self._retire(tmp_path, widgets) is False
            now[0] = launch_agent._PLACED_WIDGETS_CONFIRM_S
            assert self._retire(tmp_path, widgets) is True
        assert calls == []
        assert "no widget host app" in capsys.readouterr().err

    def test_the_answer_is_cached_and_logged_once(self, tmp_path, capsys):
        self._app(tmp_path)
        now = [0.0]
        widgets, run, calls = self._probe(
            iter([self._done('{"count": 1}'), self._done('{"count": 1}'),
                  self._done('{"count": 0}')]),
            clock=lambda: now[0],
        )
        with patch.object(launch_agent.subprocess, "run", run):
            assert widgets.count(tmp_path) == 1
            now[0] = launch_agent._PLACED_WIDGETS_CACHE_S - 1
            assert widgets.count(tmp_path) == 1
            assert len(calls) == 1  # served from the cache
            now[0] = launch_agent._PLACED_WIDGETS_CACHE_S
            assert widgets.count(tmp_path) == 1
            assert len(calls) == 2
            now[0] = 2 * launch_agent._PLACED_WIDGETS_CACHE_S
            assert widgets.count(tmp_path) == 0
        err = capsys.readouterr().err.splitlines()
        # One line per change of answer, not per query.
        assert len(err) == 2
        assert "1 widget(s) placed" in err[0] and "no widgets placed" in err[1]

    def test_an_open_surface_does_not_ask_the_app(self, tmp_path):
        from claude_swap import locking

        widgets, run, calls = self._probe(iter([]))
        surface = locking.register_surface(tmp_path, "tui")
        try:
            with patch.object(launch_agent.subprocess, "run", run):
                assert launch_agent.retire_backend_if_idle(
                    tmp_path, home=tmp_path, widgets=widgets
                ) is False
        finally:
            surface.release()
        assert calls == []

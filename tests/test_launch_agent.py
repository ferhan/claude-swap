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

from claude_swap import launch_agent
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


def test_build_plist_is_parseable_and_runs_the_menubar_subcommand(tmp_path):
    parsed = plistlib.loads(launch_agent.build_plist(PROGRAM, home=tmp_path))
    assert parsed["Label"] == launch_agent.LABEL
    assert parsed["ProgramArguments"] == [*PROGRAM, "menubar"]
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
    whichever ran --install-service last silently owns it. Reporting the argv
    the plist on disk actually carries is what makes that visible.
    """
    with patch.object(launch_agent.subprocess, "run") as run:
        run.side_effect = _router({"print": _completed(1)})
        launch_agent.install(home=tmp_path, program=PROGRAM, uid=UID)
        result = launch_agent.status(home=tmp_path, uid=UID)

    assert result["program"] == [*PROGRAM, "menubar"]


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

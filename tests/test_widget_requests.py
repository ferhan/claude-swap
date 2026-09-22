"""The widget's auto-switch requests: a drop directory the backend drains."""

from __future__ import annotations

import json
import stat
from pathlib import Path

from claude_swap import widget_requests
from claude_swap.settings import load_settings, set_setting


def _drop(backup: Path, name: str, enabled, at: str = "2026-09-21T22:00:00Z") -> Path:
    path = widget_requests.ensure_requests_dir(backup) / name
    path.write_text(json.dumps({"autoswitch": {"enabled": enabled}, "at": at}))
    return path


def test_the_directory_is_created_private(tmp_path):
    path = widget_requests.ensure_requests_dir(tmp_path)
    assert path == tmp_path / "widget-requests"
    assert stat.S_IMODE(path.stat().st_mode) == 0o700
    widget_requests.ensure_requests_dir(tmp_path)  # idempotent


def test_a_request_sets_autoswitch_enabled(tmp_path, capsys):
    _drop(tmp_path, "autoswitch-1000.json", True)
    assert widget_requests.apply_pending(tmp_path) is True
    assert load_settings(tmp_path).enabled is True
    raw = json.loads((tmp_path / "settings.json").read_text())
    assert raw["autoswitch"] == {"enabled": True}  # same writer as config set
    assert list(widget_requests.requests_dir(tmp_path).iterdir()) == []
    err = capsys.readouterr().err.strip().splitlines()
    assert err == ["widget: autoswitch.enabled -> true (requested 2026-09-21T22:00:00Z)"]


def test_the_newest_request_wins(tmp_path):
    # Written out of order: the name's epochMillis decides, not mtime.
    _drop(tmp_path, "autoswitch-3000.json", False)
    _drop(tmp_path, "autoswitch-1000.json", True)
    _drop(tmp_path, "autoswitch-2000.json", True)
    set_setting(tmp_path, "autoswitch.enabled", "true")
    assert widget_requests.apply_pending(tmp_path) is True
    assert load_settings(tmp_path).enabled is False
    assert list(widget_requests.requests_dir(tmp_path).iterdir()) == []


def test_invalid_files_are_deleted_and_ignored(tmp_path):
    folder = widget_requests.ensure_requests_dir(tmp_path)
    _drop(tmp_path, "autoswitch-1000.json", True)
    # Newer, but unusable: they must not win, and must not stay.
    (folder / "autoswitch-5000.json").write_text("{not json")
    (folder / "autoswitch-6000.json").write_text(json.dumps({"autoswitch": {"enabled": "yes"}}))
    (folder / "autoswitch-7000.json").write_text(json.dumps([1]))
    _drop(tmp_path, "something-else.json", False)
    assert widget_requests.apply_pending(tmp_path) is True
    assert load_settings(tmp_path).enabled is True
    assert list(folder.iterdir()) == []


def test_only_invalid_files_change_nothing(tmp_path):
    folder = widget_requests.ensure_requests_dir(tmp_path)
    (folder / "autoswitch-1.json").write_text("")
    assert widget_requests.apply_pending(tmp_path) is False
    assert not (tmp_path / "settings.json").exists()
    assert list(folder.iterdir()) == []


def test_dotfiles_are_in_flight_and_left_alone(tmp_path):
    temp = _drop(tmp_path, ".autoswitch-9000.json.tmp", False)
    assert widget_requests.apply_pending(tmp_path) is False
    assert temp.exists()
    assert not (tmp_path / "settings.json").exists()


def test_a_request_matching_the_setting_is_consumed_quietly(tmp_path, capsys):
    set_setting(tmp_path, "autoswitch.enabled", "true")
    _drop(tmp_path, "autoswitch-1000.json", True)
    assert widget_requests.apply_pending(tmp_path) is False
    assert list(widget_requests.requests_dir(tmp_path).iterdir()) == []
    assert capsys.readouterr().err == ""


def test_a_missing_directory_is_nothing_to_do(tmp_path):
    assert widget_requests.apply_pending(tmp_path) is False


def test_autoswitch_pass_leaves_switch_requests_alone(tmp_path):
    folder = widget_requests.ensure_requests_dir(tmp_path)
    (folder / "switch-1000.json").write_text(json.dumps({"switch": {"to": 2}}))
    widget_requests.apply_pending(tmp_path)
    assert [p.name for p in folder.iterdir()] == ["switch-1000.json"]


# -- switch requests -----------------------------------------------------------

NOW = 1_800_000_000.0  # seconds; request names carry milliseconds


class _Switcher:
    """Stands in for ClaudeAccountSwitcher: records what the CLI path gets."""

    def __init__(self, *, active="1", disabled=(), known=("1", "2", "3")):
        self.active = active
        self.disabled = set(disabled)
        self.known = set(known)
        self.calls = []

    def is_account_disabled(self, num):
        return num in self.disabled

    def switch_to(self, identifier, json_output=False, force=False):
        from claude_swap.exceptions import AccountNotFoundError

        self.calls.append((identifier, json_output, force))
        if identifier not in self.known:
            raise AccountNotFoundError(f"No account found with identifier: {identifier}")
        ref = lambda n: {"number": int(n), "email": f"u{n}@example.com"}  # noqa: E731
        if identifier == self.active:
            return {"switched": False, "from": ref(identifier), "to": ref(identifier),
                    "message": f"Already on Account-{identifier} (u{identifier}@example.com)"}
        came_from, self.active = self.active, identifier
        return {"switched": True, "from": ref(came_from), "to": ref(identifier),
                "message": f"Switched to Account-{identifier} (u{identifier}@example.com)"}


def _switch(backup: Path, age_s: float, to, at: str = "2026-09-22T10:00:00Z") -> Path:
    millis = int((NOW - age_s) * 1000)
    path = widget_requests.ensure_requests_dir(backup) / f"switch-{millis}.json"
    path.write_text(json.dumps({"switch": {"to": to}, "at": at}))
    return path


def _apply(backup: Path, switcher: _Switcher) -> bool:
    return widget_requests.apply_switch_request(backup, lambda: switcher, now=NOW)


def test_a_fresh_switch_request_goes_through_switch_to(tmp_path, capsys):
    switcher = _Switcher()
    _switch(tmp_path, 2, 3)
    assert _apply(tmp_path, switcher) is True
    # Exactly what `cswap switch 3` runs, minus the console output.
    assert switcher.calls == [("3", True, False)]
    assert list(widget_requests.requests_dir(tmp_path).iterdir()) == []
    assert capsys.readouterr().err.strip().splitlines() == [
        "widget: Switched to Account-3 (u3@example.com), from Account-1 "
        "(requested 2026-09-22T10:00:00Z)"
    ]


def test_the_newest_fresh_switch_request_wins(tmp_path):
    switcher = _Switcher()
    _switch(tmp_path, 5, 2)
    _switch(tmp_path, 1, 3)
    _switch(tmp_path, 10, 2)
    assert _apply(tmp_path, switcher) is True
    assert switcher.calls == [("3", True, False)]
    assert list(widget_requests.requests_dir(tmp_path).iterdir()) == []


def test_a_stale_switch_request_is_deleted_unapplied(tmp_path, capsys):
    switcher = _Switcher()
    _switch(tmp_path, widget_requests.SWITCH_MAX_AGE_S + 1, 3)
    made = []
    assert widget_requests.apply_switch_request(
        tmp_path, lambda: made.append(1) or switcher, now=NOW
    ) is False
    assert switcher.calls == [] and made == []  # no switcher even built
    assert list(widget_requests.requests_dir(tmp_path).iterdir()) == []
    err = capsys.readouterr().err
    assert "widget: ignored stale switch request to 3 (age 61s" in err


def test_a_stale_newest_does_not_let_an_older_one_through(tmp_path):
    switcher = _Switcher()
    _switch(tmp_path, 120, 2)
    _switch(tmp_path, 90, 3)
    assert _apply(tmp_path, switcher) is False
    assert switcher.calls == []


def test_an_unknown_target_is_refused(tmp_path, capsys):
    switcher = _Switcher()
    _switch(tmp_path, 1, 9)
    assert _apply(tmp_path, switcher) is False
    assert switcher.active == "1"
    assert list(widget_requests.requests_dir(tmp_path).iterdir()) == []
    assert "widget: refused switch request to 9: No account found" in capsys.readouterr().err


def test_a_disabled_target_is_refused(tmp_path, capsys):
    switcher = _Switcher(disabled={"2"})
    _switch(tmp_path, 1, 2)
    assert _apply(tmp_path, switcher) is False
    assert switcher.calls == []
    assert "refused switch request to 2: Account-2 is disabled" in capsys.readouterr().err


def test_the_active_account_is_a_logged_noop(tmp_path, capsys):
    switcher = _Switcher(active="2")
    _switch(tmp_path, 1, 2)
    assert _apply(tmp_path, switcher) is False
    assert "switch request to 2: Already on Account-2" in capsys.readouterr().err


def test_malformed_switch_requests_are_deleted(tmp_path):
    switcher = _Switcher()
    for age, to in enumerate(("2", True, 0, None), start=1):
        _switch(tmp_path, age, to)
    folder = widget_requests.requests_dir(tmp_path)
    (folder / f"switch-{int(NOW * 1000)}.json").write_text("{nope")
    assert _apply(tmp_path, switcher) is False
    assert switcher.calls == []
    assert list(folder.iterdir()) == []


def test_in_flight_switch_temps_are_left_alone(tmp_path):
    folder = widget_requests.ensure_requests_dir(tmp_path)
    temp = folder / f".switch-{int(NOW * 1000)}.json.tmp"
    temp.write_text(json.dumps({"switch": {"to": 2}}))
    assert _apply(tmp_path, _Switcher()) is False
    assert temp.exists()

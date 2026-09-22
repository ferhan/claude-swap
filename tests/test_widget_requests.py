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

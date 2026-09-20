"""Generalized change detection: stat, mtime gate, value comparison.

Every test bumps mtimes explicitly with ``os.utime`` rather than relying on
the clock: two writes inside one filesystem timestamp tick would make an
mtime-gated watcher look broken when it is doing exactly what it should.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from claude_swap.state_watch import ACCOUNTS, ACTIVE, SETTINGS, StateWatcher


def _write(path: Path, data: dict, *, mtime: float) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data), encoding="utf-8")
    os.utime(path, (mtime, mtime))


@pytest.fixture
def state(tmp_path: Path):
    """A config file and a backup root holding the two cswap state files."""
    config = tmp_path / ".claude.json"
    backup = tmp_path / "backup"
    _write(config, {"oauthAccount": {"emailAddress": "a@example.com"}}, mtime=1000)
    _write(backup / "sequence.json", {"accounts": {"1": {"email": "a@example.com"}},
                                      "lastUpdated": "t0"}, mtime=1000)
    _write(backup / "settings.json", {"autoswitch": {"enabled": False}}, mtime=1000)
    return config, backup


def test_construction_primes_so_the_first_poll_is_quiet(state):
    config, backup = state
    assert StateWatcher(config, backup).poll() == set()


def test_detects_the_active_login_changing(state):
    config, backup = state
    watcher = StateWatcher(config, backup)
    _write(config, {"oauthAccount": {"emailAddress": "b@example.com"}}, mtime=2000)
    assert watcher.poll() == {ACTIVE}
    assert watcher.poll() == set()  # reported once, not every tick after


def test_detects_an_account_added_or_aliased(state):
    config, backup = state
    watcher = StateWatcher(config, backup)
    _write(
        backup / "sequence.json",
        {"accounts": {"1": {"email": "a@example.com", "alias": "work"}},
         "lastUpdated": "t1"},
        mtime=2000,
    )
    assert watcher.poll() == {ACCOUNTS}


def test_detects_autoswitch_toggled_from_another_surface(state):
    config, backup = state
    watcher = StateWatcher(config, backup)
    _write(backup / "settings.json", {"autoswitch": {"enabled": True}}, mtime=2000)
    assert watcher.poll() == {SETTINGS}


def test_a_no_op_rewrite_of_claude_json_is_not_a_change(state):
    """Claude Code rewrites this file constantly for its own reasons.

    mtime alone is far too noisy to drive a repaint, so an identical login
    written under a new mtime — plus unrelated keys churning around it — must
    report nothing.
    """
    config, backup = state
    watcher = StateWatcher(config, backup)
    _write(
        config,
        {
            "oauthAccount": {"emailAddress": "a@example.com"},
            "tipsHistory": {"shift-enter": 4},
            "projects": {"/tmp/x": {"lastUsed": "now"}},
        },
        mtime=2000,
    )
    assert watcher.poll() == set()


def test_a_sequence_write_that_only_bumps_lastupdated_is_not_a_change(state):
    config, backup = state
    watcher = StateWatcher(config, backup)
    _write(
        backup / "sequence.json",
        {"accounts": {"1": {"email": "a@example.com"}}, "lastUpdated": "t99"},
        mtime=2000,
    )
    assert watcher.poll() == set()


def test_only_the_file_whose_mtime_moved_is_parsed(state):
    """The gate that keeps a per-second check cheap: no stat change, no read.

    The second half is the other half of the contract — the file that DID
    move is parsed, and still reports nothing because its value is the same.
    """
    config, backup = state
    watcher = StateWatcher(config, backup)
    reads: list[Path] = []
    watcher._sources = {
        name: (path, lambda p, _reader=reader: (reads.append(p), _reader(p))[1])
        for name, (path, reader) in watcher._sources.items()
    }
    assert watcher.poll() == set()
    assert reads == []
    os.utime(config, (2000, 2000))
    assert watcher.poll() == set()
    assert reads == [config]


def test_missing_files_compare_equal_to_each_other(tmp_path: Path):
    """A fresh machine has none of these yet; that is a steady state, not a
    change every second until something creates them."""
    watcher = StateWatcher(tmp_path / "nope.json", tmp_path / "backup")
    assert watcher.poll() == set()
    assert watcher.poll() == set()


def test_a_file_appearing_is_a_change(tmp_path: Path):
    backup = tmp_path / "backup"
    watcher = StateWatcher(tmp_path / ".claude.json", backup)
    _write(backup / "settings.json", {"autoswitch": {"enabled": True}}, mtime=2000)
    assert watcher.poll() == {SETTINGS}


def test_corrupt_json_is_not_a_crash_and_heals(state):
    config, backup = state
    watcher = StateWatcher(config, backup)
    settings = backup / "settings.json"
    settings.write_text("{ truncated", encoding="utf-8")
    os.utime(settings, (2000, 2000))
    assert watcher.poll() == {SETTINGS}  # unreadable differs from what was there
    _write(settings, {"autoswitch": {"enabled": False}}, mtime=3000)
    assert watcher.poll() == {SETTINGS}


def test_detection_touches_neither_the_keychain_nor_the_network(state, monkeypatch):
    """The whole reason a ~1s cadence is affordable (ARCHITECTURE.md, "Two
    classes of change"): state is a local file read, measurements are not."""
    import subprocess
    import urllib.request

    from claude_swap import macos_keychain

    def _forbidden(*args, **kwargs):
        raise AssertionError("state detection must not leave the filesystem")

    for name in ("get_password", "set_password", "item_exists", "delete_password"):
        monkeypatch.setattr(macos_keychain, name, _forbidden)
    monkeypatch.setattr(subprocess, "run", _forbidden)
    monkeypatch.setattr(subprocess, "Popen", _forbidden)
    monkeypatch.setattr(urllib.request, "urlopen", _forbidden)

    config, backup = state
    watcher = StateWatcher(config, backup)
    _write(config, {"oauthAccount": {"emailAddress": "b@example.com"}}, mtime=2000)
    _write(backup / "settings.json", {"autoswitch": {"enabled": True}}, mtime=2000)
    assert watcher.poll() == {ACTIVE, SETTINGS}


def test_mappings_are_deliberately_not_watched(state):
    """`cswap map` writes mappings.json, but no surface renders directory
    mappings — so watching it would buy a repaint of nothing. Documented as a
    test so the omission reads as a decision, not an oversight."""
    config, backup = state
    watcher = StateWatcher(config, backup)
    _write(backup / "mappings.json", {"/tmp/p": {"email": "a@example.com"}}, mtime=2000)
    assert watcher.poll() == set()

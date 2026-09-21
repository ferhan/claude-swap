"""Tests for the backend's 24h display history store (``usage_history``)."""

from __future__ import annotations

import stat
import sys
from pathlib import Path
from unittest.mock import patch

import pytest

from claude_swap.usage_history import MAX_POINTS, UsageHistory

_NOW = 2_000_000_000.0


def test_samples_round_trip_oldest_first(tmp_path: Path):
    h = UsageHistory(tmp_path)
    h.record_samples({"1": ("a@x.com", _NOW - 900, 10.0)}, _NOW - 900)
    h.record_samples({"1": ("a@x.com", _NOW - 300, 20.0)}, _NOW)
    assert h.five_hour({"1": "a@x.com"}, _NOW) == {
        "1": [[_NOW - 900, 10.0], [_NOW - 300, 20.0]]
    }


def test_one_point_per_five_minute_bucket_latest_wins(tmp_path: Path):
    h = UsageHistory(tmp_path)
    base = 300.0 * (_NOW // 300)
    for offset, pct in ((0, 1.0), (60, 2.0), (299, 3.0), (300, 4.0)):
        h.record_samples({"1": ("a@x.com", base + offset, pct)}, base + offset)
    assert h.five_hour({"1": "a@x.com"}, base + 300) == {
        "1": [[base + 299, 3.0], [base + 300, 4.0]]
    }


def test_an_already_recorded_measurement_writes_nothing(tmp_path: Path):
    h = UsageHistory(tmp_path)
    h.record_samples({"1": ("a@x.com", _NOW, 10.0)}, _NOW)
    with patch("claude_swap.usage_history.atomic_write_json") as write:
        h.record_samples({"1": ("a@x.com", _NOW, 10.0)}, _NOW + 60)
    write.assert_not_called()


def test_pruned_to_24h_and_capped(tmp_path: Path):
    h = UsageHistory(tmp_path)
    start = _NOW - 30 * 3600
    for i in range(400):
        t = start + i * 300
        h.record_samples({"1": ("a@x.com", t, float(i))}, t)
    end = start + 399 * 300
    series = h.five_hour({"1": "a@x.com"}, end)["1"]
    assert len(series) <= MAX_POINTS == 288
    assert series[0][0] >= end - 24 * 3600
    assert series[-1] == [end, 399.0]


def test_a_reused_slot_does_not_inherit_the_previous_series(tmp_path: Path):
    h = UsageHistory(tmp_path)
    h.record_samples({"1": ("old@x.com", _NOW - 600, 90.0)}, _NOW - 600)
    assert h.five_hour({"1": "new@x.com"}, _NOW) == {}
    h.record_samples({"1": ("new@x.com", _NOW, 5.0)}, _NOW)
    assert h.five_hour({"1": "new@x.com"}, _NOW) == {"1": [[_NOW, 5.0]]}


def test_switches_pruned_to_24h(tmp_path: Path):
    h = UsageHistory(tmp_path)
    h.record_switch(_NOW - 25 * 3600, 1, 2)
    h.record_switch(_NOW - 60, 2, 3)
    assert h.switches(_NOW) == [{"at": _NOW - 60, "from": 2, "to": 3}]


def test_unreadable_file_reads_empty(tmp_path: Path):
    (tmp_path / "usage_history.json").write_text("{not json")
    h = UsageHistory(tmp_path)
    assert h.five_hour({"1": "a@x.com"}, _NOW) == {}
    assert h.switches(_NOW) == []
    h.record_switch(_NOW, 1, 2)  # a corrupt file is replaced, not fatal
    assert h.switches(_NOW) == [{"at": _NOW, "from": 1, "to": 2}]


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX file modes")
def test_written_0600(tmp_path: Path):
    UsageHistory(tmp_path).record_switch(_NOW, 1, 2)
    assert stat.S_IMODE((tmp_path / "usage_history.json").stat().st_mode) == 0o600

"""Tests for ``cswap snapshot`` — the one-shot display-state JSON document.

The projection itself is pure (``snapshot_payload`` takes an
``AccountsSnapshot`` and returns a dict), so most of this needs no switcher at
all; the CLI tests drive ``cli.main`` against a fake switcher that serves a
canned aggregate.
"""

from __future__ import annotations

import json
import os
import stat
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

from claude_swap import cli
from claude_swap.json_output import SCHEMA_VERSION, USAGE_API_KEY, USAGE_TOKEN_EXPIRED
from claude_swap.models import AccountSnapshot, AccountsSnapshot
from claude_swap.snapshot_json import snapshot_payload, take_snapshot, write_snapshot
from claude_swap.usage_store import UsageEntry

_NOW = time.time()


def _iso(offset_s: float, now: float = _NOW) -> str:
    return datetime.fromtimestamp(now + offset_s, tz=timezone.utc).isoformat()


def _entry(
    usage: dict | None = None,
    *,
    sentinel: str | None = None,
    fetched_at: float | None = None,
    age_s: float | None = None,
) -> UsageEntry:
    return UsageEntry(
        sentinel=sentinel,
        last_good=usage,
        fetched_at=_NOW - 60 if fetched_at is None and usage else fetched_at,
        age_s=60.0 if age_s is None and usage else age_s,
    )


def _account(
    number: str = "1",
    *,
    email: str = "one@example.com",
    org_name: str = "",
    org_uuid: str = "",
    is_active: bool = False,
    kind: str = "oauth",
    switchable: bool = True,
    usage: UsageEntry | None = None,
    alias: str = "",
    disabled: bool = False,
) -> AccountSnapshot:
    return AccountSnapshot(
        number=number,
        email=email,
        org_name=org_name,
        org_uuid=org_uuid,
        is_active=is_active,
        kind=kind,
        switchable=switchable,
        usage=usage if usage is not None else _entry(),
        alias=alias,
        disabled=disabled,
    )


def _snap(*accounts: AccountSnapshot, taken_at: float = _NOW) -> AccountsSnapshot:
    active = next((a.number for a in accounts if a.is_active), None)
    return AccountsSnapshot(
        active_number=active, accounts=tuple(accounts), taken_at=taken_at
    )


# --- field completeness vs the aggregate --------------------------------------

def test_payload_carries_every_aggregate_field():
    usage = {"five_hour": {"pct": 25.0, "resets_at": _iso(3600)}}
    acc = _account(
        "2",
        email="two@example.com",
        org_name="Acme",
        org_uuid="org-uuid-1",
        is_active=True,
        kind="oauth",
        switchable=True,
        usage=_entry(usage),
        alias="work",
        disabled=True,
    )

    payload = snapshot_payload(_snap(acc))

    assert payload["schemaVersion"] == SCHEMA_VERSION
    assert payload["takenAt"].endswith("Z")
    assert payload["activeAccountNumber"] == 2
    row = payload["accounts"][0]
    assert row["number"] == 2
    assert row["email"] == "two@example.com"
    assert row["organizationName"] == "Acme"
    assert row["organizationUuid"] == "org-uuid-1"
    assert row["isOrganization"] is True
    assert row["active"] is True
    assert row["kind"] == "oauth"
    assert row["switchable"] is True
    assert row["alias"] == "work"
    assert row["disabled"] is True
    assert row["usageStatus"] == "ok"
    assert row["usage"]["fiveHour"]["pct"] == 25.0
    assert row["usageFetchedAt"].endswith("Z")
    assert row["usageAgeSeconds"] == 60.0


def test_payload_carries_switchable_and_kind_that_list_json_drops():
    # The two fields the aggregate has and ``--list --json`` does not; a
    # consumer needs ``switchable`` to decide whether to offer a switch.
    rows = snapshot_payload(
        _snap(
            _account("1", switchable=True, kind="oauth"),
            _account("2", email="k@example.com", switchable=False, kind="api_key",
                     usage=_entry(sentinel=USAGE_API_KEY)),
        )
    )["accounts"]

    assert [(r["number"], r["kind"], r["switchable"]) for r in rows] == [
        (1, "oauth", True),
        (2, "api_key", False),
    ]
    assert rows[1]["usageStatus"] == "api_key"
    assert rows[1]["usage"] is None


def test_optional_fields_absent_when_unset():
    row = snapshot_payload(_snap(_account()))["accounts"][0]
    assert "alias" not in row
    assert "disabled" not in row


def test_no_active_account_reports_null():
    payload = snapshot_payload(_snap(_account("1"), _account("2", email="b@x.com")))
    assert payload["activeAccountNumber"] is None


def test_sentinel_row_reports_status_and_null_usage():
    row = snapshot_payload(
        _snap(_account(usage=_entry({"five_hour": {"pct": 5.0}},
                                    sentinel=USAGE_TOKEN_EXPIRED)))
    )["accounts"][0]
    assert row["usageStatus"] == "token_expired"
    assert row["usage"] is None
    # Nothing is served, so nothing is dated (mirrors ``account_row``).
    assert "usageFetchedAt" not in row


def test_missing_usage_reports_unavailable():
    row = snapshot_payload(_snap(_account(usage=_entry(None))))["accounts"][0]
    assert row["usageStatus"] == "unavailable"
    assert row["usage"] is None


# --- weekly roll-forward -------------------------------------------------------

def test_passed_weekly_reset_is_reported_zeroed():
    usage = {
        "five_hour": {"pct": 42.0, "resets_at": _iso(3600)},
        "seven_day": {"pct": 95.0, "resets_at": _iso(-3 * 86400),
                      "countdown": "stale", "clock": "old"},
    }
    row = snapshot_payload(_snap(_account(usage=_entry(usage))))["accounts"][0]

    seven = row["usage"]["sevenDay"]
    assert seven["pct"] == 0.0  # the window objectively rolled over
    rolled = datetime.fromisoformat(seven["resetsAt"]).timestamp()
    assert abs(rolled - (_NOW + 4 * 86400)) < 1
    assert seven["countdown"] != "stale"  # recomputed from the rolled resetsAt
    # The 5h window is untouched by the weekly roll-forward.
    assert row["usage"]["fiveHour"]["pct"] == 42.0


def test_passed_scoped_weekly_reset_is_reported_zeroed():
    usage = {
        "scoped": [
            {"name": "Fable", "pct": 100.0, "resets_at": _iso(-2 * 86400)},
            {"name": "Opus", "pct": 70.0, "resets_at": _iso(2 * 86400)},
        ]
    }
    scoped = snapshot_payload(
        _snap(_account(usage=_entry(usage)))
    )["accounts"][0]["usage"]["scoped"]

    assert scoped[0]["name"] == "Fable"
    assert scoped[0]["pct"] == 0.0  # rolled, so no longer maxed
    assert scoped[0]["maxed"] is False
    assert scoped[1]["pct"] == 70.0  # future reset untouched
    assert scoped[1]["maxed"] is False


def test_roll_forward_does_not_mutate_the_aggregate():
    usage = {"seven_day": {"pct": 95.0, "resets_at": _iso(-3 * 86400)}}
    acc = _account(usage=_entry(usage))
    snapshot_payload(_snap(acc))
    assert usage["seven_day"]["pct"] == 95.0
    assert acc.usage.last_good is usage


# --- derived presentation flags ------------------------------------------------

def test_maxed_scoped_window_is_flagged():
    usage = {"scoped": [{"name": "Fable", "pct": 100.0, "resets_at": _iso(2 * 86400)}]}
    scoped = snapshot_payload(
        _snap(_account(usage=_entry(usage)))
    )["accounts"][0]["usage"]["scoped"][0]
    assert scoped["maxed"] is True
    assert scoped["resetsAt"]  # raw timestamp kept for a live countdown


def test_ahead_of_pace_is_precomputed_for_the_weekly_window():
    # Mid-week (reset 3.5d out) at 90% used — far past the ~50% expected.
    fetched_at = _NOW - 60
    usage = {"seven_day": {"pct": 90.0, "resets_at": _iso(3.5 * 86400)}}
    seven = snapshot_payload(
        _snap(_account(usage=_entry(usage, fetched_at=fetched_at)))
    )["accounts"][0]["usage"]["sevenDay"]

    assert seven["aheadOfPace"] is True
    assert seven["expectedPct"] == pytest.approx(50.0, abs=1.0)


def test_rolled_weekly_window_is_never_ahead_of_pace():
    # Pace must be computed against the rolled (0%) window, not last cycle's.
    usage = {"seven_day": {"pct": 99.0, "resets_at": _iso(-3 * 86400)}}
    seven = snapshot_payload(
        _snap(_account(usage=_entry(usage, fetched_at=_NOW - 60)))
    )["accounts"][0]["usage"]["sevenDay"]
    assert seven.get("aheadOfPace") is not True


def test_matches_the_menubar_roll_forward():
    from claude_swap import menubar

    window = {"pct": 88.0, "resets_at": _iso(-9 * 86400)}
    assert menubar._rolled_weekly_window(window, _NOW) == {
        "pct": 0.0,
        "resets_at": snapshot_payload(
            _snap(_account(usage=_entry({"seven_day": dict(window)})))
        )["accounts"][0]["usage"]["sevenDay"]["resetsAt"],
    }


# --- scoped-window family grouping ----------------------------------------------

def test_scoped_windows_collapse_by_model_family():
    # Two Opus versions collapse into one row; the max-pct window wins.
    usage = {
        "scoped": [
            {"name": "Claude Opus 4.8", "pct": 40.0, "resets_at": _iso(1 * 86400)},
            {"name": "Opus 5", "pct": 90.0, "resets_at": _iso(2 * 86400)},
        ]
    }
    scoped = snapshot_payload(
        _snap(_account(usage=_entry(usage)))
    )["accounts"][0]["usage"]["scoped"]

    assert len(scoped) == 1
    assert scoped[0]["name"] == "Opus"
    assert scoped[0]["pct"] == 90.0  # max across the group
    # resetsAt/countdown come from the max-pct (binding) window.
    assert scoped[0]["resetsAt"] == usage["scoped"][1]["resets_at"]


def test_scoped_windows_maxed_is_true_if_any_member_is_maxed():
    usage = {
        "scoped": [
            {"name": "Opus 4", "pct": 100.0, "resets_at": _iso(1 * 86400)},
            {"name": "Opus 5", "pct": 20.0, "resets_at": _iso(2 * 86400)},
        ]
    }
    scoped = snapshot_payload(
        _snap(_account(usage=_entry(usage)))
    )["accounts"][0]["usage"]["scoped"]

    assert len(scoped) == 1
    # The binding (max-pct) window is the 100% one, so pct/resetsAt/maxed all
    # agree here; the point of the test is that "any maxed" holds generally.
    assert scoped[0]["pct"] == 100.0
    assert scoped[0]["maxed"] is True


def test_scoped_window_name_matching_no_family_passes_through_unchanged():
    usage = {"scoped": [{"name": "Some Custom Model", "pct": 10.0}]}
    scoped = snapshot_payload(
        _snap(_account(usage=_entry(usage)))
    )["accounts"][0]["usage"]["scoped"]

    assert len(scoped) == 1
    assert scoped[0]["name"] == "Some Custom Model"
    assert scoped[0]["pct"] == 10.0


def test_scoped_family_match_is_case_insensitive():
    usage = {"scoped": [{"name": "opus", "pct": 15.0}]}
    scoped = snapshot_payload(
        _snap(_account(usage=_entry(usage)))
    )["accounts"][0]["usage"]["scoped"]

    assert scoped[0]["name"] == "Opus"  # normalized to the canonical family name


def test_scoped_family_groups_preserve_order_of_first_appearance():
    usage = {
        "scoped": [
            {"name": "Sonnet 4", "pct": 10.0},
            {"name": "Custom Model", "pct": 20.0},
            {"name": "Opus 4", "pct": 30.0},
            {"name": "Opus 5", "pct": 40.0},  # collapses into the earlier Opus group
            {"name": "Sonnet 5", "pct": 50.0},  # collapses into the earlier Sonnet group
        ]
    }
    scoped = snapshot_payload(
        _snap(_account(usage=_entry(usage)))
    )["accounts"][0]["usage"]["scoped"]

    assert [w["name"] for w in scoped] == ["Sonnet", "Custom Model", "Opus"]
    assert next(w for w in scoped if w["name"] == "Sonnet")["pct"] == 50.0
    assert next(w for w in scoped if w["name"] == "Opus")["pct"] == 40.0


# --- no secrets ----------------------------------------------------------------

_SECRET_MARKERS = ("token", "secret", "password", "apikey", "credential", "bearer")


def _walk(node, path=""):
    if isinstance(node, dict):
        for key, value in node.items():
            yield f"{path}.{key}", key, value
            yield from _walk(value, f"{path}.{key}")
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from _walk(value, f"{path}[{i}]")


def test_payload_emits_no_token_like_keys_or_values():
    usage = {
        "five_hour": {"pct": 25.0, "resets_at": _iso(3600)},
        "seven_day": {"pct": 40.0, "resets_at": _iso(3 * 86400)},
        "scoped": [{"name": "Fable", "pct": 100.0, "resets_at": _iso(86400)}],
        "spend": {"used": 12.5, "limit": 300.0, "pct": 4.0, "currency": "USD"},
    }
    payload = snapshot_payload(
        _snap(
            _account("1", usage=_entry(usage), is_active=True, alias="work"),
            _account("2", email="k@example.com", kind="api_key", switchable=False,
                     usage=_entry(sentinel=USAGE_API_KEY)),
        )
    )

    for dotted, key, value in _walk(payload):
        lowered = key.lower()
        assert not any(m in lowered for m in _SECRET_MARKERS), dotted
        if isinstance(value, str):
            assert not value.startswith("sk-ant-"), dotted
    # ``usageStatus`` values are the only place a sentinel string surfaces, and
    # they are fixed vocabulary, not data.
    assert {r["usageStatus"] for r in payload["accounts"]} <= {
        "ok", "api_key", "token_expired", "keychain_unavailable",
        "relogin_required", "foreign_credential", "no_credentials", "unavailable",
    }


# --- atomic 0600 write ---------------------------------------------------------

@pytest.mark.skipif(sys.platform == "win32", reason="POSIX file modes")
def test_write_snapshot_creates_the_file_0600(tmp_path: Path):
    out = tmp_path / "snapshot.json"
    write_snapshot(out, {"schemaVersion": SCHEMA_VERSION, "accounts": []})

    assert stat.S_IMODE(out.stat().st_mode) == 0o600
    assert json.loads(out.read_text())["schemaVersion"] == SCHEMA_VERSION


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX file modes")
def test_write_snapshot_rewrites_a_loose_mode_in_place(tmp_path: Path):
    out = tmp_path / "snapshot.json"
    out.write_text("{}")
    os.chmod(out, 0o644)

    write_snapshot(out, {"schemaVersion": SCHEMA_VERSION})

    assert stat.S_IMODE(out.stat().st_mode) == 0o600


def test_write_snapshot_publishes_by_rename(tmp_path: Path):
    out = tmp_path / "snapshot.json"
    seen: list[tuple[str, str]] = []

    real_replace = os.replace

    def spy(src, dst):
        # The target must not exist under its final name until the rename: a
        # reader polling the file never sees a half-written document.
        seen.append((str(src), str(dst)))
        assert Path(src) != out
        real_replace(src, dst)

    with patch("claude_swap.fsutil.os.replace", spy):
        write_snapshot(out, {"schemaVersion": SCHEMA_VERSION})

    assert len(seen) == 1 and seen[0][1] == str(out)
    assert list(tmp_path.iterdir()) == [out]  # no temp file left behind


def test_write_snapshot_creates_missing_parents(tmp_path: Path):
    out = tmp_path / "nested" / "dir" / "snapshot.json"
    write_snapshot(out, {"schemaVersion": SCHEMA_VERSION})
    assert out.exists()


def test_write_snapshot_rejects_a_directory(tmp_path: Path):
    from claude_swap.exceptions import ClaudeSwitchError

    with pytest.raises(ClaudeSwitchError, match="not a directory"):
        write_snapshot(tmp_path, {"schemaVersion": SCHEMA_VERSION})


def test_write_snapshot_leaves_no_temp_file_on_failure(tmp_path: Path):
    out = tmp_path / "snapshot.json"
    with patch("claude_swap.fsutil.os.replace", side_effect=OSError("boom")):
        with pytest.raises(OSError):
            write_snapshot(out, {"schemaVersion": SCHEMA_VERSION})
    assert list(tmp_path.iterdir()) == []


# --- CLI wiring ----------------------------------------------------------------

class _FakeSwitcher:
    """The surface ``SnapshotSource`` consumes, and nothing else."""

    def __init__(self, snap: AccountsSnapshot, backup_dir: Path | None = None):
        self._snap = snap
        # Where ``take_snapshot`` reads the 5h history store; a missing dir
        # just means no history yet.
        self.backup_dir = backup_dir or Path("/nonexistent-cswap-backup")
        self.fetch_sets: list[set[str] | None] = []

    def accounts_snapshot(self, fetch: set[str] | None = None) -> AccountsSnapshot:
        self.fetch_sets.append(fetch)
        return self._snap

    def _is_running_in_container(self) -> bool:
        return True


@pytest.fixture
def fake_switcher():
    switcher = _FakeSwitcher(
        _snap(
            _account("1", is_active=True,
                     usage=_entry({"five_hour": {"pct": 25.0, "resets_at": _iso(3600)}})),
            _account("2", email="two@example.com", switchable=False),
        )
    )
    with patch.object(cli, "ClaudeAccountSwitcher", return_value=switcher):
        yield switcher


def _run(argv: list[str]) -> None:
    with patch.object(sys, "argv", ["cswap", *argv]):
        cli.main()


def test_snapshot_command_prints_json_to_stdout(fake_switcher, capsys):
    _run(["snapshot"])

    payload = json.loads(capsys.readouterr().out)
    assert payload["schemaVersion"] == SCHEMA_VERSION
    assert payload["activeAccountNumber"] == 1
    assert [a["number"] for a in payload["accounts"]] == [1, 2]
    # Paced like every other read path: the store decides what may be fetched.
    assert fake_switcher.fetch_sets == [None]
    # History is store data, so the one-shot carries it (empty here); the
    # ``autoswitch`` block is engine state and only the engine publishes it.
    assert payload["accounts"][0]["usage"]["fiveHour"]["history"] == []
    assert "autoswitch" not in payload


def test_snapshot_command_writes_the_file_instead_of_stdout(
    fake_switcher, capsys, tmp_path: Path
):
    out = tmp_path / "state.json"
    _run(["snapshot", "--out", str(out)])

    assert capsys.readouterr().out == ""
    assert json.loads(out.read_text())["activeAccountNumber"] == 1
    if sys.platform != "win32":
        assert stat.S_IMODE(out.stat().st_mode) == 0o600


def test_snapshot_command_reports_errors_as_a_json_envelope(capsys):
    from claude_swap.exceptions import ConfigError

    with patch.object(cli, "ClaudeAccountSwitcher", side_effect=ConfigError("nope")):
        with pytest.raises(SystemExit) as exc:
            _run(["snapshot"])

    assert exc.value.code == 1
    payload = json.loads(capsys.readouterr().out)
    assert payload["error"] == {"type": "ConfigError", "message": "nope"}


def test_snapshot_never_probes_the_terminal_background():
    from claude_swap.appearance import cli_should_probe

    assert cli_should_probe(["snapshot"], colors_enabled=True) is False
    assert cli_should_probe(["list"], colors_enabled=True) is True


# --- golden fixture: the Swift widget's schema contract ------------------------

# The macOS WidgetKit widget (``widget/``, Swift) decodes this exact document,
# and its own decoder test — ``widget/Tests/SnapshotGoldenTests.swift`` — asserts
# against this same committed file. The two halves move together or the widget
# silently fails to decode a shipped snapshot.
_GOLDEN_PATH = Path(__file__).parent / "fixtures" / "snapshot_golden.json"

# A fixed clock, so the fixture is byte-stable across runs. Every ``...Z``
# timestamp in it is derived from this instant; the ``resetsAt`` strings are raw
# API values (fractional seconds, numeric offset) passed straight through.
_GOLDEN_NOW = datetime(2026, 9, 20, 10, 3, 48, tzinfo=timezone.utc).timestamp()


@pytest.fixture
def frozen_clock(monkeypatch):
    """Pin the wall clock AND the local zone for ``countdown``/``clock``.

    Those two strings are re-rendered at serialization time from
    ``datetime.now()`` in *local* time (``oauth.format_reset``), so they are the
    only part of the payload that is neither pure nor UTC. Both have to be
    pinned or the fixture differs per machine and per minute.
    """
    monkeypatch.setenv("TZ", "UTC")
    time.tzset()
    frozen = datetime.fromtimestamp(_GOLDEN_NOW, tz=timezone.utc)
    with patch("claude_swap.oauth.datetime") as mock_dt:
        mock_dt.fromisoformat = datetime.fromisoformat
        mock_dt.now.return_value = frozen
        yield
    time.tzset()


def _golden_switcher(backup_dir: Path | None = None) -> _FakeSwitcher:
    """The synthetic aggregate the fixture is generated from.

    Fake identities only — no real email, organization name or organization
    UUID may ever reach a committed file. Each row pins one decoding case:

    1. pace present (``aheadOfPace``/``expectedPct``/``projectedExhaustionAt``),
       plus ``spend``, an alias and the active flag.
    2. pace ABSENT — not false, not null: under 24h into the weekly window, so
       ``pace.compute_pace`` suppresses it.
    3. a ``maxed`` scoped window (which outranks ``aheadOfPace``) beside a
       plain one, and no ``sevenDay`` at all.
    4. a sentinel row: ``usage: null`` with a machine-readable ``usageStatus``,
       non-switchable, and the optional ``disabled`` flag.
    """
    return _FakeSwitcher(_snap(
        _account(
            "1",
            email="dev@example.com",
            org_name="Example Org",
            org_uuid="00000000-0000-4000-8000-000000000001",
            is_active=True,
            alias="work",
            usage=_entry(
                {
                    "five_hour": {
                        "pct": 62.5,
                        "resets_at": "2026-09-20T13:33:43.377897+00:00",
                    },
                    "seven_day": {
                        "pct": 88.0,
                        "resets_at": "2026-09-23T21:33:43.377897+00:00",
                    },
                    "spend": {
                        "used": 12.5,
                        "limit": 300.0,
                        "pct": 4.2,
                        "currency": "USD",
                        "resets_at": "2026-10-01T00:00:00.000000+00:00",
                    },
                },
                fetched_at=_GOLDEN_NOW - 90,
                age_s=90.0,
            ),
        ),
        _account(
            "2",
            email="second@example.com",
            usage=_entry(
                {
                    "five_hour": {
                        "pct": 5.0,
                        "resets_at": "2026-09-20T12:48:12.114530+00:00",
                    },
                    "seven_day": {
                        "pct": 12.0,
                        "resets_at": "2026-09-27T03:03:48.512345+00:00",
                    },
                },
                fetched_at=_GOLDEN_NOW - 3600,
                age_s=3600.0,
            ),
        ),
        _account(
            "3",
            email="third@example.com",
            org_name="Example Team",
            org_uuid="00000000-0000-4000-8000-000000000003",
            usage=_entry(
                {
                    "five_hour": {
                        "pct": 41.0,
                        "resets_at": "2026-09-20T11:12:05.980112+00:00",
                    },
                    "scoped": [
                        {
                            "name": "Opus",
                            "pct": 100.0,
                            "resets_at": "2026-09-24T08:15:00.240921+00:00",
                        },
                        {
                            "name": "Sonnet",
                            "pct": 30.0,
                            "resets_at": "2026-09-24T08:15:00.240921+00:00",
                        },
                    ],
                },
                fetched_at=_GOLDEN_NOW - 120,
                age_s=120.0,
            ),
        ),
        _account(
            "4",
            email="apikey@example.com",
            kind="api_key",
            switchable=False,
            disabled=True,
            usage=_entry(sentinel=USAGE_API_KEY),
        ),
        taken_at=_GOLDEN_NOW,
    ), backup_dir)


def _golden_history(backup_dir: Path) -> None:
    """History rows for the fixture: account 1 has three samples (one older
    than 24h, pruned), account 2 has a series recorded under a previous
    occupant's email (not served, so ``history: []``), and two switches, one
    older than 24h."""
    from claude_swap.usage_history import UsageHistory

    history = UsageHistory(backup_dir)
    history.record_samples(
        {"1": ("dev@example.com", _GOLDEN_NOW - 25 * 3600, 10.0)},
        _GOLDEN_NOW - 25 * 3600,
    )
    history.record_samples(
        {"1": ("dev@example.com", _GOLDEN_NOW - 600, 55.0),
         "2": ("someone-else@example.com", _GOLDEN_NOW - 600, 99.0)},
        _GOLDEN_NOW - 600,
    )
    history.record_samples(
        {"1": ("dev@example.com", _GOLDEN_NOW - 90, 62.5)}, _GOLDEN_NOW
    )
    history.record_switch(_GOLDEN_NOW - 30 * 3600, 3, 2)
    history.record_switch(_GOLDEN_NOW - 7200, 2, 1)


# What the engine passes as ``cswap_command`` (``launch_agent.resolve_program``).
_GOLDEN_CSWAP_COMMAND = ["/Users/dev/.local/bin/cswap"]


# What the engine passes as ``autoswitch`` (see
# ``AutoSwitchEngine._autoswitch_block``); pinned here as the shape contract.
def _golden_autoswitch(backup_dir: Path) -> dict:
    from claude_swap.json_output import iso_timestamp
    from claude_swap.usage_history import UsageHistory

    return {
        "enabled": True,
        "threshold": 90.0,
        "nextCandidateNumber": 2,
        "switches": [
            {"at": iso_timestamp(s["at"]), "from": s["from"], "to": s["to"]}
            for s in UsageHistory(backup_dir).switches(_GOLDEN_NOW)
        ],
    }


@pytest.mark.skipif(sys.platform == "win32", reason="TZ pinning needs time.tzset()")
def test_snapshot_matches_the_committed_golden_fixture(frozen_clock, tmp_path):
    from claude_swap.snapshot_json import history_for

    _golden_history(tmp_path)
    snap = _golden_switcher(tmp_path).accounts_snapshot()
    # The engine's publish path: history from the store plus its own block.
    payload = snapshot_payload(
        snap,
        history=history_for(tmp_path, snap),
        autoswitch=_golden_autoswitch(tmp_path),
        cswap_command=_GOLDEN_CSWAP_COMMAND,
    )
    # The one-shot is the same document minus the engine-only keys.
    one_shot = take_snapshot(_golden_switcher(tmp_path))
    engine_only = {"autoswitch", "cswapCommand"}
    assert one_shot == {k: v for k, v in payload.items() if k not in engine_only}

    if os.environ.get("UPDATE_GOLDEN"):
        _GOLDEN_PATH.write_text(json.dumps(payload, indent=2) + "\n")

    assert payload == json.loads(_GOLDEN_PATH.read_text()), (
        "The `cswap snapshot` JSON schema changed: this payload no longer "
        f"matches the committed golden fixture at {_GOLDEN_PATH}. The macOS "
        "widget's Swift decoder asserts against this same file "
        "(widget/Tests/SnapshotGoldenTests.swift) and MUST be updated in "
        "lockstep — a field renamed, dropped or retyped here is a decode "
        "failure in a shipped widget. If the change is intentional, "
        "regenerate with:\n"
        "    UPDATE_GOLDEN=1 uv run pytest tests/test_snapshot_json.py -k golden"
    )


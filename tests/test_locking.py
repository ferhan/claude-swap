"""Tests for file locking mechanism."""

from __future__ import annotations

import multiprocessing
import os
import time
from pathlib import Path

import pytest

from claude_swap.exceptions import LockError
from claude_swap.locking import (
    EngineLock,
    FileLock,
    describe_engine_holder,
    engine_lock_holder,
    engine_lock_path,
)


class TestFileLock:
    """Test FileLock class."""

    def test_acquire_and_release(self, tmp_path: Path):
        """Test basic lock acquire and release."""
        lock_path = tmp_path / ".lock"
        lock = FileLock(lock_path)

        assert lock.acquire(timeout=1.0) is True
        assert lock._locked is True
        lock.release()
        assert lock._locked is False

    def test_context_manager(self, tmp_path: Path):
        """Test using lock as context manager."""
        lock_path = tmp_path / ".lock"

        with FileLock(lock_path) as lock:
            assert lock._locked is True

        assert lock._locked is False

    def test_context_manager_creates_parent_dirs(self, tmp_path: Path):
        """Test that lock creates parent directories."""
        lock_path = tmp_path / "nested" / "dir" / ".lock"

        with FileLock(lock_path):
            assert lock_path.parent.exists()

    def test_lock_timeout(self, tmp_path: Path):
        """Test that lock times out when already held."""
        lock_path = tmp_path / ".lock"

        # Acquire first lock
        lock1 = FileLock(lock_path)
        assert lock1.acquire(timeout=1.0) is True

        # Try to acquire second lock - should timeout
        lock2 = FileLock(lock_path)
        assert lock2.acquire(timeout=0.5) is False

        lock1.release()

    def test_lock_acquired_after_release(self, tmp_path: Path):
        """Test that lock can be acquired after previous holder releases."""
        lock_path = tmp_path / ".lock"

        lock1 = FileLock(lock_path)
        lock1.acquire(timeout=1.0)
        lock1.release()

        lock2 = FileLock(lock_path)
        assert lock2.acquire(timeout=1.0) is True
        lock2.release()

    def test_context_manager_raises_on_timeout(self, tmp_path: Path):
        """Test that context manager raises LockError on timeout."""
        lock_path = tmp_path / ".lock"

        # Hold the lock
        holder = FileLock(lock_path)
        holder.acquire(timeout=1.0)

        # Try to acquire with context manager
        with pytest.raises(LockError):
            # Create a lock with very short timeout
            lock = FileLock(lock_path)
            lock.acquire = lambda timeout=10.0: False  # Force failure
            with lock:
                pass

        holder.release()

    def test_double_release_safe(self, tmp_path: Path):
        """Test that releasing twice doesn't raise."""
        lock_path = tmp_path / ".lock"
        lock = FileLock(lock_path)

        lock.acquire(timeout=1.0)
        lock.release()
        lock.release()  # Should not raise


def _hold_lock_process(lock_path: str, duration: float, ready_event, done_event):
    """Helper function to hold a lock in a subprocess."""
    lock = FileLock(Path(lock_path))
    if lock.acquire(timeout=5.0):
        ready_event.set()  # Signal that lock is held
        time.sleep(duration)
        lock.release()
    done_event.set()


class TestFileLockConcurrency:
    """Test concurrent access to file locks."""

    def test_concurrent_access_blocked(self, tmp_path: Path):
        """Test that concurrent processes are blocked."""
        lock_path = tmp_path / ".lock"

        ready_event = multiprocessing.Event()
        done_event = multiprocessing.Event()

        # Start process that holds the lock
        p = multiprocessing.Process(
            target=_hold_lock_process,
            args=(str(lock_path), 2.0, ready_event, done_event),
        )
        p.start()

        # Wait for the subprocess to acquire the lock
        ready_event.wait(timeout=5.0)

        # Now try to acquire - should fail fast
        lock = FileLock(lock_path)
        result = lock.acquire(timeout=0.5)

        assert result is False

        # Clean up
        p.join(timeout=5.0)
        if p.is_alive():
            p.terminate()

    def test_lock_acquired_after_process_exits(self, tmp_path: Path):
        """Test that lock can be acquired after holding process exits."""
        lock_path = tmp_path / ".lock"

        ready_event = multiprocessing.Event()
        done_event = multiprocessing.Event()

        # Start process that holds the lock briefly
        p = multiprocessing.Process(
            target=_hold_lock_process,
            args=(str(lock_path), 0.5, ready_event, done_event),
        )
        p.start()

        # Wait for subprocess to finish
        done_event.wait(timeout=5.0)
        p.join(timeout=5.0)

        # Now we should be able to acquire
        lock = FileLock(lock_path)
        result = lock.acquire(timeout=1.0)

        assert result is True
        lock.release()


def _hold_engine_lock_process(lock_path: str, ready_event):
    """Hold the engine lock forever; the parent kills this process."""
    lock = EngineLock(Path(lock_path))
    if lock.acquire():
        ready_event.set()
        time.sleep(60.0)


class TestEngineLock:
    """The singleton engine lock: exactly one process may run an engine."""

    def test_second_acquirer_is_refused_and_can_name_the_first(self, tmp_path: Path):
        path = engine_lock_path(tmp_path)
        first = EngineLock(path)
        assert first.acquire() is True

        assert EngineLock(path).acquire() is False
        holder = engine_lock_holder(path)
        assert holder is not None
        assert holder["pid"] == os.getpid()
        assert "pid" in describe_engine_holder(holder)

        first.release()
        assert engine_lock_holder(path) is None
        assert EngineLock(path).acquire() is True

    def test_holder_probe_does_not_disturb_the_holder(self, tmp_path: Path):
        # engine_lock_holder acquires to test liveness; a failed FileLock
        # acquire still truncates the file, which is exactly why the owner
        # identity lives in a sidecar and must survive the probe.
        path = engine_lock_path(tmp_path)
        lock = EngineLock(path)
        lock.acquire()
        for _ in range(3):
            assert engine_lock_holder(path)["pid"] == os.getpid()
        assert EngineLock(path).acquire() is False
        lock.release()

    def test_lock_is_released_when_the_holder_dies(self, tmp_path: Path):
        """flock dies with the process — a crashed engine blocks nothing."""
        path = engine_lock_path(tmp_path)
        ready = multiprocessing.Event()
        p = multiprocessing.Process(
            target=_hold_engine_lock_process, args=(str(path), ready)
        )
        p.start()
        try:
            assert ready.wait(timeout=10.0)
            assert engine_lock_holder(path)["pid"] == p.pid
            assert EngineLock(path).acquire() is False
        finally:
            p.kill()  # SIGKILL: no chance to release, no sidecar cleanup
            p.join(timeout=10.0)

        assert engine_lock_holder(path) is None
        assert EngineLock(path).acquire() is True

    def test_holder_of_an_unnamed_lock_is_reported_as_held(self, tmp_path: Path):
        # A build predating the lock is the honest gap, but a plain FileLock
        # holder (no sidecar) must still read as "held", not "free".
        path = engine_lock_path(tmp_path)
        raw = FileLock(path)
        raw.acquire()
        assert engine_lock_holder(path) == {}
        assert describe_engine_holder({}) == "an unidentified process"
        raw.release()


class TestSurfaceRegistry:
    """Open surfaces are counted by a lock each holds for its lifetime."""

    def test_a_registered_surface_is_live(self, tmp_path):
        from claude_swap.locking import live_surfaces, register_surface

        reg = register_surface(tmp_path, "tui")
        try:
            assert live_surfaces(tmp_path) == [f"tui-{os.getpid()}"]
        finally:
            reg.release()

    def test_a_released_surface_is_gone_and_its_file_cleaned(self, tmp_path):
        from claude_swap.locking import live_surfaces, register_surface, surfaces_dir

        register_surface(tmp_path, "menubar").release()
        assert live_surfaces(tmp_path) == []
        assert list(surfaces_dir(tmp_path).iterdir()) == []

    def test_a_dead_process_does_not_count(self, tmp_path):
        """flock dies with its holder, so a crash needs no cleanup to count."""
        import subprocess
        import sys
        import textwrap

        from claude_swap.locking import live_surfaces

        script = textwrap.dedent(
            f"""
            from pathlib import Path
            from claude_swap.locking import register_surface
            assert register_surface(Path({str(tmp_path)!r}), "tui") is not None
            """
        )
        subprocess.run([sys.executable, "-c", script], check=True)
        assert live_surfaces(tmp_path) == []

    def test_no_registry_directory_means_no_surfaces(self, tmp_path):
        from claude_swap.locking import live_surfaces

        assert live_surfaces(tmp_path) == []

"""Textual-based interactive TUI for claude-swap.

Entry point for ``cswap tui`` (and bare ``cswap`` in an interactive
terminal). Heavy imports (textual, rich) stay inside :func:`run` so the
plain CLI paths — ``cswap list``, cron's ``cswap auto --once`` — never pay
for them.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from claude_swap.switcher import ClaudeAccountSwitcher


def run(switcher: "ClaudeAccountSwitcher", start: str = "dashboard") -> int:
    """Run the TUI over an existing switcher. Returns the process exit code.

    ``start="watch"`` (the ``cswap watch`` command) opens directly on the
    live watch page, stacked over the dashboard.

    On macOS the TUI is a surface of the backend: it registers itself and
    makes sure the backend is running before it draws, and the backend
    retires once the last surface is gone. If the backend cannot be started
    the TUI still opens, hosting its own engine as it did before there was one.
    """
    from claude_swap import launch_agent
    from claude_swap.appearance import detect_terminal_background, drain_stdin
    from claude_swap.tui.app import CswapApp

    # Held, not used: the lock file it keeps is what marks this TUI as open.
    registration, managed, backend_error = launch_agent.open_surface(
        switcher.backup_dir, "tui"
    )
    if backend_error:
        switcher._logger.warning("backend not started: %s", backend_error)

    # Sense the terminal background while we still own stdin in cooked mode
    # (Textual's driver starts inside app.run()). Always detect so cycling to
    # 'auto' works even when the initial theme is explicit. Both calls are
    # meant to fail safe on their own, but they're wrapped here too: a
    # detection bug must never crash the TUI launch.
    try:
        detected = detect_terminal_background()
    except Exception:
        detected = None
    app = CswapApp(
        switcher,
        start=start,
        detected=detected,
        backend_managed=managed,
        backend_error=backend_error,
    )
    # Drain any late OSC reply immediately before Textual's driver starts,
    # so it isn't reissued as keystrokes once the app takes over the terminal.
    try:
        drain_stdin()
    except Exception:
        pass
    try:
        app.run()
    finally:
        if registration is not None:
            registration.release()
    return app.return_code or 0

"""Integration check: automatic backup, retention and keyboard settings in a PTY.
Run after cargo build -p quire-tui: python3 -I tools/check_tui_settings.py target/debug/quire
Uses only temporary journal, backup and configuration directories.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="quire-settings-check-") as scratch:
    root = Path(scratch)
    journal = root / "notes"
    day = journal / "journal/2026/10/15.md"
    day.parent.mkdir(parents=True)
    day.write_text("[2026-10-15 08:00:00] Test\nBody\n")
    backups = root / "backups"
    backups.mkdir()
    for n in [1, 2, 3]:
        (backups / f"Quire backup 2026-01-0{n}-000000").mkdir()
    config = root / "config/quire/settings.json"
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({"backup_dir": str(backups), "backup_interval": "daily", "backup_keep": 2}))
    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM="xterm-256color", XDG_CONFIG_HOME=str(root / "config"))
        os.execv(binary, [binary, "--folder", str(journal)])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    output = bytearray()

    def pump(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                try:
                    output.extend(os.read(fd, 65536))
                except OSError:
                    break

    def send(value):
        os.write(fd, value.encode())
        pump(0.5)

    try:
        for _ in range(100):
            pump(0.1)
            if json.loads(config.read_text()).get("last_backup"):
                break
        assert json.loads(config.read_text()).get("last_backup"), "automatic backup did not complete"
        names = list(backups.glob("Quire backup *"))
        assert len(names) == 2, names
        newest = sorted(names)[-1]
        assert (newest / "journal/2026/10/15.md").read_text().endswith("Body\n")
        send(",")
        for _ in range(7):
            send("\x1b[B")
        send("\x1b[C")
        send("\x1b[C")
        assert json.loads(config.read_text())["backup_interval"] == "monthly", "monthly selector"
        send("\x1b[B")
        send("\x1b[C")
        assert json.loads(config.read_text())["backup_keep"] == 3, "retention increase"
        send("\x1b[D")
        assert json.loads(config.read_text())["backup_keep"] == 2, "retention decrease"
        assert b"Quire 0.7.0" in output, "version display"
        send("\x03")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            done, status = os.waitpid(pid, os.WNOHANG)
            if done:
                pid = None
                assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
                break
            pump(0.1)
        assert pid is None, "clean exit"
        print("PASS: automatic backup, contents, pruning, monthly selector, retention controls, version display and exit")
    finally:
        if pid is not None:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(fd)

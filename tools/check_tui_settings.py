"""Integration check: automatic backup, retention and keyboard settings in a PTY.
Run after cargo build -p quire-tui: python3 -I tools/check_tui_settings.py target/debug/quire
Uses only temporary journal, backup and configuration directories. The app is
pointed at them three ways, because no one of them is enough everywhere:
QUIRE_CONFIG_DIR (the folder Quire reads settings.json from when it is set),
XDG_CONFIG_HOME (Linux only; macOS ignores it) and HOME (a Mac's
~/Library/Application Support, jnl's config, ~/notes). A binary from before
QUIRE_CONFIG_DIR existed fails the first check on a Mac instead of reaching the
real settings. The version it looks for is the workspace's, from Cargo.toml.
Run by hand, not by make; the keys it sends were last checked against 0.7.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import sys
import tempfile
import termios
import time

binary = str(Path(sys.argv[1]).resolve())
cargo = (Path(__file__).resolve().parent.parent / "Cargo.toml").read_text()
version = re.search(r'(?ms)^\[workspace\.package\].*?^version = "([^"]+)"', cargo).group(1)
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
        os.environ.update(TERM="xterm-256color", HOME=str(root), XDG_CONFIG_HOME=str(root / "config"),
                          QUIRE_CONFIG_DIR=str(config.parent))
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
        assert ("Quire " + version).encode() in output, "version display"
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

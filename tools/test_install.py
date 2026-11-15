#!/usr/bin/env python3
"""Checks for install.sh that change nothing: its syntax, shellcheck when it
is installed, and dry runs against a made-up home folder.

A dry run is the only way the installer is ever started here. Each one gets
a scratch HOME and a bare PATH, and the test fails if a single file in that
home is different afterwards.

    python3 tools/test_install.py
"""
import hashlib
import os
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.path.join(ROOT, "install.sh")

BASH_JNL = "#!/usr/bin/env bash\n# the original jnl\n: \"${JNL_DIR:=$HOME/notes}\"\necho jnl\n"
GO_JNL = "\x7fELF pretend binary\nGo build ID: \"abc\"\n"


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, mode)


def snapshot(root):
    """Every path under root with what it is and, for a file, what it holds."""
    out = {}
    for dirpath, dirs, files in os.walk(root):
        for d in dirs:
            out[os.path.relpath(os.path.join(dirpath, d), root)] = "dir"
        for fn in files:
            p = os.path.join(dirpath, fn)
            with open(p, "rb") as f:
                out[os.path.relpath(p, root)] = hashlib.sha256(f.read()).hexdigest()
    return out


class Home:
    """A scratch home with a journal in ~/notes and whatever the test adds."""

    def __init__(self):
        self.path = os.path.realpath(tempfile.mkdtemp(prefix="quire-install-test-"))
        write(self.file("notes/journal/2026/01/01.md"), "[2026-01-01 08:00:00] New year\nText.\n")
        write(self.file("notes/inbox.md"), "[2026-01-02 09:00:00] A draft\nText.\n")

    def file(self, rel):
        return os.path.join(self.path, rel)

    def dry_run(self, *args, **extra_env):
        env = {"HOME": self.path, "PATH": "/usr/bin:/bin", "TERM": "dumb", "SHELL": "/bin/bash"}
        env.update(extra_env)
        before = snapshot(self.path)
        r = subprocess.run(["bash", INSTALL, "--dry-run"] + list(args), env=env, cwd=self.path,
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=120)
        return r, before == snapshot(self.path)

    def close(self):
        shutil.rmtree(self.path, ignore_errors=True)


def commands(out):
    """The commands a dry run printed (`  $ …`), in order."""
    return [line.strip()[2:] for line in out.splitlines() if line.strip().startswith("$ ")]


class Static(unittest.TestCase):
    def test_syntax(self):
        r = subprocess.run(["bash", "-n", INSTALL], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        self.assertEqual(r.returncode, 0, r.stdout)

    def test_no_bash_4(self):
        # macOS's /bin/bash is 3.2: none of these exist there.
        with open(INSTALL, encoding="utf-8") as f:
            text = "\n".join(line for line in f.read().split("\n") if not line.lstrip().startswith("#"))
        for word in ("declare -A", "local -A", "mapfile", "readarray", "${!", "&>>", "|&", ";;&", "coproc "):
            self.assertNotIn(word, text, "bash 4 only: " + word)

    @unittest.skipUnless(shutil.which("shellcheck"), "shellcheck is not installed")
    def test_shellcheck(self):
        # Errors only, for now: this gate was added on a machine without
        # shellcheck. Once `shellcheck --severity=warning install.sh` has been
        # seen to pass, raise it to warning here.
        r = subprocess.run(["shellcheck", "--severity=error", "--shell=bash", INSTALL],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
        self.assertEqual(r.returncode, 0, r.stdout)


class DryRun(unittest.TestCase):
    def setUp(self):
        self.home = Home()
        self.addCleanup(self.home.close)

    def run_dry(self, *args, **extra_env):
        r, unchanged = self.home.dry_run(*args, **extra_env)
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertTrue(unchanged, "a dry run changed the home folder:\n" + r.stdout)
        self.assertIn("Dry run: nothing was changed.", r.stdout)
        return r.stdout

    def test_install_changes_nothing_and_finds_the_journal(self):
        out = self.run_dry("--tui")
        self.assertIn(self.home.file("notes"), out)
        self.assertIn("point Quire at " + self.home.file("notes"), out)
        self.assertNotIn(self.home.file("notes"), " ".join(c for c in commands(out) if c.startswith(("mv ", "rm ", "gio "))),
                         "the journal folder must never be moved or removed")

    def test_uninstall_changes_nothing(self):
        self.run_dry("--uninstall")

    def test_backup_is_written_partial_read_back_then_named(self):
        cmds = commands(self.run_dry("--tui"))
        tar = [i for i, c in enumerate(cmds) if c.startswith("tar -czf ")]
        self.assertEqual(len(tar), 1, cmds)
        self.assertIn(".tar.gz.partial ", cmds[tar[0]])
        rest = cmds[tar[0] + 1:]
        self.assertTrue(rest[0].startswith("sh -c tar -tzf"), rest[:3])
        self.assertTrue(any(c.startswith("mv ") and ".tar.gz.partial " in c and c.endswith(".tar.gz") for c in rest[:3]), rest[:3])

    @unittest.skipUnless(platform.system() == "Darwin", "the Trash names are macOS's")
    def test_two_removed_files_of_one_name_get_two_names_in_the_trash(self):
        write(self.home.file("bin/jnl"), BASH_JNL, 0o755)
        write(self.home.file("go/bin/jnl"), GO_JNL, 0o755)
        out = self.run_dry("--tui")
        dests = [c.split(" ", 2)[2].split(self.home.file(".Trash/"), 1)[1]
                 for c in commands(out) if c.startswith("mv ") and "/.Trash/jnl " in c]
        self.assertEqual(len(dests), 2, out)
        self.assertEqual(len(set(dests)), 2, "both went to one name in the Trash: %r" % dests)

    def test_an_old_jnl_in_the_install_folder_is_moved_only_after_quires_is_ready(self):
        # Where the terminal app goes: ~/.cargo/bin for a build, ~/.local/bin
        # for a download. A foreign jnl is put in both.
        for d in (".cargo/bin", ".local/bin"):
            write(self.home.file(d + "/jnl"), BASH_JNL, 0o755)
        out = self.run_dry("--tui")
        cmds = commands(out)
        got = [i for i, c in enumerate(cmds) if c.startswith(("cargo build ", "tar -xzf "))]
        self.assertTrue(got, "no build or unpack step:\n" + out)
        moved = [i for i, c in enumerate(cmds)
                 if c.startswith(("mv ", "gio trash ")) and (self.home.file(".cargo/bin/jnl") in c or self.home.file(".local/bin/jnl") in c)]
        self.assertTrue(moved, "the jnl in the install folder was not moved aside:\n" + out)
        self.assertGreater(moved[0], got[0], "the old jnl was moved before Quire's was built or unpacked")
        # It is told, not asked: a "no" could not have kept it there. (Told in
        # the plan always, and at the questions when it was listed as an old app.)
        path = cmds[moved[0]].split(" ")[1 if cmds[moved[0]].startswith("mv ") else 2]
        self.assertIn("move %s aside" % path, out)
        self.assertNotIn("%s? [" % path, out)
        if "• jnl (the original bash script) — %s\n" % path in out:
            self.assertIn("sits where Quire's own goes", out)

    def test_a_listed_jnl_in_the_install_folder_is_told_not_asked(self):
        # A build installs into $CARGO_HOME/bin; here that is ~/.local/bin,
        # one of the places an old jnl is looked for.
        path = self.home.file(".local/bin/jnl")
        write(path, BASH_JNL, 0o755)
        for flags in (("--tui", "--build"), ("--tui", "--build", "--keep-old")):
            out = self.run_dry(*flags, CARGO_HOME=self.home.file(".local"))
            self.assertIn("• jnl (the original bash script) — %s\n" % path, out)
            self.assertNotIn("%s? [" % path, out)
            self.assertIn("move %s aside" % path, out)
            self.assertIn("Quire's own goes", out)
            cmds = commands(out)
            build = [i for i, c in enumerate(cmds) if c.startswith("cargo build ")]
            moved = [i for i, c in enumerate(cmds) if c.startswith(("mv ", "gio trash ")) and path in c]
            self.assertEqual(len(moved), 1, "moved once, and not again as a removal:\n" + out)
            self.assertGreater(moved[0], build[0])


if __name__ == "__main__":
    unittest.main()

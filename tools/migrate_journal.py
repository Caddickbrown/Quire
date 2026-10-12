#!/usr/bin/env python3
"""Move a jnl / Nook / Quire journal to Quire's new layout.

Two changes, both reversible, both idempotent:

  1. inbox.md  ->  inbox/YYYY/MM/DD.md
     Every draft already carries a [YYYY-MM-DD HH:MM:SS] header, so the inbox
     splits into one file per day exactly like journal/. Entries keep their raw
     text byte for byte; within a day they are ordered oldest first (jnl's
     stable sort). The old inbox.md is moved, never deleted, to
     .quire/migration/inbox-<stamp>.md, and only after every entry has been
     re-read from the new files and matched against the original.

  2. .nook/  ->  .quire/
     A rename when .quire/ does not exist; otherwise a file-by-file move that
     never overwrites, leaving anything that clashed in .nook/ and saying so.

Dependency-free, Python 3.8+. Dry run by default; --apply writes.

    python3 tools/migrate_journal.py ~/Notes            # show the plan
    python3 tools/migrate_journal.py ~/Notes --apply    # do it
    python3 tools/migrate_journal.py ~/Notes --apply --keep-nook   # inbox only

Run it again later and it merges any inbox.md an older app has written since
(entries already present in inbox/ are skipped by raw text).
"""
import argparse
import os
import re
import sys
import tempfile
import time
from collections import OrderedDict

# jnl's header regex: ASCII hyphen or en-dash in the date.
HEADER_RE = re.compile(r"^\[(\d{4}[-–]\d{2}[-–]\d{2}) (\d{2}:\d{2}:\d{2})\](.*)")


class Entry:
    __slots__ = ("date", "ts", "suffix", "raw")

    def __init__(self, date, ts, suffix, raw):
        self.date, self.ts, self.suffix, self.raw = date, ts, suffix, raw


# ---------- jnl's parser, line for line ----------

def normalised(text):
    """Drop a BOM and turn CRLF into LF (Wander does this; jnl splits on \\n)."""
    if text.startswith("﻿"):
        text = text[1:]
    return text.replace("\r\n", "\n")


def parse_entries(content):
    entries, cur = [], []
    cur_ts = cur_date = cur_suffix = ""

    def flush():
        if cur_ts:
            entries.append(Entry(cur_date, cur_ts, cur_suffix, "\n".join(cur)))

    for line in content.split("\n"):
        m = HEADER_RE.match(line)
        if m:
            flush()
            cur_date = m.group(1).replace("–", "-")
            cur_ts = cur_date + " " + m.group(2)
            cur_suffix = m.group(3).strip()
            header = "[" + cur_ts + "]" + (" " + cur_suffix if cur_suffix else "")
            cur = [header]
        elif cur_ts:
            cur.append(line)
    flush()
    return entries


def leading_preamble(content):
    pre = []
    for line in content.split("\n"):
        if HEADER_RE.match(line):
            break
        pre.append(line)
    text = "\n".join(pre).rstrip("\n")
    return "" if not text.strip() else text


def sorted_by_timestamp(entries):
    return sorted(entries, key=lambda e: e.ts)  # Python's sort is stable


def render_entries(preamble, entries):
    parts = []
    if preamble:
        parts.append(preamble.rstrip("\n"))
    parts.extend(e.raw.rstrip("\n") for e in entries)
    return "\n\n".join(parts) + "\n" if parts else ""


# ---------- files ----------

def read_text(path):
    with open(path, "rb") as f:
        return normalised(f.read().decode("utf-8"))


def write_atomic(path, text):
    """temp file in the same directory, fsync, rename — as jnl's writeFile."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".quire-", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(text.encode("utf-8"))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def day_path(base, date):
    y, m, d = date.split("-")
    return os.path.join(base, "inbox", y, m, d + ".md")


# ---------- step 1: split the inbox ----------

def plan_inbox(base):
    """Return (plan, preamble, source_entries) where plan maps day file -> (preamble, entries)."""
    src = os.path.join(base, "inbox.md")
    if not os.path.isfile(src):
        return None, "", []
    content = read_text(src)
    entries = parse_entries(content)
    preamble = leading_preamble(content)

    by_day = OrderedDict()
    for e in entries:
        by_day.setdefault(e.date, []).append(e)

    plan = OrderedDict()
    for date, new in by_day.items():
        target = day_path(base, date)
        existing_pre, existing = "", []
        if os.path.isfile(target):
            existing_text = read_text(target)
            existing = parse_entries(existing_text)
            existing_pre = leading_preamble(existing_text)
        seen = {e.raw.rstrip("\n") for e in existing}
        added = [e for e in new if e.raw.rstrip("\n") not in seen]
        plan[target] = (existing_pre, sorted_by_timestamp(existing + added), len(added), len(new) - len(added))
    return plan, preamble, entries


def verify_inbox(base, source_entries):
    """Every source entry must be readable back out of inbox/, raw for raw."""
    want = {}
    for e in source_entries:
        want[e.raw.rstrip("\n")] = want.get(e.raw.rstrip("\n"), 0) + 1
    have = {}
    for e in all_inbox_entries(base):
        k = e.raw.rstrip("\n")
        have[k] = have.get(k, 0) + 1
    missing = [k for k, n in want.items() if have.get(k, 0) < 1]
    return missing


def all_inbox_entries(base):
    root = os.path.join(base, "inbox")
    out = []
    if not os.path.isdir(root):
        return out
    for dirpath, _, files in os.walk(root):
        for fn in sorted(files):
            if fn.endswith(".md") and re.fullmatch(r"\d{2}\.md", fn):
                out.extend(parse_entries(read_text(os.path.join(dirpath, fn))))
    return out


def apply_inbox(base, plan, preamble, source_entries, log):
    for target, (pre, entries, _, _) in plan.items():
        write_atomic(target, render_entries(pre, entries))
    if preamble:
        p = os.path.join(base, "inbox", "preamble.md")
        if os.path.exists(p):
            existing = read_text(p)
            if preamble.strip() not in existing:
                write_atomic(p, existing.rstrip("\n") + "\n\n" + preamble + "\n")
        else:
            write_atomic(p, preamble + "\n")
        log("  preamble (text before the first header) kept in inbox/preamble.md")

    missing = verify_inbox(base, source_entries)
    if missing:
        log("  VERIFY FAILED: %d entries not found in inbox/ — inbox.md left in place" % len(missing))
        for k in missing[:5]:
            log("    " + k.split("\n")[0])
        return False

    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup_dir = os.path.join(base, ".quire", "migration")
    os.makedirs(backup_dir, exist_ok=True)
    backup = os.path.join(backup_dir, "inbox-%s.md" % stamp)
    n = 1
    while os.path.exists(backup):  # two runs in one second must not overwrite a backup
        n += 1
        backup = os.path.join(backup_dir, "inbox-%s-%d.md" % (stamp, n))
    os.replace(os.path.join(base, "inbox.md"), backup)
    log("  inbox.md moved to %s" % os.path.relpath(backup, base))
    return True


# ---------- step 2: .nook -> .quire ----------

def plan_sidecar(base):
    nook, quire = os.path.join(base, ".nook"), os.path.join(base, ".quire")
    if not os.path.isdir(nook):
        return None
    if not os.path.isdir(quire):
        return ("rename", [], [])
    moves, clashes = [], []
    for dirpath, _, files in os.walk(nook):
        for fn in files:
            src = os.path.join(dirpath, fn)
            rel = os.path.relpath(src, nook)
            dst = os.path.join(quire, rel)
            (clashes if os.path.exists(dst) else moves).append(rel)
    return ("merge", sorted(moves), sorted(clashes))


def apply_sidecar(base, plan, log):
    nook, quire = os.path.join(base, ".nook"), os.path.join(base, ".quire")
    kind, moves, clashes = plan
    if kind == "rename":
        os.rename(nook, quire)
        log("  .nook/ renamed to .quire/")
        return
    for rel in moves:
        dst = os.path.join(quire, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.replace(os.path.join(nook, rel), dst)
    log("  %d file(s) moved from .nook/ into .quire/" % len(moves))
    # Prune empty directories bottom-up; .nook/ itself goes only if nothing clashed.
    for dirpath, _, _ in os.walk(nook, topdown=False):
        try:
            os.rmdir(dirpath)
        except OSError:
            pass  # not empty: a clash stayed behind
    if clashes:
        log("  %d file(s) left in .nook/ because .quire/ already has them:" % len(clashes))
        for rel in clashes:
            log("    " + rel)


# ---------- main ----------

def run(base, apply, keep_nook, log=print):
    base = os.path.abspath(base)
    if not os.path.isdir(base):
        log("not a folder: " + base)
        return 2
    ok = True
    log(("Applying to " if apply else "Dry run for ") + base)

    log("\n.nook/ -> .quire/")
    if keep_nook:
        log("  skipped (--keep-nook)")
    else:
        sp = plan_sidecar(base)
        if sp is None:
            log("  no .nook/ folder" + (", .quire/ present" if os.path.isdir(os.path.join(base, ".quire")) else "") + ". Nothing to do.")
        else:
            kind, moves, clashes = sp
            if kind == "rename":
                log("  rename .nook/ -> .quire/ (no .quire/ yet)")
            else:
                log("  merge: %d file(s) to move, %d clash(es) stay in .nook/" % (len(moves), len(clashes)))
            if apply:
                apply_sidecar(base, sp, log)

    plan, preamble, source = plan_inbox(base)
    log("\ninbox.md -> inbox/YYYY/MM/DD.md")
    if plan is None:
        n = len(all_inbox_entries(base))
        log("  no inbox.md; inbox/ holds %d draft(s). Nothing to do." % n)
    else:
        total_new = sum(a for _, _, a, _ in plan.values())
        total_dup = sum(d for _, _, _, d in plan.values())
        log("  %d draft(s) across %d day(s); %d new, %d already in inbox/" % (len(source), len(plan), total_new, total_dup))
        for target, (_, entries, added, dup) in plan.items():
            log("  %-28s %3d entr%s  (+%d%s)" % (os.path.relpath(target, base), len(entries), "y" if len(entries) == 1 else "ies", added, ", %d dup" % dup if dup else ""))
        if preamble:
            log("  preamble: %d line(s) before the first header -> inbox/preamble.md" % (preamble.count("\n") + 1))
        if apply:
            ok = apply_inbox(base, plan, preamble, source, log) and ok

    if not apply:
        log("\nNothing written. Re-run with --apply.")
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("folder", help="the journal folder (JNL_DIR)")
    ap.add_argument("--apply", action="store_true", help="write changes (default is a dry run)")
    ap.add_argument("--keep-nook", action="store_true", help="leave .nook/ alone")
    a = ap.parse_args(argv)
    return run(a.folder, a.apply, a.keep_nook)


if __name__ == "__main__":
    sys.exit(main())

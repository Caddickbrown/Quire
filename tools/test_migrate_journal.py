import os, sys, tempfile, unittest, shutil
sys.path.insert(0, os.path.dirname(__file__))
import migrate_journal as mj

INBOX = """[2026-01-05 09:00:00] Second day
Body two.

[2026-01-04 22:10:00]
Late note @tag

[2026-01-05 07:30:00] Early on day two *
- a list
- [ ] a task
"""

class Base(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.log = []
    def tearDown(self):
        shutil.rmtree(self.d)
    def w(self, rel, text):
        p = os.path.join(self.d, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb") as f: f.write(text.encode("utf-8"))
    def r(self, rel):
        with open(os.path.join(self.d, rel), "rb") as f: return f.read().decode("utf-8")
    def run_(self, apply=True, keep_nook=False):
        return mj.run(self.d, apply, keep_nook, log=self.log.append)

class Parser(Base):
    def test_matches_jnl_cases(self):
        es = mj.parse_entries("preamble\n\n[2026–01–02 08:00:00] En dash\nbody\n\n[2026-01-03 09:00:00]\n")
        self.assertEqual([e.ts for e in es], ["2026-01-02 08:00:00", "2026-01-03 09:00:00"])
        self.assertEqual(es[0].raw, "[2026-01-02 08:00:00] En dash\nbody\n")  # header normalised, body kept
        self.assertEqual(mj.leading_preamble("preamble\n\n[2026-01-02 08:00:00]"), "preamble")
        self.assertEqual(mj.leading_preamble("\n\n[2026-01-02 08:00:00]"), "")
    def test_render_round_trips(self):
        text = INBOX
        es = mj.parse_entries(text)
        self.assertEqual(mj.render_entries("", es), text)
    def test_crlf_and_bom(self):
        es = mj.parse_entries(mj.normalised("﻿[2026-01-02 08:00:00] T\r\nbody\r\n"))
        self.assertEqual(es[0].raw, "[2026-01-02 08:00:00] T\nbody\n")

class Inbox(Base):
    def test_dry_run_writes_nothing(self):
        self.w("inbox.md", INBOX)
        self.assertEqual(self.run_(apply=False), 0)
        self.assertEqual(sorted(os.listdir(self.d)), ["inbox.md"])
    def test_split_by_day_sorted_and_backed_up(self):
        self.w("inbox.md", INBOX)
        self.assertEqual(self.run_(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.d, "inbox.md")))
        self.assertEqual(self.r("inbox/2026/01/04.md"), "[2026-01-04 22:10:00]\nLate note @tag\n")
        self.assertEqual(self.r("inbox/2026/01/05.md"),
            "[2026-01-05 07:30:00] Early on day two *\n- a list\n- [ ] a task\n\n[2026-01-05 09:00:00] Second day\nBody two.\n")
        backups = os.listdir(os.path.join(self.d, ".quire", "migration"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(self.r(".quire/migration/" + backups[0]), INBOX)
    def test_rerun_merges_without_duplicates(self):
        self.w("inbox.md", INBOX); self.run_()
        # an old app writes a new inbox.md with one old and one new draft
        self.w("inbox.md", "[2026-01-05 09:00:00] Second day\nBody two.\n\n[2026-01-06 10:00:00] New\nx\n")
        self.assertEqual(self.run_(), 0)
        self.assertEqual(len(mj.parse_entries(self.r("inbox/2026/01/05.md"))), 2)
        self.assertEqual(self.r("inbox/2026/01/06.md"), "[2026-01-06 10:00:00] New\nx\n")
        self.assertEqual(len(os.listdir(os.path.join(self.d, ".quire", "migration"))), 2)
    def test_preamble_kept(self):
        self.w("inbox.md", "# My inbox\nnotes\n\n" + INBOX); self.run_()
        self.assertEqual(self.r("inbox/preamble.md"), "# My inbox\nnotes\n")
    def test_empty_inbox_is_just_moved(self):
        self.w("inbox.md", "\n"); self.assertEqual(self.run_(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.d, "inbox.md")))
        self.assertFalse(os.path.exists(os.path.join(self.d, "inbox")))
    def test_journal_untouched(self):
        self.w("journal/2026/01/05.md", "[2026-01-05 08:00:00] Filed\nkeep\n"); self.w("inbox.md", INBOX); self.run_()
        self.assertEqual(self.r("journal/2026/01/05.md"), "[2026-01-05 08:00:00] Filed\nkeep\n")
    def test_verify_failure_keeps_inbox(self):
        self.w("inbox.md", INBOX)
        real = mj.all_inbox_entries
        mj.all_inbox_entries = lambda base: []   # pretend the re-read finds nothing
        try: self.assertEqual(self.run_(), 1)
        finally: mj.all_inbox_entries = real
        self.assertTrue(os.path.exists(os.path.join(self.d, "inbox.md")))

    def test_draft_written_during_the_move_is_not_lost(self):
        # An app appends a draft after the plan was made and before inbox.md is
        # moved: the file is read again, planned again, and only then moved.
        self.w("inbox.md", INBOX)
        late = "\n[2026-01-07 08:00:00] Late\nwritten mid-move\n"
        real, calls = mj.verify_inbox, []
        def verify(base, source):
            if not calls:
                with open(os.path.join(base, "inbox.md"), "ab") as f: f.write(late.encode("utf-8"))
            calls.append(1)
            return real(base, source)
        mj.verify_inbox = verify
        try: self.assertEqual(self.run_(), 0)
        finally: mj.verify_inbox = real
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.r("inbox/2026/01/07.md"), "[2026-01-07 08:00:00] Late\nwritten mid-move\n")
        self.assertFalse(os.path.exists(os.path.join(self.d, "inbox.md")))
        backups = os.listdir(os.path.join(self.d, ".quire", "migration"))
        self.assertEqual(self.r(".quire/migration/" + backups[0]), INBOX + late)
        self.assertTrue(any("planning it again" in l for l in self.log))
    def test_source_that_keeps_changing_is_left_in_place(self):
        self.w("inbox.md", INBOX)
        real, n = mj.verify_inbox, [0]
        def verify(base, source):
            n[0] += 1
            with open(os.path.join(base, "inbox.md"), "ab") as f:
                f.write(("\n[2026-02-%02d 08:00:00] Again\n" % n[0]).encode("utf-8"))
            return real(base, source)
        mj.verify_inbox = verify
        try: self.assertEqual(self.run_(), 1)
        finally: mj.verify_inbox = real
        self.assertEqual(n[0], mj.MAX_PLANS)
        self.assertTrue(os.path.exists(os.path.join(self.d, "inbox.md")))
        self.assertFalse(os.path.exists(os.path.join(self.d, ".quire")))
    def test_inbox_that_is_not_utf8_is_skipped(self):
        raw = b"[2026-01-05 09:00:00] Caf\xe9\nlatin-1 body\n"
        p = os.path.join(self.d, "inbox.md")
        with open(p, "wb") as f: f.write(raw)
        self.w("work.md", "[2026-10-14 09:00:00] Standup\n")
        self.assertEqual(self.run_(), 1)
        with open(p, "rb") as f: self.assertEqual(f.read(), raw)
        self.assertFalse(os.path.exists(os.path.join(self.d, "inbox")))
        self.assertTrue(any("not UTF-8" in l for l in self.log))
        # the rest of the run still happens
        self.assertEqual(self.r("split/work/2026/10/14.md"), "[2026-10-14 09:00:00] Standup\n")
    def test_day_file_that_is_not_utf8_stops_the_inbox_only(self):
        self.w("inbox.md", INBOX)
        os.makedirs(os.path.join(self.d, "inbox/2026/01"))
        with open(os.path.join(self.d, "inbox/2026/01/05.md"), "wb") as f: f.write(b"[2026-01-05 01:00:00] \xff\n")
        self.assertEqual(self.run_(), 1)
        self.assertEqual(self.r("inbox.md"), INBOX)
        self.assertFalse(os.path.exists(os.path.join(self.d, "inbox/2026/01/04.md")))

class Sidecar(Base):
    def test_rename(self):
        self.w(".nook/templates/Morning.md", "{{date}}"); self.w(".nook/searches.json", "[]")
        self.run_()
        self.assertFalse(os.path.exists(os.path.join(self.d, ".nook")))
        self.assertEqual(self.r(".quire/templates/Morning.md"), "{{date}}")
    def test_merge_never_overwrites(self):
        self.w(".nook/searches.json", "old"); self.w(".nook/datasaver-a.json", "{}")
        self.w(".quire/searches.json", "new")
        self.run_()
        self.assertEqual(self.r(".quire/searches.json"), "new")
        self.assertEqual(self.r(".quire/datasaver-a.json"), "{}")
        self.assertEqual(self.r(".nook/searches.json"), "old")
    def test_keep_nook(self):
        self.w(".nook/searches.json", "[]"); self.run_(keep_nook=True)
        self.assertTrue(os.path.exists(os.path.join(self.d, ".nook/searches.json")))
    def test_keep_nook_with_inbox_keeps_nook_the_only_sidecar(self):
        # Making .quire/ here would hide .nook/ from Quire, which reads .nook/
        # only while .quire/ does not exist: the original goes to .nook/migration/.
        self.w(".nook/searches.json", "[]"); self.w(".nook/templates/Morning.md", "{{date}}"); self.w("inbox.md", INBOX)
        self.w("work.md", "[2026-10-14 09:00:00] Standup\n")
        self.assertEqual(self.run_(keep_nook=True), 0)
        self.assertFalse(os.path.exists(os.path.join(self.d, ".quire")))
        self.assertEqual(self.r(".nook/searches.json"), "[]")
        self.assertEqual(self.r(".nook/templates/Morning.md"), "{{date}}")
        kept = sorted(os.listdir(os.path.join(self.d, ".nook", "migration")))
        self.assertEqual(len(kept), 2, kept)
        self.assertTrue(kept[0].startswith("inbox-") and kept[1].startswith("split-work-"), kept)
        self.assertEqual(self.r(".nook/migration/" + kept[0]), INBOX)
        self.assertFalse(os.path.exists(os.path.join(self.d, "inbox.md")))
        self.assertEqual(self.r("inbox/2026/01/04.md"), "[2026-01-04 22:10:00]\nLate note @tag\n")
        # A later run without --keep-nook renames the sidecar, originals and all.
        self.assertEqual(self.run_(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.d, ".nook")))
        self.assertEqual(sorted(os.listdir(os.path.join(self.d, ".quire", "migration"))), kept)
    def test_keep_nook_with_both_sidecars_uses_quire(self):
        self.w(".nook/searches.json", "old"); self.w(".quire/searches.json", "new"); self.w("inbox.md", INBOX)
        self.assertEqual(self.run_(keep_nook=True), 0)
        self.assertEqual(len(os.listdir(os.path.join(self.d, ".quire", "migration"))), 1)
        self.assertEqual(os.listdir(os.path.join(self.d, ".nook")), ["searches.json"])
    def test_merge_prunes_emptied_nook(self):
        self.w(".nook/templates/A.md", "a"); self.w(".quire/searches.json", "[]")
        self.run_()
        self.assertFalse(os.path.exists(os.path.join(self.d, ".nook")))
        self.assertEqual(self.r(".quire/templates/A.md"), "a")
    def test_sidecar_runs_before_inbox_so_rename_wins(self):
        self.w(".nook/searches.json", "[]"); self.w("inbox.md", INBOX)
        self.run_()
        self.assertTrue(any("renamed" in l for l in self.log))
        self.assertTrue(os.path.isdir(os.path.join(self.d, ".quire", "migration")))
    def test_idempotent(self):
        self.w(".nook/searches.json", "[]"); self.run_(); n = len(self.log); self.run_()
        self.assertFalse(os.path.exists(os.path.join(self.d, ".nook")))

class Splits(Base):
    WORK = "Work log\n\n[2026-10-14 09:00:00] Standup @work\n![](./assets/a.jpg)\n\n[2026-10-13 17:00:00] Retro\nGood week.\n\nSecond paragraph.\n"

    def test_split_journal_into_day_files(self):
        self.w("work.md", self.WORK)
        self.w("ideas.md", "Just notes, no entries.\n")
        self.w("transfer.md", "[2026-10-14 09:00:00] not a split journal\n")
        self.assertEqual(self.run_(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.d, "work.md")))
        self.assertEqual(self.r("split/work/2026/10/14.md"), "[2026-10-14 09:00:00] Standup @work\n![](assets/a.jpg)\n")
        self.assertEqual(self.r("split/work/2026/10/13.md"), "[2026-10-13 17:00:00] Retro\nGood week.\n\nSecond paragraph.\n")
        self.assertEqual(self.r("split/work/preamble.md"), "Work log\n")
        self.assertEqual(self.r("ideas.md"), "Just notes, no entries.\n")
        self.assertTrue(os.path.exists(os.path.join(self.d, "transfer.md")))
        backups = os.listdir(os.path.join(self.d, ".quire", "migration"))
        self.assertTrue(any(b.startswith("split-work-") for b in backups), backups)

    def test_dry_run_and_keep_splits(self):
        self.w("work.md", self.WORK)
        self.run_(apply=False)
        self.assertTrue(os.path.exists(os.path.join(self.d, "work.md")))
        mj.run(self.d, True, False, log=self.log.append, keep_splits=True)
        self.assertTrue(os.path.exists(os.path.join(self.d, "work.md")))

    def test_rerun_merges_split_without_duplicates(self):
        self.w("work.md", self.WORK)
        self.run_()
        self.w("work.md", "[2026-10-14 09:00:00] Standup @work\n![](assets/a.jpg)\n\n[2026-10-15 08:00:00] New @work\n")
        self.run_()
        self.assertEqual(len(mj.parse_entries(self.r("split/work/2026/10/14.md"))), 1)
        self.assertEqual(self.r("split/work/2026/10/15.md"), "[2026-10-15 08:00:00] New @work\n")


    def test_split_written_during_the_move_is_not_lost(self):
        self.w("work.md", self.WORK)
        late = "\n[2026-10-16 08:00:00] Late @work\n"
        real, calls = mj.all_split_entries, []
        def entries(base, tag):
            if not calls:
                with open(os.path.join(base, "work.md"), "ab") as f: f.write(late.encode("utf-8"))
            calls.append(1)
            return real(base, tag)
        mj.all_split_entries = entries
        try: self.assertEqual(self.run_(), 0)
        finally: mj.all_split_entries = real
        self.assertEqual(self.r("split/work/2026/10/16.md"), "[2026-10-16 08:00:00] Late @work\n")
        self.assertFalse(os.path.exists(os.path.join(self.d, "work.md")))

    def test_split_that_is_not_utf8_is_skipped_and_the_others_move(self):
        raw = b"[2026-10-14 09:00:00] Caf\xe9 @home\n"
        with open(os.path.join(self.d, "home.md"), "wb") as f: f.write(raw)
        with open(os.path.join(self.d, "scan.md"), "wb") as f: f.write(b"\xff\xfe not a journal\n")
        self.w("work.md", self.WORK)
        self.assertEqual(self.run_(), 1)
        with open(os.path.join(self.d, "home.md"), "rb") as f: self.assertEqual(f.read(), raw)
        self.assertFalse(os.path.exists(os.path.join(self.d, "split", "home")))
        self.assertFalse(os.path.exists(os.path.join(self.d, "work.md")))
        self.assertTrue(os.path.exists(os.path.join(self.d, "split/work/2026/10/14.md")))
        self.assertEqual(len([l for l in self.log if "not UTF-8" in l]), 1, self.log)

    def test_root_file_that_is_not_utf8_and_not_a_journal_is_ignored(self):
        with open(os.path.join(self.d, "scan.md"), "wb") as f: f.write(b"\xff\xfe not a journal\n")
        self.assertEqual(self.run_(), 0)
        self.assertFalse(any("not UTF-8" in l for l in self.log))


if __name__ == "__main__":
    unittest.main()

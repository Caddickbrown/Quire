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

if __name__ == "__main__":
    unittest.main()

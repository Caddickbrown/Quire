"""Drive the TUI in a pseudo-terminal: send keys, collect output, check files."""
import os, pty, sys, time, select, fcntl, termios, struct, signal, re, datetime, glob
binary, folder = sys.argv[1], sys.argv[2]
cols, rows = int(sys.argv[3]), int(sys.argv[4])
theme = sys.argv[5] if len(sys.argv) > 5 else "cinema"
# A photo to drop on the composer, outside the journal; and a config dir of
# our own, so the run never reads or writes the real settings.json.
scratch = os.path.abspath(folder) + "-scratch"
os.makedirs(scratch, exist_ok=True)
photo = os.path.join(scratch, "drop me.png")
open(photo, "wb").write(b"\x89PNG\r\n\x1a\n")
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"; os.environ["COLORTERM"] = "truecolor"
    os.environ["XDG_CONFIG_HOME"] = scratch
    os.execv(binary, [binary, "--folder", folder, "--theme", theme])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
out = bytearray()
def pump(t=0.4):
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: out.extend(os.read(fd, 65536))
            except OSError: return
def send(s, t=0.35):
    os.write(fd, s.encode() if isinstance(s, str) else s); pump(t)
def seen(s):
    text = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", out.decode("utf-8", "replace"))
    return s in text or s.replace(" ", "") in text.replace(" ", "")
ESC, UP, DOWN, RIGHT, LEFT, ENTER, TAB = "\x1b", "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D", "\r", "\t"
def paste(s, t=0.6): send("\x1b[200~" + s + "\x1b[201~", t)
def click(x, y, t=0.5): send(f"\x1b[<0;{x + 1};{y + 1}M\x1b[<0;{x + 1};{y + 1}m", t)   # 0-based cell, SGR mouse
checks = []
def check(name, cond): checks.append((name, bool(cond)))
pump(1.0)
check("today screen drew", seen("ON THIS DAY") and seen("A PROMPT") and seen("INBOX"))
send("n"); check("write screen", seen("saves to the inbox"))
send("Smoke test"); send(ENTER); send("Hello from the pty, a list:"); send(ENTER); send("- one"); send(ENTER); send("two @gar", 0.5)
check("tag popover", seen("@garden"))
send(TAB); paste("'" + photo + "' ")   # a drop, as GNOME Terminal pastes it
check("dropped photo attached", seen("Attached") and glob.glob(os.path.join(folder, "assets", "*", "*", "*.png")))
send("\x0f"); send("\x0f"); check("timer starts, then pauses", seen("paused"))   # ctrl+o twice
send("\x13", 1.2)   # ctrl+s
today = datetime.date.today().isoformat()
p = os.path.join(folder, "inbox", today[:4], today[5:7], today[8:] + ".md")
txt = open(p).read() if os.path.exists(p) else ""
check("draft saved to inbox day file", "Smoke test" in txt and "- two @garden" in txt and "- one" in txt and "![](assets/" in txt)
send(ESC, 0.6); check("back on today after esc", seen("day streak"))
click(10, rows - 1); check("a click on the hint bar opens the inbox", seen("review"))
send("t"); check("retime modal", seen("Date & time")); send(ESC)
send("f", 1.0)
jp = os.path.join(folder, "journal", today[:4], today[5:7], today[8:] + ".md")
check("filed to journal day file", os.path.exists(jp) and "Smoke test" in open(jp).read())
check("inbox day file removed when emptied", not os.path.exists(p))
send(ESC); send("j"); check("browse screen", seen("YEAR") and seen("MONTH") and seen("DAY"))
send(RIGHT); send(RIGHT); send(RIGHT); send(ENTER); check("open entry from browse", seen("editing"))
send(ESC, 0.6); send("s"); check("split picker cycles", seen("@work"))
send("s"); send("s"); send("/"); send("20"); send(ESC); send(ESC)
send("l"); check("look back", seen("THE YEAR") and seen("WORDS A MONTH"))
send(LEFT); send(RIGHT); send(ESC)
send("/"); send("garden"); check("search results", seen("result")); send(DOWN); send(ENTER); check("open from search", seen("editing") or seen("draft"))
send(ESC, 0.6); send(ESC); send(ESC)   # leave the editor, clear the query, leave search
check("back on today after search", seen("A PROMPT"))
send("r"); check("random opens browse", seen("YEAR")); send(ESC)
send(","); check("settings page", seen("Daily word goal") and seen("Back up now") and seen("Clean up")); send(ESC, 0.6)
send("?"); check("help overlay", seen("KEYS")); send("x")
send("q", 0.8)
status = None
for _ in range(50):
    try:
        wp, st = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        wp, st = pid, 0
    if wp == pid:
        status = st; break
    pump(0.1)
if status is None:
    os.kill(pid, signal.SIGKILL); status = 9
text = out.decode("utf-8", "replace")
check("no panic", "panicked" not in text and "RUST_BACKTRACE" not in text)
check("clean exit", status != 9 and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0)
ok = all(c for _, c in checks)
for n, c in checks: print(("  ok  " if c else "  FAIL") + " " + n)
if not ok:
    tail = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)[-3000:]
    print("---- last output ----"); print(tail)
sys.exit(0 if ok else 1)

"""Drive the TUI in a pseudo-terminal: send keys, collect output, check files."""
import os, pty, sys, time, select, fcntl, termios, struct, signal, re, datetime, glob, unicodedata
binary, folder = sys.argv[1], sys.argv[2]
cols, rows = int(sys.argv[3]), int(sys.argv[4])
theme = sys.argv[5] if len(sys.argv) > 5 else "cinema"
# Slow disks / simultaneous builds can delay redraws and saves. Keep the same
# assertions, but allow release checks to give the app more processing time.
wait_scale = max(1.0, float(os.environ.get("QUIRE_SMOKE_WAIT_SCALE", "1")))
# A photo to drop on the composer, outside the journal; and a home of our
# own, so the run never reads or writes the real settings.json. Three
# variables, because no one of them is enough everywhere: QUIRE_CONFIG_DIR is
# the folder Quire reads settings.json from when it is set; XDG_CONFIG_HOME
# moves the settings on Linux only (macOS ignores it); HOME moves them on a
# Mac (~/Library/Application Support) and on Linux without XDG, and keeps
# jnl's config and ~/notes out of it too.
scratch = os.path.abspath(folder) + "-scratch"
os.makedirs(scratch, exist_ok=True)
photo = os.path.join(scratch, "drop me.png")
open(photo, "wb").write(b"\x89PNG\r\n\x1a\n")
own_home = {"HOME": scratch, "XDG_CONFIG_HOME": os.path.join(scratch, "config"), "QUIRE_CONFIG_DIR": os.path.join(scratch, "config", "quire")}
# Run the binary once before the clock starts. macOS checks a program the
# first time it runs after it is built: about 3 s on an idle machine and far
# longer on a busy one, which is every `make smoke` after a change. Keys sent
# while that is going on reach a terminal that is not in raw mode yet, where
# Enter arrives as ^J and files the draft. `--version` returns before any
# settings or journal is read.
import subprocess
subprocess.run([binary, "--version"], env={**os.environ, **own_home}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=300)
pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"; os.environ["COLORTERM"] = "truecolor"
    os.environ.update(own_home)
    os.execv(binary, [binary, "--folder", folder, "--theme", theme])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
out = bytearray()
def pump(t=0.4):
    end = time.time() + t * wait_scale
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try: out.extend(os.read(fd, 65536))
            except OSError: return
# Where the output stood when the last action was sent. A check looks only at
# what came after it, so text an earlier screen printed can't pass it.
mark = 0
def send(s, t=0.35):
    global mark
    mark = len(out)
    os.write(fd, s.encode() if isinstance(s, str) else s)
    if s == "\x1b":
        # A lone Esc is an Esc only if the app reads it with nothing behind
        # it: with the next key already waiting, the terminal layer reads
        # the pair as Alt+key (or two Escs as one), and the run goes down
        # another path. On a busy machine the app can be that far behind, so
        # wait for it to answer (every Esc here redraws) before going on.
        deadline = time.time() + 5 * wait_scale
        while len(out) == mark and time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try: out.extend(os.read(fd, 65536))
                except OSError: break
    pump(t)
CSI = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")
def screen():
    """The window as it stands now: the whole output replayed onto a grid.
    The app redraws only the cells that changed, so a word that was already
    in place is not sent again; the grid has it either way."""
    text = out.decode("utf-8", "replace")
    grid = [[" "] * cols for _ in range(rows)]
    r = c = i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\x1b":
            m = CSI.match(text, i)
            if m:
                i = m.end()
                nums = [int(x) if x.isdigit() else 0 for x in m.group(1).lstrip("?").split(";")]
                n, k = nums[0], m.group(2)
                if k in "Hf": r, c = max(n, 1) - 1, max(nums[1] if len(nums) > 1 else 1, 1) - 1
                elif k == "A": r -= max(n, 1)
                elif k == "B": r += max(n, 1)
                elif k == "C": c += max(n, 1)
                elif k == "D": c -= max(n, 1)
                elif k == "G": c = max(n, 1) - 1
                elif k == "d": r = max(n, 1) - 1
                elif k == "J" and n in (2, 3) or k in "hl" and "1049" in m.group(1):
                    grid = [[" "] * cols for _ in range(rows)]
                elif k == "J" and n == 0 and 0 <= r < rows:
                    grid[r][max(c, 0):] = [" "] * (cols - max(c, 0))
                    for rr in range(r + 1, rows): grid[rr] = [" "] * cols
                elif k == "K" and 0 <= r < rows:
                    a, b = (0, c + 1) if n == 1 else (0, cols) if n == 2 else (c, cols)
                    for cc in range(max(a, 0), min(b, cols)): grid[r][cc] = " "
                r, c = min(max(r, 0), rows - 1), min(max(c, 0), cols)
            elif text.startswith("\x1b]", i):   # an OSC string, to BEL or ST
                ends = [e for e in (text.find("\x07", i), text.find("\x1b\\", i)) if e != -1]
                i = min(ends) + 1 if ends else len(text)
            else:
                i += 2
            continue
        i += 1
        if ch == "\r": c = 0
        elif ch == "\n": r = min(r + 1, rows - 1)
        elif ch == "\b": c = max(c - 1, 0)
        elif ch < " " or ch == "\x7f": pass
        elif unicodedata.combining(ch) or ch in "\u200d\ufe0e\ufe0f":
            if 0 < c <= cols: grid[r][c - 1] += ch
        elif c < cols:
            grid[r][c] = ch
            w = 2 if unicodedata.east_asian_width(ch) in "WF" else 1
            if w == 2 and c + 1 < cols: grid[r][c + 1] = ""
            c += w
    return "\n".join("".join(row) for row in grid)
def seen(s):
    """True when s was drawn by the action being checked: it is in the output
    since that action, or on the screen that action left."""
    since = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", out[mark:].decode("utf-8", "replace"))
    tight = s.replace(" ", "")
    if s in since or tight in since.replace(" ", ""): return True
    if mark == len(out): return False   # the action drew nothing at all
    now = screen()
    return s in now or tight in now.replace(" ", "")
ESC, UP, DOWN, RIGHT, LEFT, ENTER, TAB = "\x1b", "\x1b[A", "\x1b[B", "\x1b[C", "\x1b[D", "\r", "\t"
def paste(s, t=0.6): send("\x1b[200~" + s + "\x1b[201~", t)
def click(x, y, t=0.5): send(f"\x1b[<0;{x + 1};{y + 1}M\x1b[<0;{x + 1};{y + 1}m", t)   # 0-based cell, SGR mouse
checks = []
def check(name, cond): checks.append((name, bool(cond)))
# Cold starts can outlast one second while Xcode/cargo are building. Wait
# for the same readiness assertion, with a deadline so a broken screen fails.
startup_deadline = time.monotonic() + 30 * wait_scale
while time.monotonic() < startup_deadline:
    pump(0.1)
    if seen("ON THIS DAY") and seen("A PROMPT") and seen("INBOX"):
        break
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
click(10, rows - 1); check("a click on the hint bar opens the inbox", seen("review") and seen("YEAR") and seen("MONTH"))
# Select the new (newest) draft explicitly: the review selection can survive
# a reload while the composer autosaves.
send(UP * 16)
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
click(2, 0)  # Quire masthead: return Home, independently of the navigation stack.
# Random lands on the entries; below 100 columns the date columns only draw
# once you step back to them.
send("r"); send(LEFT); check("random opens browse", seen("YEAR")); send(ESC)
click(2, 0)
send(","); check("settings page", seen("Daily word goal") and seen("Automatic backups") and seen("Keep backups") and seen("Back up now") and seen("Clean up")); send(ESC, 0.6)
send("?"); check("help overlay", seen("KEYS")); send("x")
click(2, 0); send("q", 0.8)
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

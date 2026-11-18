"""The pairing rules every home server shares (docs/DEVICES.md, section 1).

Plain functions and one small limiter, standard library only, so any server can import it from its
copy of the kit. `kit/vectors/pairing.json` holds the cases; `kit/rust/home-pairing` is the same
rules in Rust and must pass the same file.

    from home_pairing import tidy_code, pretty_code, new_code, new_key, key_hash, ...
"""
import base64
import hashlib
import hmac
import secrets

ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"   # 32 characters: no 0, O, 1 or I
CODE_LENGTH = 6
CODE_SECONDS = 600            # a code lives 10 minutes, and works once
MAX_WAITING = 20              # unclaimed codes per server
POLL_WAIT_MAX = 25            # seconds a poll may be held
KEY_BYTES = 32
TOKEN_BYTES = 16
REVOKED_KEEP_DAYS = 30
ROTATE_GRACE_SECONDS = 300    # the old key keeps working this long after a rotate
SEEN_EVERY_SECONDS = 60       # last seen is written at most this often

# (window seconds, limit, lockout seconds). A lockout of 0 means "refuse while over the limit".
WRONG_PER_ADDRESS = (600, 5, 600)
WRONG_TOTAL = (600, 20, 600)
START_PER_ADDRESS = (60, 10, 0)
BAD_KEY_PER_ADDRESS = (60, 30, 300)
DEVICE_CALLS = (60, 1, 0)     # hello and log: once a minute per device

SCOPES = ("display", "touch", "sensor", "voice", "record", "read", "write", "devices")

_IGNORED = " \t\r\n-."


def tidy_code(typed):
    """What a person typed, as the code it means, or None if it can't be one. Case doesn't matter and
    spaces, dashes and dots are ignored. Anything else, or the wrong length, is not a code."""
    if not isinstance(typed, str):
        return None
    code = "".join(c for c in typed if c not in _IGNORED).upper()
    if len(code) != CODE_LENGTH or any(c not in ALPHABET for c in code):
        return None
    return code


def pretty_code(code):
    """7Q4M2X as 7Q4-M2X, the way it is shown."""
    return f"{code[:3]}-{code[3:]}" if len(code) == CODE_LENGTH else code


def code_from_bytes(raw):
    """Six random bytes as a code. 32 divides 256, so taking the low five bits is unbiased."""
    if len(raw) != CODE_LENGTH:
        raise ValueError("a code needs exactly six bytes")
    return "".join(ALPHABET[b & 31] for b in raw)


def new_code():
    return code_from_bytes(secrets.token_bytes(CODE_LENGTH))


def b64url(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def key_from_bytes(prefix, raw):
    if len(raw) != KEY_BYTES:
        raise ValueError("a key is 32 random bytes")
    return prefix + b64url(raw)


def new_key(prefix):
    return key_from_bytes(prefix, secrets.token_bytes(KEY_BYTES))


def new_token():
    """The secret a device polls with. Stored hashed, like a key."""
    return b64url(secrets.token_bytes(TOKEN_BYTES))


def key_hash(key):
    """What the server stores: SHA-256 of the key's UTF-8 bytes, as lower-case hex. The key is 256
    random bits, so a plain hash is enough: no salt, no slow hash."""
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def hash_matches(supplied_key, stored_hash):
    return bool(supplied_key) and hmac.compare_digest(key_hash(supplied_key), stored_hash or "")


def key_tail(key):
    return key[-4:]


def key_display(prefix, tail):
    """How a list shows a key: the prefix, an ellipsis and the last four characters."""
    return f"{prefix}…{tail}"


def narrow_scopes(ceiling, requested, default=None):
    """The scopes a key gets. None asks for the default (the ceiling unless a default is given). A list
    may only narrow: every name must be known and under the ceiling, and at least one is needed.
    Returns (scopes, None) or (None, error)."""
    if requested is None:
        chosen = list(default if default is not None else ceiling)
    elif isinstance(requested, list) and all(isinstance(s, str) for s in requested):
        chosen = requested
    else:
        return None, "scopes must be a list of names"
    unknown = [s for s in chosen if s not in SCOPES]
    if unknown:
        return None, f"unknown scope: {unknown[0]}"
    over = [s for s in chosen if s not in ceiling]
    if over:
        return None, f"this kind of device can't have {over[0]}"
    if not chosen:
        return None, "a key needs at least one scope"
    return [s for s in SCOPES if s in chosen], None


def parse_version(text):
    """MAJOR.MINOR[.PATCH], with an optional leading v, as a tuple of three numbers. Anything else is
    None, and an unreadable version is never an update."""
    if not isinstance(text, str):
        return None
    t = text.strip()
    if t[:1] in ("v", "V"):
        t = t[1:]
    parts = t.split(".")
    if len(parts) not in (2, 3) or not all(p.isascii() and p.isdigit() and len(p) <= 9 for p in parts):
        return None
    nums = [int(p) for p in parts] + [0] * (3 - len(parts))
    return tuple(nums)


def is_newer(candidate, current):
    a, b = parse_version(candidate), parse_version(current)
    return a is not None and b is not None and a > b


def ota_message(product, board, version, size, sha256):
    """The bytes an update's signature covers."""
    return f"{product}|{board}|{version}|{int(size)}|{sha256.lower()}".encode("ascii")


class Limiter:
    """Counts events per key in a sliding window. Over the limit, a key is refused for `lockout`
    seconds (or, with no lockout, until the window has room again). Time is passed in, so tests and
    other languages can replay the same steps."""

    def __init__(self, window, limit, lockout):
        self.window, self.limit, self.lockout = window, limit, lockout
        self.events = {}
        self.until = {}

    def _trim(self, key, now):
        kept = [t for t in self.events.get(key, []) if now - t < self.window]
        if kept:
            self.events[key] = kept
        else:
            self.events.pop(key, None)
        return kept

    def blocked(self, key, now):
        if self.until.get(key, 0) > now:
            return True
        self.until.pop(key, None)
        return not self.lockout and len(self._trim(key, now)) >= self.limit

    def record(self, key, now):
        """Count one event. Returns True if this one tipped the key over into a lockout."""
        kept = self._trim(key, now)
        kept.append(now)
        self.events[key] = kept
        if self.lockout and len(kept) >= self.limit:
            self.until[key] = now + self.lockout
            self.events.pop(key, None)
            return True
        return False

    def hit(self, key, now):
        """Check and count in one step, for a plain rate limit. False means refused."""
        if self.blocked(key, now):
            return False
        self.record(key, now)
        return True

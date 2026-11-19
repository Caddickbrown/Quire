"""The /api/pair routes for a home server, without the web framework (docs/DEVICES.md, sections 1 and 2).

home_pairing.py is the rules; this is the bookkeeping on top of them, for a server that runs as one
process (every server on the Pi does): codes waiting to be approved live in memory (they last ten
minutes, so a restart only means "start again"), and paired keys live in a small JSON file holding
their SHA-256 hashes, never the keys. The server wires each route to one method and decides who is
signed in. `kit/rust/home-pairing` (feature "book") is the same book in Rust; both pass the same steps
in kit/tests.

    book = PairingBook("hub", "Hub", "3.2", path=data_dir / "paired.json")

    GET  /.well-known/pair           -> book.well_known()                         no auth
    POST /api/pair/start             -> book.start(body, ip, base_url)            no auth
    GET  /api/pair/poll?wait=25      -> book.poll(bearer, wait)                   the poll token
    POST /api/pair/lookup            -> book.lookup(body, ip)                     signed in, or `devices`
    POST /api/pair/approve           -> book.approve(body, ip, approver)          signed in, or `devices`
    GET  /api/paired                 -> book.listing()                            signed in, or `devices`
    POST /api/paired/<id>            -> book.update(id, body)                     signed in, or `devices`
    POST /api/paired/<id>/revoke     -> book.revoke(id)    (/restore, /remove)    signed in, or `devices`
    POST /api/device/unpair          -> book.unpair(device)                       the device's own key
    GET  /pair                       -> kit/web/pair.html                         the approve page

Each method returns (status, body). A request carrying `Authorization: Bearer <key>` where
book.is_key(key) is a device key goes to book.check(key, ip), which gives ("ok", device), ("bad",
None) or ("limited", None). Everything else keeps whatever auth the server had (the main token).
"""
import json
import os
import pathlib
import tempfile
import threading
import time

import home_pairing as hp

APP_SCOPES = ("read", "write", "devices")
APP_DEFAULT = ("read", "write")
LOCKED = "too many wrong codes; code entry is paused for ten minutes"
GONE = "that pairing has expired or was already collected; start again on the device"
NOT_SHOWING = "no device is showing that code; check it, or start pairing again on the device"
UNKNOWN = "no device with that id"


def text_field(data, name, limit):
    value = data.get(name)
    if not isinstance(value, str):
        return ""
    return " ".join(value.split())[:limit]


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


class PairingBook:
    def __init__(self, service, name, version, path, kinds=None, clock=time.time, approve_path="/pair",
                 cert_sha256=None):
        self.service, self.name, self.version = service, name, version
        self.path = pathlib.Path(path)
        self.kinds = kinds or {"app": {"prefix": f"{service}_app_", "ceiling": list(APP_SCOPES),
                                       "default": list(APP_DEFAULT), "title": "phone app"}}
        self.clock = clock
        self.approve_path = approve_path
        self.cert_sha256 = cert_sha256
        self.cond = threading.Condition()
        self.pending = {}            # code -> request
        self.wrong_by_address = hp.Limiter(*hp.WRONG_PER_ADDRESS)
        self.wrong_in_total = hp.Limiter(*hp.WRONG_TOTAL)
        self.starts = hp.Limiter(*hp.START_PER_ADDRESS)
        self.bad_keys = hp.Limiter(*hp.BAD_KEY_PER_ADDRESS)
        self.devices = self._load()

    # ------------------------------------------------------------------ storage

    def _load(self):
        """The paired keys. A damaged file is moved aside (paired.json.damaged-<time>) and the server starts
        with none, saying so: the phones fall back to pairing again, and the damaged file is kept for a
        person to look at, never overwritten. The Rust book does the same."""
        try:
            text = self.path.read_text()
        except FileNotFoundError:
            return []
        try:
            rows = json.loads(text)
            if not isinstance(rows, list):
                raise ValueError("not a list")
        except ValueError as e:
            aside = self.path.with_name(f"{self.path.name}.damaged-{int(self.clock())}")
            os.replace(self.path, aside)
            print(f"[pairing] {self.path} was damaged ({e.__class__.__name__}); moved to {aside.name}. "
                  "Paired phones must pair again.", flush=True)
            return []
        return [r for r in rows if isinstance(r, dict)]

    def _save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".paired-", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(self.devices, f, indent=1)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o600)
            os.replace(tmp, self.path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def _tidy_up(self, t):
        for code in [c for c, r in self.pending.items() if r["expires"] <= t]:
            del self.pending[code]
        keep = hp.REVOKED_KEEP_DAYS * 86400
        before = len(self.devices)
        self.devices = [d for d in self.devices if not d.get("revoked_s") or t - d["revoked_s"] < keep]
        if len(self.devices) != before:
            self._save()

    def _device(self, n):
        for d in self.devices:
            if d.get("id") == n:
                return d
        return None

    def _view(self, d):
        kind = self.kinds.get(d["kind"], {})
        return {"id": d["id"], "kind": d["kind"], "title": kind.get("title", d["kind"]),
                "model": d.get("model", ""), "name": d.get("name", ""), "firmware": d.get("firmware", ""),
                "key": hp.key_display(kind.get("prefix", ""), d.get("key_tail", "")),
                "scopes": d.get("scopes", []), "ceiling": kind.get("ceiling", []),
                "paired_at": d.get("paired_at"), "approved_by": d.get("approved_by", ""),
                "last_seen": d.get("last_seen"), "last_ip": d.get("last_ip"),
                "online": bool(d.get("last_seen_s")) and self.clock() - d["last_seen_s"] < 120,
                "revoked_at": d.get("revoked_at")}

    # ------------------------------------------------------------------ the routes

    def well_known(self):
        return 200, {"service": self.service, "name": self.name, "version": self.version, "pair": "/api/pair",
                     "kinds": list(self.kinds), "cert_sha256": self.cert_sha256}

    def _code_locked(self, ip, t):
        return self.wrong_by_address.blocked(ip, t) or self.wrong_in_total.blocked("*", t)

    def _wrong(self, ip, t):
        self.wrong_by_address.record(ip, t)
        self.wrong_in_total.record("*", t)

    def start(self, data, ip, base_url):
        data = data if isinstance(data, dict) else {}
        kind = data.get("kind")
        if not isinstance(kind, str) or kind not in self.kinds:
            return 400, {"error": "kind must be one of: " + ", ".join(self.kinds)}
        if "code" in data:
            return 409, {"error": f"{self.name} pairs from the device: start without a code, then approve it"}
        t = self.clock()
        with self.cond:
            self._tidy_up(t)
            if not self.starts.hit(ip, t):
                return 429, {"error": "too many pairing requests from this address; wait a minute"}
            if len(self.pending) >= hp.MAX_WAITING:
                return 429, {"error": "too many devices waiting to pair; try again in a few minutes"}
            code = hp.new_code()
            while code in self.pending:
                code = hp.new_code()
            token = hp.new_token()
            self.pending[code] = {
                "token_hash": hp.key_hash(token), "kind": kind, "model": text_field(data, "model", 80),
                "name": text_field(data, "name", 40), "firmware": text_field(data, "firmware", 40),
                "ip": ip, "asked_at": iso(t), "expires": t + hp.CODE_SECONDS, "approved": None}
        shown = hp.pretty_code(code)
        return 200, {"code": shown, "token": token, "expires_in": hp.CODE_SECONDS,
                     "url": f"{base_url.rstrip('/')}{self.approve_path}?code={code}",
                     "say": f"On {self.name}'s Devices page ({self.approve_path}), type {shown}"}

    def poll(self, token, wait=0):
        """Held up to `wait` seconds (25 at most). 202 waiting, 200 with the key once, 410 after."""
        try:
            wait = max(0, min(int(wait), hp.POLL_WAIT_MAX))
        except (TypeError, ValueError):
            wait = 0
        if not token:
            return 410, {"error": GONE}
        wanted = hp.key_hash(token)
        deadline = self.clock() + wait
        with self.cond:
            while True:
                t = self.clock()
                self._tidy_up(t)
                code = next((c for c, r in self.pending.items() if r["token_hash"] == wanted), None)
                if code is None:
                    return 410, {"error": GONE}
                req = self.pending[code]
                if req["approved"]:
                    del self.pending[code]
                    return 200, self._mint(req, t)
                left = deadline - t
                if left <= 0:
                    return 202, {"waiting": True, "expires_in": int(req["expires"] - t)}
                self.cond.wait(min(1.0, left))

    def _mint(self, req, t):
        kind = self.kinds[req["kind"]]
        key = hp.new_key(kind["prefix"])
        ok = req["approved"]
        n = max([d["id"] for d in self.devices] + [0]) + 1
        self.devices.append({"id": n, "kind": req["kind"], "model": req["model"], "name": ok["name"],
                             "firmware": req["firmware"], "key_hash": hp.key_hash(key),
                             "key_tail": hp.key_tail(key), "scopes": ok["scopes"], "paired_at": iso(t),
                             "approved_by": ok["by"], "last_seen": None, "last_seen_s": 0,
                             "last_ip": None, "revoked_at": None, "revoked_s": None})
        self._save()
        return {"key": key, "device": {"id": n, "name": ok["name"]}, "scopes": ok["scopes"]}

    def _waiting(self, data, ip, t):
        """The request this code names, or a refusal. A wrong code counts against the address."""
        if self._code_locked(ip, t):
            return None, None, (429, {"error": LOCKED})
        self._tidy_up(t)
        code = hp.tidy_code(data.get("code"))
        req = self.pending.get(code) if code else None
        if req is None or req["approved"]:
            self._wrong(ip, t)
            return None, None, (409, {"error": NOT_SHOWING})
        return code, req, None

    def lookup(self, data, ip):
        data = data if isinstance(data, dict) else {}
        t = self.clock()
        with self.cond:
            _, req, refusal = self._waiting(data, ip, t)
            if refusal:
                return refusal
            kind = self.kinds[req["kind"]]
            return 200, {"request": {"kind": req["kind"], "title": kind["title"], "model": req["model"],
                                     "name": req["name"], "firmware": req["firmware"], "ip": req["ip"],
                                     "asked_at": req["asked_at"], "expires_in": int(req["expires"] - t),
                                     "ceiling": kind["ceiling"], "default": kind.get("default") or kind["ceiling"]}}

    def approve(self, data, ip, approver):
        """`approver` is who is signed in, as words for the list: "the main token", "Dan's iPad"."""
        data = data if isinstance(data, dict) else {}
        t = self.clock()
        with self.cond:
            _, req, refusal = self._waiting(data, ip, t)
            if refusal:
                return refusal
            expected = data.get("kind")
            if expected is not None and expected != req["kind"]:
                what = self.kinds[expected]["title"] if expected in self.kinds else str(expected)
                return 409, {"error": f"that code is for a {self.kinds[req['kind']]['title']}, not a {what}"}
            kind = self.kinds[req["kind"]]
            scopes, err = hp.narrow_scopes(kind["ceiling"], data.get("scopes"), kind.get("default"))
            if err:
                return 400, {"error": err}
            name = text_field(data, "name", 40) or req["name"] or kind["title"].capitalize()
            req["approved"] = {"name": name, "scopes": scopes, "by": str(approver)[:60]}
            self.cond.notify_all()
            return 200, {"device": {"name": name, "kind": req["kind"], "scopes": scopes}}

    def listing(self):
        t = self.clock()
        with self.cond:
            self._tidy_up(t)
            return 200, {"paired": [self._view(d) for d in self.devices],
                         "waiting": sum(1 for r in self.pending.values() if not r["approved"]),
                         "locked": self.wrong_in_total.blocked("*", t)}

    def update(self, n, data):
        data = data if isinstance(data, dict) else {}
        with self.cond:
            d = self._device(n)
            if d is None:
                return 404, {"error": UNKNOWN}
            if "name" in data:
                name = text_field(data, "name", 40)
                if not name:
                    return 400, {"error": "a name can't be empty"}
                d["name"] = name
            if "scopes" in data:
                kind = self.kinds.get(d["kind"], {"ceiling": []})
                scopes, err = hp.narrow_scopes(kind["ceiling"], data["scopes"])
                if err:
                    return 400, {"error": err}
                d["scopes"] = scopes
            self._save()
            return 200, self._view(d)

    def revoke(self, n):
        with self.cond:
            d = self._device(n)
            if d is None:
                return 404, {"error": UNKNOWN}
            if not d.get("revoked_at"):
                t = self.clock()
                d["revoked_at"], d["revoked_s"] = iso(t), t
                self._save()
            return 200, self._view(d)

    def restore(self, n):
        with self.cond:
            d = self._device(n)
            if d is None:
                return 404, {"error": UNKNOWN}
            d["revoked_at"] = d["revoked_s"] = None
            self._save()
            return 200, self._view(d)

    def remove(self, n):
        with self.cond:
            d = self._device(n)
            if d is None:
                return 404, {"error": UNKNOWN}
            self.devices.remove(d)
            self._save()
            return 200, {"removed": n}

    def unpair(self, device):
        """A device signing itself out: its key stops working (it can be restored for 30 days)."""
        return self.revoke(device["id"])

    # ------------------------------------------------------------------ keys on requests

    def is_key(self, bearer):
        return isinstance(bearer, str) and any(bearer.startswith(k["prefix"]) for k in self.kinds.values())

    def check(self, key, ip):
        """("ok", device view), ("bad", None) or ("limited", None). A revoked or unknown key is the same
        "bad", so a 401 never says whether a key existed. Last seen is written at most once a minute.
        An address locked for wrong keys is still let in with a right one (review LOW 44): another phone
        behind the same address isn't locked out, and a key can't be guessed anyway."""
        t = self.clock()
        with self.cond:
            found = None
            if key:
                for d in self.devices:
                    if hp.hash_matches(key, d.get("key_hash")) and not d.get("revoked_at"):
                        found = d
                        break
            if found is None:
                if self.bad_keys.blocked(ip, t):
                    return "limited", None
                self.bad_keys.record(ip, t)
                return "bad", None
            if t - (found.get("last_seen_s") or 0) >= hp.SEEN_EVERY_SECONDS:
                found["last_seen"], found["last_seen_s"], found["last_ip"] = iso(t), t, ip
                self._save()
            return "ok", self._view(found)

    @staticmethod
    def allows(device, scope):
        return bool(device) and scope in device.get("scopes", [])

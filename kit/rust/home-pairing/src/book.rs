//! The pairing book: the /api/pair routes without the web framework (feature "book"). The same book
//! as `kit/python/home_pairing_book.py`, passing the same steps (`kit/vectors/pairing-book.json`).
//!
//! For a server that runs as one process. Codes waiting to be approved live in memory (ten minutes,
//! so a restart only means "start again"); paired keys live in a small JSON file of their SHA-256
//! hashes. Each method returns `(status, body)`. Keep the book in a `Mutex`; a held poll calls
//! `poll(token, 0)` under the lock, then sleeps outside it and asks again, up to `wait` seconds
//! (see `poll_wait`), so the lock is never held while waiting.
//!
//! ```ignore
//! let book = Mutex::new(Book::open("hub", "Hub", "3.2", data.join("paired.json"), Book::app_kinds("hub")));
//! // GET /.well-known/pair      book.well_known()
//! // POST /api/pair/start       book.start(&body, ip, base_url)
//! // GET /api/pair/poll         book.poll(bearer, 0) in a loop (poll_wait)
//! // POST /api/pair/lookup      book.lookup(&body, ip)              signed in, or `devices`
//! // POST /api/pair/approve     book.approve(&body, ip, approver)   signed in, or `devices`
//! // GET /api/paired            book.listing()                      signed in, or `devices`
//! // POST /api/paired/<id>      book.update(id, &body); /revoke, /restore, /remove
//! // a Bearer where book.is_key(..): book.check(key, ip) -> Check::Ok(device) | Bad | Limited
//! ```
use crate::*;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::PathBuf;

pub const LOCKED: &str = "too many wrong codes; code entry is paused for ten minutes";
pub const GONE: &str = "that pairing has expired or was already collected; start again on the device";
pub const NOT_SHOWING: &str = "no device is showing that code; check it, or start pairing again on the device";
pub const UNKNOWN: &str = "no device with that id";

pub type Reply = (u16, Value);

#[derive(Clone, Debug)]
pub struct Kind {
    pub prefix: String,
    pub ceiling: Vec<&'static str>,
    pub default: Option<Vec<&'static str>>,
    pub title: String,
}

struct Approved {
    name: String,
    scopes: Vec<String>,
    by: String,
}

struct Request {
    token_hash: String,
    kind: String,
    model: String,
    name: String,
    firmware: String,
    ip: String,
    asked_at: String,
    expires: f64,
    approved: Option<Approved>,
}

pub enum Check {
    Ok(Value),
    Bad,
    Limited,
}

pub struct Book {
    pub service: String,
    pub name: String,
    pub version: String,
    pub path: PathBuf,
    pub kinds: Vec<(String, Kind)>,
    pub approve_path: String,
    pub cert_sha256: Option<String>,
    pub clock: Box<dyn Fn() -> f64 + Send>,
    pub random: Box<dyn Fn(&mut [u8]) + Send>,
    pending: Vec<(String, Request)>,
    devices: Vec<Value>,
    wrong_by_address: Limiter,
    wrong_in_total: Limiter,
    starts: Limiter,
    bad_keys: Limiter,
}

/// Random bytes from the operating system.
pub fn os_random(buf: &mut [u8]) {
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(buf)).expect("no /dev/urandom");
}

pub fn wall_clock() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// Seconds since the epoch as 2026-11-18T09:40:00Z.
pub fn iso(t: f64) -> String {
    let secs = t.floor() as i64;
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    // Howard Hinnant's civil_from_days.
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, m, d, rem / 3600, rem % 3600 / 60, rem % 60)
}

/// A string field, its runs of spaces made one, cut to `limit` characters.
pub fn text_field(data: &Value, name: &str, limit: usize) -> String {
    match data.get(name).and_then(Value::as_str) {
        Some(s) => s.split_whitespace().collect::<Vec<_>>().join(" ").chars().take(limit).collect(),
        None => String::new(),
    }
}

fn err(status: u16, msg: impl Into<String>) -> Reply {
    (status, json!({"error": msg.into()}))
}

fn capitalised(s: &str) -> String {
    let mut c = s.chars();
    match c.next() {
        Some(f) => f.to_uppercase().collect::<String>() + &c.as_str().to_lowercase(),
        None => String::new(),
    }
}

fn requested(v: Option<&Value>) -> Result<Requested<'_>, ()> {
    match v {
        None | Some(Value::Null) => Ok(Requested::Default),
        Some(Value::Array(items)) => {
            let names: Option<Vec<&str>> = items.iter().map(Value::as_str).collect();
            Ok(names.map(Requested::Names).unwrap_or(Requested::NotAList))
        }
        Some(_) => Ok(Requested::NotAList),
    }
}

/// The paired keys. A damaged file is moved aside (paired.json.damaged-<time>) and the server starts with
/// none, saying so; the damaged file is kept for a person to look at, never overwritten. As the Python book.
pub fn load_devices(path: &std::path::Path, now: f64) -> Vec<Value> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Vec::new(),
        Err(e) => {
            eprintln!("[pairing] couldn't read {}: {}", path.display(), e);
            String::from("\u{0}")
        }
    };
    match serde_json::from_str::<Value>(&text) {
        Ok(Value::Array(rows)) => rows.into_iter().filter(Value::is_object).collect(),
        _ => {
            let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "paired.json".into());
            let aside = path.with_file_name(format!("{}.damaged-{}", name, now as i64));
            let _ = std::fs::rename(path, &aside);
            eprintln!("[pairing] {} was damaged; moved to {}. Paired phones must pair again.", path.display(), aside.display());
            Vec::new()
        }
    }
}

impl Book {
    /// The usual kinds for a server whose only paired things are phone apps.
    pub fn app_kinds(service: &str) -> Vec<(String, Kind)> {
        vec![(
            "app".into(),
            Kind {
                prefix: format!("{}_app_", service),
                ceiling: vec!["read", "write", "devices"],
                default: Some(vec!["read", "write"]),
                title: "phone app".into(),
            },
        )]
    }

    pub fn open(service: &str, name: &str, version: &str, path: impl Into<PathBuf>, kinds: Vec<(String, Kind)>) -> Book {
        let path = path.into();
        let devices = load_devices(&path, wall_clock());
        Book {
            service: service.into(),
            name: name.into(),
            version: version.into(),
            path,
            kinds,
            approve_path: "/pair".into(),
            cert_sha256: None,
            clock: Box::new(wall_clock),
            random: Box::new(os_random),
            pending: Vec::new(),
            devices,
            wrong_by_address: Limiter::new(WRONG_PER_ADDRESS),
            wrong_in_total: Limiter::new(WRONG_TOTAL),
            starts: Limiter::new(START_PER_ADDRESS),
            bad_keys: Limiter::new(BAD_KEY_PER_ADDRESS),
        }
    }

    fn kind(&self, name: &str) -> Option<&Kind> {
        self.kinds.iter().find(|(n, _)| n == name).map(|(_, k)| k)
    }

    fn save(&self) {
        if let Some(dir) = self.path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let tmp = self.path.with_extension(format!("tmp{}", std::process::id()));
        let text = serde_json::to_string_pretty(&Value::Array(self.devices.clone())).unwrap_or_else(|_| "[]".into());
        let written = (|| -> std::io::Result<()> {
            let mut f = std::fs::File::create(&tmp)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
            }
            f.write_all(text.as_bytes())?;
            f.sync_all()?;
            std::fs::rename(&tmp, &self.path)
        })();
        if let Err(e) = written {
            let _ = std::fs::remove_file(&tmp);
            eprintln!("[pairing] couldn't save {}: {}", self.path.display(), e);
        }
    }

    fn tidy_up(&mut self, t: f64) {
        self.pending.retain(|(_, r)| r.expires > t);
        let keep = (REVOKED_KEEP_DAYS * 86400) as f64;
        let before = self.devices.len();
        self.devices.retain(|d| match d.get("revoked_s").and_then(Value::as_f64) {
            Some(s) => t - s < keep,
            None => true,
        });
        if self.devices.len() != before {
            self.save();
        }
    }

    fn device_index(&self, n: i64) -> Option<usize> {
        self.devices.iter().position(|d| d.get("id").and_then(Value::as_i64) == Some(n))
    }

    fn view(&self, d: &Value) -> Value {
        let s = |k: &str| d.get(k).cloned().unwrap_or(Value::Null);
        let kind_name = d.get("kind").and_then(Value::as_str).unwrap_or("");
        let kind = self.kind(kind_name);
        let seen = d.get("last_seen_s").and_then(Value::as_f64).unwrap_or(0.0);
        json!({
            "id": s("id"), "kind": kind_name, "title": kind.map(|k| k.title.clone()).unwrap_or(kind_name.into()),
            "model": d.get("model").cloned().unwrap_or(json!("")), "name": d.get("name").cloned().unwrap_or(json!("")),
            "firmware": d.get("firmware").cloned().unwrap_or(json!("")),
            "key": key_display(kind.map(|k| k.prefix.as_str()).unwrap_or(""), d.get("key_tail").and_then(Value::as_str).unwrap_or("")),
            "scopes": d.get("scopes").cloned().unwrap_or(json!([])),
            "ceiling": kind.map(|k| json!(k.ceiling)).unwrap_or(json!([])),
            "paired_at": s("paired_at"), "approved_by": d.get("approved_by").cloned().unwrap_or(json!("")),
            "last_seen": s("last_seen"), "last_ip": s("last_ip"),
            "online": seen > 0.0 && (self.clock)() - seen < 120.0,
            "revoked_at": s("revoked_at"),
        })
    }

    pub fn well_known(&self) -> Reply {
        let kinds: Vec<&str> = self.kinds.iter().map(|(n, _)| n.as_str()).collect();
        (200, json!({"service": self.service, "name": self.name, "version": self.version, "pair": "/api/pair",
                     "kinds": kinds, "cert_sha256": self.cert_sha256}))
    }

    fn code_locked(&mut self, ip: &str, t: f64) -> bool {
        self.wrong_by_address.blocked(ip, t) || self.wrong_in_total.blocked("*", t)
    }

    fn wrong(&mut self, ip: &str, t: f64) {
        self.wrong_by_address.record(ip, t);
        self.wrong_in_total.record("*", t);
    }

    fn new_code(&self) -> String {
        let mut raw = [0u8; CODE_LENGTH];
        (self.random)(&mut raw);
        code_from_bytes(&raw)
    }

    pub fn start(&mut self, data: &Value, ip: &str, base_url: &str) -> Reply {
        let kind = data.get("kind").and_then(Value::as_str).unwrap_or("").to_string();
        if self.kind(&kind).is_none() {
            let names: Vec<&str> = self.kinds.iter().map(|(n, _)| n.as_str()).collect();
            return err(400, format!("kind must be one of: {}", names.join(", ")));
        }
        if data.get("code").is_some() {
            return err(409, format!("{} pairs from the device: start without a code, then approve it", self.name));
        }
        let t = (self.clock)();
        self.tidy_up(t);
        if !self.starts.hit(ip, t) {
            return err(429, "too many pairing requests from this address; wait a minute");
        }
        if self.pending.len() as i64 >= MAX_WAITING {
            return err(429, "too many devices waiting to pair; try again in a few minutes");
        }
        let mut code = self.new_code();
        while self.pending.iter().any(|(c, _)| *c == code) {
            code = self.new_code();
        }
        let mut raw = [0u8; TOKEN_BYTES];
        (self.random)(&mut raw);
        let token = token_from_bytes(&raw);
        self.pending.push((
            code.clone(),
            Request {
                token_hash: key_hash(&token),
                kind,
                model: text_field(data, "model", 80),
                name: text_field(data, "name", 40),
                firmware: text_field(data, "firmware", 40),
                ip: ip.into(),
                asked_at: iso(t),
                expires: t + CODE_SECONDS as f64,
                approved: None,
            },
        ));
        let shown = pretty_code(&code);
        (200, json!({"code": shown, "token": token, "expires_in": CODE_SECONDS,
                     "url": format!("{}{}?code={}", base_url.trim_end_matches('/'), self.approve_path, code),
                     "say": format!("On {}'s Devices page ({}), type {}", self.name, self.approve_path, shown)}))
    }

    /// One look: 202 waiting, 200 with the key once, 410 after. `wait` is ignored here; hold the poll
    /// with `poll_wait` (sync) or a loop with your runtime's sleep (async).
    pub fn poll(&mut self, token: &str, _wait: u64) -> Reply {
        if token.is_empty() {
            return err(410, GONE);
        }
        let t = (self.clock)();
        self.tidy_up(t);
        let wanted = key_hash(token);
        let Some(i) = self.pending.iter().position(|(_, r)| r.token_hash == wanted) else {
            return err(410, GONE);
        };
        if self.pending[i].1.approved.is_some() {
            let (_, req) = self.pending.remove(i);
            return (200, self.mint(req, t));
        }
        (202, json!({"waiting": true, "expires_in": (self.pending[i].1.expires - t) as i64}))
    }

    fn mint(&mut self, req: Request, t: f64) -> Value {
        let prefix = self.kind(&req.kind).map(|k| k.prefix.clone()).unwrap_or_default();
        let mut raw = [0u8; KEY_BYTES];
        (self.random)(&mut raw);
        let key = key_from_bytes(&prefix, &raw);
        let ok = req.approved.expect("approved");
        let n = self.devices.iter().filter_map(|d| d.get("id").and_then(Value::as_i64)).max().unwrap_or(0) + 1;
        self.devices.push(json!({
            "id": n, "kind": req.kind, "model": req.model, "name": ok.name, "firmware": req.firmware,
            "key_hash": key_hash(&key), "key_tail": key_tail(&key), "scopes": ok.scopes, "paired_at": iso(t),
            "approved_by": ok.by, "last_seen": null, "last_seen_s": 0, "last_ip": null,
            "revoked_at": null, "revoked_s": null,
        }));
        self.save();
        json!({"key": key, "device": {"id": n, "name": ok.name}, "scopes": ok.scopes})
    }

    fn waiting(&mut self, data: &Value, ip: &str, t: f64) -> Result<usize, Reply> {
        if self.code_locked(ip, t) {
            return Err(err(429, LOCKED));
        }
        self.tidy_up(t);
        let code = data.get("code").and_then(Value::as_str).and_then(tidy_code);
        let found = code.and_then(|c| self.pending.iter().position(|(pc, r)| *pc == c && r.approved.is_none()));
        match found {
            Some(i) => Ok(i),
            None => {
                self.wrong(ip, t);
                Err(err(409, NOT_SHOWING))
            }
        }
    }

    pub fn lookup(&mut self, data: &Value, ip: &str) -> Reply {
        let t = (self.clock)();
        let i = match self.waiting(data, ip, t) {
            Ok(i) => i,
            Err(r) => return r,
        };
        let r = &self.pending[i].1;
        let kind = self.kind(&r.kind).cloned().expect("kind");
        (200, json!({"request": {
            "kind": r.kind, "title": kind.title, "model": r.model, "name": r.name, "firmware": r.firmware,
            "ip": r.ip, "asked_at": r.asked_at, "expires_in": (r.expires - t) as i64,
            "ceiling": kind.ceiling, "default": kind.default.clone().unwrap_or(kind.ceiling.clone()),
        }}))
    }

    /// `approver` is who is signed in, as words for the list: "the main token", "Dan's iPad".
    pub fn approve(&mut self, data: &Value, ip: &str, approver: &str) -> Reply {
        let t = (self.clock)();
        let i = match self.waiting(data, ip, t) {
            Ok(i) => i,
            Err(r) => return r,
        };
        let kind_name = self.pending[i].1.kind.clone();
        let kind = self.kind(&kind_name).cloned().expect("kind");
        if let Some(expected) = data.get("kind") {
            let expected = expected.as_str().map(String::from).unwrap_or_else(|| expected.to_string());
            if expected != kind_name {
                let what = self.kind(&expected).map(|k| k.title.clone()).unwrap_or(expected);
                return err(409, format!("that code is for a {}, not a {}", kind.title, what));
            }
        }
        let req = match requested(data.get("scopes")) {
            Ok(r) => r,
            Err(()) => return err(400, "scopes must be a list of names"),
        };
        let scopes = match narrow_scopes(&kind.ceiling, req, kind.default.as_deref()) {
            Ok(s) => s,
            Err(e) => return err(400, e),
        };
        let typed = text_field(data, "name", 40);
        let r = &mut self.pending[i].1;
        let name = if !typed.is_empty() {
            typed
        } else if !r.name.is_empty() {
            r.name.clone()
        } else {
            capitalised(&kind.title)
        };
        r.approved = Some(Approved { name: name.clone(), scopes: scopes.clone(), by: approver.chars().take(60).collect() });
        (200, json!({"device": {"name": name, "kind": kind_name, "scopes": scopes}}))
    }

    pub fn listing(&mut self) -> Reply {
        let t = (self.clock)();
        self.tidy_up(t);
        let paired: Vec<Value> = self.devices.iter().map(|d| self.view(d)).collect();
        let waiting = self.pending.iter().filter(|(_, r)| r.approved.is_none()).count();
        let locked = self.wrong_in_total.blocked("*", t);
        (200, json!({"paired": paired, "waiting": waiting, "locked": locked}))
    }

    pub fn update(&mut self, n: i64, data: &Value) -> Reply {
        let Some(i) = self.device_index(n) else { return err(404, UNKNOWN) };
        if data.get("name").is_some() {
            let name = text_field(data, "name", 40);
            if name.is_empty() {
                return err(400, "a name can't be empty");
            }
            self.devices[i]["name"] = json!(name);
        }
        if data.get("scopes").is_some() {
            let kind_name = self.devices[i].get("kind").and_then(Value::as_str).unwrap_or("").to_string();
            let ceiling = self.kind(&kind_name).map(|k| k.ceiling.clone()).unwrap_or_default();
            let req = match requested(data.get("scopes")) {
                Ok(r) => r,
                Err(()) => return err(400, "scopes must be a list of names"),
            };
            match narrow_scopes(&ceiling, req, None) {
                Ok(s) => self.devices[i]["scopes"] = json!(s),
                Err(e) => return err(400, e),
            }
        }
        self.save();
        (200, self.view(&self.devices[i]))
    }

    pub fn revoke(&mut self, n: i64) -> Reply {
        let Some(i) = self.device_index(n) else { return err(404, UNKNOWN) };
        if self.devices[i].get("revoked_at").map_or(true, Value::is_null) {
            let t = (self.clock)();
            self.devices[i]["revoked_at"] = json!(iso(t));
            self.devices[i]["revoked_s"] = json!(t);
            self.save();
        }
        (200, self.view(&self.devices[i]))
    }

    pub fn restore(&mut self, n: i64) -> Reply {
        let Some(i) = self.device_index(n) else { return err(404, UNKNOWN) };
        self.devices[i]["revoked_at"] = Value::Null;
        self.devices[i]["revoked_s"] = Value::Null;
        self.save();
        (200, self.view(&self.devices[i]))
    }

    pub fn remove(&mut self, n: i64) -> Reply {
        let Some(i) = self.device_index(n) else { return err(404, UNKNOWN) };
        self.devices.remove(i);
        self.save();
        (200, json!({"removed": n}))
    }

    /// A device signing itself out: its key stops working (restorable for 30 days).
    pub fn unpair(&mut self, device: &Value) -> Reply {
        self.revoke(device.get("id").and_then(Value::as_i64).unwrap_or(-1))
    }

    pub fn is_key(&self, bearer: &str) -> bool {
        self.kinds.iter().any(|(_, k)| bearer.starts_with(&k.prefix))
    }

    /// A revoked or unknown key is the same `Bad`, so a 401 never says whether a key existed. Last
    /// seen is written at most once a minute.
    pub fn check(&mut self, key: &str, ip: &str) -> Check {
        let t = (self.clock)();
        // A right key gets in even from an address locked for wrong ones (review LOW 44), as the Python book.
        let found = if key.is_empty() {
            None
        } else {
            self.devices.iter().position(|d| {
                hash_matches(key, d.get("key_hash").and_then(Value::as_str).unwrap_or(""))
                    && d.get("revoked_at").map_or(true, Value::is_null)
            })
        };
        let Some(i) = found else {
            if self.bad_keys.blocked(ip, t) {
                return Check::Limited;
            }
            self.bad_keys.record(ip, t);
            return Check::Bad;
        };
        let seen = self.devices[i].get("last_seen_s").and_then(Value::as_f64).unwrap_or(0.0);
        if t - seen >= SEEN_EVERY_SECONDS as f64 {
            let d = &mut self.devices[i];
            d["last_seen"] = json!(iso(t));
            d["last_seen_s"] = json!(t);
            d["last_ip"] = json!(ip);
            self.save();
        }
        Check::Ok(self.view(&self.devices[i]))
    }

    pub fn allows(device: &Value, scope: &str) -> bool {
        device.get("scopes").and_then(Value::as_array).is_some_and(|s| s.iter().any(|x| x.as_str() == Some(scope)))
    }
}

/// A held poll for a server with threads: asks, sleeps half a second outside the lock, asks again,
/// up to `wait` seconds (25 at most).
pub fn poll_wait(book: &std::sync::Mutex<Book>, token: &str, wait: u64) -> Reply {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(wait.min(POLL_WAIT_MAX));
    loop {
        let reply = book.lock().unwrap_or_else(|e| e.into_inner()).poll(token, 0);
        if reply.0 != 202 || std::time::Instant::now() >= deadline {
            return reply;
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
}

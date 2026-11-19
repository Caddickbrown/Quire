//! The pairing rules every home server shares (app-kit docs/DEVICES.md, section 1): the code, its
//! tidying, keys and their hashes, scopes, limits and firmware versions. The same rules as
//! `kit/python/home_pairing.py`, tested against the same `kit/vectors/pairing.json` and `ota.json`.
//!
//! No randomness of its own: callers pass random bytes in (`code_from_bytes`, `key_from_bytes`), so
//! this crate needs nothing but SHA-256 and every case can be replayed.
use sha2::{Digest, Sha256};
use std::collections::HashMap;

#[cfg(feature = "book")]
pub mod book;

pub const ALPHABET: &str = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ";
pub const CODE_LENGTH: usize = 6;
pub const CODE_SECONDS: i64 = 600;
pub const MAX_WAITING: i64 = 20;
pub const POLL_WAIT_MAX: u64 = 25;
pub const KEY_BYTES: usize = 32;
pub const TOKEN_BYTES: usize = 16;
pub const REVOKED_KEEP_DAYS: i64 = 30;
pub const ROTATE_GRACE_SECONDS: i64 = 300;
pub const SEEN_EVERY_SECONDS: i64 = 60;

/// (window seconds, limit, lockout seconds). No lockout means "refuse while over the limit".
pub const WRONG_PER_ADDRESS: (f64, usize, f64) = (600.0, 5, 600.0);
pub const WRONG_TOTAL: (f64, usize, f64) = (600.0, 20, 600.0);
pub const START_PER_ADDRESS: (f64, usize, f64) = (60.0, 10, 0.0);
pub const BAD_KEY_PER_ADDRESS: (f64, usize, f64) = (60.0, 30, 300.0);
pub const DEVICE_CALLS: (f64, usize, f64) = (60.0, 1, 0.0);

pub const SCOPES: [&str; 8] = ["display", "touch", "sensor", "voice", "record", "read", "write", "devices"];

const IGNORED: [char; 6] = [' ', '\t', '\r', '\n', '-', '.'];

/// What a person typed, as the code it means, or None. Case doesn't matter; spaces, dashes and
/// dots are ignored; anything else, or the wrong length, is not a code.
pub fn tidy_code(typed: &str) -> Option<String> {
    let code: String = typed.chars().filter(|c| !IGNORED.contains(c)).collect::<String>().to_uppercase();
    (code.chars().count() == CODE_LENGTH && code.chars().all(|c| ALPHABET.contains(c))).then_some(code)
}

/// 7Q4M2X as 7Q4-M2X.
pub fn pretty_code(code: &str) -> String {
    if code.len() == CODE_LENGTH && code.is_ascii() {
        format!("{}-{}", &code[..3], &code[3..])
    } else {
        code.to_string()
    }
}

/// Six random bytes as a code. 32 divides 256, so the low five bits are unbiased.
pub fn code_from_bytes(raw: &[u8; CODE_LENGTH]) -> String {
    raw.iter().map(|b| ALPHABET.as_bytes()[(b & 31) as usize] as char).collect()
}

/// base64url with no padding.
pub fn b64url(raw: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(raw.len().div_ceil(3) * 4);
    for chunk in raw.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        let chars = chunk.len() + 1;
        for i in 0..chars {
            out.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
        }
    }
    out
}

/// SHA-256 of the first certificate's DER bytes in PEM text, lower-case hex, or None. What a server
/// puts in /.well-known/pair as cert_sha256: the /pair page shows it, and the phone shows the hash of the
/// certificate its TLS handshake saw, so a relay on the Wi-Fi shows up as a mismatch.
pub fn cert_sha256_from_pem(pem: &str) -> Option<String> {
    const BEGIN: &str = "-----BEGIN CERTIFICATE-----";
    const END: &str = "-----END CERTIFICATE-----";
    let start = pem.find(BEGIN)? + BEGIN.len();
    let end = start + pem[start..].find(END)?;
    let body: Vec<u8> = pem[start..end].bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    let der = b64_decode(&body)?;
    if der.is_empty() {
        return None;
    }
    Some(Sha256::digest(&der).iter().map(|b| format!("{:02x}", b)).collect())
}

/// cert_sha256_from_pem for the server's certificate file; None if it can't be read.
pub fn cert_sha256_from_file(path: &std::path::Path) -> Option<String> {
    cert_sha256_from_pem(&std::fs::read_to_string(path).ok()?)
}

/// The first 16 hex characters in four groups, the way the phone and the /pair page show it.
pub fn short_hash(hex: &str) -> Option<String> {
    if hex.len() < 16 || !hex.is_ascii() {
        return None;
    }
    Some((0..16).step_by(4).map(|i| &hex[i..i + 4]).collect::<Vec<_>>().join(" "))
}

/// Standard base64 with padding, strict: anything else is None.
fn b64_decode(text: &[u8]) -> Option<Vec<u8>> {
    if text.len() % 4 != 0 {
        return None;
    }
    let val = |c: u8| -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    };
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let chunks = text.len() / 4;
    for (i, q) in text.chunks(4).enumerate() {
        let pad = q.iter().rev().take_while(|&&c| c == b'=').count();
        if pad > 2 || (pad > 0 && i + 1 != chunks) {
            return None;
        }
        let mut n = 0u32;
        for &c in &q[..4 - pad] {
            n = n << 6 | val(c)?;
        }
        n <<= 6 * pad as u32;
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..3 - pad]);
    }
    Some(out)
}

pub fn key_from_bytes(prefix: &str, raw: &[u8; KEY_BYTES]) -> String {
    format!("{}{}", prefix, b64url(raw))
}

/// The poll token's text, from 16 random bytes.
pub fn token_from_bytes(raw: &[u8; TOKEN_BYTES]) -> String {
    b64url(raw)
}

/// SHA-256 of the key's UTF-8 bytes, lower-case hex: all the server keeps.
pub fn key_hash(key: &str) -> String {
    Sha256::digest(key.as_bytes()).iter().map(|b| format!("{:02x}", b)).collect()
}

/// Constant time over the hashes.
pub fn hash_matches(supplied_key: &str, stored_hash: &str) -> bool {
    if supplied_key.is_empty() {
        return false;
    }
    let (a, b) = (key_hash(supplied_key), stored_hash.as_bytes().to_vec());
    a.len() == b.len() && a.as_bytes().iter().zip(&b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

pub fn key_tail(key: &str) -> String {
    let chars: Vec<char> = key.chars().collect();
    chars[chars.len().saturating_sub(4)..].iter().collect()
}

pub fn key_display(prefix: &str, tail: &str) -> String {
    format!("{}\u{2026}{}", prefix, tail)
}

/// What a request asked for: nothing (the default), a list of names, or something that isn't one.
pub enum Requested<'a> {
    Default,
    Names(Vec<&'a str>),
    NotAList,
}

/// The scopes a key gets, in the shared order, or why not. A list may only narrow.
pub fn narrow_scopes(ceiling: &[&str], requested: Requested, default: Option<&[&str]>) -> Result<Vec<String>, String> {
    let chosen: Vec<&str> = match requested {
        Requested::Default => default.unwrap_or(ceiling).to_vec(),
        Requested::Names(names) => names,
        Requested::NotAList => return Err("scopes must be a list of names".into()),
    };
    if let Some(s) = chosen.iter().find(|s| !SCOPES.contains(s)) {
        return Err(format!("unknown scope: {}", s));
    }
    if let Some(s) = chosen.iter().find(|s| !ceiling.contains(s)) {
        return Err(format!("this kind of device can't have {}", s));
    }
    if chosen.is_empty() {
        return Err("a key needs at least one scope".into());
    }
    Ok(SCOPES.iter().filter(|s| chosen.contains(s)).map(|s| s.to_string()).collect())
}

/// MAJOR.MINOR[.PATCH] with an optional leading v. None for anything else: an unreadable version
/// is never an update. The rule every firmware shares (DEVICES.md section 3, vectors/ota.json):
/// only spaces, tabs, CR and LF are trimmed; parts are 1 to 9 ASCII digits.
pub fn parse_version(text: &str) -> Option<(u64, u64, u64)> {
    let t = text.trim_matches([' ', '\t', '\r', '\n']);
    let t = t.strip_prefix(['v', 'V']).unwrap_or(t);
    let parts: Vec<&str> = t.split('.').collect();
    if !(2..=3).contains(&parts.len()) || !parts.iter().all(|p| !p.is_empty() && p.len() <= 9 && p.bytes().all(|b| b.is_ascii_digit())) {
        return None;
    }
    let n = |i: usize| parts.get(i).map(|p| p.parse::<u64>().unwrap()).unwrap_or(0);
    Some((n(0), n(1), n(2)))
}

pub fn is_newer(candidate: &str, current: &str) -> bool {
    matches!((parse_version(candidate), parse_version(current)), (Some(a), Some(b)) if a > b)
}

/// The bytes an update's signature covers.
pub fn ota_message(product: &str, board: &str, version: &str, size: u64, sha256: &str) -> String {
    format!("{}|{}|{}|{}|{}", product, board, version, size, sha256.to_lowercase())
}

/// Events per key in a sliding window; over the limit, refused for `lockout` seconds (or, with no
/// lockout, until the window has room). Time is passed in.
pub struct Limiter {
    window: f64,
    limit: usize,
    lockout: f64,
    events: HashMap<String, Vec<f64>>,
    until: HashMap<String, f64>,
}

impl Limiter {
    pub fn new((window, limit, lockout): (f64, usize, f64)) -> Self {
        Limiter { window, limit, lockout, events: HashMap::new(), until: HashMap::new() }
    }
    fn trim(&mut self, key: &str, now: f64) -> usize {
        let window = self.window;
        let n = match self.events.get_mut(key) {
            Some(v) => {
                v.retain(|t| now - t < window);
                v.len()
            }
            None => 0,
        };
        if n == 0 {
            self.events.remove(key);
        }
        n
    }
    pub fn blocked(&mut self, key: &str, now: f64) -> bool {
        if self.until.get(key).is_some_and(|u| *u > now) {
            return true;
        }
        self.until.remove(key);
        self.lockout == 0.0 && self.trim(key, now) >= self.limit
    }
    /// Count one event; true if it tipped the key into a lockout.
    pub fn record(&mut self, key: &str, now: f64) -> bool {
        self.trim(key, now);
        let v = self.events.entry(key.to_string()).or_default();
        v.push(now);
        if self.lockout > 0.0 && v.len() >= self.limit {
            self.until.insert(key.to_string(), now + self.lockout);
            self.events.remove(key);
            return true;
        }
        false
    }
    /// Check and count, for a plain rate limit. False means refused.
    pub fn hit(&mut self, key: &str, now: f64) -> bool {
        if self.blocked(key, now) {
            return false;
        }
        self.record(key, now);
        true
    }
}

#[cfg(test)]
mod vectors {
    use super::*;
    use serde_json::Value;

    fn load(name: &str) -> Value {
        let text = match name {
            "pairing" => include_str!("../../../vectors/pairing.json"),
            _ => include_str!("../../../vectors/ota.json"),
        };
        serde_json::from_str(text).unwrap()
    }
    fn strs(v: &Value) -> Vec<&str> {
        v.as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect()
    }
    fn limit(v: &Value) -> (f64, usize, f64) {
        (v["window"].as_f64().unwrap(), v["limit"].as_u64().unwrap() as usize, v["lockout"].as_f64().unwrap())
    }

    #[test]
    fn constants() {
        let v = load("pairing");
        assert_eq!(v["code"]["alphabet"], ALPHABET);
        assert_eq!(v["code"]["length"], CODE_LENGTH as u64);
        assert_eq!(v["code"]["seconds"], CODE_SECONDS);
        assert_eq!(v["code"]["max_waiting"], MAX_WAITING);
        assert_eq!(v["code"]["poll_wait_max"], POLL_WAIT_MAX);
        assert_eq!(strs(&v["scopes"]["all"]), SCOPES.to_vec());
        let l = &v["limits"];
        assert_eq!(limit(&l["wrong_per_address"]), WRONG_PER_ADDRESS);
        assert_eq!(limit(&l["wrong_total"]), WRONG_TOTAL);
        assert_eq!(limit(&l["start_per_address"]), START_PER_ADDRESS);
        assert_eq!(limit(&l["bad_key_per_address"]), BAD_KEY_PER_ADDRESS);
        assert_eq!(limit(&l["device_calls"]), DEVICE_CALLS);
    }

    #[test]
    fn codes() {
        let v = load("pairing");
        for c in v["tidy"].as_array().unwrap() {
            assert_eq!(tidy_code(c["typed"].as_str().unwrap()).as_deref(), c["code"].as_str(), "{}", c["typed"]);
        }
        for c in v["pretty"].as_array().unwrap() {
            assert_eq!(pretty_code(c["code"].as_str().unwrap()), c["shown"].as_str().unwrap());
        }
        for c in v["code_from_bytes"].as_array().unwrap() {
            let raw = hex(c["bytes"].as_str().unwrap());
            assert_eq!(code_from_bytes(raw[..].try_into().unwrap()), c["code"].as_str().unwrap());
        }
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    #[test]
    fn keys() {
        let v = load("pairing");
        for c in v["keys"]["cases"].as_array().unwrap() {
            let prefix = c["prefix"].as_str().unwrap();
            let key = key_from_bytes(prefix, hex(c["bytes"].as_str().unwrap())[..].try_into().unwrap());
            assert_eq!(key, c["key"].as_str().unwrap());
            assert_eq!(key_hash(&key), c["sha256"].as_str().unwrap());
            assert_eq!(key_tail(&key), c["tail"].as_str().unwrap());
            assert_eq!(key_display(prefix, &key_tail(&key)), c["display"].as_str().unwrap());
            assert!(hash_matches(&key, c["sha256"].as_str().unwrap()));
            assert!(!hash_matches(&format!("{}x", key), c["sha256"].as_str().unwrap()));
            assert!(!hash_matches("", c["sha256"].as_str().unwrap()));
        }
    }

    #[test]
    fn scopes() {
        let v = load("pairing");
        for c in v["scopes"]["cases"].as_array().unwrap() {
            let ceiling = strs(&c["ceiling"]);
            let default = c.get("default").map(strs);
            let requested = match &c["requested"] {
                Value::Null => Requested::Default,
                Value::Array(a) if a.iter().all(|s| s.is_string()) => Requested::Names(a.iter().map(|s| s.as_str().unwrap()).collect()),
                _ => Requested::NotAList,
            };
            let got = narrow_scopes(&ceiling, requested, default.as_deref());
            match c.get("error") {
                Some(e) => assert_eq!(got.unwrap_err(), e.as_str().unwrap()),
                None => assert_eq!(got.unwrap(), strs(&c["scopes"])),
            }
        }
    }

    #[test]
    fn limiter() {
        let v = load("pairing");
        for c in v["limiter"].as_array().unwrap() {
            let mut lim = Limiter::new(limit(c));
            for (i, s) in c["steps"].as_array().unwrap().iter().enumerate() {
                let (t, key) = (s["t"].as_f64().unwrap(), s["key"].as_str().unwrap());
                let (got, want) = match s["op"].as_str().unwrap() {
                    "record" => (lim.record(key, t), &s["locked_now"]),
                    "blocked" => (lim.blocked(key, t), &s["blocked"]),
                    _ => (lim.hit(key, t), &s["allowed"]),
                };
                assert_eq!(got, want.as_bool().unwrap(), "{} step {}", c["name"], i);
            }
        }
    }

    #[test]
    fn cert_fingerprints() {
        let v = load("pairing");
        for c in v["cert_sha256"]["cases"].as_array().unwrap() {
            assert_eq!(cert_sha256_from_pem(c["pem"].as_str().unwrap()).as_deref(), c["sha256"].as_str(), "{:?}", c.get("why"));
            if let Some(short) = c.get("short") {
                assert_eq!(short_hash(c["sha256"].as_str().unwrap()).as_deref(), short.as_str());
            }
        }
        assert_eq!(short_hash("abc"), None);
    }

    #[test]
    fn versions() {
        let v = load("ota");
        for c in v["parse"].as_array().unwrap() {
            let want = c["version"].as_array().map(|a| (a[0].as_u64().unwrap(), a[1].as_u64().unwrap(), a[2].as_u64().unwrap()));
            assert_eq!(parse_version(c["text"].as_str().unwrap()), want, "{}", c["text"]);
        }
        for c in v["newer"].as_array().unwrap() {
            assert_eq!(is_newer(c["candidate"].as_str().unwrap(), c["current"].as_str().unwrap()), c["newer"].as_bool().unwrap());
        }
        for c in v["message"].as_array().unwrap() {
            let m = ota_message(c["product"].as_str().unwrap(), c["board"].as_str().unwrap(), c["version"].as_str().unwrap(), c["size"].as_u64().unwrap(), c["sha256"].as_str().unwrap());
            assert_eq!(m, c["bytes"].as_str().unwrap());
        }
    }
}

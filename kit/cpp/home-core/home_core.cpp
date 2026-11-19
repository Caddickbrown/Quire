#include "home_core.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <ctype.h>
#include "mbedtls/pk.h"
#include "mbedtls/sha256.h"
#include "mbedtls/base64.h"

namespace homecore {

// ─── Flat JSON ──────────────────────────────────────────────────────────────

static size_t skipWs(const std::string& s, size_t i) {
  while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
  return i;
}

// Reads a JSON string starting at the opening quote. Returns the index after the closing
// quote, or npos. \uXXXX below 0x80 is decoded; anything above becomes '?', which nothing the
// device reads ever contains.
static size_t readString(const std::string& s, size_t i, std::string* out) {
  if (i >= s.size() || s[i] != '"') return std::string::npos;
  i++;
  std::string v;
  while (i < s.size()) {
    char c = s[i++];
    if (c == '"') { if (out) *out = v; return i; }
    if (c != '\\') { v += c; continue; }
    if (i >= s.size()) return std::string::npos;
    char e = s[i++];
    switch (e) {
      case '"': v += '"'; break;
      case '\\': v += '\\'; break;
      case '/': v += '/'; break;
      case 'b': v += '\b'; break;
      case 'f': v += '\f'; break;
      case 'n': v += '\n'; break;
      case 'r': v += '\r'; break;
      case 't': v += '\t'; break;
      case 'u': {
        if (i + 4 > s.size()) return std::string::npos;
        char hex[5] = {s[i], s[i + 1], s[i + 2], s[i + 3], 0};
        for (int k = 0; k < 4; k++) if (!isxdigit((unsigned char)hex[k])) return std::string::npos;
        long cp = strtol(hex, nullptr, 16);
        v += (cp < 0x80) ? (char)cp : '?';
        i += 4;
        break;
      }
      default: return std::string::npos;
    }
  }
  return std::string::npos;
}

// Skips any JSON value. Returns the index after it, or npos.
static size_t skipValue(const std::string& s, size_t i) {
  i = skipWs(s, i);
  if (i >= s.size()) return std::string::npos;
  char c = s[i];
  if (c == '"') return readString(s, i, nullptr);
  if (c == '{' || c == '[') {
    int depth = 0;
    while (i < s.size()) {
      char d = s[i];
      if (d == '"') { i = readString(s, i, nullptr); if (i == std::string::npos) return i; continue; }
      if (d == '{' || d == '[') depth++;
      if (d == '}' || d == ']') { depth--; if (depth == 0) return i + 1; }
      i++;
    }
    return std::string::npos;
  }
  size_t start = i;
  while (i < s.size() && s[i] != ',' && s[i] != '}' && s[i] != ']' &&
         s[i] != ' ' && s[i] != '\r' && s[i] != '\n' && s[i] != '\t') i++;
  return i > start ? i : std::string::npos;
}

bool jsonField(const std::string& json, const char* key, std::string& out) {
  size_t i = skipWs(json, 0);
  if (i >= json.size() || json[i] != '{') return false;
  i++;
  while (true) {
    i = skipWs(json, i);
    if (i >= json.size()) return false;
    if (json[i] == '}') return false;
    std::string k;
    i = readString(json, i, &k);
    if (i == std::string::npos) return false;
    i = skipWs(json, i);
    if (i >= json.size() || json[i] != ':') return false;
    i = skipWs(json, i + 1);
    if (k == key) {
      if (i < json.size() && json[i] == '"') return readString(json, i, &out) != std::string::npos;
      if (i < json.size() && (json[i] == '{' || json[i] == '[')) return false;
      size_t end = skipValue(json, i);
      if (end == std::string::npos) return false;
      std::string raw = json.substr(i, end - i);
      if (raw == "null") return false;
      out = raw;
      return true;
    }
    i = skipValue(json, i);
    if (i == std::string::npos) return false;
    i = skipWs(json, i);
    if (i < json.size() && json[i] == ',') { i++; continue; }
    return false;
  }
}

// ─── Versions ───────────────────────────────────────────────────────────────

static bool versionSpace(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

bool parseVersion3(const std::string& text, long out[3]) {
  size_t begin = 0, end = text.size();
  while (begin < end && versionSpace(text[begin])) begin++;
  while (end > begin && versionSpace(text[end - 1])) end--;
  size_t i = begin;
  if (i < end && (text[i] == 'v' || text[i] == 'V')) i++;
  int part = 0;
  out[0] = out[1] = out[2] = 0;
  while (part < 3) {
    if (i >= end || text[i] < '0' || text[i] > '9') return false;
    long n = 0;
    int digits = 0;
    while (i < end && text[i] >= '0' && text[i] <= '9') {
      if (++digits > 9) return false;
      n = n * 10 + (text[i] - '0');
      i++;
    }
    out[part++] = n;
    if (i == end) return part >= 2;
    if (text[i] != '.') return false;
    i++;
  }
  return false;   // a fourth part, or a trailing dot
}

bool versionIsNewer(const std::string& candidate, const std::string& running) {
  long a[3], b[3];
  if (!parseVersion3(candidate, a) || !parseVersion3(running, b)) return false;
  for (int k = 0; k < 3; k++) if (a[k] != b[k]) return a[k] > b[k];
  return false;
}

// ─── Manifest ───────────────────────────────────────────────────────────────

std::string manifestMessage(const std::string& product, const std::string& board,
                            const std::string& version, unsigned long size,
                            const std::string& sha256Hex) {
  char sz[24];
  snprintf(sz, sizeof(sz), "%lu", size);
  std::string hex = sha256Hex;
  for (char& c : hex) if (c >= 'A' && c <= 'F') c = (char)(c - 'A' + 'a');
  return product + "|" + board + "|" + version + "|" + sz + "|" + hex;
}

bool isHex64(const std::string& s) {
  if (s.size() != 64) return false;
  for (char c : s) if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
  return true;
}

bool parseManifest(const std::string& json, OtaManifest& m) {
  std::string size;
  if (!jsonField(json, "product", m.product) || !jsonField(json, "board", m.board) ||
      !jsonField(json, "version", m.version) || !jsonField(json, "size", size) ||
      !jsonField(json, "sha256", m.sha256) || !jsonField(json, "url", m.url) ||
      !jsonField(json, "key_id", m.keyId) || !jsonField(json, "sig", m.sig)) return false;
  if (!jsonField(json, "channel", m.channel)) m.channel = "";
  if (!jsonField(json, "notes", m.notes)) m.notes = "";
  if (size.empty() || size.size() > 9) return false;
  for (char c : size) if (!isdigit((unsigned char)c)) return false;
  m.size = strtoul(size.c_str(), nullptr, 10);
  return true;
}

static const char* keyIds[2]  = {nullptr, nullptr};
static const char* keyPems[2] = {nullptr, nullptr};

void otaSetKeys(const char* idCurrent, const char* pemCurrent, const char* idNext, const char* pemNext) {
  keyIds[0] = idCurrent; keyPems[0] = pemCurrent;
  keyIds[1] = idNext;    keyPems[1] = pemNext;
}

const char* otaPublicKeyFor(const std::string& keyId) {
  for (int i = 0; i < 2; i++)
    if (keyIds[i] && keyPems[i] && keyId == keyIds[i]) return keyPems[i];
  return nullptr;
}

bool verifySignature(const char* publicKeyPem, const std::string& message, const std::string& sigBase64) {
  if (!publicKeyPem || sigBase64.empty() || sigBase64.size() > 200) return false;
  unsigned char der[160];
  size_t derLen = 0;
  if (mbedtls_base64_decode(der, sizeof(der), &derLen,
                            (const unsigned char*)sigBase64.data(), sigBase64.size()) != 0) return false;
  unsigned char hash[32];
  if (mbedtls_sha256((const unsigned char*)message.data(), message.size(), hash, 0) != 0) return false;

  mbedtls_pk_context pk;
  mbedtls_pk_init(&pk);
  bool ok = false;
  if (mbedtls_pk_parse_public_key(&pk, (const unsigned char*)publicKeyPem, strlen(publicKeyPem) + 1) == 0 &&
      mbedtls_pk_can_do(&pk, MBEDTLS_PK_ECKEY)) {
    ok = mbedtls_pk_verify(&pk, MBEDTLS_MD_SHA256, hash, sizeof(hash), der, derLen) == 0;
  }
  mbedtls_pk_free(&pk);
  return ok;
}

std::string otaFailedVersion(const std::string& rememberedBad, const std::string& attemptedTo,
                             const std::string& running) {
  std::string failed = rememberedBad;
  if (!attemptedTo.empty() && attemptedTo != running &&
      (failed.empty() || versionIsNewer(attemptedTo, failed)))
    failed = attemptedTo;
  return failed;
}

bool otaClockValid(long long epoch) { return epoch >= OTA_CLOCK_VALID_FROM; }

bool otaRetryBlocked(const std::string& candidate, const std::string& failed, long long failedAt,
                     long long now, int timerSyncs) {
  long v[3];
  if (failed.empty() || !parseVersion3(failed, v)) return false;
  if (versionIsNewer(candidate, failed)) return false;
  if (otaClockValid(failedAt) && otaClockValid(now) && now >= failedAt)
    return now - failedAt < OTA_RETRY_SECONDS;
  return timerSyncs < 1;
}

bool manifestAcceptable(const OtaManifest& m, const char* product, const char* board,
                        const char* running, unsigned long maxSize, std::string& why,
                        const char* (*keyFor)(const std::string&)) {
  const char* pem = keyFor(m.keyId);
  if (!pem) { why = "unknown key id"; return false; }
  if (!isHex64(m.sha256)) { why = "sha256 is not 64 lower-case hex"; return false; }
  if (!verifySignature(pem, manifestMessage(m.product, m.board, m.version, m.size, m.sha256), m.sig)) {
    why = "bad signature"; return false;
  }
  if (m.product != product) { why = "wrong product"; return false; }
  if (m.board != board) { why = "wrong board"; return false; }
  if (!versionIsNewer(m.version, running)) { why = "not newer"; return false; }
  if (m.size < 1024 || m.size > maxSize) { why = "size doesn't fit"; return false; }
  why = "";
  return true;
}

bool imageHeaderOk(const uint8_t* buf, size_t len, uint16_t chipId) {
  if (len < 16) return false;
  if (buf[0] != 0xE9) return false;
  uint16_t id = (uint16_t)buf[12] | ((uint16_t)buf[13] << 8);
  return id == chipId;
}

std::string hex32(const uint8_t digest[32]) {
  static const char* d = "0123456789abcdef";
  std::string s;
  s.reserve(64);
  for (int i = 0; i < 32; i++) { s += d[digest[i] >> 4]; s += d[digest[i] & 15]; }
  return s;
}

}  // namespace homecore

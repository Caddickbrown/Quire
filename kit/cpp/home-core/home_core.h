#pragma once
// home-core: the parts of pairing and signed OTA that need no hardware, shared by every firmware
// (app-kit docs/DEVICES.md §3). Reading the server's small JSON replies, versions, the signed
// message, the manifest, verifying a signature, the failed-build retry rule, an image header.
// Plain C++17 and mbedTLS only, no Arduino, so each firmware runs it on the Mac against
// vectors/ota.json (test/replay_ota_vectors.h).
//
// Vendored by copy (kit tools/sync_home_core.py), never edited in place: the copy's MANIFEST
// lists every file's hash and check_copy.py fails if one changed. Pala and Glance have it at
// src/home/core/, reRead at lib/HomeCore/.
#include <stddef.h>
#include <stdint.h>
#include <string>

namespace homecore {

// One top-level field of a flat JSON object: a string (unescaped), a number, true/false, or
// null (which reads as not present). Nested objects and arrays are skipped over, never read.
// False when the key isn't there or the text isn't an object.
bool jsonField(const std::string& json, const char* key, std::string& out);

// The version rule (DEVICES.md §3): surrounding spaces, tabs, CR and LF trimmed, an optional
// leading v or V, then MAJOR.MINOR or MAJOR.MINOR.PATCH (patch 0), each part 1 to 9 ASCII
// digits. False for anything else: an unreadable version is never an update.
bool parseVersion3(const std::string& v, long out[3]);
// True only when both parse and candidate is strictly higher.
bool versionIsNewer(const std::string& candidate, const std::string& running);

// The build that last failed its health check (or "" for none), from what the device remembers:
// `rememberedBad` (kept for good), `attemptedTo` (the version an update restarted into; cleared
// once a hello has reported the result) and the version now running. An attempt that isn't
// what's running means the device went back. The newer of the two failures wins.
std::string otaFailedVersion(const std::string& rememberedBad, const std::string& attemptedTo,
                             const std::string& running);
// A clock that has been set (RTC chip or NTP): anything before Nov 2023 hasn't.
constexpr long long OTA_CLOCK_VALID_FROM = 1700000000LL;
bool otaClockValid(long long epoch);
// How long a failed build waits before it's tried again (Dan, 18 Nov 2026: "Retry once a day").
constexpr long long OTA_RETRY_SECONDS = 24LL * 60 * 60;
// True when `candidate` is that failed build or older and it failed less than a day ago: don't
// install it yet. A newer build is tried at once. `failedAt` is the clock when it failed (0 if
// there was no valid clock then), `now` the clock now; without a valid pair (or if the clock went
// backwards) it waits instead until the daily timer has synced once since (`timerSyncs` >= 1).
// A record that doesn't read as a version never blocks an update.
bool otaRetryBlocked(const std::string& candidate, const std::string& failed, long long failedAt,
                     long long now, int timerSyncs);

// What the signature covers: product|board|version|size|sha256, the hash in lower case.
std::string manifestMessage(const std::string& product, const std::string& board,
                            const std::string& version, unsigned long size,
                            const std::string& sha256Hex);

// 64 lower-case hex digits.
bool isHex64(const std::string& s);

struct OtaManifest {
  std::string product, board, version, channel, sha256, url, notes, keyId, sig;
  unsigned long size = 0;
};
// Reads the flat manifest's fields. False if any required one is missing or malformed.
bool parseManifest(const std::string& json, OtaManifest& m);

// The two keys this firmware trusts (the product sets them at start-up).
void otaSetKeys(const char* idCurrent, const char* pemCurrent, const char* idNext, const char* pemNext);
// The public key (PEM) for a key id, or nullptr when the firmware doesn't know it.
const char* otaPublicKeyFor(const std::string& keyId);

// ECDSA P-256 over SHA-256 of `message`, DER signature in standard base64.
bool verifySignature(const char* publicKeyPem, const std::string& message, const std::string& sigBase64);

// Everything short of downloading: signature, product, board, version, size, a 64-hex hash.
// `why` says what was wrong, for the log (and the vectors' "verdict"). Nothing here is secret.
bool manifestAcceptable(const OtaManifest& m, const char* product, const char* board,
                        const char* running, unsigned long maxSize, std::string& why,
                        const char* (*keyFor)(const std::string&) = otaPublicKeyFor);

// The first bytes of an ESP application image: magic 0xE9 and the chip id at offset 12
// (little endian). ESP32-S3 is 0x0009.
bool imageHeaderOk(const uint8_t* buf, size_t len, uint16_t chipId);

// Lower-case hex of 32 bytes.
std::string hex32(const uint8_t digest[32]);

}  // namespace homecore

#pragma once
// Replays vectors/ota.json through home-core: versions, the signed message, signatures with the
// TEST-ONLY key, flat manifests (parseManifest then manifestAcceptable) and the failed-build retry
// rule. Header-only and for host tests only; each firmware's test calls it with the path of its
// copy's vectors/ota.json:
//
//   #include "<home-core>/test/replay_ota_vectors.h"
//   int failed = homecore_test::replayOtaVectors(path, &checks);
//
// Prints one line per failure. The product-specific sections (reread, reread_newer) are left to
// that product's own test; loadJsonFile gives it the same file.
#include <stdio.h>
#include <string>

#include "../home_core.h"
#include "json_value.h"

namespace homecore_test {

namespace detail {
inline std::string& testPem() { static std::string pem; return pem; }
inline std::string& testKeyId() { static std::string id; return id; }
inline const char* testKeyFor(const std::string& id) {
  return id == testKeyId() ? testPem().c_str() : nullptr;
}
}  // namespace detail

inline int replayOtaVectors(const char* path, int* checksOut = nullptr) {
  using namespace homecore;
  Json v;
  if (!loadJsonFile(path, v)) return 1;
  int failures = 0, checks = 0;
  auto check = [&](bool ok, const std::string& what) {
    checks++;
    if (!ok) { failures++; printf("FAIL ota.json %s\n", what.c_str()); }
  };

  for (const Json& c : v["parse"].items) {
    long got[3];
    bool ok = parseVersion3(c["text"].str(), got);
    const Json& want = c["version"];
    if (want.isNull()) check(!ok, "parse " + Json::quote(c["text"].str()) + " should be unreadable");
    else check(ok && got[0] == want.items[0].i64() && got[1] == want.items[1].i64() && got[2] == want.items[2].i64(),
               "parse " + Json::quote(c["text"].str()));
  }
  for (const Json& c : v["newer"].items)
    check(versionIsNewer(c["candidate"].str(), c["current"].str()) == c["newer"].b,
          "newer " + c["candidate"].str() + " than " + c["current"].str());
  for (const Json& c : v["message"].items)
    check(manifestMessage(c["product"].str(), c["board"].str(), c["version"].str(),
                          (unsigned long)c["size"].i64(), c["sha256"].str()) == c["bytes"].str(),
          "message " + c["bytes"].str());

  const Json& key = v["test_key"];
  detail::testPem() = key["public_pem"].str();
  detail::testKeyId() = key["key_id"].str();
  check(detail::testKeyId().rfind("test-only-", 0) == 0, "the test key's id starts test-only-");
  for (const Json& c : v["verify"].items)
    check(verifySignature(detail::testPem().c_str(), c["message"].str(), c["sig"].str()) == c["ok"].b,
          "verify: " + c["why"].str());

  // Pala's flat manifests, and the Sticky's (the same fields beside Narrowcast's GitHub-shaped ones).
  for (const char* section : {"manifests", "reread_flat"}) {
  const Json& running = v[section]["running"];
  for (const Json& c : v[section]["cases"].items) {
    OtaManifest m;
    std::string verdict;
    if (!parseManifest(c["manifest"].dump(), m)) {
      verdict = "unreadable";
    } else {
      std::string why;
      bool ok = manifestAcceptable(m, running["product"].str().c_str(), running["board"].str().c_str(),
                                   running["version"].str().c_str(), (unsigned long)running["max_size"].i64(), why,
                                   detail::testKeyFor);
      verdict = ok ? "ok" : why;
    }
    check(verdict == c["verdict"].str(), std::string(section) + " " + c["name"].str() + ": got " + verdict);
  }
  }

  const Json& retry = v["retry"];
  check(retry["retry_seconds"].i64() == OTA_RETRY_SECONDS, "retry_seconds");
  check(retry["clock_valid_from"].i64() == OTA_CLOCK_VALID_FROM, "clock_valid_from");
  for (const Json& c : retry["failed_version"].items)
    check(otaFailedVersion(c["remembered_bad"].str(), c["attempted_to"].str(), c["running"].str()) ==
              c["failed"].str(),
          "failed_version: " + c["why"].str());
  for (const Json& c : retry["blocked"].items)
    check(otaRetryBlocked(c["candidate"].str(), c["failed"].str(), c["failed_at"].i64(), c["now"].i64(),
                          (int)c["timer_syncs"].i64()) == c["blocked"].b,
          "blocked " + c.dump());
  for (const Json& c : retry["clock_valid"].items)
    check(otaClockValid(c["epoch"].i64()) == c["valid"].b, "clock_valid " + c["epoch"].text);

  if (checksOut) *checksOut += checks;
  printf("ota.json: %d checks, %d failed\n", checks, failures);
  return failures;
}

}  // namespace homecore_test

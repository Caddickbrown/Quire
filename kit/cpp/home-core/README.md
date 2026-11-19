# home-core

The pure C++ every Dan firmware shares for pairing replies and signed OTA (`docs/DEVICES.md`
section 3): the flat JSON field reader, the version rule, the signed message, the flat manifest,
ECDSA P-256 verification (mbedTLS), the failed-build retry rule (Pala 2.6.3), the ESP image
header check and `hex32`. Namespace `homecore`. No Arduino, so every firmware tests it on the Mac.

| File | What |
|---|---|
| `home_core.h`, `home_core.cpp` | The code. C++17 and mbedTLS 3 only |
| `test/replay_ota_vectors.h` | Replays `vectors/ota.json` through it; a firmware's host test calls `homecore_test::replayOtaVectors(path)` |
| `test/json_value.h` | The small JSON reader the replay uses (header-only, never in a firmware build) |
| `check_copy.py` | In a copy: fails if any file differs from the copy's `MANIFEST` |
| `library.json` | PlatformIO builds only `home_core.cpp` |

## Using it

It is copied, never a submodule or a registry package, so an upstream merge never pulls it and a
build needs no network:

    python3 <app-kit>/sample/kit/tools/sync_home_core.py --into src/home/core     # Pala, Glance
    python3 <app-kit>/sample/kit/tools/sync_home_core.py --into lib/HomeCore      # reRead

The copy also gets `vectors/ota.json` (the kit's), `HOME_CORE_VERSION` (the kit's version: home-core is
versioned with the kit) and `MANIFEST`. (Not `VERSION`: on a case-insensitive disk a file of that name in an include path
shadows the C++ `<version>` header.) Run `python3 <copy>/check_copy.py` in the firmware's host
tests. Never edit a copy: change it here, run `python3 -m unittest discover -s kit/tests`, bump the
kit, and copy again.

The product supplies its two public keys with `homecore::otaSetKeys` at start-up. The vectors'
key (`test-only-a`) is TEST ONLY and no firmware may build it in.

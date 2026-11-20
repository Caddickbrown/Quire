#!/usr/bin/env bash
# latest.json for the AppImage updater, written into DIST, and the release
# notes moved out of it (to DIST/../notes.md) so they aren't uploaded:
#
#   tools/latest_json.sh DIST OWNER/REPO TAG VERSION
#
# The AppImages' download addresses name OWNER/REPO, the repository the
# release is published to, so each copy of a release points at its own files.
# With no signed AppImage in DIST there is no latest.json.
set -euo pipefail
dist=$1 repo=$2 tag=$3 version=$4
cd "$dist"
platforms='{}'
# Tauri names them Quire_<version>_amd64.AppImage / _aarch64.AppImage.
for pair in x86_64:amd64 aarch64:aarch64; do
  arch=${pair%%:*}
  img=$(ls ./*_"${pair#*:}".AppImage 2>/dev/null | head -1) || true; img=${img#./}
  [ -n "$img" ] && [ -f "$img.sig" ] || continue
  platforms=$(jq --arg k "linux-$arch" --arg sig "$(cat "$img.sig")" \
    --arg url "https://github.com/$repo/releases/download/$tag/$img" \
    '. + {($k): {signature: $sig, url: $url}}' <<<"$platforms")
done
if [ "$platforms" != '{}' ]; then
  jq -n --arg v "$version" --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg n "See https://github.com/$repo/releases/tag/$tag" --argjson p "$platforms" \
    '{version: $v, notes: $n, pub_date: $d, platforms: $p}' > latest.json
  cat latest.json
fi
[ ! -f notes.md ] || mv notes.md ../notes.md
ls -l

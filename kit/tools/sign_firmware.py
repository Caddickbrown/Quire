#!/usr/bin/env python3
"""Sign a firmware image for OTA, on Dan's Mac: one signer for every product (DEVICES.md §3).

    python3 sign_firmware.py --product pala   app.bin --version 2.6.4 [--channel canary] [--notes "..."]
    python3 sign_firmware.py --product reread firmware.bin --version 2.3.9 [--board sticky]
    options: --key-id <product>-a|<product>-b   --out FILE   --url URL

Writes the flat manifest (JSON):
    {"product", "board", "version", "channel", "size", "sha256", "url", "notes", "key_id", "sig"}
The signature is ECDSA P-256 over SHA-256 of "product|board|version|size|sha256" (home-core's
manifestMessage), DER, standard base64, made with ~/.config/<product>-signing/<key-id>.pem (or
$<PRODUCT>_SIGNING_DIR). The private key never leaves this Mac; only the manifest and the image go
to the Pi. Pala's server serves the file as it is; Narrowcast copies it into /api/ota/manifest
beside the GitHub-shaped fields older Stickies read (it is also the Sticky's signature.json).

Before writing anything it checks its own work: the image is an ESP application image for the
product's chip (and, for reRead, carries exactly one board tag naming --board), it fits the
product's update slot, the version is MAJOR.MINOR.PATCH, and the signature verifies against the
public key.

Product wrappers: Pala tools/release.py, reRead tools/ota-signing/sign_ota.py. This file travels
in every firmware's home-core copy (tools/sign_firmware.py), so each repo signs with the same code.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

VERSION_RE = re.compile(r"^\d{1,9}\.\d{1,9}\.\d{1,9}$")
BOARD_TAG_RE = re.compile(rb"CROSSPOINT-BOARD-V1:([A-Za-z0-9_.-]{1,23});")
S3_CHIP = 0x0009

# What each product's devices check, so a signed image can never be one they would refuse.
PRODUCTS = {
    "pala": {"board": "pala-s3", "boards": ("pala-s3",), "chip": S3_CHIP, "slot": 0x330000, "board_tag": False},
    "reread": {"board": "sticky", "boards": None, "chip": None, "slot": 0x640000, "board_tag": True},
}


def keys_dir(product):
    env = os.environ.get(f"{product.upper()}_SIGNING_DIR")
    return Path(env) if env else Path.home() / ".config" / f"{product}-signing"


def message(product, board, version, size, sha256):
    return f"{product}|{board}|{version}|{size}|{sha256.lower()}".encode()


def _openssl(*args):
    return subprocess.run(["openssl", *args], check=True, capture_output=True).stdout


def sign(msg, key):
    with tempfile.TemporaryDirectory() as tmp:
        m = Path(tmp) / "msg"
        m.write_bytes(msg)
        return base64.b64encode(_openssl("dgst", "-sha256", "-sign", str(key), str(m))).decode()


def verify(msg, sig_b64, pub):
    with tempfile.TemporaryDirectory() as tmp:
        m, s = Path(tmp) / "msg", Path(tmp) / "sig"
        m.write_bytes(msg)
        s.write_bytes(base64.b64decode(sig_b64))
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(pub), "-signature", str(s), str(m)],
                           capture_output=True)
    return r.returncode == 0


def public_key(key):
    pub = key.with_name(key.name[: -len(".pem")] + ".pub.pem")
    if not pub.exists():
        subprocess.run(["openssl", "ec", "-in", str(key), "-pubout", "-out", str(pub)], check=True,
                       capture_output=True)
    return pub


def image_board(data):
    found = BOARD_TAG_RE.findall(data)
    return found[0].decode() if len(found) == 1 else None


def check_image(product, data, board):
    p = PRODUCTS[product]
    if len(data) < 1024 or data[0] != 0xE9:
        raise SystemExit("not an ESP application image (no 0xE9 magic byte)")
    if p["chip"] is not None and int.from_bytes(data[12:14], "little") != p["chip"]:
        raise SystemExit("not an image for this product's chip (ESP32-S3)")
    if len(data) > p["slot"]:
        raise SystemExit(f"{len(data)} bytes doesn't fit the {p['slot']}-byte update slot")
    if p["boards"] is not None and board not in p["boards"]:
        raise SystemExit(f"{product} has no board {board!r}")
    if p["board_tag"]:
        tagged = image_board(data)
        if tagged != board:
            raise SystemExit(f"the image's board tag says {tagged!r}, not {board!r}")


def sign_image(product, bin_path, version, board=None, channel="stable", notes="", url="", key_id=None,
               keys=None):
    """The flat manifest for one image, signed. Raises SystemExit (nothing written) on any problem."""
    if product not in PRODUCTS:
        raise SystemExit(f"unknown product {product!r} (one of {', '.join(sorted(PRODUCTS))})")
    if not VERSION_RE.match(version):
        raise SystemExit(f"version {version!r} is not MAJOR.MINOR.PATCH")
    board = board or PRODUCTS[product]["board"]
    key_id = key_id or f"{product}-a"
    if key_id not in (f"{product}-a", f"{product}-b"):
        raise SystemExit(f"key id {key_id!r} isn't one of {product}'s ({product}-a, {product}-b)")
    data = Path(bin_path).read_bytes()
    check_image(product, data, board)
    key = Path(keys or keys_dir(product)) / f"{key_id}.pem"
    if not key.exists():
        raise SystemExit(f"no signing key at {key} (make_signing_keys.sh --product {product} makes one)")
    digest = hashlib.sha256(data).hexdigest()
    msg = message(product, board, version, len(data), digest)
    sig = sign(msg, key)
    if not verify(msg, sig, public_key(key)):
        raise SystemExit("the signature didn't verify against its own public key; nothing written")
    return {"product": product, "board": board, "version": version, "channel": channel, "size": len(data),
            "sha256": digest, "url": url, "notes": notes, "key_id": key_id, "sig": sig}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("bin")
    ap.add_argument("--product", required=True, choices=sorted(PRODUCTS))
    ap.add_argument("--version", required=True)
    ap.add_argument("--board")
    ap.add_argument("--channel", default="stable")
    ap.add_argument("--notes", default="")
    ap.add_argument("--url", default="")
    ap.add_argument("--key-id")
    ap.add_argument("--out", help="default: <bin without .bin>.json")
    a = ap.parse_args(argv)
    m = sign_image(a.product, a.bin, a.version, a.board, a.channel, a.notes, a.url, a.key_id)
    out = Path(a.out) if a.out else Path(a.bin).with_suffix(".json")
    out.write_text(json.dumps(m, indent=1) + "\n")
    print(f"signed {a.bin}: {m['product']} {m['board']} {m['version']} {m['size']} bytes, key {m['key_id']}")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

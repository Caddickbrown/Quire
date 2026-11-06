#!/usr/bin/env python3
"""Fetch the faces the themes need.

Two formats, because the two runtimes disagree: CoreText (macOS/iOS) reads TTF
and cannot read woff2; the webview wants woff2 and would pay for TTF. Latin
subset only. Run from the repo root: python3 tools/fetch-fonts.py
"""
import re, subprocess, sys, pathlib

MODERN = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36")
LEGACY = "Mozilla/5.0"

# family -> the css2 query for the weights a theme actually uses
FAMILIES = {
    "Newsreader": "Newsreader:ital,opsz,wght@0,6..72,300..600;1,6..72,300..600",
    "IBM Plex Sans": "IBM+Plex+Sans:wght@300;400;500;600",
    "IBM Plex Mono": "IBM+Plex+Mono:wght@400;500",
    "Karla": "Karla:wght@300;400;500",
    "Nunito Sans": "Nunito+Sans:opsz,wght@6..12,300;6..12,400;6..12,600",
    "EB Garamond": "EB+Garamond:ital,wght@0,400;0,600;1,400",
    "Cormorant Garamond": "Cormorant+Garamond:ital,wght@0,300;0,500;1,300",
    "Playfair Display": "Playfair+Display:wght@500;700;900",
    "Libre Baskerville": "Libre+Baskerville:ital,wght@0,400;0,700;1,400",
    "Oswald": "Oswald:wght@300;500;700",
    "Barlow": "Barlow:wght@300;400;600",
    "Archivo": "Archivo:wght@400;600;800",
    "Archivo Black": "Archivo+Black",
    "Courier Prime": "Courier+Prime:ital,wght@0,400;0,700;1,400",
    "Anton": "Anton",
    "Spectral": "Spectral:ital,wght@0,300;0,600;1,300",
    "Poppins": "Poppins:wght@400;600;800",
}

def fetch(url, ua):
    return subprocess.run(["curl", "-sL", "-A", ua, url], capture_output=True).stdout.decode("utf8", "replace")

def download(url, dest):
    subprocess.run(["curl", "-sL", "-A", MODERN, url, "-o", str(dest)], check=True)

def slug(name):
    return name.replace(" ", "")

def main():
    root = pathlib.Path(".")
    ttf_dir = root / "Resources" / "Fonts"
    woff_dir = root / "tauri" / "src" / "fonts"
    faces = []

    for family, query in FAMILIES.items():
        # woff2, latin subset, for the webview
        css = fetch(f"https://fonts.googleapis.com/css2?family={query}&display=swap", MODERN)
        n = 0
        for block in re.findall(r"@font-face \{.*?\}", css, re.S):
            if "U+0000-00FF" not in block:
                continue
            url = re.search(r"url\((https://[^)]+\.woff2)\)", block)
            if not url:
                continue
            style = "italic" if "font-style: italic" in block else "normal"
            weight = re.search(r"font-weight: ([^;]+);", block).group(1).strip().replace(" ", "-")
            name = f"{slug(family)}-{style}-{weight}.woff2"
            download(url.group(1), woff_dir / name)
            faces.append((family, style, weight, name))
            n += 1

        # ttf for CoreText
        css = fetch(f"https://fonts.googleapis.com/css2?family={query}&display=swap", LEGACY)
        urls = []
        for block in re.findall(r"@font-face \{.*?\}", css, re.S):
            url = re.search(r"url\((https://[^)]+\.ttf)\)", block)
            if url and url.group(1) not in urls:
                urls.append(url.group(1))
        for i, url in enumerate(urls):
            download(url, ttf_dir / f"{slug(family)}-{i}.ttf")
        print(f"{family}: {n} woff2, {len(urls)} ttf", flush=True)

    css_out = ["/* Bundled so every theme looks the same on a machine that has none of",
               "   these installed. All SIL Open Font Licence 1.1 — see OFL.txt. */", ""]
    for family, style, weight, name in faces:
        css_out.append("@font-face {")
        css_out.append(f"  font-family: '{family}';")
        css_out.append(f"  font-style: {style};")
        css_out.append(f"  font-weight: {weight.replace('-', ' ')};")
        css_out.append("  font-display: swap;")
        css_out.append(f"  src: url(./{name}) format('woff2');")
        css_out.append("}")
        css_out.append("")
    (woff_dir / "fonts.css").write_text("\n".join(css_out))
    print("wrote", woff_dir / "fonts.css")

main()

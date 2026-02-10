#!/usr/bin/env python3
"""Manual TS6 addon installer - no GUI required.
Replicates what TS6AddonInstaller does: patches the binary and injects the addon."""

import json
import hashlib
import shutil
import sys
import uuid
import base64
from pathlib import Path

import argparse

parser = argparse.ArgumentParser(description="313 Soundboard - TS6 Addon Installer")
parser.add_argument("addon_dir", nargs="?", default="myinstants-soundboard", help="Path to addon directory")
parser.add_argument("--ts-dir", default="/opt/teamspeak", help="Path to TeamSpeak 6 installation")
parser.add_argument("--patches", default="/tmp/patches.json", help="Path to patches.json")
_args = parser.parse_args()

TS6_DIR = Path(_args.ts_dir)
ADDON_DIR = Path(_args.addon_dir)
PATCHES_FILE = Path(_args.patches)
INDEX_PATH = TS6_DIR / "html" / "client_ui" / "index.html"
BINARY_PATH = TS6_DIR / "TeamSpeak"


def md5sum(filepath):
    h = hashlib.md5()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def apply_binary_patches():
    """Patch the TeamSpeak binary to bypass file/domain validation."""
    with open(PATCHES_FILE) as f:
        all_patches = json.load(f)

    binary_md5 = md5sum(BINARY_PATH)
    print(f"  Binary MD5: {binary_md5}")

    # Try each version's patches, matching by actual bytes at offsets (not just MD5)
    for version, platforms in all_patches.items():
        linux_patches = platforms.get("linux", {})
        for filename, file_patch in linux_patches.items():
            patched_md5 = file_patch["patched"]

            if binary_md5 == patched_md5:
                print(f"  Already patched for {version}")
                return True

            # Check if bytes at offsets match vanilla (works even if overall MD5 differs)
            all_match = True
            all_already_patched = True
            with open(BINARY_PATH, "rb") as f:
                for patch in file_patch["patches"]:
                    offset = int(patch["offset"], 16)
                    vanilla_bytes = bytes(int(b, 16) for b in patch["vanilla"].split())
                    patched_bytes = bytes(int(b, 16) for b in patch["patched"].split())
                    f.seek(offset)
                    current = f.read(len(vanilla_bytes))
                    if current == vanilla_bytes:
                        all_already_patched = False
                    elif current == patched_bytes:
                        pass
                    else:
                        all_match = False
                        break

            if all_already_patched and all_match:
                print(f"  All offsets already patched for {version}")
                return True

            if not all_match:
                continue

            print(f"  Bytes match {version}, applying patches...")
            backup = Path(str(BINARY_PATH) + ".bak")
            if not backup.exists():
                shutil.copy2(BINARY_PATH, backup)
                print(f"  Backup saved to {backup}")

            with open(BINARY_PATH, "r+b") as f:
                for patch in file_patch["patches"]:
                    offset = int(patch["offset"], 16)
                    vanilla_bytes = bytes(int(b, 16) for b in patch["vanilla"].split())
                    patched_bytes = bytes(int(b, 16) for b in patch["patched"].split())

                    f.seek(offset)
                    current = f.read(len(vanilla_bytes))

                    if current == vanilla_bytes:
                        f.seek(offset)
                        f.write(patched_bytes)
                        print(f"    Patched offset 0x{patch['offset']}")
                    elif current == patched_bytes:
                        print(f"    Offset 0x{patch['offset']} already patched")

            print("  Binary patched successfully")
            return True

    print(f"  No matching patches for this binary version")
    return False


def inject_addon():
    """Inline the addon JS/CSS and inject into index.html."""
    addon_json_path = ADDON_DIR / "addon.json"
    with open(addon_json_path) as f:
        addon = json.load(f)

    addon_id = addon["id"]
    addon_name = addon["name"]
    addon_version = addon["version"]
    sources_dir = ADDON_DIR / addon.get("sources", "src/")
    inject_file = ADDON_DIR / addon["inject"]
    if not inject_file.exists():
        inject_file = sources_dir / addon["inject"]
    injection_point = addon.get("injection_point", "HEAD").upper()
    inject_at = addon.get("inject_at", "TAIL").upper()

    # Read the inject file (index.html of the addon)
    with open(inject_file) as f:
        inject_content = f.read()

    # Inline external references
    import re

    def inline_css(match):
        href = match.group(1)
        css_path = sources_dir / Path(href).name if not href.startswith("http") else None
        if css_path and css_path.exists():
            with open(css_path) as f:
                return "<style>" + f.read() + "</style>"
        return match.group(0)

    def inline_js(match):
        src = match.group(1)
        js_path = sources_dir / Path(src).name if not src.startswith("http") else None
        if js_path and js_path.exists():
            with open(js_path) as f:
                return "<script>" + f.read() + "</script>"
        return match.group(0)

    inject_content = re.sub(r'<link\s+rel="stylesheet"\s+href="([^"]+)"\s*/?>', inline_css, inject_content)
    inject_content = re.sub(r'<script\s+src="([^"]+)"\s*>\s*</script>', inline_js, inject_content)

    # Wrap with addon markers
    install_id = uuid.uuid4()
    name_b64 = base64.b64encode(addon_name.encode()).decode()
    start_marker = f'<!-- ADDON_START v2 {addon_id} {addon_version} "{name_b64}" {install_id} -->'
    end_marker = f"<!-- ADDON_END {install_id} -->"
    wrapped = start_marker + inject_content + end_marker

    # Read current index.html
    with open(INDEX_PATH) as f:
        index = f.read()

    # Remove existing addon with same ID
    existing_pattern = re.compile(
        r'<!-- ADDON_START v\d+ ' + re.escape(addon_id) + r' .*?<!-- ADDON_END[^>]*-->',
        re.DOTALL
    )
    index = existing_pattern.sub("", index)

    # Inject at the right position
    if injection_point == "BODY":
        if inject_at == "TAIL":
            index = index.replace("</body>", wrapped + "</body>")
        else:
            index = index.replace("<body>", "<body>" + wrapped)
    else:  # HEAD
        if inject_at == "TAIL":
            index = index.replace("</head>", wrapped + "</head>")
        else:
            index = index.replace("<head>", "<head>" + wrapped)

    # Write back
    with open(INDEX_PATH, "w") as f:
        f.write(index)

    print(f"  Addon '{addon_name}' injected into index.html")
    return True


def main():
    print(f"Addon: {ADDON_DIR}")
    print(f"TS6 dir: {TS6_DIR}")
    print()

    print("[1/2] Patching binary...")
    if not apply_binary_patches():
        print("Binary patching failed or unsupported version. Continuing anyway...")
    print()

    print("[2/2] Injecting addon...")
    if inject_addon():
        print()
        print("Done! Restart TeamSpeak to load the addon.")
    else:
        print("Injection failed.")
        sys.exit(1)


if __name__ == "__main__":
    main()

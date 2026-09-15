#!/usr/bin/env python
"""Vendor the Tracy client sources used by the feng_godottracy engine module.

Only the client is installed: `public/` holds TracyClient.cpp and every header
it includes. The profiler GUI is a separate download from the Tracy releases
page. Install once, then build the engine with module_feng_godottracy_enabled=yes.
"""

import argparse
import shutil
import sys
import tempfile
import urllib.request
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
DESTINATION = ROOT / "thirdparty" / "tracy"
DEFAULT_VERSION = "v0.11.1"

# Copied from the upstream tag, everything else is left behind. Only these are
# replaced, so notes kept next to the vendored sources survive an update.
MANAGED = ("public", "LICENSE")
VERSION_FILE = "VERSION.txt"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=DEFAULT_VERSION, help=f"Tracy tag to install (default: {DEFAULT_VERSION}).")
    parser.add_argument("--force", action="store_true", help="Replace an existing installation.")
    args = parser.parse_args()

    if DESTINATION.exists() and not args.force:
        print(f"{DESTINATION.relative_to(ROOT)} already exists. Pass --force to replace it.")
        return 0

    archive = Path(tempfile.gettempdir()) / f"tracy-{args.version}.zip"
    url = f"https://github.com/wolfpld/tracy/archive/refs/tags/{args.version}.zip"
    print(f"Downloading Tracy {args.version} ...")
    urllib.request.urlretrieve(url, str(archive))

    staging = Path(tempfile.mkdtemp(prefix="tracy-install-", dir=tempfile.gettempdir()))
    try:
        with ZipFile(archive) as zip_file:
            zip_file.extractall(staging)
        extracted = [entry for entry in staging.iterdir() if entry.is_dir()]
        if len(extracted) != 1:
            print(f"ERROR: unexpected archive layout in {url}.")
            return 1
        source = extracted[0]
        for name in MANAGED:
            if not (source / name).exists():
                print(f"ERROR: {name} is missing from {url}.")
                return 1
        DESTINATION.mkdir(parents=True, exist_ok=True)
        for name in MANAGED:
            target = DESTINATION / name
            if target.is_dir():
                shutil.rmtree(target)
            elif target.exists():
                target.unlink()
            if (source / name).is_dir():
                shutil.copytree(source / name, target)
            else:
                shutil.copyfile(source / name, target)
        (DESTINATION / VERSION_FILE).write_text(f"{args.version}\n", encoding="utf-8")
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        archive.unlink(missing_ok=True)

    print(f"Installed Tracy {args.version} into {DESTINATION.relative_to(ROOT)}.")
    print("Build the editor with module_feng_godottracy_enabled=yes to use it.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

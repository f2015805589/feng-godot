"""Install a pinned official LibNTC SDK locally, without changing the engine or system.

Only the runtime DLL is installed in bin; SDK tools are not redistributed with games.
Downloads and headers stay in .sdk (ignored by Godot and Git).
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import time
import urllib.request
import zipfile

VERSION = "v0.10.0-beta"
LIB_COMMIT = "35ec039503ef5e151c661beccc82390948dd5218"
ARCHIVE = "RTXNTC_windows_x64_v0.10.0b.zip"
SIZE = 186882745
SHA256 = "2d349fae349a14d0f35e856963f2c53d1cbbc4bb5fb1fe129ea6159c93d9e39d"
URL = f"https://github.com/NVIDIA-RTX/RTXNTC/releases/download/{VERSION}/{ARCHIVE}"
ROOT = Path(__file__).resolve().parents[1]


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "feng-ntc-setup/0.1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def download(path):
    offset = path.stat().st_size if path.exists() else 0
    if offset > SIZE:
        raise RuntimeError("Archive is larger than the pinned release; supply a clean --archive path")
    if offset == SIZE:
        return
    chunk_size = 4 * 1024 * 1024
    chunks = [(start, min(start + chunk_size, SIZE)) for start in range(offset, SIZE, chunk_size)]
    parts = ROOT / ".sdk" / "download-parts"
    parts.mkdir(exist_ok=True)

    def get_chunk(bounds):
        start, end = bounds
        part = parts / f"{start}-{end}.part"
        if part.exists() and part.stat().st_size == end - start:
            return part
        for retry in range(4):
            try:
                request = urllib.request.Request(URL, headers={"Range": f"bytes={start}-{end - 1}",
                                                            "User-Agent": "feng-ntc-setup/0.1"})
                with urllib.request.urlopen(request, timeout=90) as response:
                    if response.status != 206 or not response.headers.get("Content-Range", "").startswith(f"bytes {start}-"):
                        raise RuntimeError("Download server did not honor byte range")
                    with part.open("wb") as output:
                        shutil.copyfileobj(response, output)
                if part.stat().st_size != end - start:
                    raise RuntimeError("Incomplete download chunk")
                print(f"Downloaded chunk {start // chunk_size + 1}", flush=True)
                return part
            except Exception:
                if retry == 3:
                    raise
                time.sleep(1 + retry)

    with ThreadPoolExecutor(max_workers=8) as pool:
        chunk_paths = list(pool.map(get_chunk, chunks))
    with path.open("ab") as output:
        for part in chunk_paths:
            with part.open("rb") as source:
                shutil.copyfileobj(source, output)
    for part in chunk_paths:
        part.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Reuse or resume an official release ZIP")
    parser.add_argument("--headers-only", action="store_true")
    args = parser.parse_args()
    sdk = ROOT / ".sdk"
    sdk.mkdir(exist_ok=True)
    (sdk / ".gdignore").touch()
    for name in ("ntc.h", "wrappers.h", "shaders/InferenceConstants.h"):
        target = sdk / "include" / "libntc" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(fetch(f"https://raw.githubusercontent.com/NVIDIA-RTX/RTXNTC-Library/{LIB_COMMIT}/include/libntc/{name}"))
    licenses = ROOT / "LICENSES"
    licenses.mkdir(exist_ok=True)
    for name in ("LICENSE.txt", "ThirdPartyLicenses.txt"):
        (licenses / ("NVIDIA-" + name)).write_bytes(fetch(
            f"https://raw.githubusercontent.com/NVIDIA-RTX/RTXNTC-Library/{LIB_COMMIT}/{name}"))
    if args.headers_only:
        print("Pinned headers and licenses installed")
        return
    archive = args.archive.resolve() if args.archive else sdk / ARCHIVE
    archive.parent.mkdir(parents=True, exist_ok=True)
    download(archive)
    with archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != SHA256:
        raise RuntimeError("SDK SHA-256 mismatch; nothing was installed")
    binary = ROOT / "bin"
    binary.mkdir(exist_ok=True)
    with zipfile.ZipFile(archive) as package:
        entries = [entry for entry in package.infolist()
                   if PurePosixPath(entry.filename).name.lower() in ("ntc.dll", "libntc.dll")]
        if len(entries) != 1:
            raise RuntimeError(f"Expected one LibNTC runtime DLL, found {len(entries)}")
        (binary / "ntc.dll").write_bytes(package.read(entries[0]))
    print(f"Installed {VERSION} runtime in {binary}; no engine changes")


if __name__ == "__main__":
    main()

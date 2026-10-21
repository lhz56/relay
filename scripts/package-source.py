#!/usr/bin/env python3
"""Allowlisted source packaging. Never reads Keychain, app data, build output or history."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import plistlib
import re
import tarfile

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    "Package.swift", "Info.plist", "entitlements.plist", "build.command", ".gitignore",
    "README.md", "SECURITY.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md",
    "RELEASE_CHECKLIST.md", "HANDOFF.md", "TESTING.md", "scripts/check.sh", "scripts/package-source.py",
    ".github/workflows/check.yml",
]
# Intentionally narrow: untracked files in source folders are not swept into a release.
FILES += [str(p.relative_to(ROOT)) for base in ("Sources", "Tests") for p in (ROOT / base).rglob("*.swift")]
FILES += [name for name in ("LICENSE", "LICENSE.proposed") if (ROOT / name).is_file()]
SECRET_PATTERNS = [
    rb"AKIA[0-9A-Z]{16}", rb"gh[pousr]_[A-Za-z0-9]{30,}",
    rb"sk-[A-Za-z0-9_-]{24,}", rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    rb"/Users/[a-zA-Z0-9_.-]+/", rb"/home/[a-zA-Z0-9_.-]+/",
]

def collect():
    result = []
    for name in sorted(set(FILES)):
        path = ROOT / name
        if not path.is_file() or path.is_symlink():
            raise SystemExit(f"Missing or symlinked release input: {name}")
        if not path.resolve().is_relative_to(ROOT):
            raise SystemExit(f"Input escapes source root: {name}")
        data = path.read_bytes()
        if any(re.search(pattern, data) for pattern in SECRET_PATTERNS):
            raise SystemExit(f"Potential credential or personal path in {name}; inspect locally. Value withheld.")
        if len(data) > 1_000_000:
            raise SystemExit(f"Unexpectedly large source input: {name}")
        result.append((name, data))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    inputs = collect()
    print(f"Source audit passed: {len(inputs)} allowlisted text files; no binaries, recordings or app state included.")
    if not (ROOT / "LICENSE").exists():
        print("LICENSE STATUS: source preview only; the proposed license and copyright holder are not confirmed.")
    if args.check:
        return
    version = plistlib.loads((ROOT / "Info.plist").read_bytes())["CFBundleShortVersionString"]
    output = args.output or ROOT / "dist" / f"relay-{version}-source.tar.gz"
    output.parent.mkdir(parents=True, exist_ok=True)
    # Stable ordering, timestamps, ownership, modes and gzip header; no absolute paths.
    with output.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, data in inputs:
                entry = tarfile.TarInfo(f"relay-{version}/{name}")
                entry.size = len(data); entry.mtime = 0; entry.uid = 0; entry.gid = 0
                entry.mode = 0o755 if name.endswith((".sh", ".command", ".py")) else 0o644
                archive.addfile(entry, io.BytesIO(data))
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_name(output.name + ".sha256").write_text(f"{digest}  {output.name}\n")
    print(f"Created {output.name} ({output.stat().st_size} bytes), SHA-256 {digest}")
    print("This audit checks common credential patterns and personal paths; it does not prove that arbitrary content is non-sensitive.")

if __name__ == "__main__":
    main()

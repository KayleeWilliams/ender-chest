#!/usr/bin/env python3
"""Validate native artifacts and assemble the curl and npm release files."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import re
import shutil
import tarfile

ROOT = Path(__file__).resolve().parent.parent
TARGETS = {
    "ec-aarch64-macos": ("aarch64-macos", bytes.fromhex("cffaedfe0c000001")),
    "ec-x86_64-macos": ("x86_64-macos", bytes.fromhex("cffaedfe07000001")),
    "ec-aarch64-linux": ("aarch64-linux", 183),
    "ec-x86_64-linux": ("x86_64-linux", 62),
}


def checksum(data):
    return hashlib.sha256(data).hexdigest()


def native_matches(data, expected):
    if isinstance(expected, bytes):
        return data.startswith(expected)
    return (
        len(data) >= 20
        and data[:6] == b"\x7fELF\x02\x01"
        and int.from_bytes(data[18:20], "little") == expected
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--source-hash", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", args.version):
        parser.error("version must be a stable X.Y.Z release")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("commit must be a full Git commit hash")
    if not re.fullmatch(r"[0-9a-f]{64}", args.source_hash):
        parser.error("source-hash must be a SHA-256 hash")
    if args.output.exists():
        parser.error("output directory already exists")

    binaries = {}
    assets = {}
    for name, (key, native) in TARGETS.items():
        matches = [p for p in args.artifacts.rglob(name) if p.is_file()]
        if len(matches) != 1:
            parser.error(f"expected one {name}, found {len(matches)}")
        binary = matches[0]
        data = binary.read_bytes()
        digest = checksum(data)
        expected = binary.with_name(name + ".sha256").read_text().strip()
        if digest != expected:
            parser.error(f"checksum mismatch for {name}")
        if binary.with_name("source_hash.txt").read_text().strip() != args.source_hash:
            parser.error(f"source hash mismatch for {name}")
        if not native_matches(data, native):
            parser.error(f"wrong native target for {name}")
        binaries[name] = data
        assets[key] = {"name": name, "sha256": digest}

    source_package = json.loads((ROOT / "packages/ec/package.json").read_text())
    package = {
        key: source_package[key]
        for key in ("name", "description", "license", "repository", "type")
    }
    package.update({
        "version": args.version,
        "bin": {"ec": "bin/ec.mjs"},
        "engines": {"node": ">=20"},
        "os": ["darwin", "linux"],
        "cpu": ["arm64", "x64"],
        "files": ["bin", "native", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.txt"],
    })
    args.output.mkdir(parents=True)
    for name, data in binaries.items():
        dest = args.output / name
        dest.write_bytes(data)
        dest.chmod(0o755)
        dest.with_name(name + ".sha256").write_text(checksum(data) + "\n")
    shutil.copyfile(ROOT / "install.sh", args.output / "install.sh")
    (args.output / "install.sh.sha256").write_text(checksum((ROOT / "install.sh").read_bytes()) + "\n")
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.txt"):
        shutil.copyfile(ROOT / name, args.output / name)

    entries = {
        "package.json": (json.dumps(package, indent=2).encode() + b"\n", 0o644),
        "README.md": ((ROOT / "packages/ec/npm/README.md").read_bytes(), 0o644),
        "LICENSE": ((ROOT / "LICENSE").read_bytes(), 0o644),
        "THIRD_PARTY_NOTICES.txt": ((ROOT / "THIRD_PARTY_NOTICES.txt").read_bytes(), 0o644),
        "bin/ec.mjs": ((ROOT / "packages/ec/npm/ec.mjs").read_bytes(), 0o755),
    }
    entries.update({f"native/{name}": (data, 0o755) for name, data in binaries.items()})
    tarball = args.output / f"ender-chest-{args.version}.tgz"
    with tarball.open("wb") as output:
        with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w") as archive:
                for name, (data, mode) in sorted(entries.items()):
                    entry = tarfile.TarInfo(f"package/{name}")
                    entry.size = len(data)
                    entry.mode = mode
                    archive.addfile(entry, io.BytesIO(data))
    tarball.with_name(tarball.name + ".sha256").write_text(checksum(tarball.read_bytes()) + "\n")
    manifest = {
        "schema_version": 1,
        "version": args.version,
        "commit": args.commit,
        "source_hash": args.source_hash,
        "assets": assets,
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Prepared ec {args.version}: four native binaries, curl installer, and {tarball.name}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Refresh the NVMe PLE reader's audited source guard for this working tree.

The reader plugin refuses to load when a guarded module's bytes differ from the
audited manifest, so every commit that touches a guarded module has to refresh
the manifest and re-run the guard test.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GUARD = (
    REPO
    / "tools"
    / "ple_nvme"
    / "ssd_stream"
    / "src"
    / "sglang_ssd_stream"
    / "pennyroyal-source.json"
)


def module_path(module: str) -> Path:
    base = REPO / "python" / Path(*module.split("."))
    for candidate in (base.with_suffix(".py"), base / "__init__.py"):
        if candidate.is_file():
            return candidate
    raise SystemExit(f"cannot locate guarded module {module}")


def module_digest(module: str) -> str:
    return hashlib.sha256(module_path(module).read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, help="audited provenance string")
    parser.add_argument("--check", action="store_true", help="report drift, write nothing")
    args = parser.parse_args()

    manifest = json.loads(GUARD.read_text())
    refreshed = {
        "source": args.source,
        "modules": {name: module_digest(name) for name in manifest["modules"]},
    }
    payload = json.dumps(refreshed, indent=2) + "\n"

    if args.check:
        drifted = sorted(
            name
            for name, digest in refreshed["modules"].items()
            if digest != manifest["modules"][name]
        )
        for name in drifted:
            print(f"{name}: {manifest['modules'][name]} -> {refreshed['modules'][name]}")
        if manifest["source"] != args.source:
            print(f"source: {manifest['source']} -> {args.source}")
        return 1 if drifted or manifest["source"] != args.source else 0

    GUARD.write_text(payload)
    print(f"{GUARD.relative_to(REPO)}: {len(refreshed['modules'])} modules audited")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

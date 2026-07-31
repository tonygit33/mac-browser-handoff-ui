#!/usr/bin/env python3
"""Merge every OBDb SAEJ1979 signalset and compile a pinned runtime data pack."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


def command_key(command: dict[str, Any]) -> tuple[str, tuple[tuple[str, str], ...]] | None:
    mapping = command.get("cmd")
    if not isinstance(mapping, dict) or not mapping:
        return None
    return str(command.get("hdr") or ""), tuple(sorted((str(k).upper(), str(v).upper()) for k, v in mapping.items()))


def signal_key(signal: dict[str, Any]) -> str:
    return str(signal.get("id") or signal.get("name") or json.dumps(signal, sort_keys=True))


def merge_signalsets(root: Path) -> tuple[list[dict[str, Any]], int]:
    merged: dict[tuple[str, tuple[tuple[str, str], ...]], dict[str, Any]] = {}
    source_files = 0
    for path in sorted(root.rglob("*.json")):
        try:
            document = json.loads(path.read_text())
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        commands = document.get("commands") if isinstance(document, dict) else None
        if not isinstance(commands, list):
            continue
        source_files += 1
        for raw in commands:
            if not isinstance(raw, dict):
                continue
            key = command_key(raw)
            if key is None:
                continue
            existing = merged.get(key)
            if existing is None:
                existing = dict(raw)
                existing["signals"] = []
                merged[key] = existing
            current = {signal_key(item): item for item in existing.get("signals") or [] if isinstance(item, dict)}
            for signal in raw.get("signals") or []:
                if isinstance(signal, dict):
                    current[signal_key(signal)] = signal
            existing["signals"] = [current[name] for name in sorted(current)]
            frequencies = [value for value in (existing.get("freq"), raw.get("freq")) if isinstance(value, (int, float)) and value > 0]
            if frequencies:
                existing["freq"] = min(frequencies)
    commands = sorted(
        merged.values(),
        key=lambda item: (str(item.get("hdr") or ""), json.dumps(item.get("cmd"), sort_keys=True)),
    )
    return commands, source_files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()

    commands, source_files = merge_signalsets(args.repository)
    if not commands:
        print("No OBDb commands found", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as temporary:
        combined = Path(temporary) / "obdb-combined.json"
        combined.write_text(json.dumps({"commands": commands}, indent=2, sort_keys=True) + "\n")
        compiler = Path(__file__).with_name("compile_vehicle_data_pack.py")
        source_url = f"https://github.com/OBDb/SAEJ1979/tree/{args.revision}"
        subprocess.run(
            [
                sys.executable,
                str(compiler),
                "obdb",
                str(combined),
                str(args.output),
                "--pack-id",
                "core.sae-j1979.generated",
                "--pack-version",
                args.revision[:12],
                "--display-name",
                "Complete pinned OBDb SAE J1979 catalog",
                "--source-version",
                args.revision,
                "--source-url",
                source_url,
            ],
            check=True,
        )

    pack = json.loads(args.output.read_text())
    print(
        f"Generated {args.output}: {len(pack.get('signals', []))} signals from "
        f"{len(commands)} commands across {source_files} JSON source files at {args.revision}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

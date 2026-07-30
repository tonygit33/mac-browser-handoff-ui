#!/usr/bin/env python3
"""Compile external automotive databases into OBD Bridge diagnostic data packs.

Supported inputs:
- OBDb SAEJ1979 signalsets/v3 JSON (standard-library only)
- DBC, KCD, SYM, ARXML and CDD through the optional `cantools` package

The iPhone application never parses arbitrary third-party databases directly. CI compiles,
validates, attributes and pins them into the small canonical JSON format used at runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path
from typing import Any, Iterable

READ_ONLY_J1979_SERVICES = {"01", "02", "03", "06", "07", "09", "0A"}
SCHEMA_VERSION = "1.0"


def load_json(source: str) -> tuple[dict[str, Any], str]:
    if source.startswith(("https://", "http://")):
        with urllib.request.urlopen(source, timeout=30) as response:  # nosec: user-supplied CLI source
            payload = response.read()
    else:
        payload = Path(source).read_bytes()
    return json.loads(payload), hashlib.sha256(payload).hexdigest()


def provenance(
    *,
    source_id: str,
    name: str,
    version: str,
    kind: str,
    license_name: str,
    source_url: str | None,
    checksum: str | None,
    attribution: str,
    confidence: float,
) -> dict[str, Any]:
    return {
        "id": source_id,
        "name": name,
        "version": version,
        "kind": kind,
        "license": license_name,
        "sourceURL": source_url,
        "checksum": checksum,
        "attribution": attribution,
        "confidence": confidence,
    }


def generic_matcher(args: argparse.Namespace) -> dict[str, Any]:
    return {
        "makes": list(args.make or []),
        "models": list(args.model or []),
        "minimumYear": args.minimum_year,
        "maximumYear": args.maximum_year,
        "vinPrefixes": list(args.vin_prefix or []),
        "enginePatterns": list(args.engine_pattern or []),
        "calibrationIDPrefixes": list(args.calibration_prefix or []),
        "requiredECUAddresses": list(args.ecu_address or []),
    }


def expression_for_format(fmt: dict[str, Any]) -> str | None:
    parts = ["RAW"]
    if "bix" in fmt or "len" in fmt:
        parts.append(f"bits[{fmt.get('bix', 0)}:{fmt.get('len', '?')}]")
    if fmt.get("mul") not in (None, 1):
        parts.append(f"*{fmt['mul']}")
    if fmt.get("div") not in (None, 1):
        parts.append(f"/{fmt['div']}")
    if fmt.get("add") not in (None, 0):
        parts.append(f"{fmt['add']:+g}")
    return " ".join(parts)


def normalized_lookup(raw: Any) -> dict[str, str] | None:
    if not isinstance(raw, dict):
        return None
    result: dict[str, str] = {}
    for key, value in raw.items():
        if isinstance(value, dict):
            resolved = value.get("value") or value.get("description") or json.dumps(value, sort_keys=True)
        else:
            resolved = value
        result[str(key)] = str(resolved)
    return result


def category_from_obdb(signal: dict[str, Any]) -> str:
    path = str(signal.get("path") or "generic").lower()
    identifier = str(signal.get("id") or "").lower()
    joined = f"{path} {identifier}"
    rules = (
        ("fuel-trim", ("fuel trim", "shrtft", "longft")),
        ("engine-speed", ("rpm",)),
        ("vehicle-speed", ("speed", "vss")),
        ("temperature", ("temperature", "temp", "ect", "iat")),
        ("oxygen", ("oxygen", "lambda", "o2")),
        ("airflow", ("air flow", "maf")),
        ("pressure", ("pressure", "map", "baro")),
        ("pedal", ("pedal",)),
        ("throttle", ("throttle",)),
        ("voltage", ("voltage", "volt")),
        ("dtc", ("dtc", "mil", "readiness")),
    )
    for category, needles in rules:
        if any(needle in joined for needle in needles):
            return category
    return path.split(".")[0] or "generic"


def compile_obdb(args: argparse.Namespace) -> dict[str, Any]:
    document, checksum = load_json(args.input)
    commands = document.get("commands")
    if not isinstance(commands, list):
        raise ValueError("OBDb input must contain a commands array")

    source = provenance(
        source_id="obdb.saej1979",
        name="OBDb SAEJ1979 Standard PIDs",
        version=args.source_version,
        kind="sae",
        license_name="CC-BY-SA-4.0",
        source_url=args.source_url or args.input if args.input.startswith("http") else args.source_url,
        checksum=checksum,
        attribution="Generated from OBDb/SAEJ1979 signalsets/v3. Preserve CC-BY-SA attribution and share-alike obligations.",
        confidence=0.95,
    )

    signals: list[dict[str, Any]] = []
    for command in commands:
        command_map = command.get("cmd")
        if not isinstance(command_map, dict) or len(command_map) != 1:
            continue
        service, identifier = next(iter(command_map.items()))
        service = str(service).upper()
        identifier = str(identifier).upper()
        interval_seconds = float(command.get("freq") or 1)
        preferred_hz = 1.0 / interval_seconds if interval_seconds > 0 else 1.0
        response_service = f"{(int(service, 16) + 0x40) & 0xFF:02X}"

        for signal in command.get("signals") or []:
            fmt = signal.get("fmt") or {}
            lookup = normalized_lookup(fmt.get("map"))
            bit_length = int(fmt["len"]) if fmt.get("len") is not None else None
            decode_kind = "lookup" if lookup else ("boolean" if bit_length == 1 else "linear")
            multiplier = float(fmt.get("mul", 1))
            divisor = float(fmt.get("div", 1))
            factor = multiplier / divisor if divisor else None
            offset = float(fmt.get("add", 0))
            signal_id = str(signal.get("id") or signal.get("name") or f"SIGNAL_{len(signals)}")
            unit = fmt.get("unit")
            minimum = fmt.get("min")
            maximum = fmt.get("max")

            signals.append(
                {
                    "key": {
                        "namespace": "sae",
                        "service": service,
                        "identifier": identifier,
                        "signalID": signal_id,
                        "ecuAddress": None,
                    },
                    "name": str(signal.get("name") or signal_id),
                    "descriptionText": signal.get("description"),
                    "category": category_from_obdb(signal),
                    "request": {
                        "service": service,
                        "identifier": identifier,
                        "header": command.get("hdr"),
                        "session": None,
                        "subfunction": None,
                        "timeoutMilliseconds": 3000,
                        "responsePrefix": f"{response_service}{identifier}",
                    },
                    "decode": {
                        "kind": decode_kind,
                        "startBit": int(fmt.get("bix", 0)) if bit_length is not None else None,
                        "bitLength": bit_length,
                        "endian": "big",
                        "isSigned": bool(fmt.get("signed", False)),
                        "factor": factor,
                        "offset": offset,
                        "unit": unit,
                        "expression": expression_for_format(fmt),
                        "lookup": lookup,
                    },
                    "safety": "readOnly" if service in READ_ONLY_J1979_SERVICES else "restricted",
                    "preferredFrequencyHz": preferred_hz,
                    "maximumFrequencyHz": max(preferred_hz, min(50.0, preferred_hz * 4)),
                    "expectedRange": {
                        "minimum": minimum,
                        "maximum": maximum,
                        "unit": unit,
                        "conditions": [],
                    }
                    if minimum is not None or maximum is not None
                    else None,
                    "preconditions": ["ignition-on"],
                    "tags": [str(signal.get("path") or "generic"), signal_id],
                    "provenance": source,
                }
            )

    return {
        "schemaVersion": SCHEMA_VERSION,
        "id": args.pack_id,
        "version": args.pack_version,
        "displayName": args.display_name,
        "matcher": generic_matcher(args),
        "provenance": source,
        "signals": signals,
        "scenarios": [],
        "researchTargets": [],
        "notes": [
            f"Generated from {args.input}.",
            "One request may decode into multiple signals; signalID preserves that distinction.",
        ],
    }


def iter_cantools_databases(database: Any) -> Iterable[Any]:
    # cantools may return a Database directly or a container with buses/databases.
    if hasattr(database, "messages"):
        yield database
    for attribute in ("databases", "buses"):
        for item in getattr(database, attribute, []) or []:
            if hasattr(item, "messages"):
                yield item


def compile_network_database(args: argparse.Namespace) -> dict[str, Any]:
    try:
        import cantools  # type: ignore
    except ImportError as error:
        raise RuntimeError("Install the optional compiler dependency: python -m pip install cantools") from error

    input_path = Path(args.input)
    payload = input_path.read_bytes()
    checksum = hashlib.sha256(payload).hexdigest()
    database = cantools.database.load_file(str(input_path), strict=True)
    source = provenance(
        source_id=args.source_id,
        name=args.source_name,
        version=args.source_version,
        kind=args.source_kind,
        license_name=args.license,
        source_url=args.source_url,
        checksum=checksum,
        attribution=args.attribution,
        confidence=args.confidence,
    )

    signals: list[dict[str, Any]] = []
    for db in iter_cantools_databases(database):
        for message in db.messages:
            frame = f"{message.frame_id:X}"
            for signal in message.signals:
                choices = None
                if signal.choices:
                    choices = {str(key): str(value) for key, value in signal.choices.items()}
                signals.append(
                    {
                        "key": {
                            "namespace": "dbc",
                            "service": "CAN",
                            "identifier": frame,
                            "signalID": signal.name,
                            "ecuAddress": None,
                        },
                        "name": signal.name,
                        "descriptionText": signal.comment,
                        "category": "can-signal",
                        "request": {
                            "service": "PASSIVE",
                            "identifier": frame,
                            "header": None,
                            "session": None,
                            "subfunction": None,
                            "timeoutMilliseconds": 5000,
                            "responsePrefix": None,
                        },
                        "decode": {
                            "kind": "lookup" if choices else "linear",
                            "startBit": signal.start,
                            "bitLength": signal.length,
                            "endian": "little" if signal.byte_order == "little_endian" else "big",
                            "isSigned": signal.is_signed,
                            "factor": float(signal.scale),
                            "offset": float(signal.offset),
                            "unit": signal.unit,
                            "expression": f"raw*{signal.scale}+{signal.offset}",
                            "lookup": choices,
                        },
                        "safety": "passive",
                        "preferredFrequencyHz": args.default_frequency,
                        "maximumFrequencyHz": args.maximum_frequency,
                        "expectedRange": {
                            "minimum": signal.minimum,
                            "maximum": signal.maximum,
                            "unit": signal.unit,
                            "conditions": [],
                        }
                        if signal.minimum is not None or signal.maximum is not None
                        else None,
                        "preconditions": ["bus-visible"],
                        "tags": ["can", message.name, signal.name],
                        "provenance": source,
                    }
                )

    return {
        "schemaVersion": SCHEMA_VERSION,
        "id": args.pack_id,
        "version": args.pack_version,
        "displayName": args.display_name,
        "matcher": generic_matcher(args),
        "provenance": source,
        "signals": signals,
        "scenarios": [],
        "researchTargets": [],
        "notes": [
            f"Generated with cantools from {input_path.name}.",
            "All imported network signals are passive; transmit definitions are intentionally not emitted.",
        ],
    }


def add_matcher_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--make", action="append")
    parser.add_argument("--model", action="append")
    parser.add_argument("--minimum-year", type=int)
    parser.add_argument("--maximum-year", type=int)
    parser.add_argument("--vin-prefix", action="append")
    parser.add_argument("--engine-pattern", action="append")
    parser.add_argument("--calibration-prefix", action="append")
    parser.add_argument("--ecu-address", action="append")


def write_pack(pack: dict[str, Any], output: str) -> None:
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(pack, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
    print(f"wrote {destination} ({len(pack['signals'])} signals)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    obdb = subparsers.add_parser("obdb", help="Compile OBDb SAEJ1979 signalsets/v3 JSON")
    obdb.add_argument("input")
    obdb.add_argument("output")
    obdb.add_argument("--pack-id", default="core.sae-j1979.generated")
    obdb.add_argument("--pack-version", required=True)
    obdb.add_argument("--display-name", default="Generated SAE J1979 Catalog")
    obdb.add_argument("--source-version", required=True)
    obdb.add_argument("--source-url")
    add_matcher_arguments(obdb)
    obdb.set_defaults(handler=compile_obdb)

    network = subparsers.add_parser("network", help="Compile DBC/KCD/SYM/ARXML/CDD through cantools")
    network.add_argument("input")
    network.add_argument("output")
    network.add_argument("--pack-id", required=True)
    network.add_argument("--pack-version", required=True)
    network.add_argument("--display-name", required=True)
    network.add_argument("--source-id", required=True)
    network.add_argument("--source-name", required=True)
    network.add_argument("--source-version", required=True)
    network.add_argument("--source-kind", choices=["dbc", "arxml", "cdd", "manufacturer", "community", "userVerified"], required=True)
    network.add_argument("--license", required=True)
    network.add_argument("--source-url")
    network.add_argument("--attribution", required=True)
    network.add_argument("--confidence", type=float, default=0.8)
    network.add_argument("--default-frequency", type=float, default=5.0)
    network.add_argument("--maximum-frequency", type=float, default=50.0)
    add_matcher_arguments(network)
    network.set_defaults(handler=compile_network_database)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        pack = args.handler(args)
        write_pack(pack, args.output)
    except Exception as error:  # noqa: BLE001 - CLI must return a useful failure
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

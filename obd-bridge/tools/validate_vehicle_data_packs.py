#!/usr/bin/env python3
"""Validate canonical OBD Bridge vehicle data packs and AI snapshot schemas."""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any

AUTOMATIC_SAE_READ_SERVICES = {"01", "02", "03", "06", "07", "09", "0A"}
AUTOMATIC_UDS_READ_SERVICES = {"19", "22", "1A"}
SAFE_CLASSES = {"passive", "readOnly"}


def load(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def signal_key(signal: dict[str, Any]) -> tuple[Any, ...]:
    key = signal["key"]
    return (
        str(key.get("namespace", "")).lower(),
        str(key.get("service", "")).upper(),
        str(key.get("identifier", "")).upper(),
        str(key.get("signalID") or ""),
        str(key.get("ecuAddress") or "").upper(),
    )


def request_key(signal: dict[str, Any]) -> tuple[Any, ...]:
    request = signal["request"]
    return (
        str(request.get("service", "")).upper(),
        str(request.get("identifier", "")).upper(),
        str(request.get("header") or "").upper(),
        str(request.get("session") or "").upper(),
        str(request.get("subfunction") or "").upper(),
    )


def is_automatic_safe(signal: dict[str, Any]) -> bool:
    if signal.get("safety") not in SAFE_CLASSES:
        return False
    namespace = str(signal["key"].get("namespace", "")).lower()
    service = str(signal["request"].get("service", "")).upper()
    if namespace in {"sae", "j1979"}:
        return service in AUTOMATIC_SAE_READ_SERVICES
    if namespace in {"uds", "odx"}:
        return service in AUTOMATIC_UDS_READ_SERVICES
    if namespace in {"can", "dbc"}:
        return signal.get("safety") == "passive" and service in {"PASSIVE", "CAN"}
    return signal.get("safety") in SAFE_CLASSES


def validate_semantics(pack: dict[str, Any], path: Path) -> list[str]:
    errors: list[str] = []
    pack_id = pack.get("id", path.stem)
    provenance = pack.get("provenance") or {}
    if not provenance.get("license"):
        errors.append(f"{pack_id}: missing source license")
    confidence = provenance.get("confidence")
    if not isinstance(confidence, (int, float)) or not math.isfinite(confidence) or not 0 <= confidence <= 1:
        errors.append(f"{pack_id}: provenance confidence must be finite and between 0 and 1")

    seen_signals: set[tuple[Any, ...]] = set()
    requests: dict[tuple[Any, ...], list[dict[str, Any]]] = defaultdict(list)
    for signal in pack.get("signals", []):
        key = signal_key(signal)
        if key in seen_signals:
            errors.append(f"{pack_id}: duplicate signal key {key}")
        seen_signals.add(key)
        requests[request_key(signal)].append(signal)

        preferred = signal.get("preferredFrequencyHz")
        maximum = signal.get("maximumFrequencyHz")
        if preferred is not None and (not isinstance(preferred, (int, float)) or preferred <= 0):
            errors.append(f"{pack_id}: invalid preferred frequency for {key}")
        if maximum is not None and (not isinstance(maximum, (int, float)) or maximum <= 0):
            errors.append(f"{pack_id}: invalid maximum frequency for {key}")
        if preferred is not None and maximum is not None and preferred > maximum:
            errors.append(f"{pack_id}: preferred frequency exceeds maximum for {key}")

        timeout = signal.get("request", {}).get("timeoutMilliseconds")
        if not isinstance(timeout, int) or timeout <= 0:
            errors.append(f"{pack_id}: invalid timeout for {key}")

        if signal.get("safety") in SAFE_CLASSES and not is_automatic_safe(signal):
            errors.append(
                f"{pack_id}: signal {key} is marked {signal.get('safety')} but uses a non-whitelisted service"
            )

        definition_provenance = signal.get("provenance") or {}
        if not definition_provenance.get("license"):
            errors.append(f"{pack_id}: signal {key} has no provenance license")

    for key, group in requests.items():
        service, _, _, _, _ = key
        safety_values = {signal.get("safety") for signal in group}
        if "write" in safety_values and safety_values.intersection(SAFE_CLASSES):
            errors.append(f"{pack_id}: request {key} mixes write and read-only signal definitions")
        if service in {"04", "08", "10", "11", "14", "2E", "2F", "31", "34", "36", "37", "3D"}:
            if any(signal.get("safety") in SAFE_CLASSES for signal in group):
                errors.append(f"{pack_id}: dangerous service {service} cannot be automatic read-only")

    scenario_ids: set[str] = set()
    for scenario in pack.get("scenarios", []):
        scenario_id = str(scenario.get("id", ""))
        if not scenario_id:
            errors.append(f"{pack_id}: scenario without id")
        elif scenario_id in scenario_ids:
            errors.append(f"{pack_id}: duplicate scenario id {scenario_id}")
        scenario_ids.add(scenario_id)
        if not scenario.get("phases"):
            errors.append(f"{pack_id}: scenario {scenario_id} has no phases")
        for phase in scenario.get("phases", []):
            if not phase.get("signals"):
                errors.append(f"{pack_id}: phase {phase.get('id')} in {scenario_id} has no signals")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packs", type=Path, default=Path("obd-bridge/Resources/VehicleDataPacks"))
    parser.add_argument("--schema", type=Path, default=Path("obd-bridge/schemas/diagnostic-pack.schema.json"))
    args = parser.parse_args()

    try:
        import jsonschema
    except ImportError:
        print("error: install jsonschema to validate data packs", file=sys.stderr)
        return 2

    schema = load(args.schema)
    validator = jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker())
    pack_paths = sorted(args.packs.glob("*.diagnostic-pack.json"))
    if not pack_paths:
        print(f"error: no diagnostic packs found in {args.packs}", file=sys.stderr)
        return 1

    failures: list[str] = []
    pack_ids: set[str] = set()
    for path in pack_paths:
        pack = load(path)
        pack_id = str(pack.get("id", path.stem))
        if pack_id in pack_ids:
            failures.append(f"duplicate pack id across files: {pack_id}")
        pack_ids.add(pack_id)
        for error in sorted(validator.iter_errors(pack), key=lambda item: list(item.path)):
            location = "/".join(str(item) for item in error.path)
            failures.append(f"{path}:{location}: {error.message}")
        failures.extend(validate_semantics(pack, path))

    if failures:
        print("vehicle data-pack validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    signal_count = sum(len(load(path).get("signals", [])) for path in pack_paths)
    scenario_count = sum(len(load(path).get("scenarios", [])) for path in pack_paths)
    print(f"validated {len(pack_paths)} packs, {signal_count} signals, {scenario_count} scenarios")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

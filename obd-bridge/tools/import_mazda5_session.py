#!/usr/bin/env python3
"""Safely ingest an OBDBridge session into the authoritative Mazda 5 SQLite database.

The importer is deliberately read-only at the vehicle-command level. It rejects a
session containing configuration, active-test, clear-code, programming, or security
commands. Imports are atomic, content-addressed, and idempotent.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sqlite3
from pathlib import Path
from typing import Any, Iterable

VEHICLE = "Mazda 5 CR 2007 L3 2.3 gasoline"
READ_ONLY_MODES = {"01", "02", "03", "06", "07", "09", "0A"}
ADAPTER_READ_PREFIXES = (
    "ATI", "ATDP", "ATDPN", "ATRV", "STI", "STDI", "STIX", "STDIX",
    "STMFR", "STPR", "STPRS", "STPBRR",
)
ADAPTER_SETUP_ALLOWLIST = {"ATZ", "ATE0", "ATL0", "ATS1", "ATH1", "ATAL", "ATSP0"}
HEX_RE = re.compile(r"^[0-9A-F]+$")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalize_command(value: Any) -> str:
    return re.sub(r"\s+", "", str(value or "").upper())


def is_safe_command(command: str) -> bool:
    if command in ADAPTER_SETUP_ALLOWLIST or any(command.startswith(p) for p in ADAPTER_READ_PREFIXES):
        return True
    if len(command) >= 2 and HEX_RE.fullmatch(command):
        return command[:2] in READ_ONLY_MODES
    return False


def normalized_response(value: Any) -> str:
    text = str(value or "").replace("\r", "\n")
    lines = [" ".join(line.strip().split()) for line in text.splitlines() if line.strip()]
    return "\n".join(lines)


def classify_response(response: str, timed_out: bool) -> tuple[str, int | None, str | None]:
    upper = response.upper()
    if timed_out or "TIMEOUT" in upper:
        return "timeout", 0, "timeout"
    if "NO DATA" in upper:
        return "no_data", 0, "no_data"
    if "UNABLE TO CONNECT" in upper or "BUS ERROR" in upper or "CAN ERROR" in upper:
        return "transport_error", 0, "transport_error"
    if "?" == upper.strip() or "ERROR" in upper:
        return "adapter_error", 0, "adapter_error"
    if response.strip():
        return "response", 1, None
    return "empty", None, "empty_response"


def ecu_header(response: str) -> str | None:
    for line in response.splitlines():
        token = line.split()[0] if line.split() else ""
        if re.fullmatch(r"[0-9A-F]{3}", token) or re.fullmatch(r"[0-9A-F]{8}", token):
            return token
    return None


def positive_service(command: str, response: str) -> str | None:
    if len(command) < 2 or not HEX_RE.fullmatch(command):
        return None
    service = int(command[:2], 16)
    candidate = f"{(service + 0x40) & 0xFF:02X}"
    return candidate if candidate in re.sub(r"[^0-9A-F]", "", response.upper()) else None


def load_events(path: Path) -> tuple[Path, list[dict[str, Any]], bytes]:
    events_path = path / "events.jsonl" if path.is_dir() else path
    if events_path.name != "events.jsonl":
        raise ValueError("Expected a session directory or events.jsonl")
    raw = events_path.read_bytes()
    events: list[dict[str, Any]] = []
    for number, line in enumerate(raw.decode("utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ValueError(f"events.jsonl line {number} is not an object")
        events.append(value)
    if not events:
        raise ValueError("events.jsonl is empty")
    return events_path, events, raw


def ensure_column(db: sqlite3.Connection, table: str, definition: str) -> None:
    name = definition.split()[0]
    names = {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
    if name not in names:
        db.execute(f"ALTER TABLE {table} ADD COLUMN {definition}")


def migrate(db: sqlite3.Connection) -> None:
    db.execute("""
        CREATE TABLE IF NOT EXISTS mazda5_session_imports (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            source_path TEXT NOT NULL,
            source_sha256 TEXT NOT NULL UNIQUE,
            session_id INTEGER,
            imported_at TEXT NOT NULL,
            event_count INTEGER NOT NULL,
            command_count INTEGER NOT NULL,
            sample_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL CHECK(status IN ('imported','rejected')),
            notes TEXT,
            FOREIGN KEY(session_id) REFERENCES mazda5_obd_capture_sessions(id)
        )
    """)
    ensure_column(db, "mazda5_obd_capture_sessions", "source_path TEXT")
    ensure_column(db, "mazda5_obd_capture_sessions", "source_sha256 TEXT")
    ensure_column(db, "mazda5_obd_capture_sessions", "scenario TEXT")
    ensure_column(db, "mazda5_obd_capture_sessions", "fuel_mode TEXT")
    ensure_column(db, "mazda5_obd_capture_sessions", "read_only INTEGER NOT NULL DEFAULT 1")
    ensure_column(db, "mazda5_obd_raw_responses", "source_event_sha256 TEXT")
    ensure_column(db, "mazda5_obd_raw_responses", "timed_out INTEGER NOT NULL DEFAULT 0")
    db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_m5_session_import_sha ON mazda5_session_imports(source_sha256)")
    db.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_m5_raw_event_sha ON mazda5_obd_raw_responses(source_event_sha256) WHERE source_event_sha256 IS NOT NULL")
    db.execute("CREATE INDEX IF NOT EXISTS idx_m5_capture_source_sha ON mazda5_obd_capture_sessions(source_sha256)")


def event_timestamp(event: dict[str, Any], fallback: str) -> str:
    value = str(event.get("timestamp") or fallback)
    return value


def import_session(db_path: Path, source: Path, dry_run: bool = False) -> dict[str, Any]:
    events_path, events, raw = load_events(source)
    source_sha = sha256_bytes(raw)
    start = next((e for e in events if e.get("type") == "session_start"), {})
    end = next((e for e in reversed(events) if e.get("type") == "session_end"), {})
    commands = [e for e in events if e.get("type") == "command"]
    unsafe = sorted({normalize_command(e.get("command")) for e in commands if not is_safe_command(normalize_command(e.get("command")))})
    if unsafe:
        raise ValueError("Unsafe or unknown commands present: " + ", ".join(unsafe))
    started_at = str(start.get("startedAt") or start.get("timestamp") or "")
    if not started_at:
        raise ValueError("session_start timestamp is missing")
    finished_at = str(end.get("endedAt") or end.get("timestamp") or "") or None
    scenario = str(start.get("scenario") or end.get("scenario") or events_path.parent.name)
    fuel_mode = str(start.get("fuelMode") or end.get("fuelMode") or "Unknown")
    adapter = str(start.get("adapter") or "OBDLink MX+")
    app_mode = str(start.get("appMode") or "read-only")
    if "read-only" not in app_mode.lower():
        raise ValueError(f"Session is not explicitly read-only: {app_mode}")

    db = sqlite3.connect(str(db_path))
    db.execute("PRAGMA foreign_keys=ON")
    try:
        with db:
            migrate(db)
            existing = db.execute("SELECT session_id FROM mazda5_session_imports WHERE source_sha256=?", (source_sha,)).fetchone()
            if existing:
                return {"status": "duplicate", "source_sha256": source_sha, "session_id": existing[0], "commands": 0}
            if dry_run:
                return {"status": "validated", "source_sha256": source_sha, "events": len(events), "commands": len(commands)}
            cur = db.execute("""
                INSERT INTO mazda5_obd_capture_sessions
                (started_at, finished_at, vehicle, adapter, transport, detected_protocol, vin, app_version,
                 status, notes, source_path, source_sha256, scenario, fuel_mode, read_only)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
            """, (
                started_at, finished_at, VEHICLE, adapter, "OBD-II", None, None, None,
                "complete" if finished_at else "open", "Imported from OBDBridge events.jsonl",
                str(events_path), source_sha, scenario, fuel_mode,
            ))
            session_id = int(cur.lastrowid)
            inserted = 0
            for index, event in enumerate(commands, 1):
                command = normalize_command(event.get("command"))
                response_raw = str(event.get("response") or "")
                response_norm = normalized_response(response_raw)
                timed_out = str(event.get("timedOut") or "false").lower() == "true"
                classification, supported, error_class = classify_response(response_norm, timed_out)
                captured_at = event_timestamp(event, started_at)
                fingerprint = sha256_bytes(json.dumps({
                    "source": source_sha, "index": index, "timestamp": captured_at,
                    "command": command, "response": response_norm,
                }, sort_keys=True, separators=(",", ":")).encode())
                db.execute("""
                    INSERT INTO mazda5_obd_raw_responses
                    (session_id, request, response_raw, response_normalized, ecu_header,
                     positive_response_service, classification, supported, decoded_json,
                     error_class, elapsed_ms, captured_at, source_event_sha256, timed_out)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, (
                    session_id, command, response_raw, response_norm, ecu_header(response_norm),
                    positive_service(command, response_norm), classification, supported, None,
                    error_class, None, captured_at, fingerprint, 1 if timed_out else 0,
                ))
                inserted += 1
            db.execute("""
                INSERT INTO mazda5_session_imports
                (source_path, source_sha256, session_id, imported_at, event_count, command_count, sample_count, status, notes)
                VALUES (?,?,?,datetime('now'),?,?,0,'imported',?)
            """, (str(events_path), source_sha, session_id, len(events), inserted, "Atomic read-only evidence import"))
        return {"status": "imported", "source_sha256": source_sha, "session_id": session_id, "events": len(events), "commands": inserted}
    finally:
        db.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path)
    parser.add_argument("session", type=Path)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    result = import_session(args.database, args.session, args.dry_run)
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

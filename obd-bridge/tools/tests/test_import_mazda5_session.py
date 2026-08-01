import importlib.util
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "import_mazda5_session.py"
spec = importlib.util.spec_from_file_location("importer", MODULE_PATH)
importer = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(importer)

BASE_SCHEMA = """
CREATE TABLE mazda5_obd_capture_sessions (
 id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL, finished_at TEXT,
 vehicle TEXT NOT NULL, adapter TEXT, adapter_firmware TEXT, transport TEXT,
 detected_protocol TEXT, vin TEXT, app_version TEXT, status TEXT NOT NULL, notes TEXT
);
CREATE TABLE mazda5_obd_raw_responses (
 id INTEGER PRIMARY KEY AUTOINCREMENT, session_id INTEGER NOT NULL, request TEXT NOT NULL,
 response_raw TEXT NOT NULL, response_normalized TEXT, ecu_header TEXT,
 positive_response_service TEXT, classification TEXT, supported INTEGER,
 decoded_json TEXT, error_class TEXT, elapsed_ms INTEGER, captured_at TEXT NOT NULL,
 FOREIGN KEY(session_id) REFERENCES mazda5_obd_capture_sessions(id)
);
"""

class ImportTests(unittest.TestCase):
    def make_fixture(self, command="010C"):
        root = Path(tempfile.mkdtemp())
        db = root / "db.sqlite"
        con = sqlite3.connect(db); con.executescript(BASE_SCHEMA); con.close()
        session = root / "session"; session.mkdir()
        rows = [
            {"type":"session_start","timestamp":"2026-08-01T10:00:00Z","startedAt":"2026-08-01T10:00:00Z","scenario":"Warm idle","fuelMode":"Gasoline","adapter":"OBDLink MX+","appMode":"read-only"},
            {"type":"command","timestamp":"2026-08-01T10:00:01Z","command":command,"response":"7E8 04 41 0C 1A F8","timedOut":"false"},
            {"type":"session_end","timestamp":"2026-08-01T10:00:02Z","endedAt":"2026-08-01T10:00:02Z"},
        ]
        (session / "events.jsonl").write_text("".join(json.dumps(r)+"\n" for r in rows))
        return root, db, session

    def test_atomic_import_and_duplicate(self):
        _, db, session = self.make_fixture()
        first = importer.import_session(db, session)
        second = importer.import_session(db, session)
        self.assertEqual(first["status"], "imported")
        self.assertEqual(first["commands"], 1)
        self.assertEqual(second["status"], "duplicate")
        con = sqlite3.connect(db)
        self.assertEqual(con.execute("select count(*) from mazda5_obd_capture_sessions").fetchone()[0], 1)
        self.assertEqual(con.execute("select count(*) from mazda5_obd_raw_responses").fetchone()[0], 1)
        self.assertEqual(con.execute("select ecu_header from mazda5_obd_raw_responses").fetchone()[0], "7E8")

    def test_rejects_active_or_clear_command(self):
        _, db, session = self.make_fixture("04")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            importer.import_session(db, session)
        con = sqlite3.connect(db)
        self.assertEqual(con.execute("select count(*) from mazda5_obd_capture_sessions").fetchone()[0], 0)

if __name__ == "__main__":
    unittest.main()

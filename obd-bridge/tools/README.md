# OBD data-pack build tools

- `compile_vehicle_data_pack.py` compiles pinned OBDb SAE J1979 JSON or passive network databases supported by `cantools` into the canonical runtime data-pack format.
- `validate_vehicle_data_packs.py` validates JSON Schema, provenance, licenses, duplicate keys, rates, scenarios and automatic read-only safety.

These tools run at build time. The iPhone application loads only validated canonical JSON packs.

## Import verified Mazda 5 sessions into the authoritative database

`import_mazda5_session.py` ingests an exported OBDBridge session directory (or its
`events.jsonl`) into the Mazda 5 evidence tables. The operation is atomic,
content-addressed, and idempotent. A session is rejected before any write if it
contains a command outside adapter identification/setup or OBD read-only modes
01, 02, 03, 06, 07, 09 and 0A.

```bash
python3 tools/import_mazda5_session.py /path/to/mazda5-knowledge.db /path/to/session
```

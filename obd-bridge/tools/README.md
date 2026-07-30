# OBD data-pack build tools

- `compile_vehicle_data_pack.py` compiles pinned OBDb SAE J1979 JSON or passive network databases supported by `cantools` into the canonical runtime data-pack format.
- `validate_vehicle_data_packs.py` validates JSON Schema, provenance, licenses, duplicate keys, rates, scenarios and automatic read-only safety.

These tools run at build time. The iPhone application loads only validated canonical JSON packs.

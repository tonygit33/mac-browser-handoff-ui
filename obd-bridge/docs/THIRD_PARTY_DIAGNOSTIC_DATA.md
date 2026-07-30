# Third-party diagnostic data and tooling

Every bundled or generated data pack must preserve source identity, version, checksum, license, attribution and confidence. A repository name is not a license; CI rejects packs without explicit provenance.

| Source | Role | Runtime or build time | License / redistribution policy |
|---|---|---|---|
| OBDb/SAEJ1979 | Structured standard SAE J1979 commands, signals, formats, units and recommended frequencies | Build time; compiled to canonical JSON | CC-BY-SA-4.0. Preserve attribution and share-alike obligations for derived data packs. Pin the upstream revision and record SHA-256. |
| cantools | Parser/compiler for DBC, KCD, SYM, ARXML and CDD; optional database QA and decoding | Build time/server tools only | MIT. The imported database retains its own separate license; cantools does not grant rights to third-party DBC/ARXML/CDD content. |
| commaai/opendbc | Optional CAN signal definitions, vehicle fingerprints and examples for supported vehicles | Build time / research | MIT for repository code/data as published. Verify individual generated artifacts and suitability; do not treat it as a complete generic OBD database. |
| ASAM MCD-2 D / ODX | Canonical OEM diagnostic data model and PDX exchange format | Build time/server import | Standard/specification rights and each OEM PDX license apply. Do not redistribute proprietary PDX/ODX content without permission. |
| ISO 14229 UDS | Service semantics, sessions, DIDs, DTC and routine framework | Protocol implementation reference | Copyrighted standard. Implement behavior; do not copy protected tables/text into public data packs. |
| SAE J1979 / J1979-2 | Standard emissions diagnostic services and data model | Protocol implementation reference | Copyrighted standard. OBDb is the redistributable structured source currently used for generated standard packs. |
| OBDLink/STN documentation | Adapter AT/ST command behavior, protocol setup and performance controls | Transport implementation reference | Follow OBD Solutions terms. Do not assume undocumented commands are safe. |
| Manufacturer workshop/diagnostic databases | OEM DIDs, PIDs, routines, ECU variants and expected values | Licensed build-time import | License-dependent. Store in private, access-controlled packs unless redistribution is explicitly permitted. |
| User-verified captures | Regression fingerprints, raw responses and repaired outcomes | Research and validation | User consent required. Remove personal/location data and distinguish observations from verified formulas. |

## Import policy

1. Import only from a pinned version or immutable artifact.
2. Record SHA-256 before compilation.
3. Preserve source and data licenses separately.
4. Never infer a formula from a name alone.
5. Unknown identifiers remain raw until validated against an authoritative source or a repeatable controlled experiment.
6. Mark community definitions with lower confidence than standard/OEM definitions unless independently verified.
7. Automatic plans include only `passive` and `readOnly` definitions.
8. A write-capable database may be parsed for documentation, but transmit/routine/coding definitions are not emitted into automatic runtime packs.

## Updating generated SAE packs

The compiler supports OBDb `signalsets/v3` JSON:

```bash
python obd-bridge/tools/compile_vehicle_data_pack.py obdb \
  ./upstream/default.json \
  obd-bridge/Resources/VehicleDataPacks/core-sae-j1979.generated.diagnostic-pack.json \
  --pack-version 2026.07-obdb-<revision> \
  --source-version <immutable-revision> \
  --source-url <immutable-source-url>
```

The generated pack must then pass:

```bash
python obd-bridge/tools/validate_vehicle_data_packs.py
```

## Importing passive network databases

```bash
python obd-bridge/tools/compile_vehicle_data_pack.py network vehicle.dbc output.diagnostic-pack.json \
  --pack-id vehicle.example \
  --pack-version 1.0.0 \
  --display-name "Example vehicle CAN" \
  --source-id example.dbc \
  --source-name "Example DBC" \
  --source-version 1.0 \
  --source-kind dbc \
  --license "LICENSE-ID" \
  --attribution "Required attribution" \
  --make Example --model Model --minimum-year 2020 --maximum-year 2024
```

The compiler emits passive receive/decode definitions only. It does not emit message transmission commands.

# Professional multi-vehicle AI diagnostics architecture

## Objective

OBD Bridge is evolving from a vehicle-specific OBD reader into a read-only diagnostic acquisition platform. The application must identify the connected vehicle and ECUs, discover supported capabilities, select verified signal definitions, execute controlled measurement scenarios, preserve raw evidence, and produce a canonical snapshot for AI-assisted diagnosis.

The platform does **not** assume that one public database contains every signal for every vehicle. It combines a standards layer, runtime discovery, and versioned vehicle data packs.

## Data-source hierarchy

1. **Standard emissions diagnostics**
   - SAE J1979 / OBD-II services and signals.
   - Compiled from a pinned OBDb SAEJ1979 revision into the canonical data-pack format.
   - Provides the universal baseline: DTCs, freeze frames, readiness, vehicle identity, Mode 06 and supported live PIDs.

2. **Runtime capability discovery**
   - VIN, protocol, adapter identity, response headers, ECU names, calibration IDs, CVNs and supported-service/PID bitmaps.
   - A signal is queried only when the vehicle advertises it or a verified ECU profile explicitly declares it.
   - Unsupported or unverified responses remain raw and are never assigned an invented meaning.

3. **OEM diagnostics**
   - ASAM ODX/PDX, CDD, ARXML or licensed manufacturer definitions.
   - Used for UDS/KWP services, DIDs, routines, ECU variants, sessions and response decoding.
   - Automatic acquisition remains limited to verified passive/read-only definitions. Write, actuator, coding and adaptation operations stay blocked.

4. **Passive network signals**
   - DBC/KCD/SYM/ARXML/CDD imported through the build-time `cantools` compiler.
   - Useful for pedal channels, steering, brakes, transmission, battery, hybrid and chassis signals broadcast on accessible CAN buses.
   - Only receive/decode definitions are emitted; transmit definitions are not included in automatic plans.

5. **Community and verified captures**
   - `opendbc` and other community packs may add CAN definitions or ECU fingerprints where licensing and provenance permit.
   - Every imported definition records source, version, checksum, license and confidence.
   - Community definitions never silently override a more authoritative verified OEM definition at the same specificity.

## Runtime components

### 1. Transport adapter

The current implementation uses iOS `ExternalAccessory` and `com.obdlink` for OBDLink MX+. Future transport implementations may add BLE, Wi-Fi, USB and DoIP without changing the diagnostic domain model.

Transport responsibilities:

- establish and maintain the physical session;
- serialize requests and responses;
- enforce timeouts and backpressure;
- timestamp raw frames;
- never interpret vehicle-specific values.

### 2. Protocol engine

Protocol engines implement SAE J1979, J1979-2/UDS, ISO 14229 UDS, KWP2000, J1939 or passive CAN framing. They return normalized response records including ECU address and raw payload.

### 3. Vehicle and ECU identity resolver

The resolver creates `VehicleProfileV1` and `ECUFingerprintV1` from:

- VIN and user-confirmed make/model/year/engine;
- physical and application protocol;
- response headers and ECU addresses;
- calibration IDs, CVNs, software/hardware IDs and ECU names.

A vehicle pack is selected by a scored matcher. Calibration and ECU fingerprints are stronger than make/model/year alone.

### 4. Signal registry

`SignalRegistryV1` loads immutable JSON data packs and merges them from generic to specific. A signal definition contains:

- namespace and source;
- service, PID/DID/frame and optional signal ID;
- ECU address/header/session;
- bit layout, endianness, scaling, unit and lookup values;
- expected range and preconditions;
- preferred and maximum sampling frequency;
- safety classification;
- provenance, license and confidence.

One request may decode multiple signals. The planner coalesces these into a single physical request.

### 5. Capability resolver

The capability report distinguishes:

- verified and supported signals;
- verified but unsupported signals;
- discovered raw identifiers without definitions;
- timeouts and negative responses;
- selected data-pack versions and warnings.

This report is included in every AI snapshot so the model can distinguish “normal value,” “not supported,” “not captured,” and “unknown formula.”

### 6. Scenario and scan planner

A scenario defines phases such as:

- key-on/engine-off;
- cold start;
- warm idle;
- steady 2500 RPM;
- gentle acceleration;
- cruise;
- closed-throttle deceleration;
- gasoline versus LPG comparison;
- symptom marker window.

`ProfessionalScanPlannerV1` resolves scenario requirements to concrete signals, removes unsafe definitions, coalesces duplicate requests and balances sampling frequency against the adapter/protocol request budget. Required signals receive priority. Missing required signals are explicit and lower downstream AI confidence.

### 7. Recorder

The recorder preserves immutable evidence:

- raw request/response transcript;
- timestamped raw frames;
- decoded samples with ECU address and quality flags;
- DTCs, freeze frames and Mode 06 results;
- scenario phases, user markers and fuel mode;
- adapter/vehicle/capability metadata;
- data-pack provenance and hashes.

Large time series remain in separate CSV/JSONL/binary datasets. The manifest references them by relative path and checksum rather than embedding everything in one enormous JSON document.

### 8. AI snapshot

`AISnapshotManifestV1` is the stable contract between acquisition and analysis. It includes:

- vehicle and ECU fingerprints;
- capability report and scan plan;
- data coverage and quality metrics;
- latest normalized values;
- DTC/freeze-frame/Mode 06 evidence;
- scenario execution and symptom description;
- immutable dataset references;
- provenance and privacy notes.

The AI response is structured as ranked hypotheses with probability, confidence, supporting evidence, contrary evidence, limitations and next read-only tests. The AI must not claim that a cause is proven solely from a DTC or one out-of-range signal.

## Cloud analysis API

Recommended flow:

1. `POST /v1/diagnostic-snapshots`
   - create an upload session;
   - return pre-signed upload destinations and snapshot ID.
2. Upload raw and decoded datasets using checksums.
3. `POST /v1/diagnostic-snapshots/{id}/complete`
   - validate manifest, hashes, schemas and read-only flag.
4. `POST /v1/diagnostic-snapshots/{id}/analyses`
   - request analysis for a symptom/system.
5. `GET /v1/diagnostic-analyses/{id}`
   - return structured `AIAnalysisResponseV1`.
6. The app may request a recommended next scenario; acquisition remains local and read-only.

Server-side analysis should combine deterministic preprocessing with the language model:

- regime segmentation;
- resampling and synchronization;
- derivative/lag/correlation analysis;
- plausibility and stuck-sensor checks;
- fuel-trim and airflow/load comparisons;
- DTC/freeze-frame/Mode 06 interpretation;
- comparison with verified vehicle baselines;
- LLM synthesis only after quantitative features are generated.

## Safety boundary

Automatic mode permits only:

- passive capture;
- SAE J1979 read services 01, 02, 03, 06, 07, 09 and 0A;
- verified UDS read services such as 19 and 22;
- verified identity/session reads that have no state-changing effect.

Automatic mode blocks:

- DTC clearing;
- actuator/output-control tests;
- coding and configuration;
- adaptation reset;
- security access and key exchange;
- flashing/download/upload services;
- routines unless separately reviewed and explicitly enabled;
- brute-force DID/PID probing with unknown side effects.

## Privacy

VIN, GPS and exact timestamps can identify a person or vehicle. The upload layer must support:

- VIN hashing or redaction after vehicle-pack selection;
- optional removal of GPS/location;
- configurable timestamp precision;
- encryption in transit and at rest;
- deletion of snapshots and analysis artifacts;
- a visible list of uploaded files and retained fields.

## Development sequence

### Implemented foundation

- vehicle-agnostic domain model;
- versioned data-pack and AI-snapshot schemas;
- scored vehicle-pack matching;
- multi-signal PID/DID model;
- safe request coalescing and rate budgeting;
- OBDb and cantools build-time compiler;
- generic SAE scenarios and Mazda 5 CR regression profile;
- CI validation for schema, provenance and read-only safety.

### Next integration milestones

1. Replace the legacy Swift PID table with `SignalRegistryV1` decoding.
2. Persist complete ECU fingerprints and capability reports from the live OBDLink session.
3. Execute `DiagnosticReadPlanV1` phases through the existing prompt-driven queue.
4. Generate `ai-snapshot.json` beside the existing raw/CSV/JSONL session files.
5. Add encrypted cloud upload and structured analysis response.
6. Add licensed or verified OEM packs manufacturer by manufacturer.
7. Add passive DBC capture where the adapter and vehicle expose the required bus.
8. Build a regression corpus from known vehicles, faults and repaired outcomes.

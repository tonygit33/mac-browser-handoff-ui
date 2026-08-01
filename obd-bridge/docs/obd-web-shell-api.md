# OBD Bridge Web Shell API 1.0

## Architecture

The installed iPhone application is a durable native transport shell. It owns the `ExternalAccessory` session for `com.obdlink`, command serialization, prompt recovery, local recording, file access, background accessory mode, and the native read-only security boundary. The visible product is loaded from `OBDWebAppURL` into a full-screen `WKWebView`.

The remote page is allowed to change independently of the IPA. A bundled `obd-shell-fallback.html` provides a minimal offline interface and deterministic simulator QA.

```text
OBDLink MX+ ⇄ ExternalAccessory/EASession ⇄ AccessoryBridge
                                              ⇅
                                     NativeWebBridge 1.0
                                              ⇅
                                  window.OBDNative Promise API
                                              ⇅
                                  hosted web UI / cloud analysis
```

## JavaScript contract

```js
const result = await window.OBDNative.request(method, params)
const unsubscribe = window.OBDNative.on(eventName, payload => {})
```

### Methods

| Method | Purpose |
|---|---|
| `bridge.info` | Versioned method, event, preset, fuel, capability, and safety manifest. |
| `state.get` | Complete current connection, scan, values, DTC, file, and analysis state. |
| `accessories.refresh` | Re-read connected iOS External Accessories and advertised protocols. |
| `adapter.connect` / `adapter.disconnect` | Open or close the `com.obdlink` `EASession`. |
| `command.validate` | Check a command against the native read-only policy without sending it. |
| `command.send` | Queue one approved ELM/STN/OBD/UDS read command. Response arrives through `log` and `state` events. |
| `command.batch` | Atomically validate and queue up to 128 approved commands. |
| `scan.snapshot` | Run capability discovery, OBD modes 01/02/03/06/07/09/0A, and finite passive capture. |
| `scan.start` / `scan.stop` | Start or stop a native frequency-aware recording preset. |
| `session.marker` | Add a timestamped symptom or fuel-transition marker. |
| `session.setFuelMode` | Set `unknown`, `gasoline`, or `lpg`. |
| `log.get` / `log.clear` | Read or clear the bounded on-screen native transcript. |
| `files.list` | Recursively list app Documents metadata. |
| `files.readChunk` | Read a file in Base64 chunks up to 512 KiB for web upload without loading the whole session into memory. |
| `files.writeText` | Save up to 2 MiB under `Documents/WebData/`. |
| `files.delete` | Delete a path confined to app Documents. |
| `files.share` | Present the iOS share sheet for selected relative paths or the latest session. |
| `clipboard.write` | Copy web-generated text through the native pasteboard. |
| `haptics.impact` | Light, medium, or heavy impact feedback. |
| `app.setKeepAwake` | Keep the display awake; active native logging always wins. |
| `app.openExternal` | Open an HTTP(S) URL outside the shell. |
| `app.reload` | Reload the configured hosted web application. |

### Events

| Event | Payload |
|---|---|
| `native-ready` | Bridge manifest after a page finishes loading. |
| `state` | Debounced full native state. |
| `log` | Incremental raw transcript append. |
| `log-reset` | Replacement transcript after native clear/truncation. |

## OBDLink MX+ capability coverage

The bridge exposes the diagnostically useful read surface of the MX+ and its STN2256 family interface:

- Adapter and accessory identity: iOS accessory name/model/manufacturer/protocols, `ATI`, `STI`, `STDI`, `STIX`, `STDIX`, `STMFR`, `STSN`.
- Voltage and protocol metadata: `ATRV`, `ATDP`, `ATDPN`, `STPR`, `STPRS`, `STPBRR`.
- All legislated OBD-II transports and services used by the runtime: ISO 15765 CAN, ISO 14230 KWP2000, ISO 9141, J1850 VPW/PWM; Modes 01, 02, 03, 06, 07, 09, and 0A.
- Read-only manufacturer diagnostics: address/header/filter setup and UDS services 0x19 and 0x22 when verified vehicle data packs define the identifiers and formulas.
- CAN routing and formatting: current-session headers, receive addresses, masks, filters, flow control, CAN automatic formatting, segmentation, variable DLC, timing, baud and protocol selection.
- Additional MX+ networks: Ford MS-CAN and GM SW-CAN protocol selection; J1939 transport setup and filters when used by a verified read-only scenario.
- Passive observation: bounded `STM`/`STMA` capture and raw evidence retention.
- Local evidence: raw transcript, command JSONL, decoded CSV, summary JSON, professional samples, Mode 02/06 structures, AI snapshot, and analysis result.
- Offline operation: bundled web UI, local capture and on-device rule fallback.

## Native security boundary

The web page cannot transmit commands outside `ReadOnlyCommandPolicy`. The following categories are rejected before reaching the accessory:

- OBD Mode 04 and other fault clearing.
- UDS session/security/control/write/programming services, including 0x10, 0x14, 0x27, 0x2E, 0x2F, 0x31, and 0x34–0x37.
- Arbitrary `STPX` frames and periodic transmit configuration.
- Adapter firmware, bootloader, Bluetooth identity/pairing, NVM, calibration, GPIO-output, and other persistent configuration writes.

This deliberate boundary means that new dashboards, data packs, formulas, polling plans, reports, AI logic, and read-only vehicle scenarios are web/data changes. A new IPA is only expected if Apple changes the native platform contract, OBDLink changes the accessory protocol, or the product intentionally adds a new privileged native capability.

## Web security

- Only hosts in `OBDWebAllowedHosts` can remain inside the shell.
- Script messages are accepted only from the main frame and an allowed origin (or the bundled local fallback).
- Other HTTP(S) links open externally.
- File paths are canonicalized and confined to app Documents.
- The web page receives no general-purpose native code execution facility.

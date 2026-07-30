# OBD Bridge MVP

Read-only iPhone probe for OBDLink MX+ using Apple's `ExternalAccessory` framework and protocol `com.obdlink`.

## What this build tests

1. Whether iOS exposes the paired MX+ to this app.
2. Whether the adapter advertises `com.obdlink`.
3. Whether `EASession` opens successfully.
4. Whether MX+ replies to `ATI`.
5. Whether the vehicle replies to standard read-only OBD-II discovery commands such as `0100`, `0120`, and `0902`.

The app does not clear trouble codes, run actuators, or write vehicle configuration.

## Build

GitHub Actions generates an Xcode project with XcodeGen, builds an unsigned device app, and publishes `OBDBridge-unsigned.ipa` as a workflow artifact.

## Free installation

The unsigned IPA is intended to be signed with a free Apple ID using AltServer, SideStore, or another personal-team sideloading tool. A free signature expires after seven days and must be refreshed.

The first installation requires the iPhone to trust the Mac. After the trust pairing and Wi-Fi sync are established, later refreshes can normally be performed wirelessly while the Mac and iPhone can reach each other.

## Expected first result

A successful session should show output similar to:

```text
Opening OBDLink MX+ [MX201]
Protocols: com.obdlink
Output stream opened
→ ATI
OBDLink MX+
>
```

If the app sees the accessory but `EASession` returns `nil`, the log will state `EASession rejected`; that is the point at which manufacturer-side MFi authorization would need further investigation.

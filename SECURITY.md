# Security policy

TrailBridge VR captures game content, launches Windows processes, and can communicate with a
headset over USB or the local network. Treat unexpected network exposure, path escapes, unsafe
process execution, and capture without clear user intent as security issues.

## Supported versions

Only the latest release is supported. Security fixes are made on the default branch and reach
the app with the next release.

A release is a DMG whose app is signed ad hoc, not by Apple, and is not notarized. Download it
only from this repository's Releases page and compare its SHA-256 with the published one before
you open it.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository.
Do not open a public issue containing an exploit, credentials, device identifiers, private logs,
or captured screen content.

Include the affected revision, macOS and headset versions, reproduction steps, expected impact,
and whether the issue requires USB, LAN access, or a malicious local file. Reports are handled on
a best-effort basis; there is no guaranteed response time.

## Operational safety

- The desktop preview binds to localhost unless the user explicitly selects a LAN address.
- Wired streaming uses ADB forwards to one authorized physical device.
- In the app, Wi-Fi streaming ignores headsets the user has not allowed. The match uses the
  headset's host name, as ALVR's own trust does, and is not cryptographic.
- The streamer captures game audio only when asked to: the sound the Mac plays
  (`--game-audio mac`; macOS asks you to allow it the first time) or an explicitly selected
  loopback device. The app uses the Mac's sound by default; Settings can turn game audio off.
- Managed bottles (environments) must remain inside the configured data root.

These are intended safety boundaries, not a claim that experimental code is security audited.

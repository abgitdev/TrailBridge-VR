# Support

TrailBridge VR is an experimental project, and help is best-effort. Only the configuration and
the games listed in the [README](README.md#status) are tested; any other game, Mac, headset or
macOS version may not work.

## Where to ask

Open an issue in the [TrailBridge VR repository](https://github.com/abgitdev/TrailBridge-VR/issues)
with the matching form:

- **Bug report** for a reproducible problem in TrailBridge VR;
- **Setup or help request** when the documented setup does not complete;
- **Compatibility report** for a game, Mac or headset that works or fails;
- **Feature request** for a concrete problem and a proposed improvement.

Search existing issues first and keep one problem per issue. Report security problems privately
as described in [SECURITY.md](SECURITY.md), never in a public issue.

## What to include

- the TrailBridge VR version and build (**About TrailBridge VR**), and whether the app comes from
  the DMG or was built from source (then also the commit);
- Mac model and chip, macOS version, headset, ALVR client version, and USB or Wi-Fi;
- the game and how it was added (Steam or a folder);
- the exact steps, what you expected and what happened;
- the redacted report from **Help › Diagnostic Report…** in the app.

For problems with an app built from source, also include the output of:

```sh
./scripts/trailbridge-dev.zsh make doctor
./scripts/trailbridge-dev.zsh swift run --package-path streamer basaltctl doctor
```

For OpenXR runtime or DXMT fork build problems, also include the output of
`./scripts/trailbridge-dev.zsh make doctor-runtime` or
`./scripts/trailbridge-dev.zsh make doctor-dxmt`.

## Protect private data

Do not attach Steam or Meta credentials, headset serial numbers, game files, full Wine
environments, captured screen content, or logs that show home-folder paths. Replace user names,
device identifiers, tokens and account IDs with placeholders before posting.

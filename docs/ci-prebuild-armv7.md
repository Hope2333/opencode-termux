# CI Prebuild (armv7 only)

Phase A produces handoff assets only.

## Output scope

- armv7 Linux prebuild artifacts if upstream URLs are available
- manifest and checksums
- initial pkgfile templates

## Non-goals

- no final Termux runtime wrapping
- no final deb/pkg release claims

## Handoff contract

CI artifact bundle must include:

- `assets/`
- `manifest.json`
- `checksums.txt`
- `pkgfile-template/`
- `HANDOFF.md`

Phase B runs locally on Termux for final packaging and validation.

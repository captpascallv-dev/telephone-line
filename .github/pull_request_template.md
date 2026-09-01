## What changed

## Why

## Offline suite

- Command: `pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/Invoke-OfflineTests.ps1`
- Exit code:
- `success`:
- `assertions`:
- `residue`:

The default suite must remain offline and deterministic. No network call, no paid model, no real harness launch.

## Privacy

- [ ] No credential, absolute user path, username, machine name, private project name, or private path was added.
- [ ] Secrets remain referenced only through environment or configuration and do not enter logs, manifests, or receipts.

## Capability booleans

- [ ] No `start` / `follow_up` / `recover` / `exact_native_session` boolean changed.
- [ ] A capability boolean changed. Evidence (descriptor diff, offline proof, and why the new value is truthful):

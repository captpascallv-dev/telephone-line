# Packaging

Windows packaging commands build two deterministic zip archives from a local product tree and a machine-readable `release-manifest.json`. They never contact the network, a package registry, or a release endpoint. They do not sign, publish, upload, or install.

v0.1 is Codex-first. Packaging is transport-product distribution, not a second Lead entry and not a hosted download channel.

## The two artifacts

The redistributable set is defined once in `src/packaging/TelephonePackaging.Common.ps1` and reused by both archives and by the release manifest.

The **source archive** (`telephone-line-0.1.0-source.zip`) contains `src/` (including `src/lead-side/` and `src/dashboard/`), `schemas/`, `docs/`, `.github/`, `tests/`, and the root files `README.md`, `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `THIRD-PARTY-NOTICES.md`, and `.gitattributes`.

The **Release ZIP** (`telephone-line-0.1.0-windows.zip`) is what a user actually installs plus the license, notices, and readable docs: `src/`, `schemas/`, `docs/`, and those same six root files. It does not contain `tests/` or `.github/`. `.gitattributes` is repository metadata carried with both package forms.

Neither artifact contains `.control`, `.git`, runtime state, logs, receipts, dispatches, deliveries, caches, binaries, installer images, or anything taken from a user profile. `.control` is private control plane.

`release-manifest.json` is a repository-root file generated beside those trees. It is omitted from its own `files` list so regeneration can stay byte-identical; a file cannot carry a stable SHA-256 of its own bytes. `THIRD-PARTY-NOTICES.md` is a repository-root notice and is an entry at the root of both zips. Recipients of a zip built by these commands receive the set listed above plus `LICENSE` and `THIRD-PARTY-NOTICES.md`.

## How to build

From the product tree, write archives under a caller-supplied directory that is not the source tree unless you pass `-OutputPath` there on purpose:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/packaging/New-TelephoneSourceArchive.ps1 -OutputPath YOUR_OUTPUT_DIR
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/packaging/New-TelephoneReleaseZip.ps1 -OutputPath YOUR_OUTPUT_DIR
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/packaging/New-TelephoneReleaseManifest.ps1
```

Parameters on the archive commands: `-SourceRoot` defaults to the product tree that contains the command; `-OutputPath` is the zip file or a directory that will receive the default zip name; `-Force` replaces an existing file. The default output location is a temp directory, not the source tree. The commands refuse a reparse point, a binary that would be included, and an excluded path that would be included.

`New-TelephoneReleaseManifest.ps1` writes `release-manifest.json` at the source root when `-OutputPath` is omitted. Pass `-Force` to replace an existing file. Identity fields on the two zip artifacts stay null until a zip is actually built; this repository does not store built zips.

JSON results use `protocol_version` `telephone-line-package-result-v1` and include `ok`, `action`, `code`, `artifact` identity, and `entry_count`.

## Reproducibility

Entries are added in ascending ordinal relative-path order with forward-slash names and a fixed entry timestamp. Two runs over identical inputs produce byte-identical zips and a byte-identical `release-manifest.json`. The manifest stores no absolute path, username, machine name, wall-clock timestamp, or random id. Route ids are read from `src/catalog/routes.json`; they are not retyped.

See [install.md](install.md) for per-user install of an unpacked tree, [redistribution-audit.md](redistribution-audit.md) for the privacy and exclusion proofs, and [../THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) for the third-party inventory.

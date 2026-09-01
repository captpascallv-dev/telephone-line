# Redistribution audit

This page records what the packaging commands and the offline packaging test actually check. It is not a release, a download endpoint, or a claim that a zip has been published.

## Redistributable set

The shared resolver in `src/packaging/TelephonePackaging.Common.ps1` includes only:

- `src/`, `schemas/`, `docs/`
- `.github/` and `tests/` for the source archive and for `release-manifest.json` `files`
- root files `README.md`, `LICENSE`, `CONTRIBUTING.md`, `SECURITY.md`, `THIRD-PARTY-NOTICES.md`, `.gitattributes`. `.gitattributes` is repository metadata carried with both package forms.

It excludes `.control/`, `.git/`, `node_modules/`, `logs/`, `receipts/`, `dispatches/`, `deliveries/`, `cache/`, `caches/`, `state/`, binaries and installer images, and any path taken from a user profile. `.control` is private control plane and must not appear in an archive, in the manifest `files` list, or in any packaging artifact. Shipped Cursor external Lead examples under `docs/examples/cursor-external-lead/` and Codex app-server Lead examples under `docs/examples/codex-app-server-lead/` are placeholders only.

The offline proof `package_set_excludes_private` uses a fixture tree that deliberately contains those private paths and asserts they are absent from both the source set and the release set.

## Archives

Both zips store POSIX relative entry names, never an absolute path. `LICENSE` is an entry at the zip root. The Release ZIP contains no `tests/` and no `.github/` entry; the source archive does contain `tests/`. Two builds over identical inputs are byte-identical (`source_archive_deterministic`, `release_zip_deterministic`). Archive output is written under a temp root during tests and is not stored in this repository.

## Release manifest

`release-manifest.json` uses protocol `telephone-line-release-manifest-v1`. It records product `telephone-line`, version `0.1.0`, license `MPL-2.0`, platform `windows`, denominator 8, and the eight `route_id` values read from `src/catalog/routes.json`. Artifact identity fields are null until a zip is built. Every `files` row is a redistributable path with bytes and SHA-256; `release-manifest.json` is omitted from that list so regeneration remains stable. Regenerating over an unchanged tree is byte-identical (`manifest_deterministic`). The file validates through `Get-TelephoneSchemaPath -Name release-manifest` (`manifest_schema_valid`).

## Privacy

`redistribution_privacy_clean` scans every file this package creates, every zip entry name, and every manifest path. It rejects an absolute user path, a username, a machine name, a credential-shaped value, a private project name, and a private path. Packaging commands do not create a reparse point, junction, or symlink.

## Third-party material

[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) is the inventory. Inspection found no vendored third-party source, no `node_modules`, and no `vendor` / `third_party` directory. The DeepSea plugin `src/adapters/deepsea-common/dsh-plugin/package.json` declares no dependency keys; DSH and its bundled model library are user-installed at runtime. That is a declared dependency boundary, not redistributed material. `third_party_inventory_accurate` re-reads those facts offline.

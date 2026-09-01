# Licensing

This file explains how MPL-2.0 applies to this repository. It is not a second license. If this explanation and [LICENSE](../LICENSE) ever disagree, [LICENSE](../LICENSE) governs.

## File-level copyleft

MPL-2.0 is file-level copyleft. A file that is Covered Software stays under MPL-2.0, including modifications to that file. You may modify a covered file; the modified file remains MPL-2.0 Covered Software.

## Larger Work

A Larger Work that combines Covered Software with other files in separate files that are not Covered Software may be distributed under terms of the distributor's choice, provided the Covered Software files continue to satisfy this license. That Larger Work allowance does not relicense the covered files themselves.

## Executable Form and notices

If you distribute Covered Software in Executable Form, you must also make the Source Code Form available as MPL-2.0 requires, and you must tell recipients how to obtain that source. License notices in Covered Software must not be removed or altered in substance. Contributors must not strip the Exhibit A notice from a covered file.

## Per-file notice convention in this repository

Exhibit A permits either a notice in the file or a notice in a location a recipient would look, such as a `LICENSE` file in a relevant directory. This repository does both, as follows. This is the convention the tree actually uses; it is not an aspiration.

- PowerShell (`.ps1`) and JavaScript (`.mjs`) sources in `src/` and `tests/` carry `# SPDX-License-Identifier: MPL-2.0` as the per-file notice. They do not repeat the full Exhibit A paragraph.
- The DeepSea plugin `package.json` records `"license": "MPL-2.0"` and does not carry an Exhibit A header.
- `.gitattributes` carries the same SPDX marker as repository metadata.
- Markdown under `docs/`, JSON adapter descriptors, JSON schemas, and the route catalog do not carry a per-file Exhibit A header. They rely on the repository-root [LICENSE](../LICENSE) file, which Exhibit A explicitly permits.

The installer copies `src/`, `schemas/`, `docs/`, and `LICENSE`. `LICENSE` is a managed file at the install root and is recorded in `install-manifest.json`. Recipients who receive only an installed tree have `LICENSE` plus SPDX markers on the copied PowerShell and JavaScript sources. Recipients of this repository root have `LICENSE` plus those markers.

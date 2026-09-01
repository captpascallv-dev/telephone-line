---
name: Bug report
about: Report a telephone-line transport failure on Windows
title: ''
labels: ''
assignees: ''
---

Do not paste credentials, absolute user paths, private project content, or full transcripts.

## Environment

- Windows version:
- PowerShell version (`$PSVersionTable.PSVersion`):
- Route `route_id` (from `docs/routes.md` or the adapter descriptor):

## Failure class

- [ ] Transport (dispatch, receipt, wake, install, path resolution)
- [ ] Project work (out of scope for this product; the line does not judge it)

## Durable job identity

- `line_job_id`:
- State root described without an absolute user path (environment name or relative layout only):

## Redacted receipt

Paste a redacted `receipt.json`. Remove credentials, absolute user paths, account identifiers, prompt bodies, and private project text. Keep `protocol_version`, `line_job_id`, `route`, `transport_complete`, and public error codes.

## Expected

## Actual

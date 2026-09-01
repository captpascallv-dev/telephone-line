# Security

## Supported version

This repository's v0.1 Windows tree is the supported version. Other operating systems are not a v0.1 production target.

## How to report a vulnerability

Do not file a public issue for a vulnerability.

Use this repository's GitHub private vulnerability reporting entry under the **Security** tab. If private vulnerability reporting is temporarily unavailable, do not disclose the issue publicly; contact the repository owner through a private channel and wait for a private reporting path.

Do not attach credentials, transcripts, private project content, or unredacted absolute user paths to a report.

## Scope

In scope: transport identity handling, durable receipts and wake artifacts, install and uninstall path containment, fail-closed path resolution, adapter descriptors, and the rule that secrets must not enter logs, manifests, or receipts.

Out of scope: project-content correctness, a bug-bounty program, an SLA, a response-time promise, and a PGP key. This file does not create those.

## Posture

- No telemetry.
- The default test suite makes no network call and launches no real harness.
- Install is per-user and requires no elevation. It does not write to Program Files, HKLM, a system service, a scheduled task, or a startup entry.
- Dependency boundaries are declared rather than probed.
- Path resolution is fail-closed. Reparse points, path escape, and targets outside a trusted root are rejected.
- Credentials are referenced only through environment or configuration. They must never enter logs, manifests, or receipts.

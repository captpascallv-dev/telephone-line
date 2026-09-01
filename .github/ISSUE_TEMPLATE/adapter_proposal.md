---
name: Adapter proposal
about: Propose a community adapter. v0.1 is frozen at eight routes
title: ''
labels: ''
assignees: ''
---

Do not paste credentials, absolute user paths, private project content, or full transcripts.

## Proposed Harness

- Harness name:
- Intended role (execution, review, or a community Lead adapter):
- Declared `dependency_boundary` (what the user must already have installed; do not ask the core to probe):

## Truthful capability booleans

State each as it would appear in `adapter.json`. Do not inflate.

- `start`:
- `follow_up`:
- `recover`:
- `exact_native_session`:

## Native-session recovery evidence

Describe how start captures a native session id, how follow-up resumes that exact id, and how recover returns existing durable state without starting a replacement command. If `exact_native_session` is false, say so and explain the transport recovery that still exists.

## Frozen denominator

- [ ] I understand that v0.1 is frozen at exactly eight routes. A ninth route is a fork or a later proposal, not a v0.1 addition.

A community Lead adapter is not current capability. Inclusion still requires the unified contract, native-session recovery, Lead sleep and callback, no whole-task timeout, privacy checks, compatibility tests, and code review.

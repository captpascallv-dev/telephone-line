# Adapter authoring

This guide is for a community author who wants to add another route in their own fork. The frozen v0.1 denominator is exactly eight routes, and no ninth is planned. A ninth route is a fork or a later proposal, not a v0.1 addition.

Codex CLI is the only currently built-in Lead. Other frozen routes are execution or review sides. A community Lead adapter is welcome after passing the contract, privacy checks, compatibility tests, and code review.

## Descriptor

Publish `adapter.json` at the adapter root as a `telephone-line-adapter-v1` object. The field list and fail-closed path rules are in `docs/adapter-interface.md`; this guide does not restate that contract in full.

The loader is `Read-TelephoneAdapterDescriptor` in `src/contracts/TelephoneLine.AdapterContract.ps1`. It validates the file against `schemas/adapter.schema.json`, copies `exact_native_session` as a boolean, and resolves `windows_entrypoint` inside the same adapter root. Unknown fields are rejected. DeepSea descriptors may also declare `default_model`, `default_reasoning_effort`, and `allowed_reasoning_effort`.

## No core edit

The core does not branch on route names. It runs the frozen command from the dispatch. A new adapter attaches through the replaceable contract. Do not edit `src/core` to register a route.

## Path resolution

Callers supply a trusted adapter root. That root must be a real directory, not a reparse point.

The descriptor path and the Windows entrypoint are resolved inside that root. Relative segments may not contain `..`. A rooted path is accepted only when the resolved target still stays inside the root. Every existing path component is inspected. The load fails closed when a component is a reparse point, missing, ambiguous, a directory used as a file, or a target outside the adapter root.

`windows_entrypoint` in the descriptor is the path the contract invokes. Keep it inside the adapter directory. Shared helper scripts used by several DeepSea routes live under `src/adapters/deepsea-common` and are not a route.

## Capabilities

Advertise `start`, `follow_up`, `recover`, and `exact_native_session` as truthful booleans. `New-TelephoneAdapterInvocation` refuses an operation the descriptor does not advertise, before any process launch.

`start` must not receive a native session id. `follow_up` is exact-id only when advertised. `recover` reports existing durable transport state, must not start a replacement command, and does not imply native-session continuation.

`exact_native_session` may legitimately be `false`. Never inflate it. Loading a descriptor does not require that boolean to be `true`. The one-shot contract fixture `tests/contracts/fixtures/valid/adapter.one-shot.json` is the documented shape for `follow_up=false` and `exact_native_session=false`.

## Transport continuity

An adapter must not break the mandatory transport continuity obligations:

- immutable dispatch, receipt, and delivery identity
- callback to the exact original Lead session
- no blind rerun
- recoverable transport state
- no absolute whole-task timeout

Lead wake is not an adapter. The frozen Lead binding supplies the launcher.

## Offline mock tests

Add an offline mock test in the existing style. Do not use the network and do not call a paid model. Do not launch a real Codex, Claude, Cursor, Grok, Pi, or DSH process.

The contract fixture `tests/contracts/fixtures/mock-native-adapter.ps1` is the mock seam: it accepts `-Operation` `start` / `follow_up` / `recover`, writes a native session id into a caller-supplied store on start, and refuses overwrite or a mismatched id. Route tests under `tests/adapters/` take `-TestRoot`, keep all scratch files inside that directory, emit a JSON summary object on stdout, and exit non-zero with `success:false` on failure. Shared asserts live in `tests/adapters/AdapterTest.Common.ps1`. Child scripts are registered through `tests/adapters/Invoke-ExistingAdapterTests.ps1`.

In a fork, copy that pattern beside the new adapter. Use a mock executable and disposable files under `TestRoot` only. Clean up. Leave no residue.

## Frozen denominator

v0.1 ships exactly these eight routes. A ninth route is a fork or a later proposal, not a v0.1 addition.

- `deepsea-codex-cli`
- `deepsea-grok-cli`
- `deepsea-v4`
- `direct-claude-code`
- `direct-codex-cli`
- `direct-cursor`
- `direct-grok-cli`
- `direct-pi`

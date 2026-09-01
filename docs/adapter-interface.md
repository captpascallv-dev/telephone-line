# Adapter interface

Community adapters can be added later without editing the transport core. The core runs a frozen command from the dispatch; it does not switch on route names. v0.1 is Codex-first: the currently built-in Lead is Codex CLI. Community Lead adapters remain welcome after they pass this contract, privacy checks, compatibility tests, and code review. The frozen v0.1 denominator is exactly eight routes, and no ninth is planned.

## Descriptor

An adapter publishes a `telephone-line-adapter-v1` object:

- `route_id` — stable lowercase token
- `display_name` — human label
- `windows_entrypoint` — Windows script or executable path that stays inside the adapter root
- `dependency_boundary` — what the user must install locally
- `capabilities` — `start`, `follow_up`, `recover`, and `exact_native_session` as truthful booleans
- `default_model`, `default_reasoning_effort`, and `allowed_reasoning_effort` — optional declared DeepSea model configuration. Direct routes omit them. When present, the Windows entrypoint uses those values as the default model and reasoning effort, and `-Model` / `-ReasoningEffort` may override them.

`exact_native_session` is a per-adapter fact, not a universal gate. Loading a descriptor does not require it to be `true`. Unknown fields are rejected. Descriptor and Windows entrypoint paths are resolved from a trusted adapter root. Every existing path component is inspected; a reparse point, missing or ambiguous component, directory-as-file, or target outside that root fails closed.

## Operations

`TelephoneLine.AdapterContract.ps1` builds invocations and copies `exact_native_session` from the descriptor:

- `start` must not receive a native session id
- `follow_up` is exact-id only when advertised; an unsupported operation fails before process launch
- `recover` reports existing durable transport state, must not start a replacement command, and does not imply native-session continuation

A caller-supplied session that disagrees with the frozen value fails closed. Mandatory transport continuity remains: immutable dispatch/receipt/delivery identity, exact original Codex Lead callback, no blind rerun, recoverable transport state, and no absolute whole-task timeout.

## Lead launcher

Lead wake is not an adapter. The frozen Lead binding supplies a replaceable launcher invoked with `WorktreePath`, `PromptFile`, `ResumeSessionId`, and `RunId`. The launcher must be idempotent for that frozen wake identity: a later invoke with the same identity attaches to the existing Lead turn and must not create another. The launcher returns a run root and publishes `lead-wake-ack.json` for the exact session. After an ambiguous post-launch failure the relay recovers from that durable identity instead of starting a second turn. The core does not know provider session-file formats.

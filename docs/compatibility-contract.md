# Offline mock compatibility contract

This is the v0.1 offline mock compatibility contract for the telephone-line chain:

`dispatch -> detached execution -> durable receipt -> exact Lead wake -> next turn`

The chain is already proven by `tests/core/test_telephone_line.ps1` against the mock route and mock Lead launcher. This document names that existing coverage. It does not duplicate it. It does not claim a live Harness, a paid model, or a network call.

A conforming implementation preserves: immutable dispatch, receipt, and delivery identity; callback to the exact original Lead session; wake at most once; no blind rerun; recoverable transport state; and no absolute whole-task timeout. This contract is proven offline. No paid model call occurs. No network call occurs.

## Proving map

| stage | proving_test | proving_counter |
| --- | --- | --- |
| dispatch | tests/core/test_telephone_line.ps1 | asynchronous_lead_exit |
| detached execution | tests/core/test_telephone_line.ps1 | detached_worker_stdio |
| durable receipt | tests/core/test_telephone_line.ps1 | atomic_receipt_and_wake_ack |
| exact Lead wake | tests/core/test_telephone_line.ps1 | exact_session_wake |
| next turn | tests/core/test_telephone_line.ps1 | ambiguous_wake_at_most_once |

## Stages

### dispatch

The starter must publish a create-new dispatch, freeze the exact Lead binding session, return before the external route completes, tell Lead to exit immediately, and set `absolute_task_timeout` false.

Existing proof in `tests/core/test_telephone_line.ps1`: Lead dispatch returns before the external route completed; starter tells Lead to exit immediately; starter does not introduce an absolute task timeout; starter freezes the exact Lead binding session. The suite emits `asynchronous_lead_exit`. Related emitted counters: `exact_lead_binding` and `absolute_task_timeout` (value 0).

### detached execution

The command host and relay must run as detached Windows processes that do not keep the Lead command output pipe open. Lead must not be woken before the durable receipt exists. A duplicate line-job id must not rerun the external route.

Existing proof in `tests/core/test_telephone_line.ps1`: a hidden telephone worker does not keep the Lead command output pipe open; starter publishes `command-launch.json`; Lead is not woken before the durable route receipt exists; duplicate job id does not rerun the external route. The suite emits `detached_worker_stdio`. Related emitted counters: `duplicate_job_suppressed`, `interrupted_no_rerun`, and `automatic_rerun` (value 0).

### durable receipt

The command host must publish one create-new receipt bound to the dispatch. A successful route produces `transport_complete` true and `command_exit_code` 0. The receipt stays transport-only: `absolute_task_timeout`, `automatic_rerun`, and `project_judgment` remain false. Delivery is not published before that receipt exists.

Existing proof in `tests/core/test_telephone_line.ps1`: a successful route produces a successful durable receipt; the receipt does not cross the transport-only boundary; delivery waits until wake is acknowledged. The suite emits `atomic_receipt_and_wake_ack`. Related emitted counters: `stdin_transport` and `interrupted_no_rerun`.

### exact Lead wake

The relay must resolve the frozen original Lead session, wake that session at most once, and refuse a mismatched session id. Delivery records `lead_session_id` and a wake acknowledgment `event` of `turn.started`.

Existing proof in `tests/core/test_telephone_line.ps1`: relay resolves the exact original Lead session; delivery is published only after that wake is acknowledged; an explicit session id cannot bypass the frozen Lead binding; a wake acknowledgment for another session is rejected. The suite emits `exact_session_wake`. Related emitted counter: `exact_lead_binding`.

### next turn

The mock Lead launcher records one `turn.started` acknowledgment and one turn log line per wake identity. Concurrent relays and recovery after an ambiguous post-launch failure still produce exactly one Lead turn. This is the offline mock of the Lead's next turn. It is not a live Codex, Claude, Cursor, Grok, Pi, or DSH session.

Existing proof in `tests/core/test_telephone_line.ps1`: delivery wake acknowledgment event is `turn.started`; the launcher contract does not create a second Lead turn for the same wake identity; concurrent relays create one distinct Lead turn; an ambiguous post-launch failure still creates one Lead turn. The suite emits `ambiguous_wake_at_most_once`. Related emitted counter: `concurrent_delivery_idempotence`.

## Invariants

These invariants are preserved by the same core test. Named counters the suite emits:

- Immutable dispatch, receipt, and delivery identity: `exact_lead_binding`, `atomic_receipt_and_wake_ack`.
- Callback to the exact original Lead session: `exact_session_wake`.
- Wake at most once: `ambiguous_wake_at_most_once`.
- No blind rerun: `duplicate_job_suppressed`, `interrupted_no_rerun`, `automatic_rerun` (value 0).
- Recoverable transport state: `relay_restart`, `command_start_race_closed`.
- No absolute whole-task timeout: `absolute_task_timeout` (value 0).
- No paid model and no network: the proving test launches the current PowerShell host with `tests/core/fixtures/mock-route.ps1` and `tests/core/fixtures/mock-lead-launcher.ps1`. It does not launch a real Harness executable.

The adjacent Codex app-server Lead-side adapter is not an execution route and does not add a ninth proving stage; no ninth is planned. It binds the canonical resolved Codex executable path and bytes/hash, Codex version, generated schema identity, immutable profile identity, and `service_tier=default` into intent and run identity. After `callback_write_phase` leaves `none`, a mismatch persists `recovery_required` instead of CLI fallback. Its mock stdio fixture lives under `tests/lead-side/codex-app-server/` and is aggregated by `tests/Invoke-OfflineTests.ps1`. The five-stage map above remains the Telephone Line chain.

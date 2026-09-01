# Continuity control plane

Telephone Line keeps transport history append-only and publishes one small,
atomic current-state projection for controllers, dashboards, and recovery.
Project scope, content acceptance, and PASS remain owned by the project's
authority and exact Lead; the control plane never makes those judgments.

## Components

- `New-TelephoneWaveManifest.ps1` validates one complete high-level wave,
  freezes source and authority identities, deterministically creates the exact
  request/card/write-scaffold set, checks Direct Cursor's 1–12,000 character
  limit, and writes an immutable project/epoch/wave manifest. Zero, one, and
  many actions are always JSON arrays.
- `Start-TelephoneControlPlaneWave.ps1` is the production entry. It requires
  explicit install, supervisor-state, and dashboard-config paths, publishes
  one durable whole-batch launch intent, invokes the existing typed Telephone
  starters, and records one result row for every frozen package. No package
  can be silently omitted or added.
- `Update-TelephoneCurrentState.ps1` reduces durable job evidence into
  `current.json`, appends transition-only `events.jsonl`, updates the terminal
  history index, and publishes a compact continuation capsule atomically.
- `Invoke-TelephoneContinuityController.ps1` serializes the whole project,
  validates authority, manifest, Lead session/run, command hash, package,
  workspace, write lease, retry lineage, and postcondition before applying a
  typed action. `custom_authorized` commands are never automatic. A crash is
  reconciled from its durable effect and owner: completed effects are recorded,
  proven zero-effects may retry once with the same identity, and ambiguity is
  surfaced as a conflict instead of duplicated.
- The wired supervisor is the restart-durable continuity owner. Dispatch,
  receipt, and delivery lifecycle evidence increment a durable dirty
  generation before waking it. The supervisor acknowledges only generations
  it observed, re-drains generations written while its mutex is held, and uses
  at-logon plus one-minute periodic triggers for silent grace expiry and
  restart reconstruction. No heartbeat or online Lead is required.
- Production activation atomically registers one dashboard descriptor and
  updates the explicitly supplied dashboard config. That `current_state_file`
  is the HUD's only lifecycle input. Invalid, conflicting, or stale state is
  yellow; the dashboard exposes projection age and never scans history as a
  substitute truth source.

## Recovery behavior

Each lane is classified independently as `telephone_transport`,
`executor_session`, `shared_host`, or `state_conflict`. A `lane_recovery`
action must carry a new line-job identity, retry lineage, exact request,
workspace, and write lease for exactly one failed package. Before and after
fingerprints prove every successful lane stayed byte-identical and was never
relaunched. A dispatch with no live owner/result becomes an executor-session
failure after its bounded launch grace; malformed receipts, callback loss,
qualified start failure, and shared-host evidence are separately typed.
Wired starters enter the supervisor inbox rather than launching a job directly;
wireless starters remain explicitly bound to the App Server path. Delivery and
handled evidence bind the exact project/epoch/wave generation, Lead run,
package, batch, attempt, route, workspace, write lease, dispatch, and receipt.
Foreign or incomplete evidence is a visible conflict, never success-by-file-
existence.

The continuation capsule contains the immutable manifest/source/pointer
identities, exact Lead owner/session/run, every lane's request/card/workspace/
write lease and evidence pointers, attempt lineage, and recovery
postconditions. Each transition first writes an immutable transaction record;
`current.json`, capsule, history, and event append can therefore be rebuilt at
any write cut without resetting projection versions. Consecutive waves keep
their old manifests and history while one atomic pointer selects the current
wave.

Two-turn Lead admission is represented by manifest actions: an `admission`
action may be triggered by the bootstrap terminal, and the `second_turn`
action by the durable admission result. Both carry distinct idempotency keys;
the controller can continue them in one invocation when the first action
completes synchronously, or on the next ordinary wake without heartbeat
discovery.

## Commands

```powershell
pwsh -File src/control-plane/Start-TelephoneControlPlaneWave.ps1 -SpecFile .\wave-spec.json
pwsh -File src/control-plane/New-TelephoneWaveManifest.ps1 -SpecFile .\wave-spec.json
pwsh -File src/control-plane/Update-TelephoneCurrentState.ps1 -ManifestFile .\wave-manifest.json
pwsh -File src/control-plane/Invoke-TelephoneContinuityController.ps1 -ManifestFile .\wave-manifest.json
pwsh -File src/control-plane/Invoke-TelephoneContinuityController.ps1 -ManifestFile .\wave-manifest.json -Apply
```

Use the first command for production launch. The manifest-only command is for
preflight or packaging and does not mutate a global HUD unless the supplied
spec explicitly binds a dashboard config. The first controller command is a
read/plan pass; `-Apply` is for the installed supervisor or a reviewed manual
reconciliation.

Action state is reduced into both `current.json` and the continuation capsule
as `pending`, `running`, `completed`, `retryable_failed`, `blocked`,
`conflict`, or `exhausted`. Only `completed` suppresses later execution. One
authorized `next_wave` action must be unique and last; failed or unresolved
actions keep the current projection and HUD non-green with an exact reason.

## Open-source readiness

`src/packaging/Test-TelephoneOpenSourceReadiness.ps1` combines source parsing,
the frozen eight-route denominator, control-plane Doctor checks, privacy
scanning, the offline suite, and the single existing public-candidate
identity. It can return `READY_FOR_HUHU_CONTROL_PLANE_REVIEW`; it cannot
install, synchronize the public candidate, create a repository, or publish.

The gate requires schema-backed raw evidence bound to the exact accepted Git
head/tree and installed source identity. It recomputes P50/P95 from at least 20
cold-start samples, validates the before-session/after-prompt/after-result
failure matrix from artifact identities, and requires evidence for automatic
next-wave, Lead recovery, restart reconstruction, wired, wireless, mixed,
cancel/stop, and update/uninstall. It compares every public-candidate file and
hash with the release allowlist and rejects all extra runtime/private files.
Missing or caller-authored summary booleans cannot open the gate.

Tests that exit, restart, update, or uninstall the shared Codex host are never
automatic. They require an explicit user-selected safe window.

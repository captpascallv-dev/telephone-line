# Bundled read-only dashboard

The packaged Telephone Dashboard is a local observer. It does not dispatch work, retry a command, advance a stage, judge PASS, edit a registry, repair state, control a task, or control the wired supervisor. A color, an ack, a green transport receipt, or a dashboard refresh is not project closure.

v0.1 is Codex-first. This observer is not a ninth route and not a second Lead. The frozen denominator is exactly eight routes; no ninth is planned.

This document is a candidate description of the bundled observer. It does not claim project-owner approval of a public README and does not authorize publication.

## What you see

The watcher groups evidence by exact project plus owning Lead session and run. Multiple independent projects and disjoint jobs stay visible at the same time. Two current Telephone jobs that share a project but use different Lead sessions stay two groups. Two current jobs that share project and Lead stay one group; each job still contributes its own receipt and callback findings, so one wait is not collapsed by another. Mutex identity is the local dashboard state directory, never a Harness name.

Displayed progression is the **current** workstream. An ended interrupt leaves the regular lists only when a later job on the same project and the same Lead session (or an explicit valid successor identity) has **observed continuation**: a live command or relay owner, or, when this job has no outstanding unconsumed callback, a published receipt or delivery. An outstanding callback on this job (`CALLBACK_MISSING` or `RECEIPT_AWAITING_DELIVERY` and no delivery) stays until exact successor identity or a still-live same-obligation successor; a later same-Lead/same-stage receipt or delivery without that binding does not hide it. A later receipt on another Lead, or the same project and worktree alone, does not replace an unresolved independent obligation. Exact successor identity or a later dispatch plus binding with no owner, start, receipt, or delivery does not replace an unresolved current failure. Independent parallel lanes, live duplicate or retired-but-live owners, an unresolved current failure, and a blocked callback stay visible. Job id alone does not clear `FRESH_DIRECT_SESSION_REQUIRED`. Raw UNKNOWN records stay on disk for diagnosis; this observer does not add a history panel. A later file timestamp or a new file existing is not enough to paint the current view green.

The watcher sleeps only the remainder of the configured interval after an observation starts. A stale or failed observation does not receive a fresh healthy success timestamp.

- Lead
- execution
- explicit final audit
- correction when present
- closure
- terminal retirement

Colors:

- **green** — required public evidence is present and the lifecycle walk is legal
- **yellow** — fail-closed: missing or mismatched owner, receipt, delivery/callback, binding, skipped transition, duplicate ambiguity, stale active state, lost relay, malformed evidence, live identity disagreement, held lock, process residue, a Direct route request whose session is retired or conflicts with a required fresh session even while the owner PID is live, or a pre-prompt/`session_create` start that shows no durable prompt-acceptance progress after one bounded startup gate
- **green long execution** — after durable prompt acceptance, a live model turn stays green for any elapsed wall time; this observer does not apply a blunt task timeout
- **hidden** — the group disappeared only after exact project terminal, exact closure receipt, Lead/queue terminal-or-retired-or-idle, zero relevant live owner, held lock, or exact process residue, **and zero current fail-closed findings**. An unreadable, malformed, reparse-refused, or otherwise current yellow condition keeps one yellow group visible even after terminal artifacts exist.

The observer stays visible through nonterminal idle gaps. An idle flag on a live job is yellow, not disappearance.

## Default start, override, and opt-out

Wired `src/core/Start-TelephoneLineJob.ps1` and `src/core/Resume-TelephoneLines.ps1`, and the wireless App Server launcher/create paths, call the same `Invoke-TelephoneDashboardEnsure` entry.

Resolution order:

1. `TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT` — explicit local launcher; keep this for a private observer
2. `TELEPHONE_LINE_DASHBOARD_OPT_OUT` — `1`, `true`, `yes`, or `on` skips the bundled watcher
3. otherwise the packaged `src/dashboard/Ensure-TelephoneDashboard.ps1` is the normal default

Concurrent starters reuse one live watcher by PID plus start-time identity behind a lock file in the dashboard state root. Dashboard ensure failure is reported as `DASHBOARD_ENSURE_FAILED` and does not block dispatch.

`TELEPHONE_LINE_DASHBOARD_PROCESS_ENV_ONLY=1` limits override and opt-out lookup to this process so a nested test or host does not inherit another observer hook.

## Configuration

Point the observer at your own descriptors and StateRoots. Do not copy another machine's absolute paths.

- `TELEPHONE_LINE_DASHBOARD_STATE` — runtime directory for the watcher identity and projection (default `%LOCALAPPDATA%\TelephoneLine\dashboard-runtime`)
- `TELEPHONE_LINE_DASHBOARD_CONFIG` — `telephone-line-dashboard-config-v1` file listing descriptor files
- `TELEPHONE_LINE_STATE_ROOT` — optional extra StateRoot scanned when no config is present

A project descriptor is `telephone-line-dashboard-project-descriptor-v1` with `project`, `state_root`, and optional `lead_session_id`, `lead_run_id`, `terminal_state`, exact successor fields (`successor_lead_session_id`, `successor_line_job_id`, `successor_lead_run_id`), optional Direct-route authority (`retired_direct_session_ids`, `fresh_direct_session_required`), optional extra Direct job directories (`direct_job_roots`), one optional session-events root (`session_events_root`), and optional `supervisor_state_root`. Closure is a separate `closure.json` (`telephone-line-dashboard-closure-v1`) whose `receipt` identity must match a real receipt file.

Optional supervisor and run evidence is correlated only with the exact project plus Lead session and, when present, Lead run. Same Lead session plus project is not automatic replacement of an independent package: current-state succession requires an exact successor/current binding or the same nonempty dispatch stage (package identity). A later receipt from another stage owned by the same Lead does not hide an unresolved obligation. Blank project, session, or run identity is never a wildcard and cannot attach to another group. Mailbox Lead/batch identity under `state_root\leads` is correlated the same way: only an exact Lead session match can attach `BATCH_COLLECTING`; a foreign or empty mailbox session is not adopted. Malformed, unreadable, reparse, duplicate, mismatched, or incomplete supervisor records stay fail-closed yellow. The observer may surface `supervisor_run_id`, `supervisor_status` (`active`, `paused`, `cancelled`, `failed`, `completed`, `orphan`, `duplicate`, `version_drift`), and `paused_by_pascal`. Finding codes include `SUPERVISOR_PAUSED`, `SUPERVISOR_ORPHAN`, `SUPERVISOR_DUPLICATE`, `SUPERVISOR_VERSION_DRIFT`, `SUPERVISOR_CANCELLED`, `SUPERVISOR_FAILED`, `SUPERVISOR_PID_REUSE`, `SUPERVISOR_MISMATCH`, `SUPERVISOR_INCOMPLETE_IDENTITY`, and `BATCH_COLLECTING`. Fail-closed supervisor evidence stays yellow. Hide still uses the existing terminal, closure, and zero-residue rule. The observer never writes supervisor inbox, claimed, outbox, owner, pause, or task records, and never writes mailbox items. Legacy wired and wireless fixtures keep the same group shape when supervisor evidence is absent.

`state_root\jobs` plus every `direct_job_roots` entry feed the same project + owning Lead, with a nonempty line job id keeping independent packages on that Lead as separate current rows. Roots are unique and capped at 32. Discovery does not read contract fixtures or other files outside those roots. A present `jobs\*\dispatch.json` that is not schema-valid `telephone-line-dispatch-v1` does not become a live correlated job; the configured project stays yellow with `MALFORMED_EVIDENCE` instead of adopting a foreign protocol identity. A Telephone job and a Direct job with the same job id stay one block; they do not split. Correlation uses durable job, project, Lead, and successor evidence first; the configured `lead_session_id` filter is applied to that result. An unmatched Direct job is never forced into the current Lead merely because the descriptor names a session. A historical Direct job tied to another Lead does not create a second current project block.

When a delivered fresh Direct job or its authorized same-session correction owns the package, older failed, no-response, stale, or retired-session Direct attempts leave the current view. Ownership proof is the descriptor project plus current or successor Lead and job evidence. A successful `resume=false` job owns only its own Telephone-correlated project and Lead. A resumed correction is authorized only when the exact current or successor job id and the same non-retired session established by that lineage's successful fresh owner are both present. Job id alone or session alone is not authority. A third successful resumed job on a proven session that is not that exact job keeps `FRESH_DIRECT_SESSION_REQUIRED` and cannot retire history. An exact job on a different, unproven, mismatched, or retired session stays unowned and yellow. An older failed attempt on the same session retires only when that exact authorized successor conjunction proves supersession. The exact current failed job stays yellow with its original failure. Artifacts stay on disk. Removing or mismatching project, Lead, exact job, or session makes the unresolved failure yellow again.

Configure `session_events_root` to the parent of `<session_id>\events.jsonl`. The session folder name must be a single safe component: no separators, drive or ADS colon, `.`, `..`, trailing dot or space, or reserved Windows device names. Exact-session `turn_started` or `first_token` lines keep a live model turn green for any elapsed wall time even when the Direct job root has no lifecycle, progress, or result file. Metadata-only or system-history lines are not prompt acceptance. Wrong-session, malformed, oversized, concurrently growing, escaped, or reparse evidence is yellow, including a reparse child or unreadable listing under a configured Direct jobs root. A retired or fresh-required conflict stays yellow even when owners and accepted-turn evidence are live. Failed receipts stay yellow. Receipt and callback files are not rewritten.

Examples: [examples/dashboard/](examples/dashboard/README.md).

## Commands

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/dashboard/Ensure-TelephoneDashboard.ps1
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/dashboard/Show-TelephoneDashboard.ps1
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/dashboard/Watch-TelephoneDashboard.ps1 -StateRoot YOUR_DASHBOARD_STATE -ConfigPath YOUR_CONFIG -Once
```

`Watch-TelephoneDashboard.ps1` requires `-StateRoot`. Optional `-ConfigPath`, `-Headless`, `-Once`, and `-IntervalMilliseconds` (50–60000, default 1000). `Show-TelephoneDashboard.ps1` optional `-StateRoot` and `-ConfigPath`.

Restart reconstructs from durable artifacts. Duplicate evidence keeps the original ordinal, persists duplicate count and provenance on disk, and cannot create a second closure. Lifecycle identity includes `lead_run_id`, so otherwise identical events from two runs stay distinct. Same-provenance repetition stays one event and is informational (non-yellow) with a durable count; different, ambiguous, or unverifiable provenance is yellow and survives restart.

The public summary shows the exact line job id, stage, role, route, duplicate count, and provenance alongside project, Lead, run, phase, and findings. `final_audit` and `correction` flags come from exact job stage, role, or route evidence, not from a second invented lifecycle. Wired relay production order is `dispatched → execution → nested_target → owner_acceptance → delivered` (reducer kinds `lead → execute → sync → review → closure`); skipped or reverse transitions stay yellow.

Configured dashboard state, config, descriptor, jobs, runs, session, lifecycle, and closure paths are complete-component reparse-safe. Unreadable or refused listings stay visible yellow. A refused `TELEPHONE_LINE_DASHBOARD_STATE` path creates no file or directory through the target. Lifecycle JSONL reads use the same bounded-byte and growth check as session evidence. Projection never repairs evidence.

Watcher identity is PID plus start time bound to the exact install root and package/runtime build. Ensure reuses only a compatible live watcher. An update replaces an incompatible pre-update watcher once and keeps dashboard state. Uninstall stops that exact owned process using the durable identity even when the process command line is unavailable, and refuses PID reuse or a foreign process.

If projection, schema, config, or atomic publication fails, the watcher publishes a schema-valid yellow/stale view or retires its identity so Doctor/ensure report failure. It does not leave the last healthy view in place. Corrected input republishes automatically.

An old receipt plus relay-error with no delivery leaves the evidence on disk and stays in the current view. Exact public successor Lead/binding/job identity, a still-live same-obligation successor, or exact terminal/consumption proof removes that lineage from the current view. A later same-stage delivery that is not that successor does not. A wrong project, session, run, or job, an unbound successor, or missing terminal proof stays yellow. A successful job (receipt with delivery and no relay-error) is not retired merely because a later job exists. `BATCH_COLLECTING` is informational: it is not a current-error finding and does not keep a group visible after exact terminal retirement.

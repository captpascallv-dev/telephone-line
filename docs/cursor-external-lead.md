# Cursor external Lead compatibility

This is a lead-side compatibility profile, not an execution route and not a built-in Lead. Codex CLI remains the package's built-in Lead. The frozen v0.1 denominator is exactly eight routes, and no ninth is planned.

The profile is source-derived from the accepted Cursor External Route v1 design. It translates that topology onto the public contracts `telephone-line-dispatch-v1` and `telephone-line-lead-binding-v1`. It does not copy private control-plane protocol names, machine bindings, live evidence, or account paths into this package.

Topology:

`external Cursor Lead -> Telephone Line -> existing Direct Grok route -> durable receipt -> exact original Lead callback`

The public starter, relay, resume command, and Direct Grok adapter are reused. This profile only prepares a frozen public Lead binding and a create-new dispatch request.

## What the caller injects

No account path or default machine path is embedded. The caller supplies:

- an existing Lead run root
- the Lead worktree
- the Lead launcher script and any extra launcher arguments
- Telephone Line state root
- Direct Grok state root
- an existing dedicated empty Direct Grok scratch directory
- a prompt file
- create-new output paths for the binding and the request
- a line-job UUID and an executor job UUID

The scratch directory must be empty, free of reparse components, and neither the Lead worktree nor this product tree nor a directory that contains either. The external task may refer to separately authorized paths in its prompt. The scratch path itself is not a product-write grant.

## How the original session is derived

The Cursor compatibility profile reads the accepted durable shape under the injected run root:

- `lead-run.json` — a JSON object whose `worktree` must equal the injected Lead worktree
- `codex-events.jsonl` — JSONL records; the first non-empty `thread.started.thread_id` is the derived session

Every later non-empty `thread.started.thread_id` in that stream must equal the derived id. Ambiguity or a different id fails closed. An optional caller session may only confirm that derived id. It cannot replace it. The frozen public binding then contains that non-empty exact session, the worktree, the launcher path, and the launcher arguments. No phantom owner is invented.

## Builder, preflight, and status

Read-only preflight:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/lead-side/cursor-external-route/Invoke-CursorExternalLeadPreflight.ps1 -LeadRunRoot YOUR_LEAD_RUN_ROOT -LeadWorktree YOUR_LEAD_WORKTREE -LeadLauncher YOUR_LEAD_LAUNCHER -LineJobId YOUR_LINE_JOB_ID -ExecutorJobId YOUR_EXECUTOR_JOB_ID -TelephoneLineStateRoot YOUR_LINE_STATE_ROOT -DirectGrokStateRoot YOUR_GROK_STATE_ROOT -WorkspacePath YOUR_EMPTY_SCRATCH -PromptFile YOUR_PROMPT_FILE -BindingOutputPath YOUR_BINDING_OUTPUT -RequestOutputPath YOUR_REQUEST_OUTPUT -Project YOUR_PROJECT -Stage YOUR_STAGE -Summary YOUR_SUMMARY
```

Create-new builder (does not start Telephone Line, Direct Grok, Cursor, a model, a network request, or the Lead launcher):

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/lead-side/cursor-external-route/New-CursorExternalLeadDispatch.ps1 -LeadRunRoot YOUR_LEAD_RUN_ROOT -LeadWorktree YOUR_LEAD_WORKTREE -LeadLauncher YOUR_LEAD_LAUNCHER -LineJobId YOUR_LINE_JOB_ID -ExecutorJobId YOUR_EXECUTOR_JOB_ID -TelephoneLineStateRoot YOUR_LINE_STATE_ROOT -DirectGrokStateRoot YOUR_GROK_STATE_ROOT -WorkspacePath YOUR_EMPTY_SCRATCH -PromptFile YOUR_PROMPT_FILE -BindingOutputPath YOUR_BINDING_OUTPUT -RequestOutputPath YOUR_REQUEST_OUTPUT -Project YOUR_PROJECT -Stage YOUR_STAGE -Summary YOUR_SUMMARY
```

Optional observational status. It reports durable facts from injected source roots and never starts, resumes, cancels, reruns, or drives a route:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/lead-side/cursor-external-route/Get-CursorExternalLeadStatus.ps1 -SourcesPath YOUR_STATUS_SOURCES
```

The emitted request uses `lead.binding_file` and points at the existing Direct Grok adapter with `-Operation start`, the injected Direct Grok state root, the executor job UUID, the scratch workspace, the prompt file, and both wait values set to `0`. It does not emit Fast, priority, or ultrafast switches. It does not add automatic rerun.

## Normal start stays the public starter

After the builder writes the request, start with the existing public command. See [quick-start.md](quick-start.md). The starter result `lead_should_exit_now=true` and the relay's exact-session wake are the authoritative lifecycle. `Resume-TelephoneLines.ps1` remains the recovery entry. Status is observational only.

Known residuals remain truthful: external shared route availability may require quiescence; status is observational; there is no absolute task timeout and no blind rerun.

## What this is not

The frozen v0.1 denominator is exactly eight routes, and no ninth is planned.

- not an adapter under `src/adapters/`
- not a generic support promise for other external Leads
- not Direct Cursor Write mode, live-proof, DSH checks, or machine bindings

Placeholder request and binding shapes live under [examples/cursor-external-lead](examples/cursor-external-lead/README.md). Direct Grok remains an execution side; see [adapters/direct-grok-cli.md](adapters/direct-grok-cli.md).

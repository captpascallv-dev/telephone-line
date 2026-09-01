# Quick start

This is the shortest honest path from a clean Windows machine to one completed round trip. You are a Codex CLI Lead user attaching one execution Harness. Direct Codex CLI is an execution route invoked by that Lead, not a second built-in Lead entry.

Windows is the only v0.1 production target. The frozen denominator is exactly eight routes; no ninth is planned.

For a new Codex CLI Lead, use the App Server binding in [codex-app-server-lead.md](codex-app-server-lead.md) as the default wireless telephone. The caller-supplied CLI exec launcher is the wired cold backup for existing wired sessions or for a failed new wireless create before its first turn is accepted. Do not switch an already accepted wireless thread to wired transport; recover the same exact App Server thread instead. If the original Lead turn is still active when the receipt returns, Telephone keeps one pending callback and delivers it after that same thread is idle.

## Prerequisites and the route you pick

You need Windows PowerShell 7 or later. `Invoke-TelephoneLineDoctor.ps1` reports `platform.powershell_adequate` when `$PSVersionTable.PSVersion.Major` is at least 7, and `platform.windows_adequate` when the process is Windows.

Install Codex CLI yourself. It is the currently built-in Lead. Then pick one frozen execution or review route from [routes.md](routes.md) and satisfy that route's declared `dependency_boundary`. The catalog does not probe a local installation. Doctor reports each boundary as declared rather than probed (`boundary_declared_not_probed`).

This walkthrough uses Direct Cursor as the execution side. Its descriptor `dependency_boundary` is `cursor-agent-cli-user-installed`. You must already have Cursor Agent CLI installed. Direct Cursor is not a Lead entry. Pick a frozen route from [routes.md](routes.md).

You also supply:

- a line-job state root for `Start-TelephoneLineJob.ps1 -StateRoot`
- the current Codex CLI `session_id` and worktree
- a Lead launcher script that can resume that exact session (see [adapter-interface.md](adapter-interface.md); the launcher is caller-supplied, not an adapter)
- a prompt file whose bytes stay in that file; the line stores path, byte length, and SHA-256, not the body

## Install

From the product tree:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/install/Install-TelephoneLine.ps1
```

Parameters on `src/install/Install-TelephoneLine.ps1`:

- `-SourceRoot` — product tree that contains `src/`, `schemas/`, and `docs/`. Defaults to the tree that contains the command, or `TELEPHONE_LINE_SOURCE_ROOT`.
- `-InstallRoot` — per-user install directory. Defaults to `%LOCALAPPDATA%\TelephoneLine`, or `TELEPHONE_LINE_INSTALL_ROOT` when that variable is set.
- `-AddToPath` — opt-in per-user Path only. Without it, no environment mutation occurs.
- `-Force` — replace an existing install after verifying the manifest belongs to this product.

The command copies `src/`, `schemas/`, `docs/`, and `LICENSE` and publishes `install-manifest.json`. It also stages a versioned copy, writes `current.json`, and registers the per-user supervisor task and desktop shortcuts. It does not copy `tests/` or `.git`. It requires no elevation. A second install of the same source identity reports `code` `ALREADY_CURRENT`. Fresh success reports `code` `INSTALLED`. The JSON object uses `protocol_version` `telephone-line-install-result-v1` and includes `ok`, `action`, `status`, `code`, and `message`.

## Doctor

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/install/Invoke-TelephoneLineDoctor.ps1
```

Parameters on `src/install/Invoke-TelephoneLineDoctor.ps1`: `-InstallRoot` and `-StateRoot`. Both are optional. `-StateRoot` falls back to `TELEPHONE_LINE_STATE_ROOT`. Doctor is read-only under every flag (`read_only` is `true`). It does not launch `codex`, `claude`, `cursor-agent`, `grok`, or DSH (`harness_probed` and `harness_launched` are `false`). It reports Windows and PowerShell adequacy, install-manifest identity including drift by relative path, validity of the eight adapter descriptors, state-root reachability, in-flight job count, and supervisor task/owner/inbox/pause/version truth. Top-level `ok` is command execution success. A healthy install reports `healthy` `true` and `code` `HEALTHY`. Drift or a missing supervisor task reports `healthy` `false` while `ok` stays `true`.

## Write a first dispatch request

`src/core/Start-TelephoneLineJob.ps1` reads a request file. The request allowlist is `protocol_version`, `line_job_id`, `project`, `stage`, `role`, `route`, `summary`, `lead`, `nested_target`, `command`, and `batch`. Do not put frozen-dispatch fields such as `source_request`, `lead_binding`, `created_at_utc`, `absolute_task_timeout`, or `project_judgment` in the request; the starter writes those. A request without `batch` is an implicit `1/1` batch. Declared batches freeze `batch_id`, the exact `package_id` set, and `N`; the per-Lead mailbox closes that batch only at exact `N/N` and delivers one manifest turn.

`line_job_id` must be a lowercase UUID. `role` must be `execution` or `review`. `lead.protocol_version` must be `telephone-line-lead-binding-v1`. `command` allows `executable`, `working_directory`, `arguments`, and optional `stdin_file`.

`executable` is the Windows process image the command host launches, typically `pwsh`. `arguments` are that process's argument list. For Direct Cursor, the adapter entrypoint is `src/adapters/direct-cursor/Invoke-DirectCursorRoute.ps1` under the install root. After install, point `-File` at that installed copy.

The adapter's `-StateRoot` is a caller input on the frozen command. It is not the same parameter as `Start-TelephoneLineJob.ps1 -StateRoot`. You may point them at different directories.

Example request shape (replace the `YOUR_*` values with paths and identities you actually own; do not paste absolute user paths into issues):

```
{
  "protocol_version": "telephone-line-dispatch-v1",
  "line_job_id": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeee1",
  "project": "example-project",
  "stage": "example-stage",
  "role": "execution",
  "route": "direct-cursor",
  "summary": "first round trip",
  "lead": {
    "protocol_version": "telephone-line-lead-binding-v1",
    "session_id": "YOUR_CODEX_SESSION_ID",
    "worktree": "YOUR_WORKTREE",
    "launcher": {
      "path": "YOUR_LEAD_LAUNCHER",
      "arguments": []
    }
  },
  "command": {
    "executable": "YOUR_PWSH",
    "working_directory": "YOUR_WORKTREE",
    "arguments": [
      "-NoLogo",
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      "YOUR_INSTALLED_DIRECT_CURSOR_ENTRYPOINT",
      "-Operation",
      "start",
      "-StateRoot",
      "YOUR_ADAPTER_STATE_ROOT",
      "-WorkspacePath",
      "YOUR_WORKTREE",
      "-PromptFile",
      "YOUR_PROMPT_FILE"
    ]
  }
}
```

`Invoke-DirectCursorRoute.ps1` requires `-Operation` and `-StateRoot` for `start`, `follow_up`, and `recover`. For `start` and `follow_up` it also requires `-WorkspacePath` and `-PromptFile`. Do not pass `-NativeSessionId` on `start`. Optional adapter parameters include `-Mode` (default `ReadOnly`; also `Verify` and `Write`), `-AllowedWritePath`, `-JobId`, `-CursorTimeoutSeconds`, `-WaitTimeoutSeconds`, `-MaxOutputBytes`, and `-CursorAgentRoot`. `-Mode` `Write` requires a non-empty `-AllowedWritePath` and a linked-worktree `.git` leaf. `-Mode` `Verify` is command-capable and carries no write scope. Distinct `-Preflight` reports launchability without creating a job or model session; it grants no authority and does not replace launch-time revalidation.

## Start the job

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/core/Start-TelephoneLineJob.ps1 -RequestFile YOUR_REQUEST_FILE -StateRoot YOUR_LINE_STATE_ROOT
```

Both `-RequestFile` and `-StateRoot` are mandatory on `src/core/Start-TelephoneLineJob.ps1`. The starter validates the request, publishes a new job identity under the state root, starts the command host and relay as detached Windows processes, and returns immediately. The JSON object includes `dispatched`, `line_job_id`, `job_root`, `dispatch`, `command_owner`, `relay_owner`, `lead_should_exit_now`, `absolute_task_timeout`, and `project_judgment`.

`lead_should_exit_now` is `true`. The Lead exits immediately. It is woken later by the durable receipt through the launcher in the frozen Lead binding. `absolute_task_timeout` is `false`. `project_judgment` is `false`.

The bundled read-only dashboard is the normal default. `src/core/Start-TelephoneLineJob.ps1` and `src/core/Resume-TelephoneLines.ps1` call the same ensure entry as the wireless App Server launcher. When `TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT` is set, that launcher is used and must return JSON with `healthy=true`. When unset, `src/dashboard/Ensure-TelephoneDashboard.ps1` starts or reuses one watcher. `TELEPHONE_LINE_DASHBOARD_OPT_OUT=1` skips the bundled watcher. Ensure failure is `DASHBOARD_ENSURE_FAILED` and does not drive routing or project judgment. See [dashboard.md](dashboard.md).

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/dashboard/Ensure-TelephoneDashboard.ps1
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/dashboard/Show-TelephoneDashboard.ps1
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/dashboard/Watch-TelephoneDashboard.ps1 -StateRoot YOUR_DASHBOARD_STATE -Once
```

## Where the durable receipt and job state live

Line-job state lives at `job_root`, which is `YOUR_LINE_STATE_ROOT\jobs\<line_job_id>\`. That directory holds `dispatch.json`, `lead-binding.json`, `receipt.json`, `delivery.json`, `wake-prompt.md`, and the other job files published by the core. The durable receipt is `receipt.json`. The relay waits until that receipt exists, takes an exclusive delivery claim, and wakes the exact original Lead session at most once.

If a job is interrupted or undelivered, recover without starting a replacement command:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/core/Resume-TelephoneLines.ps1 -StateRoot YOUR_LINE_STATE_ROOT
```

`src/core/Resume-TelephoneLines.ps1` requires `-StateRoot`. Optional `-CommandStartupGraceSeconds` defaults to 30 and must be between 1 and 3600.

## Wired supervisor and Pascal control

Wired host independence uses the installed copy's per-user supervisor. `src/supervisor/Start-TelephoneWiredRun.ps1` validates one request, atomically publishes it, triggers the registered task, and returns. It does not own the run. A supervised wired Lead may start multiple batch-declared jobs; each relay enqueues into the accepted shared per-Lead mailbox and never becomes a competing sender. The collector/dispatcher for that exact Lead stays inside the supervisor-owned named Job. Cancel and emergency stop that Job, including collector and relay processes, latch pause, and preserve mailbox/partial evidence. Resume does not resurrect cancelled or completed batches. There is no wave timeout and no blind executor rerun.

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/supervisor/Start-TelephoneWiredRun.ps1 -RequestFile YOUR_SUPERVISOR_REQUEST_FILE -StateRoot YOUR_SUPERVISOR_STATE_ROOT -InstallRoot YOUR_INSTALL_ROOT
```

Parameters on `src/supervisor/Start-TelephoneWiredRun.ps1`: `-RequestFile` is mandatory. `-StateRoot` and `-InstallRoot` are optional.

Pascal control does not require Codex:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/supervisor/Invoke-TelephoneSupervisorControl.ps1 -Action status -StateRoot YOUR_SUPERVISOR_STATE_ROOT -InstallRoot YOUR_INSTALL_ROOT
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/supervisor/Invoke-TelephoneSupervisorControl.ps1 -Action cancel-one -RunId YOUR_RUN_ID -StateRoot YOUR_SUPERVISOR_STATE_ROOT
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/supervisor/Invoke-TelephoneSupervisorControl.ps1 -Action pause -StateRoot YOUR_SUPERVISOR_STATE_ROOT
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/supervisor/Invoke-TelephoneSupervisorControl.ps1 -Action emergency-stop-all -Confirm -StateRoot YOUR_SUPERVISOR_STATE_ROOT
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/supervisor/Invoke-TelephoneSupervisorControl.ps1 -Action resume -StateRoot YOUR_SUPERVISOR_STATE_ROOT
```

Parameters on `src/supervisor/Invoke-TelephoneSupervisorControl.ps1`: `-Action` is mandatory (`status`, `cancel-one`, `pause`, `emergency-stop-all`, `resume`). Optional `-RunId`, `-Confirm`, `-StateRoot`, and `-InstallRoot`. Emergency stop requires `-Confirm` and reports refused plus remaining exact runs. Resume clears intake pause, triggers the registered supervisor to process only legitimate queued work, and does not restart canceled or completed runs.

The desktop console is `src/supervisor/Show-TelephoneSupervisorControl.ps1`. Console mode lists active runs and can cancel the selected run. Emergency mode keeps explicit confirmation, count, and names. Parameters: optional `-Mode` (`Console` or `Emergency`), `-Action`, `-RunId`, `-Confirm`, `-StateRoot`, and `-InstallRoot`. Install places the emergency-stop and console shortcuts on the per-user Desktop.

## Codex app-server as a Lead-side callback

The adjacent adapter in [codex-app-server-lead.md](codex-app-server-lead.md) can persist and resume the exact Codex app-server thread and deliver the Telephone Line callback as one turn. It is a Lead-side adapter, not an execution route. The frozen denominator is exactly eight routes; no ninth is planned. Bind the installed Codex schema first (canonical resolved executable path and bytes/hash, version, generated schema identity, immutable profile identity, and default `serviceTier`), then emit an ordinary Lead binding, then keep using `Start-TelephoneLineJob.ps1`. `BindingOutputPath` and state must stay outside the product package. CLI fallback is explicit through `-CallbackTransport cli` on `New-CodexAppServerLeadBinding.ps1`. After `run.json` `callback_write_phase` leaves `none`, compatibility drift uses `recovery.json` instead of CLI fallback. Terminal publication uses `terminal_publishing` plus `terminal_target` before official `launcher-final` and `launcher-result.json`.

Before any CLI update, qualify the isolated candidate against the versioned catalog:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/lead-side/codex-app-server/Invoke-CodexAppServerCompatibilityQualification.ps1 -CodexCommand YOUR_CANDIDATE_CODEX -OutputPath YOUR_QUALIFICATION_JSON
```

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/lead-side/codex-app-server/Invoke-CodexAppServerLeadProfile.ps1 -CodexCommand YOUR_CODEX -OutputPath YOUR_PROFILE_JSON
```

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File src/lead-side/codex-app-server/New-CodexAppServerLeadBinding.ps1 -WorktreePath YOUR_WORKTREE -StateRoot YOUR_APP_SERVER_STATE_ROOT -BindingOutputPath YOUR_BINDING_JSON -CallbackTransport app-server -CodexCommand YOUR_CODEX -ProfilePath YOUR_PROFILE_JSON -PromptFile YOUR_FIRST_LEAD_PROMPT -RunId YOUR_FIRST_RUN_ID
```

The `PromptFile` plus `RunId` form is the required new-Lead activation path: one app-server process performs `thread/start` and the first `turn/start`, then publishes the binding. The ID-only form remains available for bounded binding operations but does not by itself prove that a zero-turn thread is durable across process replacement.

## Cursor as an external Lead

Codex CLI remains the built-in Lead. A caller who already has a Cursor Lead session can freeze a public Lead binding and a Direct Grok dispatch request using the adjacent profile in [cursor-external-lead.md](cursor-external-lead.md). That profile is not an execution route and not a built-in Lead. Start remains `src/core/Start-TelephoneLineJob.ps1`.

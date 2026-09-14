# Harness Telephone Line

[简体中文](docs/README.zh-CN.md)

Codex stays the Lead. Other harnesses do the heavy work. Codex sleeps while they run and resumes on the exact callback.

Telephone Line is a CLI/script-based transport layer that connects Agents and Harnesses you already use. Installation means wiring those existing tools together on your machine; it does not require building a new Agent, chat product, or desktop application.

**Recommended: ask your own Agent to read the usage and protocol documentation, then adapt and debug the setup for your local environment.** Follow the guaranteed public path in [Quick start](docs/quick-start.md): install → independent background supervisor → normal `Start-TelephoneLineJob.ps1` dispatch → original-session callback → observer. Expert lower-level entries (`Start-TelephoneWiredRun.ps1`, `Resume-TelephoneLines.ps1`, adapter recover) are distinguished there. A successful installation alone does not prove that your local dispatch and callback paths work. Verify one small task before relying on the connection.

The primary purpose is operational, not publication: in the original deployment, substantive implementation and independent review default to Telephone so every available Harness and subscription quota pool can be used. Direct in-task execution is the explicit opt-out. Open-source distribution is a secondary benefit for reuse, external feedback, and compatibility contributions.

## Who needs multi-Harness collaboration

This project is for Codex CLI users who want Codex to keep the high-value Lead work — planning, dispatch, acceptance, and advancing — while a different Harness performs long execution or review. It is especially useful when:

1. Codex is the primary subscription, but its quota is not enough for both judgment and long execution.
2. A second subscription or API already exists — such as SuperGrok, Cursor, Claude Code, PI, DSH, or another Codex account — and manual copying between sessions is wasting time.
3. Judgment and execution should use separate quota pools without turning the user into a human message relay.
4. The Lead should exit after dispatch and be woken by a durable receipt instead of waiting online.

v0.1 is Codex-first. Codex CLI is the only currently built-in Lead implemented and maintained by the original project team. Cursor, Grok/SuperGrok, PI, Claude Code, and DSH are execution or review sides, not substitute Lead entries. Direct Codex CLI is one of the eight frozen routes invoked by the Lead. It is not a second built-in Lead entry.

Codex-first is an authority model, not a branding label. Codex remains the authoritative Lead for goal alignment, task decomposition, acceptance, recovery, and final decisions. External Harnesses provide bounded execution and independent review, but never inherit project authority. This concentrates Codex's highest-value reasoning on the decisions where quality matters most while letting users reuse the tools and subscriptions they already have.

The v0.1 denominator is exactly eight routes. Each route's `dependency_boundary` is declared, not probed. The user installs that Harness; this package does not ship it.

- `deepsea-codex-cli` — DSH with a ChatGPT Plus/Pro Codex subscription
- `deepsea-grok-cli` — DSH with SuperGrok or X Premium OAuth
- `deepsea-v4` — official DeepSeek DSH
- `direct-claude-code` — Claude Code CLI
- `direct-codex-cli` — Codex CLI as an execution or review side
- `direct-cursor` — Cursor Agent CLI
- `direct-grok-cli` — official Grok CLI
- `direct-pi` — PI coding agent and Node

Direct Grok CLI uses the official CLI `--permission-mode bypassPermissions`. The `--cwd` workspace is not a sandbox; the process has the current user's rights. Isolation is an operator/Harness responsibility, not a Telephone Line sandbox or a silent permission-mode change. That guidance stays in human-facing docs; the CLI machine JSON stdout is not wrapped in a warning banner.

## Install and start ordinary work

Run these commands from the extracted product directory. Installation is per-user, requires no elevation, and defaults to `%LOCALAPPDATA%\TelephoneLine`:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\src\install\Install-TelephoneLine.ps1
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TelephoneLine\src\install\Invoke-TelephoneLineDoctor.ps1"
```

Do not dispatch work until Doctor reports `healthy=true` and `code=HEALTHY`. Telephone Line uses strict identity, path, and JSON contracts. Most users should let a local Agent generate requests from [Quick start](docs/quick-start.md), [Install](docs/install.md), [Routes](docs/routes.md), and the selected adapter documentation instead of copying another machine's absolute paths. Configure the Lead CLI with `TELEPHONE_LINE_STABLE_CLI` (an independent executable, not an App version folder); see [Install](docs/install.md).

The install also copies a companion cockpit. It is optional, not a Lead, and not a replacement for the bundled dashboard. Open it from the installed tree with `src/cockpit/Start-TelephoneCockpit.ps1`. The shipped default config has no task sources, so the window stays empty until you pass your own Telephone state or registry. Commands are in [src/cockpit/README.md](src/cockpit/README.md).

If Doctor reports `SUPERVISOR_INSTALL_VIEW_MISMATCH`, the registered task and the current process file view are not the same physical install. Bind the task, later launches, and install/state settings to the physical install Doctor already verified, using `TELEPHONE_LINE_INSTALL_ROOT` or `-InstallRoot`. Do not paste another machine's absolute path. When Doctor says the views differ, do not assume `%LOCALAPPDATA%\TelephoneLine` is the directory the scheduler reads.

If a resumable Codex Lead binding already exists, an ordinary single job uses one `telephone-line-dispatch-v1` request:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\TelephoneLine\src\core\Start-TelephoneLineJob.ps1" `
  -RequestFile "YOUR_TASK_REQUEST.json" `
  -StateRoot "YOUR_LINE_STATE_ROOT"
```

For new work, wired is the recommended default. Have the Agent create a valid `telephone-line-wired-supervisor-request-v1`, then publish it to the per-user supervisor:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\TelephoneLine\src\supervisor\Start-TelephoneWiredRun.ps1" `
  -RequestFile "YOUR_WIRED_START_REQUEST.json"
```

That supervisor request starts the owning Codex Lead; the Lead then creates the single-job requests or finite wave it owns. Installation also creates the per-user desktop controls `有线电话｜控制台` and `有线电话｜紧急停止`. Use those controls, or `Invoke-TelephoneSupervisorControl.ps1`, for status, exact-run cancellation, pause/resume, and confirmed emergency stop. Do not kill an arbitrary `pwsh`, Codex, or Harness process by PID.

For a wireless Lead, first create and freeze the real thread binding described in [Codex App Server Lead](docs/codex-app-server-lead.md). After its first turn is accepted, use that same binding for ordinary dispatch. Never switch an accepted wireless thread to wired recovery or substitute a new session for the original one.

When one phase has several non-conflicting execution lanes, start one finite wave spec instead of assembling jobs by hand:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\TelephoneLine\src\control-plane\Start-TelephoneControlPlaneWave.ps1" `
  -SpecFile "YOUR_FINITE_WAVE.json"
```

Before launch, resolve the Lead session, worktree, installed `current.json`, route, and write paths from the current machine. Keep task cards, bindings, state roots, and private project data outside the product installation. Never copy someone else's session id, absolute paths, hashes, or credentials, and do not rename a Codex thread merely to display a Telephone label. When launch returns `lead_should_exit_now=true`, end the owning Lead turn and let the supervisor, relay, and callback continue instead of waiting online.

## Why multiple Harnesses rather than merely multiple models

A Codex user attaches a different Harness because that Harness brings its own tools, permissions, sessions, workspace, context, and independent quota pools. Those are properties of the Harness, not of swapping a model name inside Codex. This is why a Codex Lead dispatches out: so Codex can sleep, and so the other Harness can spend its own quota and use its own tools, not because every Harness is an equal Lead entry.

## The pain before this project

Before a telephone line, collaboration across Harnesses meant manual relay, lost sessions, waiting online, duplicate runs, timeouts, and quota fragmentation. The Lead either sat in the session until the other side finished, or came back unable to find the exact original session and the exact prior work.

## How the telephone line solves transport continuity without judging project correctness

The telephone line is transport infrastructure only. It carries one request to an external Windows command and returns one durable result to the exact original Codex CLI Lead session. It solves transport continuity: immutable dispatch and receipt identity, exact-session callback, no blind rerun, recoverable state, and no absolute whole-task timeout. It never judges project content. Callback delivery is recorded only from durable consumption evidence for that receipt and session. Missing, conflicting, or mismatched evidence stays UNKNOWN; it is not a delivered state.

## Wireless and wired telephone

**Wired telephone** is the recommended reliable default. A per-user, Task Scheduler-created, hidden limited-user supervisor owns each run independently of the Codex desktop process remaining open. Codex validates and atomically publishes the request, triggers the registered task, and returns. The run host, Windows Job, and per-Lead FIFO mailbox continue without keeping the Lead or the desktop app online. Batch wake is keyed by a durable receipt/session/wake key: a proven same-key replay does not start a second executor or a second automatic callback. Missing writer identity, conflicting records, or missing consumption evidence stay UNKNOWN and are not treated as delivered. Automatic recovery reattaches proven same-run residue; it does not invent consumption, EOF, or a second dispatch.

**Wireless telephone** is the platform-native option. It binds the Codex CLI Lead through the official App Server protocol, publishes the exact durable thread only after the first turn is accepted, and returns results to that same thread through one FIFO callback owner. After a wireless first turn is accepted, recovery stays on that exact thread; it never silently migrates transports.

Telephone Line started with an independent wired transport, then invested in the platform-native wireless path when App Server became available. Long-running use showed that wired was more stable in this environment. Both implementations remain first-class and open: wired is recommended for reliability, while wireless remains the native-integration option. Issues and pull requests that improve wireless reliability and usability are welcome.

Codex App may show a wireless CLI Lead thread because both surfaces use the same local conversation store. It is still one thread with one active writer, not a second Lead. The safest practice is not to open or send messages in that App thread while the CLI Lead owns an active turn; use it for visibility and archive it after terminal. Desktop builds and local paths differ, so users should let their own agent adapt profile, launcher, state-root, and dashboard wiring to the machine rather than copying another user's absolute paths.

The package ships a local read-only dashboard as the normal default. Wired and wireless start/resume call one shared ensure entry so concurrent starters reuse a single watcher by PID plus start identity. A project may bind the HUD to the control plane's atomic `current.json`; when it does, the dashboard consumes that projection only and keeps append-only history out of the current error denominator. The regular view is the current workstream only: ended interrupts already replaced by a later live successor leave the lists and verdict; unstarted recovery, a current-task failure, a stuck or missing callback without this job's delivery, duplicate live owners, and independent parallel failures stay visible. Unknown or conflicting projection state is shown honestly and never guessed from historical folders. `TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT` remains an explicit observer override, and `TELEPHONE_LINE_DASHBOARD_OPT_OUT` disables the bundled watcher. The dashboard never judges project content or drives PASS. Colors, configuration, and limits are in [docs/dashboard.md](docs/dashboard.md).

Public errors stay categorical, and runtime state remains outside the package. The three-callback result proves the accepted local Windows runtime path; it is not a promise that every machine is preconfigured, and it does not itself publish a release.

## Operational recommendations learned from real use

The recommended operating shape is: use wired telephone by default; keep one Lead at a time,
with a fresh Codex Lead responsible for judgment and acceptance; let external Harnesses perform
the mechanical execution in parallel; rotate the Lead after roughly one or two
completed waves instead of carrying an indefinitely growing conversation; use
exact-session callbacks; freeze one finite wave denominator; and let the
installed control plane advance only typed, already-authorized transitions.
Successful lanes are never relaunched when one lane fails. No model waits
online, no whole-task timeout is invented, and a final independent audit is
reserved for a real major terminal.

For a governed multi-lane run, prefer
`Start-TelephoneControlPlaneWave.ps1` over hand-starting individual jobs. One
high-level spec creates the requests, cards, scaffolds, versioned manifest,
durable launch intent, supervisor registration, and unique HUD binding. The
supervisor then reacts to dispatch/receipt/delivery evidence and survives
restart; the Lead or an external heartbeat is not the continuity owner. The
recommended first deployment is one fresh wired Lead, a finite multi-lane
wave, and external Harnesses doing the mechanical work in parallel. The
supervisor owns launch and recovery, while the Lead returns only for judgment
and acceptance.

Continuity is level-triggered: lifecycle evidence increments a durable dirty
generation, the exact supervisor drains every observed generation, and a
bounded one-minute periodic trigger catches silent launch/callback grace
expiry even when no later event arrives. Failed, blocked, conflicting, or
exhausted actions remain yellow in the same current projection; they cannot be
silently skipped behind a green dashboard.

Keep these invariants: bounded package acceptance; no model waiting online;
no absolute task timeout; no blind rerun; and one final independent audit only at a major terminal.

The following practices reduce completed work getting stuck before delivery and prevent one failed lane from restarting an entire wave:

- Begin with 3–6 lanes. Increase concurrency only when workspaces, write scopes, machine capacity, and route quotas are genuinely independent.
- Give each card one finite outcome, known inputs, exact allowed write paths, expected artifacts, and an unambiguous terminal. Direct Cursor cards must remain within the 1–12,000 character contract.
- Put concurrent writers in separate worktrees and do not let them edit the same file. Parallelize mechanical search, implementation, tests, and evidence; reserve final judgment for the Lead.
- Keep large logs and artifacts in files. A callback should carry identity, terminal state, and durable paths rather than dumping full output into the Lead context.
- Freeze the exact package set and `N` at batch start. Success, explicit failure, and mechanically proven `START_FAILED` with no session are terminal envelopes; ambiguous state is not failure and must not be blindly rerun.
- If `receipt.json` exists but `delivery.json` does not, recover relay/callback first. If execution failed, recover only that lane. Never relaunch successful lanes.
- Do not impose an absolute whole-task timeout. Use bounded startup, silence, and callback grace only to inspect durable owner, receipt, delivery, and relay-error truth.
- Do not send messages from Codex App into the same task while a CLI Lead owns an active turn, and do not manually send a second result while a callback is queued.
- Observe the HUD bound to atomic `current.json`; do not infer current health from historical directories. Investigate yellow or unknown state before deleting state or rebuilding a wave.

## Add a Heartbeat to the Codex task

The Telephone supervisor owns transport continuity. A Heartbeat is an additional project observer and recovery safety net, not a high-frequency poller. Hourly is a good default; for work expected to finish within an hour, 15–30 minutes can be reasonable. More frequent checks spend more Codex quota without making the external Harness run faster.

Create a recurring Heartbeat for the **exact Codex project task** and use the following prompt. Do not share one Heartbeat across unrelated projects:

```text
This is the Telephone Line continuity Heartbeat for <project>. On every wake, perform one bounded pass and then exit; do not wait online.

1. Read the current project authority, wave manifest, control-plane current.json, and the latest dispatch, receipt, delivery, relay-error, owner, and terminal evidence. Also inspect supervisor status, Doctor, and the current HUD projection. History may explain a failure but must not override current.json.
2. Classify each anomaly as a project-content block, an executor Harness/session incident, a Telephone transport fault, or a shared-host cause. Do not disturb healthy work. If there is no ACTIVE work, report that and exit.
3. If the current wave is complete and authority already names one authorized next action, continue it idempotently. Otherwise wait for the user; do not expand scope, change acceptance, or declare PASS.
4. For transport faults, perform the smallest same-session, same-run, same-batch recovery. Recover relay/callback and proven no-effect startup first. Replace only one lane with evidence of real failure; never rerun successful lanes, rebuild the whole wave, or create duplicate callbacks. Preserve ambiguous state and report it.
5. If the cause is a reproducible general Telephone Line defect, a minimal fix and bounded verification may be prepared in an isolated branch/worktree without private project data. Show the user a sanitized reproduction, diff, and evidence; open an Issue or Pull Request only after user approval.
6. End with a short plain-language report: what was checked, the failure class, what was actually recovered or fixed, the state on exit, and whether the user must act. Do not paste large raw logs.
```

A Heartbeat never replaces callback and must not call a job failed merely because time passed. In the healthy case it confirms continuity and exits. It intervenes only when durable evidence identifies a silent gap or an already-authorized next transition.

## Let an Agent install and debug it

The easiest setup path is to give the source tree or Release ZIP to a trusted local Codex or other Agent with a bounded instruction such as:

```text
Connect the existing Harness Telephone Line scripts to my existing Codex and selected execution Harness for the current project. This is local environment setup and debugging, not a request to build another Agent or desktop application. Before changing anything, read README, docs/quick-start.md, docs/install.md, docs/routes.md, docs/adapter-interface.md, and the documentation for my selected route. Inspect the OS, PowerShell, any existing install, current.json, Doctor, the exact Codex session/worktree, and external Harness dependencies before choosing an action.

Use a per-user install and wired Lead by default. Do not request elevation or change system PATH, Codex/GitHub credentials, or external Harness configuration without my explicit approval. Keep bindings, task cards, state, and logs outside the product package. Resolve real local paths and identities; never copy sample session ids, hashes, or absolute paths.

After installation, check the actual local executable versions and paths, authentication availability without exposing secrets, permissions, launcher, state directories, and callback binding. Debug any local compatibility mismatch within this setup scope; distinguish it from a product defect. Run Doctor, then use one real, finite, reversible task to prove dispatch -> receipt -> delivery -> exact-session callback. If debugging fails, preserve evidence and distinguish executor failure from transport failure. Recover from the smallest same-session checkpoint; do not blindly rerun, delete successful envelopes, or rebuild the wave. Report the install path, version identity, Doctor result, start method, state root, task terminal, and any decision still needed from me.
```

Do not let the Agent paste credentials, full prompts, sessions, or private project logs into an Issue. It must not install or sign in to third-party Harnesses automatically, treat test success as project PASS, or rewrite historical terminals to make the dashboard look green. For a general Telephone defect, reproduce and minimally fix it in isolation, then follow [Contributing](CONTRIBUTING.md) with sanitized material.

## What it is not

The telephone line never judges scope, correctness, PASS, stage, or denominator. A green transport receipt is not project acceptance. Direct Codex CLI is an execution route, not a second Lead.

## v0.1 boundary

Windows is the only v0.1 production target. The v0.1 denominator is exactly eight routes. See [docs/routes.md](docs/routes.md).

This repository is licensed under MPL-2.0. The license text is [LICENSE](LICENSE). File-level modification expectations are in [docs/licensing.md](docs/licensing.md).

Community Lead adapters are welcome as contributions. They are not current capability and not a team commitment. A community Lead adapter is included only after it passes the unified contract, native-session recovery, Lead sleep and callback, no whole-task timeout, privacy checks, compatibility tests, and code review.

Execution consumption moves to the other Harness's independent subscription quota pool, and the Lead avoids waiting online. That is the transport fact. This README does not promise a savings figure.

## What macOS users can do

v0.1 supports Windows as its only production target. macOS users should not force-run the Windows installer or treat a successful package extraction as a working native setup.

Ask your own Agent to read the existing usage and protocol documentation first, then assess which command-line tools and scripts can run locally and which Windows-specific pieces need compatibility work. This concerns executable paths, permissions, process control, background supervision, and exact-session callback wiring. A desktop application, graphical interface, or application bundle is not a setup requirement; do not create one unless the user explicitly requests it.

Using a Windows host for Telephone Line remains an available option. If native macOS compatibility work is chosen, keep it in an isolated checkout, preserve the existing transport and session contracts, and distinguish verified local behavior from unsupported or untested behavior. Community compatibility fixes are welcome through a reviewable Pull Request; this README does not claim native macOS support.

## Current version

Current product version is **0.1.8**. After original Lead publishes this increment as GitHub Latest / tag `v0.1.8`, download:

- Windows ZIP: https://github.com/captpascallv-dev/telephone-line/releases/download/v0.1.8/telephone-line-0.1.8-windows.zip
- Source ZIP: https://github.com/captpascallv-dev/telephone-line/releases/download/v0.1.8/telephone-line-0.1.8-source.zip
- Latest page (after that tag): https://github.com/captpascallv-dev/telephone-line/releases/latest

v0.1.7 and earlier version assets remain. This increment does not overwrite them.

## Docs

- [Quick start](docs/quick-start.md)
- [v0.1.2 notes](docs/releases/v0.1.2.md)
- [v0.1.5 notes](docs/releases/v0.1.5.md)
- [v0.1.6 notes](docs/releases/v0.1.6.md)
- [v0.1.7 notes](docs/releases/v0.1.7.md)
- [v0.1.8 notes](docs/releases/v0.1.8.md)
- [Dashboard](docs/dashboard.md)
- [Continuity control plane](docs/control-plane.md)
- [Architecture](docs/architecture.md)
- [Cursor external Lead](docs/cursor-external-lead.md)
- [Codex app-server Lead](docs/codex-app-server-lead.md)
- [Adapter interface](docs/adapter-interface.md)
- [Adapter authoring](docs/adapter-authoring.md)
- [Install](docs/install.md)
- [Privacy](docs/privacy.md)
- [Routes](docs/routes.md)
- [Licensing](docs/licensing.md)
- [Packaging](docs/packaging.md)
- [Redistribution audit](docs/redistribution-audit.md)
- [Third-party notices](THIRD-PARTY-NOTICES.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)

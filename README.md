# Harness Telephone Line

Codex stays the Lead. Other harnesses do the heavy work. Codex sleeps while they run and resumes on the exact callback.

The primary purpose is operational, not publication: in the original deployment, substantive implementation and independent review default to Telephone so every available Harness and subscription quota pool can be used. Direct in-task execution is the explicit opt-out. Open-source distribution is a secondary benefit for reuse, external feedback, and compatibility contributions.

## Who needs multi-Harness collaboration

This project is for Codex CLI users who want Codex to keep the high-value Lead work — planning, dispatch, acceptance, and advancing — while a different Harness performs long execution or review. It is especially useful when:

1. Codex is the primary subscription, but its quota is not enough for both judgment and long execution.
2. A second subscription or API already exists — such as SuperGrok, Cursor, Claude Code, PI, DSH, or another Codex account — and manual copying between sessions is wasting time.
3. Judgment and execution should use separate quota pools without turning the user into a human message relay.
4. The Lead should exit after dispatch and be woken by a durable receipt instead of waiting online.

v0.1 is Codex-first. Codex CLI is the only currently built-in Lead implemented and maintained by the original project team. Cursor, Grok/SuperGrok, PI, Claude Code, and DSH are execution or review sides, not substitute Lead entries. Direct Codex CLI is one of the eight frozen routes invoked by the Lead. It is not a second built-in Lead entry.

The frozen denominator is exactly eight routes; no ninth is planned. Each route's `dependency_boundary` is declared, not probed. The user installs that Harness; this package does not ship it.

- `deepsea-codex-cli` — DSH with a ChatGPT Plus/Pro Codex subscription
- `deepsea-grok-cli` — DSH with SuperGrok or X Premium OAuth
- `deepsea-v4` — official DeepSeek DSH
- `direct-claude-code` — Claude Code CLI
- `direct-codex-cli` — Codex CLI as an execution or review side
- `direct-cursor` — Cursor Agent CLI
- `direct-grok-cli` — official Grok CLI
- `direct-pi` — PI coding agent and Node

## Why multiple Harnesses rather than merely multiple models

A Codex user attaches a different Harness because that Harness brings its own tools, permissions, sessions, workspace, context, and independent quota pools. Those are properties of the Harness, not of swapping a model name inside Codex. This is why a Codex Lead dispatches out: so Codex can sleep, and so the other Harness can spend its own quota and use its own tools, not because every Harness is an equal Lead entry.

## The pain before this project

Before a telephone line, collaboration across Harnesses meant manual relay, lost sessions, waiting online, duplicate runs, timeouts, and quota fragmentation. The Lead either sat in the session until the other side finished, or came back unable to find the exact original session and the exact prior work.

## How the telephone line solves transport continuity without judging project correctness

The telephone line is transport infrastructure only. It carries one request to an external Windows command and returns one durable result to the exact original Codex CLI Lead session. It solves transport continuity: immutable dispatch and receipt identity, exact-session callback, no blind rerun, recoverable state, and no absolute whole-task timeout. It never judges project content.

## Wireless and wired telephone

**Wired telephone** is the recommended reliable default. A per-user, Task Scheduler-created, hidden limited-user supervisor owns each run independently of the Codex desktop process. Codex validates and atomically publishes the request, triggers the registered task, and returns. The run host, Windows Job, per-Lead FIFO mailbox, and exactly-once batch wake continue without keeping the Lead or the desktop app online.

**Wireless telephone** is the platform-native option. It binds the Codex CLI Lead through the official App Server protocol, publishes the exact durable thread only after the first turn is accepted, and returns results to that same thread through one FIFO callback owner. After a wireless first turn is accepted, recovery stays on that exact thread; it never silently migrates transports.

Telephone Line started with an independent wired transport, then invested in the platform-native wireless path when App Server became available. Long-running use showed that wired was more stable in this environment. Both implementations remain first-class and open: wired is recommended for reliability, while wireless remains the native-integration option. Issues and pull requests that improve wireless reliability and usability are welcome.

Codex App may show a wireless CLI Lead thread because both surfaces use the same local conversation store. It is still one thread with one active writer, not a second Lead. The safest practice is not to open or send messages in that App thread while the CLI Lead owns an active turn; use it for visibility and archive it after terminal. Desktop builds and local paths differ, so users should let their own agent adapt profile, launcher, state-root, and dashboard wiring to the machine rather than copying another user's absolute paths.

The package ships a local read-only dashboard as the normal default. Wired and wireless start/resume call one shared ensure entry so concurrent starters reuse a single watcher by PID plus start identity. A project may bind the HUD to the control plane's atomic `current.json`; when it does, the dashboard consumes that projection only and keeps append-only history out of the current error denominator. Unknown or conflicting projection state is shown honestly and never guessed from historical folders. `TELEPHONE_LINE_DASHBOARD_ENSURE_SCRIPT` remains an explicit observer override, and `TELEPHONE_LINE_DASHBOARD_OPT_OUT` disables the bundled watcher. The dashboard never judges project content or drives PASS. Colors, configuration, and limits are in [docs/dashboard.md](docs/dashboard.md).

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

## What it is not

The telephone line never judges scope, correctness, PASS, stage, or denominator. A green transport receipt is not project acceptance. Direct Codex CLI is an execution route, not a second Lead.

## v0.1 boundary

Windows is the only v0.1 production target. The frozen denominator is exactly eight routes; no ninth is planned. See [docs/routes.md](docs/routes.md).

This repository is licensed under MPL-2.0. The license text is [LICENSE](LICENSE). File-level modification expectations are in [docs/licensing.md](docs/licensing.md).

Community Lead adapters are welcome as contributions. They are not current capability and not a team commitment. A community Lead adapter is included only after it passes the unified contract, native-session recovery, Lead sleep and callback, no whole-task timeout, privacy checks, compatibility tests, and code review.

Execution consumption moves to the other Harness's independent subscription quota pool, and the Lead avoids waiting online. That is the transport fact. This README does not promise a savings figure.

## Docs

- [Quick start](docs/quick-start.md)
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

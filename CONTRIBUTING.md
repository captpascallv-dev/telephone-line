# Contributing

v0.1 is Codex-first and Windows-only. Codex CLI is the only currently built-in Lead. Other frozen routes are execution or review sides. The frozen denominator is exactly eight routes; no ninth is planned. A ninth route is a fork or a later proposal, not a v0.1 addition.

Keep the public core small and adapters replaceable. Do not edit `src/core` to register a route. The core runs a frozen command from the dispatch; it does not switch on route names.

## Offline suite

From the repository root:

```
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/Invoke-OfflineTests.ps1
```

The default suite must stay offline and deterministic. Do not add a network call, a paid model call, or a real Codex, Claude, Cursor, Grok, Pi, or DSH process launch. Do not depend on any locally installed harness. Tests take `-TestRoot`, keep scratch files inside that directory, emit a JSON summary on stdout, and exit non-zero with `success` false on failure.

## Adapter contract

New routes attach through the replaceable contract. Follow [docs/adapter-authoring.md](docs/adapter-authoring.md) and [docs/adapter-interface.md](docs/adapter-interface.md). Advertise `start`, `follow_up`, `recover`, and `exact_native_session` as truthful booleans. Never inflate a capability. `exact_native_session` may legitimately be `false`.

## Privacy

Follow [docs/privacy.md](docs/privacy.md). Do not put credentials, prompt bodies, absolute user paths, account identifiers, or private project content into logs, manifests, receipts, wake prompts, or summaries. Secrets are referenced only through environment or configuration.

## License

Inbound contributions are MPL-2.0. See [LICENSE](LICENSE) and [docs/licensing.md](docs/licensing.md). Do not strip SPDX or Exhibit A notices from covered files.

## Community Lead adapters

Community Lead adapters are welcome. They are not current capability and not a team commitment. A community Lead adapter is included only after it passes the unified contract, native-session recovery, Lead sleep and callback, no whole-task timeout, privacy checks, compatibility tests, and code review. Direct Codex CLI remains an execution route, not a second built-in Lead entry.

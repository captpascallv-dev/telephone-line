# Direct PI

Direct PI is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The adapter discovers Node and the PI coding-agent CLI from explicit arguments or PATH. A PATH-discovered `.ps1` launcher or explicit `.ps1` target is invoked with PowerShell. A `.cmd` / `.exe` shim is invoked with its native Windows host. A JavaScript program is invoked with Node. Tests use a mock CLI seam and never read live interactive session directories.

`start` creates one session-file identity under the caller-supplied state root. `follow_up` requires that exact native session id and the saved session file. `recover` returns existing durable state without starting a replacement process. Prompt bytes are sent on stdin and are not copied into argv or request metadata. There is no absolute whole-task timeout.

`Provider`, `Model`, and `ThinkingLevel` default to `xai` / `grok-4.6` / `xhigh` for compatibility. Explicit values are written into the durable request and checked against the native result. `follow_up` keeps the same native session, session file, and model binding; a different provider/model/thinking is refused. The adapter checks the invoked executable path and content identity, then checks the native final assistant `provider`/`model` against the frozen request. Missing or mismatched native identity cannot succeed; a successful result keeps the observed assistant identity rather than copying the request labels. It does not pin a PI CLI version number.

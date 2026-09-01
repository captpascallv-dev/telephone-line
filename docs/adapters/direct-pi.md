# Direct PI

Direct PI is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The adapter discovers Node and the PI coding-agent CLI from explicit arguments or PATH. A PATH-discovered `.ps1` launcher or explicit `.ps1` target is invoked with PowerShell. A `.cmd` / `.exe` shim is invoked with its native Windows host. A JavaScript program is invoked with Node. Tests use a mock CLI seam and never read live interactive session directories.

`start` creates one session-file identity under the caller-supplied state root. `follow_up` requires that exact native session id and the saved session file. `recover` returns existing durable state without starting a replacement process. Prompt bytes are sent on stdin and are not copied into argv or request metadata. There is no absolute whole-task timeout.

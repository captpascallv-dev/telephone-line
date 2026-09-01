# Direct Claude Code

Direct Claude Code is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The adapter invokes the user-installed Claude Code CLI. Pass `-ClaudeCommand` or rely on PATH discovery. It does not pin a profile-specific executable path, set or redirect the CLI home, copy credentials, or store prompt bodies or operator session transcripts in telephone-line state. The native session id is the only identity carried forward.

`start` runs `claude -p --output-format json` with the prompt on stdin and captures the returned `session_id`. `follow_up` resumes that exact id and verifies the returned id is unchanged. `recover` returns existing durable state without rerunning the CLI. There is no absolute whole-task timeout.

The bounded terminal result and receipt retain the CLI's final `assistant_text` so a Lead can validate an exact response marker after callback. This is the final answer only, not the prompt body or an operator/session transcript; malformed or empty successful output fails closed.

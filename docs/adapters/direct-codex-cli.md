# Direct Codex CLI

Direct Codex CLI is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The adapter invokes the user-installed Codex CLI. Pass `-CodexCommand` or rely on PATH discovery. It does not pin a profile-specific executable path, set or redirect the CLI home, copy credentials, or store prompt bodies or operator session transcripts in telephone-line state. The native session id is the only identity carried forward.

`start` runs `codex exec` with the prompt on stdin and structured JSONL output, then captures the CLI's own native session id. `follow_up` runs `codex exec resume` with that exact id. `recover` returns existing durable state without rerunning the CLI. There is no absolute whole-task timeout.

`ApprovalPolicy` is forwarded through the supported `-c approval_policy=<value>` configuration override. The adapter does not emit the removed `codex exec --ask-for-approval` flag, preserving compatibility with Codex CLI `0.149.1` while keeping the requested policy explicit in durable request state.

Project-isolated non-repository workspaces must opt in with `-SkipGitRepoCheck`; the adapter freezes that boolean in the durable request and emits Codex CLI's supported `--skip-git-repo-check` flag. Repository checks remain enabled by default.

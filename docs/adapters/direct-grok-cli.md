# Direct Grok CLI

Direct Grok CLI is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The adapter invokes the official user-installed Grok CLI. Pass `-GrokCommand` or rely on PATH discovery. It does not pin a profile-specific executable path, copy the official CLI, or store prompt bodies in request metadata.

`start` creates one native Grok session. `follow_up` resumes that exact session. `recover` returns existing durable state without rerunning the CLI. There is no absolute whole-task timeout.

The adapter launches the official Grok CLI with `--permission-mode bypassPermissions`. `--cwd` is the workspace working directory, not a sandbox. The process runs with the current user's rights. Isolation is an operator and Harness responsibility. Telephone Line does not invent a sandbox, silently change that permission mode, or write a warning banner into the CLI's machine JSON stdout.

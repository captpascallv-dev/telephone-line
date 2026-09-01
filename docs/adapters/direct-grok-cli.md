# Direct Grok CLI

Direct Grok CLI is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The adapter invokes the official user-installed Grok CLI. Pass `-GrokCommand` or rely on PATH discovery. It does not pin a profile-specific executable path, copy the official CLI, or store prompt bodies in request metadata.

`start` creates one native Grok session. `follow_up` resumes that exact session. `recover` returns existing durable state without rerunning the CLI. There is no absolute whole-task timeout.

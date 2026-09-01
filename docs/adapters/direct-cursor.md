# Direct Cursor

Direct Cursor is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The adapter discovers a user-installed Cursor Agent CLI. It does not redistribute that CLI, embed an account identity, or enable Fast. Route modes are `ReadOnly`, `Verify`, and `Write`. `ReadOnly` uses the ask branch and carries no write scope. `Verify` is command-capable but always `allow_write=false`, with an empty allowlist and no linked-worktree requirement; any workspace delta is a policy failure. `Write` is command-capable, requires the explicit write switch, at least one normalized relative allowed path, and a linked-worktree `.git` leaf.

`start` captures one native Cursor session id. `follow_up` resumes that exact id with the same mode and normalized write scope. A successful model session is registered only after ordinary Cursor success; that registration is follow-up authority and is not created or updated by a policy failure.

`recover` returns existing durable state and does not start a replacement process. It resolves the latest completed transport for the opaque native session through a route recovery binding that is distinct from successful model-session registration, including a transport-complete policy terminal. Replaying the same JobId on `start` or `follow_up` is duplicate durable-state replay, not `recover`. There is no absolute whole-task timeout. Prompt files are referenced by path, byte length, and SHA-256; their bodies are not copied into adapter metadata.

A distinct `-Preflight` parameter set reports launchability against the bound runtime without creating a job, writing adapter state, launching a host, or opening a model session. A later `start` or `follow_up` independently revalidates every gate, including alias, broad-root, and sensitive-workspace rejection (the entire user AppData tree, plus `.codex` and `.ssh`), model-catalog availability, and caller-supplied account or subscription binding. The report grants no authority.

Preflight and launch both qualify the real workspace snapshot. A share-locked file is excluded only when Git independently classifies that exact relative path as ignored and it is outside every declared write lease. The adapter records each such path as `locked_gitignored_nonlease_runtime_file`, requires the exact exclusion set to remain stable before and after execution, and still fails closed for locked tracked/unignored files, locked write targets, new exclusions, reparse points, or ordinary unreadable files. This permits an active product-owned runtime to keep its ignored lock/stdout/stderr files open without weakening candidate or write-scope enforcement.

Failure results retain prompt identity plus safe `failure_kind`, `failure_code`, and `failure_stage`. The adapter never emits raw provider text, but it also must not replace an underlying capacity, rate-limit, workspace-ownership, CLI, terminal-shape, or authentication failure with a secondary missing-property exception.

Configure `StateRoot`, workspace, and prompt file explicitly. Optional `-CursorAgentRoot` selects a local install; otherwise `TELEPHONE_LINE_CURSOR_AGENT_ROOT`, otherwise a user-local `%LOCALAPPDATA%\cursor-agent` directory. Optional expected-account and expected-subscription bindings are caller-supplied.

The catalog adapter accepts a caller-supplied project-isolated `StateRoot` outside both the adapter root and execution workspace. Telephone jobs must invoke this catalog entry for isolated state; the legacy private route wrapper that confines state beneath its own route root is a different compatibility surface and is not the registered v0.1 adapter entry.

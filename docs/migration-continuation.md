# Continue a native session after an authorized installation stop

An observed partial native session may have consumed its one continuation before
an authorized installation stopped that continuation. It has neither an unused
admission nor an accepted successful binding. Do not reset the old counter,
invent a successful receipt, replay an archived collector, or create a new native
session to bypass this condition.

`src/adapters/direct-cursor/Register-DirectCursorMigrationContinuation.ps1
-ProofPath <proof.json>` validates an explicit
`telephone-line-direct-cursor-migration-proof-v1` document. The proof binds the
original Lead, native session, archived consumed admission and registry,
interrupted request and owner, current native transcript and metadata, migration
authority, stop journal, default tier, related dead owners, one new state root,
and one fixed new job ID. Each evidence item includes its absolute path, byte
count, and SHA-256. The stop journal must identify the interrupted owner by PID
and start ticks. The source job must have no receipt or accepted binding; a job
with a durable terminal must use the disposition supported by that terminal.

Registration creates a deterministic grant and a pending `migration_observed`
wrapper record in the new state root. The archive stays unchanged, with its
continuation counter at zero. This is transport admission, not product acceptance.
The grant is checked again by the public adapter:

```powershell
./src/adapters/direct-cursor/Invoke-DirectCursorRoute.ps1 `
  -Operation follow_up -NativeSessionId <original-native-id> `
  -JobId <proof-job-id> -StateRoot <proof-target-state> `
  -WorkspacePath <original-workspace> -PromptFile <current-finite-card> `
  -Mode <original-mode> -AllowedWritePath <exact-original-paths> `
  -MigrationGrantPath <registered-grant.json>
```

Use the original Lead's normal Telephone dispatch and callback. Validate the
prompt length and the existence of each declared path before dispatch. The
adapter verifies the original model, mode, workspace and exact write scope.
An exclusive create of `consumed.json` precedes the native host launch. A second
use cannot start another process. Calling the same recorded job again reads its
durable result; it does not automatically rerun interrupted work. If the process
dies between the launch claim and confirmed execution, retain that ambiguity for
an explicit disposition. Successful native execution establishes the ordinary
binding through the existing adapter completion path.

## A callback arrives before its owning Lead host exits

The relay recognizes the caller-supplied launcher refusal
`This isolated Wired Lead root already has an active run:` only when the named
old run binds the exact Lead and worktree, the launcher process exited without a
native turn, and no new target run directory exists. It saves the refusal,
launcher/prompt identities and exact old owner/CLI identities beside the wake
prompt. The existing relay waits for those processes to exit; a final file alone
does not release them. It then makes one durable launch claim and calls the same
launcher, session, prompt and deterministic run ID. Reopening a saved completed
handoff returns its result without another launch. A crash after the launch claim
with no saved result remains ambiguous and never authorizes a duplicate turn.

Unknown launcher failures and another Lead's active run are not retried. A new
competing owner at the second launch remains subject to the launcher's normal
guard. No provider job is rerun. Historical failed deliveries remain historical;
already consumed receipts use the existing trusted-consumption closeout rather
than replaying the callback.

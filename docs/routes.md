# Routes

The frozen v0.1 denominator is exactly eight routes, and no ninth is planned. Codex CLI is the only currently built-in Lead. Other frozen routes are execution or review sides. Community Lead adapters remain welcome after passing the contract, privacy checks, compatibility tests, and code review.

The catalog records `built_in_lead.route_id` as `direct-codex-cli` because Codex CLI is that built-in Lead. The field names the Codex CLI family. The Direct Codex CLI adapter remains an execution or review side, not a second Lead entry.

Each `dependency_boundary` is declared by that route's adapter descriptor. The catalog does not probe a local installation.

| route_id | display_name | family | dependency_boundary | start | follow_up | recover | exact_native_session |
| --- | --- | --- | --- | --- | --- | --- | --- |
| deepsea-codex-cli | DeepSea Codex CLI | deepsea | dsh-subscription-openai-codex-user-installed | true | false | true | false |
| deepsea-grok-cli | DeepSea Grok CLI | deepsea | dsh-subscription-xai-user-installed | true | false | true | false |
| deepsea-v4 | DeepSea V4 | deepsea | dsh-deepseek-official-user-installed | true | true | true | true |
| direct-claude-code | Direct Claude Code | direct | claude-code-user-installed | true | true | true | true |
| direct-codex-cli | Direct Codex CLI | direct | codex-cli-user-installed | true | true | true | true |
| direct-cursor | Direct Cursor | direct | cursor-agent-cli-user-installed | true | true | true | true |
| direct-grok-cli | Direct Grok CLI | direct | official-grok-cli-user-installed | true | true | true | true |
| direct-pi | Direct PI | direct | pi-coding-agent-and-node-user-installed | true | true | true | true |

# DeepSea Codex CLI

DeepSea Codex CLI is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The required shape is Codex Lead -> Telephone Line -> DSH Harness -> ChatGPT Plus/Pro Codex OAuth inside DSH -> exact original Codex Lead callback. DSH owns the agent loop, tools, permissions, workflow, and session. The subscription is model transport only. The adapter never launches Codex CLI, never launches PI coding-agent, and never copies, logs in, or exports credentials into telephone-line state.

Provider `openai-codex` is frozen for this route. Model and reasoning effort are explicit, validated, overridable configuration. The declared defaults are model `gpt-5.6-luna` and reasoning effort `high`. The allowed reasoning efforts are `minimal`, `low`, `medium`, `high`, and `xhigh`. Override them on the Windows entrypoint with `-Model` and `-ReasoningEffort`. The configured effort is written into the contained DSH headless-runner config and installed into DSH model selection so it reaches the provider call. Empty or malformed model ids, an effort outside that allowed set, and any Fast, priority, or ultrafast model variant are rejected before Headless starts. Rejections use the durable generic-error catalog and do not copy caller values into durable state.

A replaceable Cordis plugin registers that provider as a DSH `LlmAdapter` and reads a DSH-owned subscription store. The same ChatGPT Plus/Pro Codex login is reused when the community `dsh-plugin-subscriptions` plugin is installed in CLI DSH or DSH Desktop. Community login is `node src/adapters/deepsea-common/dsh-plugin/login-subscription.mjs openai-codex`. DSH creates the agent.

When a community plugin exposes multiple Codex account slots, pass the non-secret `-CommunityCredentialKey` (for example, the exact selected community store key). The adapter binds that key into the contained DSH child through `TELEPHONE_LINE_DSH_CODEX_COMMUNITY_KEY`, reads and refreshes the existing store in place, and never copies credential values into Telephone state. The generic single-account key remains `codex` when no explicit key is supplied.

`start` is supported. A correction is a new self-contained start card in a fresh DSH session. `follow_up` is not advertised until exact native resume is separately proved. `recover` returns already durable transport state and never contacts the provider. `exact_native_session` is `false`. Duplicate or incomplete start never reruns. Prompt identity in durable state is bytes and SHA-256. There is no absolute whole-task timeout.

# DeepSea Grok CLI

DeepSea Grok CLI is an execution and review side for the built-in Codex CLI Lead. It is not a Lead entry.

The required shape is Codex Lead -> Telephone Line -> DSH Harness -> SuperGrok or X Premium OAuth inside DSH -> exact original Codex Lead callback. DSH owns the agent loop, tools, permissions, workflow, and session. The subscription is model transport only. The adapter never launches Grok CLI, never launches PI coding-agent, and does not substitute `XAI_API_KEY` or separately billed API access.

Provider `xai` is frozen for this route. Model and reasoning effort are explicit, validated, overridable configuration. The declared defaults are model `grok-4.6` and reasoning effort `xhigh`. The allowed reasoning efforts are `low`, `high`, and `xhigh`. Override them on the Windows entrypoint with `-Model` and `-ReasoningEffort`. The configured effort is written into the contained DSH headless-runner config and installed into DSH model selection so it reaches the provider call. Empty or malformed model ids, an effort outside that allowed set, and any Fast, priority, or ultrafast model variant are rejected before Headless starts. Rejections use the durable generic-error catalog and do not copy caller values into durable state.

A replaceable Cordis plugin registers provider `xai` as a DSH `LlmAdapter` and reads a DSH-owned subscription store. The same SuperGrok or X Premium login is reused when the community `dsh-plugin-subscriptions` plugin is installed in CLI DSH or DSH Desktop. Community login is `node src/adapters/deepsea-common/dsh-plugin/login-subscription.mjs xai`. DSH creates the agent.

`start` is supported. A correction is a new self-contained start card in a fresh DSH session. `follow_up` is not advertised until exact native resume is separately proved. `recover` returns already durable transport state and never contacts the provider. `exact_native_session` is `false`. Duplicate or incomplete start never reruns. Prompt identity in durable state is bytes and SHA-256. There is no absolute whole-task timeout.

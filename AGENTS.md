# Working rules for the local Harness Telephone Line v0.1 candidate

- This repository is a clean public-candidate workspace. Do not copy private runtime state, prompts, logs, credentials, absolute user paths, or unpublished project material into it.
- The product is transport infrastructure only. It carries a request to an external Harness and returns the durable result to the exact original Lead session; it does not judge project content.
- Windows is the only v0.1 production target.
- Keep the public core small and adapters replaceable. Do not add a tenth route or unrelated product features.
- Paid-model and live-Harness tests must use disposable fixtures. The default test suite and CI must remain offline and deterministic.
- No public GitHub creation, push, release, deployment, or announcement is authorized from this workspace.


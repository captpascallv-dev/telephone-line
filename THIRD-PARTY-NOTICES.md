# Third-party notices

This file is an inventory of third-party material **redistributed by this repository**. It is not a second license. [LICENSE](LICENSE) remains MPL-2.0 for this project's Covered Software.

## Redistributed third-party material

This repository **vendors no third-party source**, assets, or bundled dependency directory. Inspection of the product tree found:

- no `node_modules` directory
- no `vendor`, `third_party`, or `third-party` directory
- no copied third-party license file besides this project's own [LICENSE](LICENSE)
- one plugin manifest, `src/adapters/deepsea-common/dsh-plugin/package.json`, with `"license": "MPL-2.0"` and with no `dependencies`, `devDependencies`, `optionalDependencies`, `peerDependencies`, or `bundledDependencies` keys

Files under `src/adapters/deepsea-common/dsh-plugin/` are this project's own MPL-2.0 sources. They load user-installed packages at runtime; they do not embed those packages. Files under `src/lead-side/cursor-external-route/` are also this project's own MPL-2.0 sources. That lead-side profile is source-derived from an accepted design; it does not vendor third-party code.

## Declared dependency boundaries (not redistributed)

These are user-installed prerequisites. The telephone line does not ship them, does not vendor them, and does not need a third-party notice for them. Adapter descriptors record each `dependency_boundary` as declared rather than probed.

| Boundary | Who installs it |
| --- | --- |
| `codex-cli-user-installed` | Codex CLI, by the user |
| `claude-code-user-installed` | Claude Code, by the user |
| `cursor-agent-cli-user-installed` | Cursor Agent CLI, by the user |
| `official-grok-cli-user-installed` | the official Grok CLI, by the user |
| `pi-coding-agent-and-node-user-installed` | PI coding agent and Node, by the user |
| `dsh-subscription-openai-codex-user-installed` | DSH plus ChatGPT Plus/Pro Codex subscription OAuth, by the user |
| `dsh-subscription-xai-user-installed` | DSH plus SuperGrok or X Premium OAuth, by the user |
| `dsh-deepseek-official-user-installed` | official DeepSeek DSH, by the user |

The DeepSea plugin resolves user-installed DSH and DSH's bundled `@earendil-works/pi-ai` model library at runtime, only under `DSH_HOME`, the user DSH home, or the DSH Desktop harness home. It does not walk `process.cwd()` or load PI coding-agent. Those packages are not present in this tree. PI coding-agent is not a DeepSea subscription prerequisite.

## CI pin (not redistributed)

`.github/workflows/ci.yml` references a pinned GitHub Actions checkout action for GitHub-hosted offline CI. That action's source is not copied into this repository. Recipients who run GitHub Actions fetch it at workflow time. That is not redistributed material.

## What a zip recipient receives

The source archive and the Release ZIP contain this project's redistributable set, `LICENSE`, and this notices file. See [docs/packaging.md](docs/packaging.md) and [docs/redistribution-audit.md](docs/redistribution-audit.md).

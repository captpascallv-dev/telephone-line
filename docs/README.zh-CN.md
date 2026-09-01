# Harness Telephone Line（多 Harness 电话线）

[English](../README.md)

让 Codex 继续当总指挥，把耗时执行交给其他 Harness；任务完成后，再沿原会话准确叫醒 Codex 收卷。

## 这是什么

Telephone Line 是一套面向 Codex CLI 的跨 Harness 协作基础设施。

它解决的不是“换一个模型”，而是让不同智能体运行环境真正接力：Codex 负责目标判断、拆包、派发、验收和继续推进；Cursor、Claude Code、Grok、PI、DSH 或另一套 Codex 环境负责长时间执行与独立审查。派发完成后，Codex 可以退出，不必一直在线等待；外部任务完成后，结果会通过持久化回执回到原来的 Codex Lead 会话。

一条完整链路是：

`Codex Lead → 持久化任务 → 外部 Harness 执行 → 终态回执 → 原会话回叫 → Codex 验收并继续`

Telephone Line 的首要价值是日常生产协作。开源的意义在于让更多人复用、反馈问题并共同改善兼容性，而不是为了展示一个演示项目。

## 什么人会用到

如果你有下面任意一种情况，这套工具可能适合你：

1. Codex 是主要工作入口，但不想让它同时承担长时间执行、审查和在线等待。
2. 你已经订阅了 Cursor、SuperGrok、Claude Code、DSH 或其他开发工具，却还在人工复制任务和结果。
3. 你希望“负责判断的 Lead”和“负责干活的执行端”使用不同的工具、上下文与额度池。
4. 你希望任务即使跑很久，也能在完成后准确回到原会话，而不是重新解释上下文。
5. 多路并行时，你需要失败的那一路单独恢复，已经成功的任务绝不重复执行。

## 为什么不是在 Codex 里换个模型

Harness 不只是模型名称。每个 Harness 都有自己的工具、权限、会话、工作区、上下文和订阅额度。

把模型 A 换成模型 B，并不会自动得到 Cursor 的编辑环境、Claude Code 的工具链、Grok 的订阅池或另一套 Codex 会话。Telephone Line 做的是跨运行环境派发，让外部 Harness 真正使用自己的能力和额度完成工作，再把结果送回 Codex。

因此，v0.1 仍然是 **Codex-first**：

- Codex CLI 是当前唯一内置并由项目维护的 Lead。
- Cursor、Grok、PI、Claude Code 和 DSH 是执行或审查端，不是第二个内置 Lead。
- `direct-codex-cli` 也是一条执行路线，不代表又增加了一个 Lead 入口。

## 有线电话和无线电话怎么选

两种方式都保留，也都属于正式能力；区别在于运行生命周期不同。

| | 有线电话 | 无线电话 |
| --- | --- | --- |
| 推荐定位 | 默认可靠方案 | 平台原生接入方案 |
| 核心机制 | 每用户 Windows 计划任务、隐藏 supervisor、独立 run host 与 Windows Job | Codex 官方 App Server 协议与原生线程绑定 |
| Codex 退出后 | 已派发任务继续在后台运行 | 依赖 App Server 与原线程恢复链路 |
| 回叫方式 | 每个 Lead 的 FIFO 邮箱，批量且仅回叫一次 | 同一原生线程的一条 FIFO 回叫链 |
| 适合场景 | 长任务、Codex 桌面可能关闭或升级、优先追求稳定 | 更看重平台原生体验，愿意共同改进兼容性 |

项目最早先实现了独立的有线方案。App Server 出现后，我们投入更多时间做了平台原生无线方案，希望它更贴近 Codex、也更可靠；长期使用后，当前环境里仍然是有线电话更稳定。因此，**建议默认使用有线电话**，无线电话则继续作为正式的原生集成路线开放维护。欢迎通过 Issue 或 Pull Request 改善无线电话的稳定性和使用体验。

有线电话由独立 supervisor 持有任务。Codex 完成请求校验并原子发布后即可退出；计划任务会启动 run host，后续由 Windows Job、每 Lead FIFO 邮箱和 exactly-once 批量回叫共同保证续跑与收卷。它不要求 Codex Lead 或桌面 App 一直在线。

无线电话会在首轮真正被 Codex 接受后，才把任务绑定到那个确切线程。后续恢复始终回到同一线程，不会暗中改走另一种传输方式。

## 当前支持的八条执行路线

v0.1 的路线分母固定为八条，没有计划为了凑数量增加第九条。每条路线只声明依赖边界，不会替用户探测或安装外部 Harness。

- `deepsea-codex-cli`：通过 DSH 使用 ChatGPT Plus / Pro 的 Codex 订阅。
- `deepsea-grok-cli`：通过 DSH 使用 SuperGrok 或 X Premium OAuth。
- `deepsea-v4`：官方 DeepSeek DSH。
- `direct-claude-code`：Claude Code CLI。
- `direct-codex-cli`：Codex CLI 执行或审查端。
- `direct-cursor`：Cursor Agent CLI。
- `direct-grok-cli`：官方 Grok CLI。
- `direct-pi`：PI coding agent 与 Node。

外部 Harness 及其订阅由用户自行准备；Telephone Line 不捆绑第三方程序，也不替第三方能力背书。

## 连续推进是怎么保证的

Telephone Line 只负责运输连续性，不负责判断项目做得对不对。

它提供的保证包括：

- 派发与回执身份不可混淆；
- 结果只回到原来的 Codex Lead 会话；
- 同一批任务可以从缺失或失败的包继续，不盲目重跑成功任务；
- 状态落盘，可在进程或机器重启后重建；
- 不给整个长任务设置武断的总超时；
- 失败、阻塞、冲突和重试耗尽会继续显示，不能躲在绿灯后面。

连续性采用 level-triggered（电平触发）机制：生命周期事件会推进持久化 generation，supervisor 负责把所有尚未确认的 generation 依次处理完；同时保留一分钟的有限周期触发，用来兜住没有后续事件的静默超时。这个周期触发是恢复兜底，不是轮询式重复执行。

多路正式任务建议从 `Start-TelephoneControlPlaneWave.ps1` 启动，而不是手工逐条拉线。一个有限 wave spec 会一次生成请求、执行卡、脚手架、版本化 manifest、持久化 launch intent、supervisor 注册和唯一 HUD 绑定。之后由 supervisor 根据 dispatch、receipt 和 delivery 证据推进；Lead 只在需要判断和验收时回来。

## 仪表盘告诉你什么

安装包内置一个本地只读仪表盘，作为默认观察入口。有线和无线启动时都会调用同一套 ensure 逻辑，并通过 PID 与启动身份复用唯一 watcher，避免重复开监控进程。

项目可以把 HUD 绑定到控制面的原子 `current.json`。绑定后，当前状态只从这一份投影读取，历史记录不会重新混入当前错误分母。未知、冲突或缺失状态会如实显示，不会从旧目录猜一个绿灯。

仪表盘只观察运输与连续性，不判断项目内容，也不能宣布 PASS。颜色、配置和限制见 [Dashboard 文档](dashboard.md)。

## 一个需要注意的 Codex App 现象

无线 CLI Lead 可能会出现在 Codex App 的任务列表中，因为 CLI 与桌面 App 使用同一套本地会话存储。它仍然是同一个线程，不是第二个 Lead。

当 CLI Lead 正在持有活动回合时，最安全的做法是只把 App 里的对应任务当作观察入口，不要同时打开并发送消息；任务终态后再归档即可。不同 Codex Desktop 版本和电脑路径可能不同，应让本机智能体按实际环境适配 profile、launcher、state root 和 dashboard wiring，不要照抄别人的绝对路径。

## 推荐的实际用法

经验上，最稳定的协作方式是：

1. 默认选择有线电话。
2. 每次只保留一个正式 Lead，由它负责判断、验收和收尾。
3. 把检索、实现、测试、证据整理等机械工作并行交给外部 Harness。
4. 每轮先冻结有限任务分母，互不冲突的包再并行派发。
5. Lead 完成一到两个 wave 后及时换新，不让单个会话无限增长。
6. 只恢复失败或缺失的包，已经成功的路线永不重跑。
7. 只有真正的大阶段终点才安排一次新鲜独立审计，不为每个小修重复造审核链。

## 它不负责什么

Telephone Line 不判断：

- 任务范围是否正确；
- 实现质量是否合格；
- 项目是否可以 PASS；
- 当前阶段是否应该结束；
- 验收分母是否完整。

绿色运输回执只说明结果安全送到了，不等于项目验收通过。项目判断始终属于 Lead 或项目自己的审查机制。

它也不承诺一个固定的“节省额度比例”。执行消耗会转移到外部 Harness 自己的订阅或额度池，Codex Lead 则省去长时间在线等待；这是运行机制，不是收益保证。

## v0.1 边界

- 仅支持 Windows 生产环境。
- 固定八条执行路线。
- 同时提供源码包和 Windows Release ZIP。
- 提供 PowerShell 安装、更新、Doctor 与卸载流程。
- 外部 Harness 依赖由用户自行安装。
- 许可证为 MPL-2.0，详见 [LICENSE](../LICENSE) 与 [许可说明](licensing.md)。

想开始使用，请先看：

- [快速开始](quick-start.md)
- [安装与升级](install.md)
- [路线说明](routes.md)
- [控制面](control-plane.md)

## 欢迎怎样的贡献

社区可以贡献新的 Harness adapter、其他平台移植、兼容性更新、文档与安装器改进。

新的 Lead adapter 不是当前已承诺能力。它只有在通过统一契约、原生会话恢复、Lead 休眠与回叫、无整任务总超时、隐私检查、兼容性验证和代码审查后，才会进入正式支持范围。

## 完整文档

- [快速开始](quick-start.md)
- [仪表盘](dashboard.md)
- [连续推进控制面](control-plane.md)
- [架构](architecture.md)
- [Cursor 外部 Lead](cursor-external-lead.md)
- [Codex App Server Lead](codex-app-server-lead.md)
- [Adapter 接口](adapter-interface.md)
- [Adapter 开发](adapter-authoring.md)
- [安装](install.md)
- [隐私](privacy.md)
- [路线](routes.md)
- [许可](licensing.md)
- [打包](packaging.md)
- [再分发审计](redistribution-audit.md)
- [第三方声明](../THIRD-PARTY-NOTICES.md)
- [贡献指南](../CONTRIBUTING.md)
- [安全策略](../SECURITY.md)

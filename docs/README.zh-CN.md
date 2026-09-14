# Harness Telephone Line（多 Harness 电话线）

[English](../README.md)

让 Codex 继续当总指挥，把耗时执行交给其他 Harness；任务完成后，再沿原会话准确叫醒 Codex 收卷。

## 这是什么

Telephone Line 是一套面向 Codex CLI 的跨 Harness 协作基础设施。

它通过命令行工具和脚本接入你已经在用的 Agent 与 Harness。安装的目标是把现有工具在本机接通，不需要另建一个 Agent、聊天产品或桌面应用。

**建议让你自己的 Agent 先读使用说明和协议，再完成本机环境适配与调试。** 公开推荐路径见 [Quick start](quick-start.md)：安装 → 独立后台 supervisor → 正常 `Start-TelephoneLineJob.ps1` 派发 → 原会话回叫 → 观察器。有线 `Start-TelephoneWiredRun.ps1`、Resume、适配器 recover 是专家下层入口，不是第一用户路径。安装成功不等于本机的派发和回叫已经走通；请按下方[安装调试指令](#让-agent-代为安装和调试)，先跑通一个小任务再正式使用。

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

Codex-first 不是一句品牌口号，而是一套 authority 分工。Codex 始终是负责目标对齐、任务拆分、验收、恢复与最终决策的权威 Lead。外部 Harness 承担有限执行和独立审查，但不继承项目决策权。这样可以让 Codex 的高价值推理集中在真正影响质量的判断环节，同时复用用户已有的工具和订阅。

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
| 回叫方式 | 每个 Lead 的 FIFO 邮箱，按 durable key 去重 | 同一原生线程的一条 FIFO 回叫链 |
| 适合场景 | 长任务、Codex 桌面可能关闭或升级、优先追求稳定 | 更看重平台原生体验，愿意共同改进兼容性 |

项目最早先实现了独立的有线方案。App Server 出现后，我们投入更多时间做了平台原生无线方案，希望它更贴近 Codex、也更可靠；长期使用后，当前环境里仍然是有线电话更稳定。因此，**建议默认使用有线电话**，无线电话则继续作为正式的原生集成路线开放维护。欢迎通过 Issue 或 Pull Request 改善无线电话的稳定性和使用体验。

有线电话由独立 supervisor 持有任务。Codex 完成请求校验并原子发布后即可退出；计划任务会启动 run host，后续由 Windows Job 和每 Lead FIFO 邮箱继续，不必保持 Codex Lead 或桌面 App 进程在线。批量回叫按持久化 receipt/session/wake key 去重：已证明的同一 key 不会再启动执行端，也不会再发一次自动回叫。缺少 writer 身份、记录冲突或没有真实消费证据时保持 UNKNOWN，不能当成已送达。自动恢复只接回已证明属于同一 run 的残留，不会编造消费、EOF 或第二次派发。

无线电话会在首轮真正被 Codex 接受后，才把任务绑定到那个确切线程。后续恢复始终回到同一线程，不会暗中改走另一种传输方式。

## 当前支持的八条执行路线

v0.1 的路线分母固定为八条。每条路线只声明依赖边界，不会替用户探测或安装外部 Harness。

- `deepsea-codex-cli`：通过 DSH 使用 ChatGPT Plus / Pro 的 Codex 订阅。
- `deepsea-grok-cli`：通过 DSH 使用 SuperGrok 或 X Premium OAuth。
- `deepsea-v4`：官方 DeepSeek DSH。
- `direct-claude-code`：Claude Code CLI。
- `direct-codex-cli`：Codex CLI 执行或审查端。
- `direct-cursor`：Cursor Agent CLI。
- `direct-grok-cli`：官方 Grok CLI。
- `direct-pi`：PI coding agent 与 Node。

Direct Grok CLI 会以官方 CLI 的 `--permission-mode bypassPermissions` 启动。`--cwd` 工作区不是沙箱，进程使用当前用户权限；隔离是操作者和 Harness 的责任。Telephone Line 不会发明沙箱、不会悄悄改权限模式，也不会往 CLI 的机器 JSON stdout 写入警告横幅。

外部 Harness 及其订阅由用户自行准备；Telephone Line 不捆绑第三方程序，也不替第三方能力背书。

## 安装和常规启动

下面命令都从解压后的产品目录运行。安装不需要管理员权限，默认进入当前用户的 `%LOCALAPPDATA%\TelephoneLine`：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\src\install\Install-TelephoneLine.ps1
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\TelephoneLine\src\install\Invoke-TelephoneLineDoctor.ps1"
```

Doctor 返回 `healthy=true` 和 `code=HEALTHY` 后再派任务。Telephone Line 使用严格的身份、路径和 JSON 契约，普通用户通常不需要手写请求文件；让本机 Agent 根据 [快速开始](quick-start.md)、[安装说明](install.md)、[路线说明](routes.md) 和对应 adapter 文档生成，会比复制别人的绝对路径安全。Lead CLI 请用 `TELEPHONE_LINE_STABLE_CLI` 指向独立可执行文件，不要指向 App 版本目录；详见 [安装说明](install.md)。

安装目录里还有可选的驾驶舱窗口，不是 Lead，也不替代自带看板。从已安装树运行 `src/cockpit/Start-TelephoneCockpit.ps1`。随包默认配置没有任务来源，不传本机状态目录时窗口是空的。命令见 [src/cockpit/README.md](../src/cockpit/README.md)。

如果 Doctor 报告 `SUPERVISOR_INSTALL_VIEW_MISMATCH`，说明已登记的计划任务和当前进程看到的安装目录不是同一物理位置。请按 Doctor 已核实的物理安装来绑定任务、后续启动和安装/状态设置，使用 `TELEPHONE_LINE_INSTALL_ROOT` 或 `-InstallRoot`。不要复制别人的绝对路径；当 Doctor 指出视图不一致时，不要假定 `%LOCALAPPDATA%\TelephoneLine` 就是计划任务实际读取的目录。

已经有可恢复的 Codex Lead binding 时，普通单任务使用一个 `telephone-line-dispatch-v1` 请求：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\TelephoneLine\src\core\Start-TelephoneLineJob.ps1" `
  -RequestFile "你的任务请求.json" `
  -StateRoot "你的线路状态目录"
```

新建任务时建议默认使用有线 Lead。让 Agent 生成合法的 `telephone-line-wired-supervisor-request-v1`，再交给每用户 supervisor：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\TelephoneLine\src\supervisor\Start-TelephoneWiredRun.ps1" `
  -RequestFile "你的有线启动请求.json"
```

这份 supervisor 请求启动的是拥有任务的 Codex Lead；随后由 Lead 生成自己负责的单任务请求或有限 wave。安装还会在当前用户桌面创建 `有线电话｜控制台` 和 `有线电话｜紧急停止`。查看状态、精确取消某个 run、暂停/恢复或确认紧急停止时，请使用这些入口或 `Invoke-TelephoneSupervisorControl.ps1`，不要按一个 PID 随便结束 `pwsh`、Codex 或 Harness 进程。

需要无线 Lead 时，先按 [Codex App Server Lead](codex-app-server-lead.md) 创建并冻结真实线程 binding；首轮真正被接受后，再用同一个 binding 派发普通任务。不要把已经接受的无线线程临时改成有线，也不要用一个新会话冒充原会话恢复。

同一阶段有多条互不冲突的执行路线时，使用有限 wave spec 一次启动，不要手工逐条拼装：

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File "$env:LOCALAPPDATA\TelephoneLine\src\control-plane\Start-TelephoneControlPlaneWave.ps1" `
  -SpecFile "你的有限波次.json"
```

启动前请特别确认：Lead session、worktree、installed `current.json`、执行路线和写入路径都来自本机实时状态；任务卡、binding、状态目录和真实项目资料放在产品安装目录之外；不要复制他人的 session id、绝对路径或凭据，也不要为了显示“电话线”而重命名 Codex 会话。启动命令返回 `lead_should_exit_now=true` 后，Lead 应结束当前回合，让 supervisor、relay 和 callback 接管，而不是继续在线等待。

## 连续推进是怎么保证的

Telephone Line 只负责运输连续性，不负责判断项目做得对不对。

它提供的保证包括：

- 派发与回执身份不可混淆；
- 结果只回到原来的 Codex Lead 会话；
- 同一批任务可以从缺失或失败的包继续，不盲目重跑成功任务；
- 状态落盘，可在进程或机器重启后重建；
- 不给整个长任务设置武断的总超时；
- 失败、阻塞、冲突和重试耗尽会继续显示，不能躲在绿灯后面。

回叫是否送达，只按该 receipt 与原会话的持久化消费证据记录。证据不足、互相冲突或身份不匹配时保持 UNKNOWN，不能当成已送达。

连续性采用 level-triggered（电平触发）机制：生命周期事件会推进持久化 generation，supervisor 负责把所有尚未确认的 generation 依次处理完；同时保留一分钟的有限周期触发，用来兜住没有后续事件的静默超时。这个周期触发是恢复兜底，不是轮询式重复执行。

多路正式任务建议从 `Start-TelephoneControlPlaneWave.ps1` 启动，而不是手工逐条拉线。一个有限 wave spec 会一次生成请求、执行卡、脚手架、版本化 manifest、持久化 launch intent、supervisor 注册和唯一 HUD 绑定。之后由 supervisor 根据 dispatch、receipt 和 delivery 证据推进；Lead 只在需要判断和验收时回来。

## 仪表盘告诉你什么

安装包内置一个本地只读仪表盘，作为默认观察入口。有线和无线启动时都会调用同一套 ensure 逻辑，并通过 PID 与启动身份复用唯一 watcher，避免重复开监控进程。

项目可以把 HUD 绑定到控制面的原子 `current.json`。绑定后，当前状态只从这一份投影读取，历史记录不会重新混入当前错误分母。未知、冲突或缺失状态会如实显示，不会从旧目录猜一个绿灯。

仪表盘只观察运输与连续性，不判断项目内容，也不能宣布 PASS。已结束且被后继接替的项退出常规列表；当前失败、未启动恢复、卡住或缺失且本 job 无 delivery 的回叫、重复活跃 owner 与独立并行失败仍可见。颜色、配置和限制见 [Dashboard 文档](dashboard.md)。

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

下面这些做法能明显减少“任务做完了却交不了卷”或“某一路卡住后整轮重来”：

- 单轮通常先开 3–6 路；只有工作区、写入范围、机器容量和路线额度都彼此独立时再增加并行度。
- 每张任务卡只保留一个有限目标、确定输入、允许写入路径、预期产物和清晰终态。Direct Cursor 的卡片必须控制在 1–12,000 个字符内。
- 多个写入者使用不同 worktree，并避免同时修改同一文件；机械检索、实现、测试和证据可以并行，最终判断只留给 Lead。
- 大段日志和产物留在文件中，回叫只带身份、终态和持久化路径，避免把整份输出塞回 Lead 上下文。
- 批次一开始就冻结准确的包集合和 `N`。成功、明确失败和能够证明根本没启动的 `START_FAILED` 都是终态信封；状态不明不能伪装成失败，更不能盲目重跑。
- 如果已经有 `receipt.json` 但没有 `delivery.json`，优先恢复 relay/callback；如果执行端失败，只恢复那一路。已经成功的路线永不重跑。
- 不给整项任务设置绝对总超时。只对启动、静默和回叫使用有限 grace，用持久化 owner、receipt、delivery 和 relay-error 判断真实状态。
- CLI Lead 持有活动回合时，不要同时在 Codex App 的同一任务里发送消息；回叫正在排队时也不要手工再发一份结果。
- 日常看绑定到原子 `current.json` 的 HUD，不用历史目录猜当前状态。黄色或未知应先定位身份和缺失证据，不要直接删状态重建整轮。

## 给 Codex 会话设置一个 Heartbeat

Telephone 自己的 supervisor 才是运输连续性的所有者；Heartbeat 是额外的项目观察与恢复保险，不应变成高频轮询器。一般建议每小时唤醒一次；预计一小时内结束的短任务可改为每 15–30 分钟一次。频率越高，Codex 额度消耗越大，却不会让 Harness 本身执行得更快。

在 Codex 中为**确切的项目任务**创建定时 Heartbeat，并把下面文字作为提示词。不要把一个 Heartbeat 混用于多个无关项目：

```text
这是 <项目名> 的 Telephone Line 持续推进 Heartbeat。每次唤醒只做一轮有限检查，然后立即结束，不在线等待。

1. 先读取本项目当前 authority、wave manifest、控制面的 current.json，以及最新 dispatch、receipt、delivery、relay-error、owner 和 terminal；同时查看 supervisor status、Doctor 和 HUD 当前投影。历史记录只用于追因，不能覆盖 current.json。
2. 把异常分成项目内容阻塞、执行 Harness/会话偶发故障、Telephone 运输故障或共同宿主外因。健康任务不干预；没有 ACTIVE 任务就报告后结束。
3. 已完成且 authority 已明确授权唯一下一步时，按原分母继续推进；没有明确授权就停在等待，不自行扩范围、改验收口径或宣布 PASS。
4. 运输故障只做同一 session、同一 run、同一 batch 的最小恢复。优先恢复 relay/callback 和可证明未生效的启动；只替换证据明确失败的单一路线，绝不重跑成功路线、重建整轮或制造重复回叫。状态有歧义时保留现场并报告。
5. 若定位为可复现的通用 Telephone Line 问题，可在隔离分支/worktree 做最小修复和有界验证，不夹带项目私有数据。向用户展示脱敏后的复现、改动和验证结果；得到用户确认后再提交 Issue 或 Pull Request，未经授权不自动发布。
6. 最后用简短人话报告：检查了什么、异常属于哪一类、实际恢复或修复了什么、任务离开本轮时的状态、是否需要用户处理。不要粘贴大段原始日志。
```

Heartbeat 不能替代 callback，也不能因为“时间到了”就判定失败。正常情况下，它只会确认运输健康并退出；真正出现静默卡点时，才利用已经落盘的证据从最小断点恢复。

## 让 Agent 代为安装和调试

最省事的方式，是把源码目录或 Release ZIP 交给本机 Codex/其他可信 Agent，并给它一条边界清楚的指令：

```text
请把现有 Harness Telephone Line 脚本接入我本机已有的 Codex 和所选执行 Harness，完成当前项目的环境适配与调试。这不是新建 Agent 或桌面应用的需求。先完整读取 README、docs/quick-start.md、docs/install.md、docs/routes.md、docs/adapter-interface.md，以及我选择路线的文档；先检查操作系统、PowerShell、现有安装、current.json、Doctor、Codex session/worktree 和外部 Harness 依赖，再决定动作。

默认使用当前用户安装和有线 Lead，不申请管理员权限，不修改系统级 PATH、Codex/GitHub 凭据或外部 Harness 配置，除非我明确同意。所有 binding、任务卡、状态和日志放在产品包之外；使用本机真实路径和身份，不照抄示例中的 session id、哈希或绝对路径。

安装后检查本机实际的程序版本与路径、登录可用性（不暴露凭据）、权限、启动器、状态目录和回叫绑定。对本机兼容差异在安装配置范围内调试，并与产品缺陷区分；随后运行 Doctor，再用一个真实、有限、可回滚的小任务完成 dispatch → receipt → delivery → 原会话 callback。调试失败时保留现场，先区分执行故障和运输故障；从同一 session 的最小断点恢复，不盲目重跑，不删除成功信封，不重建整轮。最后告诉我安装位置、版本身份、Doctor 结果、启动方式、状态目录、任务终态和仍需我决定的事项。
```

让 Agent 调试时还应注意：不要把隐私文件、凭据、完整 prompt、session 或真实项目日志贴进 Issue；不要自动安装或登录第三方 Harness；不要把测试绿灯当成项目 PASS；不要为了“修好看起来的状态”修改历史终态。若发现的是 Telephone Line 通用问题，先在隔离环境复现和最小修复，再按 [贡献指南](../CONTRIBUTING.md) 提交脱敏材料。

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

## macOS 用户怎么办

v0.1 目前仅验证 Windows 生产环境。macOS 用户不要强行运行 Windows 安装器，也不要把文件解压成功当成本机已经可用。

建议先让自己的 Agent 阅读现有使用说明与协议，检查本机可用的命令行工具、脚本和仍需处理的 Windows 专用部分。适配关注程序路径、权限、进程控制、后台监督和原会话回叫。这里不要求制作桌面应用、图形界面或应用包；除非用户明确提出，不要把环境适配理解成开发一款应用。

也可以继续在 Windows 主机运行 Telephone Line。如果选择做原生 macOS 兼容改动，应在隔离目录中处理，保留现有运输与会话契约，并明确区分已验证、尚未支持和未测试的行为。欢迎通过可审查的 Pull Request 贡献兼容性修复；当前 README 不宣称已支持原生 macOS。

## 当前版本

当前产品版本是 **0.1.8**。原 Lead 将本增量发布为 GitHub Latest / 标签 `v0.1.8` 后，下载地址：

- Windows ZIP：https://github.com/captpascallv-dev/telephone-line/releases/download/v0.1.8/telephone-line-0.1.8-windows.zip
- 源码 ZIP：https://github.com/captpascallv-dev/telephone-line/releases/download/v0.1.8/telephone-line-0.1.8-source.zip
- Latest 页（该标签发布后）：https://github.com/captpascallv-dev/telephone-line/releases/latest

v0.1.7 及更早版本资产保留，本增量不覆盖。

## 欢迎怎样的贡献

社区可以贡献新的 Harness adapter、其他平台移植、兼容性更新、文档与安装器改进。

新的 Lead adapter 不是当前已承诺能力。它只有在通过统一契约、原生会话恢复、Lead 休眠与回叫、无整任务总超时、隐私检查、兼容性验证和代码审查后，才会进入正式支持范围。

## 完整文档

- [快速开始](quick-start.md)
- [v0.1.2 发行说明](releases/v0.1.2.md)
- [v0.1.5 发行说明](releases/v0.1.5.md)
- [v0.1.6 发行说明](releases/v0.1.6.md)
- [v0.1.7 发行说明](releases/v0.1.7.md)
- [v0.1.8 发行说明](releases/v0.1.8.md)
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

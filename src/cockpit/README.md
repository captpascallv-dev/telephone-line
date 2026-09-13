# Bundled cockpit

This folder is the Telephone Line companion status window. It is not a second Lead, not the bundled dashboard, and not a replacement for `Ensure-TelephoneDashboard.ps1`.

After install, open it from the **installed** tree. The window reads only the registry and source paths you pass. The shipped default config is empty, so a machine with no local task metadata shows a real empty state.

## Open (English)

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\src\cockpit\Start-TelephoneCockpit.ps1
```

To show your own Telephone Line jobs, pass the same state root you already use:

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\src\cockpit\Start-TelephoneCockpit.ps1 -StateRoot $env:TELEPHONE_LINE_STATE_ROOT
```

Optional: `-RegistryPath`, `-ConfigPath`, `-DataDir`, `-InstanceName`. Language buttons are 中文 / English; the choice is stored in the data directory.

The default details page has **Current roles**: the owner on its own row, then each current executor, assigned reviewer, and live army task. Each row shows a name, the work, model, effort, and status. Model and effort are ordinary status. Session ids and the ten axes stay under diagnostics.

## 打开（中文）

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\src\cockpit\Start-TelephoneCockpit.ps1
```

要看本机电话线任务，把你正在用的状态目录传进去：

```powershell
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\src\cockpit\Start-TelephoneCockpit.ps1 -StateRoot $env:TELEPHONE_LINE_STATE_ROOT
```

可加 `-RegistryPath`、`-ConfigPath`、`-DataDir`、`-InstanceName`。窗口内「中文 / English」会记住语言偏好。

右侧默认页有「当前角色」：负责人单列，各当前执行者、已安排审核者和仍在进行的军团工作逐项列出。每项含称呼、工作、模型、effort 和状态。模型和 effort 不是诊断信息。会话 ID 与十轴仍在「查看技术诊断」里。

Rebuild the Windows payload with `Build-TelephoneCockpit.ps1` (net8.0-windows, self-contained win-x64). The published files live in `runtime/win-x64/`.

# HONOR Share Keep Alive

让荣耀电脑上的“荣耀分享：允许被其他设备发现”保持开启。程序每分钟通过荣耀超级工作台自带的原生 IPC 单独重置十分钟计时器，不会关闭荣耀分享，不截图、不模拟鼠标，也不会弹出工作台窗口。

> 本项目与荣耀（HONOR）官方无关。它使用本机已安装软件的内部接口，软件升级后接口可能变化。

## 一键使用

1. 双击 `Control.cmd`。
2. 控制面板会先显示计划任务、后台实例、荣耀分享和心跳状态。
3. 输入数字执行操作：
   - `1`：启动或修复，并设置登录自启动。
   - `2`：执行完整自检。
   - `3`：停止后台服务。
   - `4`：停止并删除登录自启动。
4. 操作完成后会明确显示成功或失败，并在 3 秒后自动关闭窗口。

上面的 1–4 操作对应 `commands\Start.cmd`、`commands\Check.cmd`、`commands\Stop.cmd` 和 `commands\Uninstall.cmd`，这些独立入口放在子目录中，方便脚本调用，不占用根目录。

稳定运行时每分钟只发送两条轻量 IPC 消息：一条重置十分钟计时器，一条查询实际开关状态。

如果荣耀分享仍因其他事件关闭，后台客户端会监听关闭通知并立即执行一次开启和状态确认。正常理想路径不需要先关闭再开启，因此不会制造断连；异常路径采用事件驱动恢复，不进行每秒轮询。

另外还有一个独立的后台恢复任务每分钟检查一次主任务和保活进程。荣耀工作台更新、崩溃或重启导致保活实例消失时，会在下一分钟内自动重新启动；如果主任务本身缺失，也会自动重建。

如果旧版本目录残留并重新启动，新版 watchdog 会检测到旧路径的任务或进程，执行一次迁移并切回当前安装，避免新旧版本每分鐘互相重启。

watchdog 使用 `watchdog-hidden.vbs` 隐藏启动，避免 Windows 11 默认终端在每分鐘检查时弹出 PowerShell 窗口。

### 自检内容

`Check.cmd` 会同时验证：

- Windows 计划任务存在且处于 `Running`。
- 自动恢复计划任务已安装且未禁用。
- 只有 1 个对应后台实例，避免重复启动。
- 后台进程最近 90 秒内写过健康心跳。
- 最近一次原生状态查询确认“允许被其他设备发现”为 `ON`。
- 保活过程不发送关闭命令，因此不会触发关闭提醒弹窗或造成设备短暂消失。

全部通过时输出：

```text
SELF-CHECK: PASS - background service is running and HONOR Share is discoverable.
```

## 移动目录

建议先双击 `Stop.cmd`，再移动整个目录。到了新位置后直接双击 `Start.cmd`，脚本会自动把计划任务更新为新路径。

如果旧位置的任务还在运行，在新位置执行 `Start.cmd` 也会清理匹配的旧后台实例并重建任务。

## 命令行

```powershell
# 启动并执行自检（也会更新到当前目录）
powershell -NoProfile -ExecutionPolicy Bypass -File .\HonorShareKeepAlive.ps1 Start

# 执行一次自检
powershell -NoProfile -ExecutionPolicy Bypass -File .\HonorShareKeepAlive.ps1 Check

# 查看简要状态
powershell -NoProfile -ExecutionPolicy Bypass -File .\HonorShareKeepAlive.ps1 Status

# 停止后台任务
powershell -NoProfile -ExecutionPolicy Bypass -File .\HonorShareKeepAlive.ps1 Stop

# 删除登录自启动任务
powershell -NoProfile -ExecutionPolicy Bypass -File .\HonorShareKeepAlive.ps1 Uninstall
```

## 文件说明

- `Control.cmd`：推荐的统一交互入口。
- `commands\Start.cmd`：直接启动、安装自启动任务并自检。
- `commands\Check.cmd`：一键自检并显示反馈。
- `commands\Stop.cmd`：停止后台实例。
- `commands\Uninstall.cmd`：停止并删除计划任务。
- `keepalive.js`：原生 IPC 保活逻辑。
- `launch-hidden.vbs`：以隐藏方式启动 Node 模式。
- `watchdog-hidden.vbs`：以完全隐藏方式启动每分鐘自动恢复检查。
- `HonorShareKeepAlive.ps1`：安装、运行控制和自检。
- `scripts\watchdog.ps1`：定期检查缺失任务或后台实例并执行恢复。
- `logs/keepalive.log`：运行日志。
- `logs/watchdog.log`：自动恢复操作日志。
- `.runtime/health.json`：自检心跳及最近状态。

运行产生的 `logs/` 和 `.runtime/` 已加入 `.gitignore`，不会被提交。

## 系统要求

- Windows 10 或 Windows 11。
- 已安装荣耀电脑管家及荣耀超级工作台。
- 当前测试版本：荣耀电脑管家 `20.0.0.60`，荣耀超级工作台 `5.5.1.104(C233)`。

本项目不访问网络，不上传文件，也不包含荣耀的专有二进制文件。

## 开发与测试

使用 Node.js 20 或更高版本：

```powershell
npm test
npm run check
npm run package
```

`npm run package` 会在 `dist\` 中生成 `HonorShareKeepAlive-v<版本>.zip` 和对应的 `SHA256SUMS.txt`。发行包只包含 `release-manifest.json` 中列出的文件，不会包含 `.runtime\`、`logs\`、`node_modules\`、Git 元数据或其他本机运行数据。

PowerShell 脚本语法检查：

```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path .\HonorShareKeepAlive.ps1),
    [ref]$null,
    [ref]$errors
) | Out-Null
$errors
```

GitHub Actions 会在 Windows 上运行同一组测试、语法检查和发行包构建。

## English summary

HONOR Share Keep Alive is a Windows utility that keeps the temporary "discoverable" switch enabled. It checks once per minute over Honor WorkStation's native IPC without opening a window. An independent watchdog restarts the worker after application updates or unexpected termination. The project is not affiliated with HONOR and uses undocumented local IPC that may change between vendor releases.

## GitHub

源码和问题反馈：[lvlucky3641/Honor-share-keepalive](https://github.com/lvlucky3641/Honor-share-keepalive)。构建完成的 ZIP 和校验文件可以在该仓库的 Releases 页面下载。

## License

MIT

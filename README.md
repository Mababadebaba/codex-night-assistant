# Codex Night Assistant / Codex 守夜助手

## English

Codex Night Assistant is a small Windows utility for running long Codex sessions safely on machines with OLED displays.

It lets Windows turn the screen off while keeping the computer awake, then monitors local Codex session activity and can shut down the PC only after Codex work appears finished and the configured idle time has elapsed. If a rate limit is detected, the app still waits for active tasks to finish and for the idle threshold before showing a shutdown confirmation dialog.

### Features

- Allow the display to turn off while preventing system sleep.
- Apply a practical power profile: screen off after a few minutes, no sleep while plugged in.
- Monitor local Codex session logs under `%USERPROFILE%\.codex\sessions`.
- Detect recent Codex activity, active Codex-launched processes, and rate-limit blocking signals.
- Shut down Windows after a configurable continuous idle period.
- Show live task progress, pending tool calls, process count, rate-limit status, and the current shutdown decision.
- Require a visible confirmation dialog before shutdown; choosing No cancels automatic shutdown, and no response triggers shutdown only after the countdown.
- Launch without a visible PowerShell console window.
- Provide a 60-second shutdown test button and a cancel button.

### Important Limitations

Codex does not currently expose an official Windows API that says "all Codex tasks are complete." This tool uses local log and process monitoring as a best-effort heuristic.

For safer unattended use, set the continuous idle threshold to 10-20 minutes. Use shorter values only for testing.

### Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- Codex desktop app with local session logs enabled

### Usage

1. Run `Install-Desktop-Shortcut.cmd`.
2. Open `Codex 守夜助手` from the desktop.
3. Click `应用息屏/睡眠设置` once if you want the recommended power settings.
4. Click `开启防睡眠` before long Codex work.
5. To shut down after global Codex completion, set:
   - `连续空闲`: 10-20 minutes recommended
   - `确认倒计时`: confirmation countdown in seconds, 60 seconds minimum
6. Click `全局完成后关机`.
7. Click `取消关机/监控` to cancel the monitor or a pending shutdown.

Logs are written to `scripts/CodexNightAssistant.log` after the app runs from `scripts/`, or next to the script location if you move it.

### Safety Notes

- The tool never forces the display to stay on.
- Closing the app releases the keep-awake state.
- Windows shutdown can be cancelled through the app or by running `shutdown /a`.

## 中文

Codex 守夜助手是一个 Windows 小工具，适合长时间运行 Codex，同时保护 OLED 屏幕。

它允许系统自动息屏，但阻止电脑进入睡眠；同时监控本机 Codex 会话活动，只在 Codex 任务看起来已经结束，并且达到你设置的连续空闲时间后才进入关机确认。如果检测到额度/速率限制阻塞，程序仍会继续等待活跃任务结束，并等待连续空闲时间达标。

### 功能

- 允许屏幕自动关闭，同时防止电脑睡眠。
- 一键应用实用电源设置：几分钟后息屏，插电时不睡眠。
- 监控 `%USERPROFILE%\.codex\sessions` 下的本地 Codex 会话日志。
- 检测最近 Codex 活动、Codex 启动的仍在运行的进程，以及额度/速率限制阻塞信号。
- 连续空闲达到设定时间后自动关机。
- 开启全局监控后，实时显示任务进度、等待中的工具调用、进程数量、额度状态和当前判断。
- 真正关机前必须弹出确认窗口；点否会取消自动关机，无人操作才会在倒计时结束后关机。
- 使用隐藏启动器启动，不显示黑色 PowerShell 窗口。
- 提供 60 秒测试关机按钮和取消关机按钮。

### 重要限制

Codex 目前没有向普通 Windows 小程序开放“所有 Codex 任务都已完成”的官方接口。本工具使用本地日志和进程监控做尽量可靠的判断。

无人值守时建议把“连续空闲”设为 10-20 分钟。1-3 分钟更适合测试，不建议长期使用。

### 系统要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1
- 已安装 Codex 桌面版，并能写入本地会话日志

### 使用方法

1. 运行 `Install-Desktop-Shortcut.cmd`。
2. 从桌面打开 `Codex 守夜助手`。
3. 如果需要推荐电源设置，先点一次 `应用息屏/睡眠设置`。
4. 长时间运行 Codex 前，点击 `开启防睡眠`。
5. 如果希望所有 Codex 工作结束后自动关机，设置：
   - `连续空闲`：建议 10-20 分钟
   - `确认倒计时`：确认弹窗倒计时，最少 60 秒
6. 点击 `全局完成后关机`。
7. 如需取消，点击 `取消关机/监控`。

日志会写入 `scripts/CodexNightAssistant.log`，如果你移动脚本，则写在脚本所在目录。

### 安全说明

- 工具不会强制点亮屏幕。
- 关闭窗口会释放防睡眠状态。
- 已安排的 Windows 关机可以通过程序取消，也可以手动运行 `shutdown /a` 取消。

## License / 许可证

MIT License. See [LICENSE](LICENSE).

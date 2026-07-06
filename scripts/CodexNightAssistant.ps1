Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"

$signature = @"
using System;
using System.Runtime.InteropServices;

public static class PowerState {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@

Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue

$ES_CONTINUOUS = [Convert]::ToUInt32("80000000", 16)
$ES_SYSTEM_REQUIRED = [uint32]0x00000001
$keepAwakeFlags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED

$script:keepAwake = $false
$script:globalMonitor = $false
$script:monitorStartedAt = Get-Date
$script:lastCodexActivity = Get-Date
$script:idleMinutesSetting = 10
$script:shutdownDelaySetting = 0
$script:logPath = Join-Path $PSScriptRoot "CodexNightAssistant.log"
$script:monitorScript = Join-Path $PSScriptRoot "CodexShutdownMonitor.ps1"
$script:monitorPidPath = Join-Path $PSScriptRoot "CodexShutdownMonitor.pid"
$script:monitorStatusPath = Join-Path $PSScriptRoot "CodexShutdownMonitor.status.json"
$script:monitorProcessId = $null
$script:shutdownPromptActive = $false
$script:lastShutdownPromptKey = ""

function Write-AppLog {
    param([string]$Message)
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Message"
        Add-Content -LiteralPath $script:logPath -Value $line -Encoding UTF8
    } catch {
        # Logging is best-effort only.
    }
}

function Set-SystemAwake {
    [void][PowerState]::SetThreadExecutionState($keepAwakeFlags)
}

function Clear-SystemAwake {
    [void][PowerState]::SetThreadExecutionState($ES_CONTINUOUS)
}

function Set-Status {
    param([string]$Text)
    $statusLabel.Text = $Text
}

function Apply-PowerSettings {
    param([int]$ScreenOffMinutes, [int]$BatterySleepMinutes)
    powercfg.exe /change monitor-timeout-ac $ScreenOffMinutes | Out-Null
    powercfg.exe /change standby-timeout-ac 0 | Out-Null
    powercfg.exe /change monitor-timeout-dc $ScreenOffMinutes | Out-Null
    powercfg.exe /change standby-timeout-dc $BatterySleepMinutes | Out-Null
    powercfg.exe /setactive SCHEME_CURRENT | Out-Null
}

function Request-Shutdown {
    param([int]$DelaySeconds, [switch]$Force)
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }
    $shutdownArgs = @("/s")
    if ($Force) {
        $shutdownArgs += "/f"
    }
    $shutdownArgs += @("/t", [string]$DelaySeconds, "/c", "Codex appears idle or blocked. Automatic shutdown requested.")

    Write-AppLog "Request shutdown: delay=$DelaySeconds force=$([bool]$Force)"
    & "$env:SystemRoot\System32\shutdown.exe" $shutdownArgs | Out-Null
    $exitCode = $LASTEXITCODE
    Write-AppLog "Shutdown command exit code: $exitCode"
    return $exitCode
}

function Cancel-Shutdown {
    Write-AppLog "Cancel shutdown requested"
    & "$env:SystemRoot\System32\shutdown.exe" /a | Out-Null
    Write-AppLog "Cancel command exit code: $LASTEXITCODE"
}

function Stop-MonitorProcess {
    if (Test-Path -LiteralPath $script:monitorPidPath) {
        try {
            $pidText = Get-Content -Raw -LiteralPath $script:monitorPidPath -ErrorAction Stop
            $monitorPid = [int]$pidText.Trim()
            Stop-Process -Id $monitorPid -Force -ErrorAction SilentlyContinue
            Write-AppLog "Stopped monitor process: pid=$monitorPid"
        } catch {
            Write-AppLog "Stop monitor process failed: $($_.Exception.Message)"
        }
        Remove-Item -LiteralPath $script:monitorPidPath -Force -ErrorAction SilentlyContinue
    }
    $script:monitorProcessId = $null
    Remove-Item -LiteralPath $script:monitorStatusPath -Force -ErrorAction SilentlyContinue
}

function Test-MonitorProcessAlive {
    $candidatePids = @()
    if ($script:monitorProcessId) {
        $candidatePids += [int]$script:monitorProcessId
    }

    if (Test-Path -LiteralPath $script:monitorPidPath) {
        try {
            $pidText = Get-Content -Raw -LiteralPath $script:monitorPidPath -ErrorAction Stop
            $candidatePids += [int]$pidText.Trim()
        } catch {
        }
    }

    foreach ($candidatePid in ($candidatePids | Select-Object -Unique)) {
        try {
            $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$candidatePid" -ErrorAction Stop
            if ($proc -and $proc.CommandLine -and $proc.CommandLine.Contains($script:monitorScript)) {
                return $true
            }
        } catch {
        }
    }

    return $false
}

function Show-ShutdownConfirmation {
    param($MonitorStatus, [string]$ReasonText)

    if ($script:shutdownPromptActive) { return }
    $script:shutdownPromptActive = $true

    $countdown = [int]$script:shutdownDelaySetting
    if ($countdown -lt 60) { $countdown = 60 }

    Write-AppLog "Shutdown confirmation shown: countdown=$countdown reason=$ReasonText"

    $confirmForm = New-Object System.Windows.Forms.Form
    $confirmForm.Text = "确认关机"
    $confirmForm.StartPosition = "CenterScreen"
    $confirmForm.Size = New-Object System.Drawing.Size(460, 260)
    $confirmForm.MinimumSize = New-Object System.Drawing.Size(460, 260)
    $confirmForm.MaximumSize = New-Object System.Drawing.Size(460, 260)
    $confirmForm.TopMost = $true
    $confirmForm.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 248)
    $confirmForm.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

    $message = New-Object System.Windows.Forms.Label
    $message.Location = New-Object System.Drawing.Point(22, 18)
    $message.Size = New-Object System.Drawing.Size(400, 112)
    $recentTurns = if ($null -ne $MonitorStatus.RecentTurnCount) { [int]$MonitorStatus.RecentTurnCount } else { 0 }
    $message.Text = "已满足自动关机条件：`r`n$ReasonText`r`n`r`n任务：活跃回合 $($MonitorStatus.ActiveTurnCount) / 活跃调用 $($MonitorStatus.PendingToolCallCount) / 活跃进程 $($MonitorStatus.ActiveProcessCount)`r`n最近会话：$recentTurns`r`n额度：$($MonitorStatus.RateLimitText)"
    $confirmForm.Controls.Add($message)

    $countdownLabel = New-Object System.Windows.Forms.Label
    $countdownLabel.Location = New-Object System.Drawing.Point(22, 138)
    $countdownLabel.Size = New-Object System.Drawing.Size(400, 28)
    $countdownLabel.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)
    $confirmForm.Controls.Add($countdownLabel)

    $yesButton = New-Object System.Windows.Forms.Button
    $yesButton.Text = "现在关机"
    $yesButton.Location = New-Object System.Drawing.Point(72, 176)
    $yesButton.Size = New-Object System.Drawing.Size(130, 36)
    $confirmForm.Controls.Add($yesButton)

    $noButton = New-Object System.Windows.Forms.Button
    $noButton.Text = "否，取消自动关机"
    $noButton.Location = New-Object System.Drawing.Point(224, 176)
    $noButton.Size = New-Object System.Drawing.Size(160, 36)
    $confirmForm.Controls.Add($noButton)

    $remaining = $countdown
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000

    $updateCountdown = {
        $countdownLabel.Text = "无人操作将在 $remaining 秒后关机"
    }

    $timer.Add_Tick({
        $remaining -= 1
        & $updateCountdown
        if ($remaining -le 0) {
            $timer.Stop()
            Write-AppLog "Shutdown confirmation countdown elapsed"
            Stop-GlobalMonitor
            $exitCode = Request-Shutdown -DelaySeconds 0 -Force
            if ($exitCode -ne 0) {
                Set-Status "关机命令失败：$exitCode。已停止监控，请查看日志。"
            }
            $confirmForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $confirmForm.Close()
        }
    })

    $yesButton.Add_Click({
        $timer.Stop()
        Write-AppLog "Shutdown confirmation accepted manually"
        Stop-GlobalMonitor
        $exitCode = Request-Shutdown -DelaySeconds 0 -Force
        if ($exitCode -ne 0) {
            Set-Status "关机命令失败：$exitCode。已停止监控，请查看日志。"
        }
        $confirmForm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $confirmForm.Close()
    })

    $noButton.Add_Click({
        $timer.Stop()
        Write-AppLog "Shutdown confirmation rejected manually"
        Stop-GlobalMonitor
        Cancel-Shutdown
        Set-Status "已取消自动关机和全局监控。"
        $confirmForm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $confirmForm.Close()
    })

    $confirmForm.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
        $script:shutdownPromptActive = $false
    })

    & $updateCountdown
    $timer.Start()
    [void]$confirmForm.ShowDialog($form)
}

function Update-MonitorProgress {
    if (-not $taskProgressLabel -or -not $taskDetailLabel -or -not $quotaProgressLabel -or -not $decisionProgressLabel) { return }

    if (-not $script:globalMonitor) {
        $taskProgressLabel.Text = "任务进度：未开启监控"
        $taskDetailLabel.Text = "任务明细：未开启监控"
        $quotaProgressLabel.Text = "额度状态：未开启监控"
        $decisionProgressLabel.Text = "当前判断：未开启监控"
        return
    }

    if ((Test-Path -LiteralPath $script:monitorStatusPath) -and -not (Test-MonitorProcessAlive)) {
        Remove-Item -LiteralPath $script:monitorStatusPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:monitorPidPath -Force -ErrorAction SilentlyContinue
        $script:globalMonitor = $false
        $script:monitorProcessId = $null
        $taskProgressLabel.Text = "任务进度：后台监控未运行"
        $taskDetailLabel.Text = "任务明细：已清理旧状态，请重新开启全局监控"
        $quotaProgressLabel.Text = "额度状态：未开启监控"
        $decisionProgressLabel.Text = "当前判断：旧监控状态已清理"
        Set-Status "后台监控未运行，旧状态已清理。请重新点击“全局完成后关机”。"
        return
    }

    if (-not (Test-Path -LiteralPath $script:monitorStatusPath)) {
        $taskProgressLabel.Text = "任务进度：等待后台监控写入状态..."
        $taskDetailLabel.Text = "任务明细：正在初始化"
        $quotaProgressLabel.Text = "额度状态：等待读取"
        $decisionProgressLabel.Text = "当前判断：正在初始化"
        return
    }

    try {
        $status = Get-Content -Raw -LiteralPath $script:monitorStatusPath -Encoding UTF8 | ConvertFrom-Json
        $recentTurns = if ($null -ne $status.RecentTurnCount) { [int]$status.RecentTurnCount } else { [int]$status.ActiveTurnCount }
        $activeTotal = [int]$status.ActiveTurnCount + [int]$status.PendingToolCallCount + [int]$status.ActiveProcessCount
        $taskState = if ($activeTotal -gt 0) { "运行中" } else { "未检测到活跃任务" }
        $rateState = if ([bool]$status.RateLimitBlocked) { "任一额度已耗尽/受限" } else { "未检测到耗尽" }
        $rateUpdated = if ($status.RateLimitUpdatedAt) { " 更新 $($status.RateLimitUpdatedAt)" } else { "" }
        $normalizedDecision = [string]$status.Decision
        if ($activeTotal -le 0 -and $normalizedDecision -in @("RATE_BLOCKED_BUT_TASKS_ACTIVE", "TASKS_ACTIVE_WAITING")) {
            $normalizedDecision = if ([bool]$status.RateLimitBlocked) { "RATE_BLOCKED_WAITING_FOR_IDLE" } else { "WAITING_FOR_TASKS_OR_IDLE" }
        } elseif ($activeTotal -gt 0 -and $normalizedDecision -in @("RATE_BLOCKED_WAITING_FOR_IDLE", "WAITING_FOR_TASKS_OR_IDLE", "")) {
            $normalizedDecision = if ([bool]$status.RateLimitBlocked) { "RATE_BLOCKED_BUT_TASKS_ACTIVE" } else { "TASKS_ACTIVE_WAITING" }
        }
        $decisionText = switch -Regex ($normalizedDecision) {
            "^INITIALIZING$" { "后台监控正在初始化。"; break }
            "^RATE_BLOCKED_BUT_TASKS_ACTIVE$" { "额度已耗尽，但仍检测到任务未结束，继续等待。"; break }
            "^TASKS_ACTIVE_WAITING$" { "检测到 Codex 任务仍在运行，继续等待。"; break }
            "^RATE_BLOCKED_WAITING_FOR_IDLE$" { "额度已耗尽，但仍需等待连续空闲满 $($status.IdleThresholdMinutes) 分钟。"; break }
            "^RATE_BLOCKED_IDLE_CONFIRM_(\d+)$" { "额度已耗尽，任务未活跃且已空闲 $($status.IdleForMinutes) 分钟；确认 $($status.ReadyChecks)/2。"; break }
            "^IDLE_CONFIRM_(\d+)$" { "任务已空闲 $($status.IdleForMinutes) 分钟；确认 $($status.ReadyChecks)/2。"; break }
            "^WAITING_FOR_TASKS_OR_IDLE$" { "等待任务结束，或连续空闲满 $($status.IdleThresholdMinutes) 分钟。"; break }
            default { [string]$status.Decision }
        }

        $taskProgressLabel.Text = "任务进度：$taskState"
        $taskDetailLabel.Text = "任务明细：活跃回合 $($status.ActiveTurnCount) / 活跃调用 $($status.PendingToolCallCount) / 活跃进程 $($status.ActiveProcessCount) / 最近会话 $recentTurns"
        $quotaProgressLabel.Text = "额度状态：$rateState  $($status.RateLimitText)$rateUpdated"
        $decisionProgressLabel.Text = "当前判断：$decisionText"
        Set-Status "全局监控中：$decisionText"

        if ($script:globalMonitor -and [bool]$status.ShutdownReady) {
            $promptKey = "$($status.MonitorStartedAt)|$($status.Decision)|$($status.ReadyChecks)"
            if ($script:lastShutdownPromptKey -ne $promptKey) {
                $script:lastShutdownPromptKey = $promptKey
                Show-ShutdownConfirmation -MonitorStatus $status -ReasonText $decisionText
            }
        }
    } catch {
        $taskProgressLabel.Text = "任务进度：状态读取失败"
        $taskDetailLabel.Text = "任务明细：状态读取失败"
        $quotaProgressLabel.Text = "额度状态：状态读取失败"
        $decisionProgressLabel.Text = "当前判断：$($_.Exception.Message)"
    }
}

function Start-MonitorProcess {
    param(
        [int]$IdleMinutes,
        [int]$ShutdownDelaySeconds
    )

    Stop-MonitorProcess

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $script:monitorScript,
        "-IdleMinutes", $IdleMinutes,
        "-ShutdownDelaySeconds", $ShutdownDelaySeconds,
        "-BaseDir", $PSScriptRoot
    )

    $proc = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
    $script:monitorProcessId = $proc.Id
    Write-AppLog "Started monitor process: pid=$($proc.Id) idleMinutes=$IdleMinutes shutdownDelay=$ShutdownDelaySeconds"
}

function Get-TailJsonLines {
    param([string]$Path, [int]$Tail = 500)
    try {
        Get-Content -LiteralPath $Path -Tail $Tail -Encoding UTF8 -ErrorAction Stop
    } catch {
        @()
    }
}

function Test-RateLimitBlocked {
    param($RateLimits)
    if ($null -eq $RateLimits) { return $false }

    try {
        if ($RateLimits.rate_limit_reached_type) { return $true }
        $json = $RateLimits | ConvertTo-Json -Depth 8 -Compress
        foreach ($match in [regex]::Matches($json, '"(?:used_percent|usage_percent|percent_used|percent)"\s*:\s*([0-9]+(?:\.[0-9]+)?)')) {
            if ([double]$match.Groups[1].Value -ge 100) { return $true }
        }
    } catch {
        return $false
    }

    return $false
}

function Get-CodexGlobalActivity {
    $sessionRoot = Join-Path $env:USERPROFILE ".codex\sessions"
    $processManagerPath = Join-Path $env:USERPROFILE ".codex\process_manager\chat_processes.json"
    $recentWindowStart = $script:monitorStartedAt.AddMinutes(-30)
    $latestActivity = $script:monitorStartedAt
    $rateLimitBlocked = $false
    $recentFileCount = 0
    $activeProcessCount = 0

    if (Test-Path -LiteralPath $processManagerPath) {
        try {
            $processEntries = Get-Content -Raw -LiteralPath $processManagerPath -Encoding UTF8 | ConvertFrom-Json
            $monitorStartMs = [int64](([DateTimeOffset]$script:monitorStartedAt.AddMinutes(-5)).ToUnixTimeMilliseconds())
            foreach ($entry in $processEntries) {
                if ($null -eq $entry.osPid) {
                    continue
                }
                if ($entry.startedAtMs -and ([int64]$entry.startedAtMs -lt $monitorStartMs)) {
                    continue
                }
                try {
                    $proc = Get-Process -Id ([int]$entry.osPid) -ErrorAction Stop
                    if ($proc) {
                        $activeProcessCount += 1
                    }
                } catch {
                    continue
                }
            }
        } catch {
            Write-AppLog "Process manager read failed: $($_.Exception.Message)"
        }
    }

    if (-not (Test-Path -LiteralPath $sessionRoot)) {
        return [pscustomobject]@{
            LatestActivity = $latestActivity
            ActiveProcessCount = $activeProcessCount
            RateLimitBlocked = $false
            RecentFileCount = 0
        }
    }

    $files = Get-ChildItem -LiteralPath $sessionRoot -Recurse -Filter "rollout-*.jsonl" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $recentWindowStart } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 40

    foreach ($file in $files) {
        $recentFileCount += 1
        if ($file.LastWriteTime -gt $latestActivity) {
            $latestActivity = $file.LastWriteTime
        }

        foreach ($line in (Get-TailJsonLines -Path $file.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }

            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                continue
            }

            if ($event.type -eq "event_msg" -and $event.payload -and $event.payload.type -eq "token_count") {
                if (Test-RateLimitBlocked -RateLimits $event.payload.rate_limits) {
                    $rateLimitBlocked = $true
                }
            }
        }
    }

    return [pscustomobject]@{
        LatestActivity = $latestActivity
        ActiveProcessCount = $activeProcessCount
        RateLimitBlocked = $rateLimitBlocked
        RecentFileCount = $recentFileCount
    }
}

function Start-GlobalMonitor {
    $script:globalMonitor = $true
    $script:keepAwake = $true
    $script:monitorStartedAt = Get-Date
    $script:lastCodexActivity = Get-Date
    $script:idleMinutesSetting = [int]$idleMinutes.Value
    $script:shutdownDelaySetting = [int]$shutdownSeconds.Value
    Remove-Item -LiteralPath $script:monitorStatusPath -Force -ErrorAction SilentlyContinue
    Set-SystemAwake
    $keepAwakeTimer.Start()
    $monitorStatusTimer.Start()
    Start-MonitorProcess -IdleMinutes $script:idleMinutesSetting -ShutdownDelaySeconds $script:shutdownDelaySetting
    Write-AppLog "Global monitor started: idleMinutes=$script:idleMinutesSetting shutdownDelay=$script:shutdownDelaySetting"
    Set-Status "全局监控进程已启动。它会在后台检测所有 Codex 会话。"
    Update-MonitorProgress
}

function Stop-GlobalMonitor {
    $script:globalMonitor = $false
    Stop-MonitorProcess
    $monitorStatusTimer.Stop()
    Update-MonitorProgress
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Codex 守夜助手"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(500, 780)
$form.MinimumSize = New-Object System.Drawing.Size(500, 780)
$form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 248)
$form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10)

$title = New-Object System.Windows.Forms.Label
$title.Text = "Codex 守夜助手"
$title.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 16, [System.Drawing.FontStyle]::Bold)
$title.Location = New-Object System.Drawing.Point(18, 16)
$title.Size = New-Object System.Drawing.Size(400, 34)
$form.Controls.Add($title)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = "准备就绪。可开启防睡眠，或开启全局监控关机。"
$statusLabel.Location = New-Object System.Drawing.Point(20, 58)
$statusLabel.Size = New-Object System.Drawing.Size(405, 52)
$statusLabel.ForeColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$form.Controls.Add($statusLabel)

$keepButton = New-Object System.Windows.Forms.Button
$keepButton.Text = "开启防睡眠"
$keepButton.Location = New-Object System.Drawing.Point(22, 118)
$keepButton.Size = New-Object System.Drawing.Size(190, 42)
$form.Controls.Add($keepButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "停止防睡眠"
$stopButton.Location = New-Object System.Drawing.Point(228, 118)
$stopButton.Size = New-Object System.Drawing.Size(190, 42)
$form.Controls.Add($stopButton)

$screenLabel = New-Object System.Windows.Forms.Label
$screenLabel.Text = "息屏时间"
$screenLabel.Location = New-Object System.Drawing.Point(24, 184)
$screenLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($screenLabel)

$screenMinutes = New-Object System.Windows.Forms.NumericUpDown
$screenMinutes.Minimum = 1
$screenMinutes.Maximum = 120
$screenMinutes.Value = 3
$screenMinutes.Location = New-Object System.Drawing.Point(160, 182)
$screenMinutes.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($screenMinutes)

$screenUnit = New-Object System.Windows.Forms.Label
$screenUnit.Text = "分钟"
$screenUnit.Location = New-Object System.Drawing.Point(238, 184)
$screenUnit.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($screenUnit)

$batteryLabel = New-Object System.Windows.Forms.Label
$batteryLabel.Text = "电池睡眠时间"
$batteryLabel.Location = New-Object System.Drawing.Point(24, 220)
$batteryLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($batteryLabel)

$batteryMinutes = New-Object System.Windows.Forms.NumericUpDown
$batteryMinutes.Minimum = 1
$batteryMinutes.Maximum = 240
$batteryMinutes.Value = 30
$batteryMinutes.Location = New-Object System.Drawing.Point(160, 218)
$batteryMinutes.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($batteryMinutes)

$batteryUnit = New-Object System.Windows.Forms.Label
$batteryUnit.Text = "分钟"
$batteryUnit.Location = New-Object System.Drawing.Point(238, 220)
$batteryUnit.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($batteryUnit)

$powerButton = New-Object System.Windows.Forms.Button
$powerButton.Text = "应用息屏/睡眠设置"
$powerButton.Location = New-Object System.Drawing.Point(22, 258)
$powerButton.Size = New-Object System.Drawing.Size(436, 38)
$form.Controls.Add($powerButton)

$progressTitle = New-Object System.Windows.Forms.Label
$progressTitle.Text = "全局完成后关机状态"
$progressTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)
$progressTitle.Location = New-Object System.Drawing.Point(24, 312)
$progressTitle.Size = New-Object System.Drawing.Size(390, 24)
$form.Controls.Add($progressTitle)

$taskProgressLabel = New-Object System.Windows.Forms.Label
$taskProgressLabel.Text = "任务进度：未开启监控"
$taskProgressLabel.Location = New-Object System.Drawing.Point(24, 340)
$taskProgressLabel.Size = New-Object System.Drawing.Size(440, 24)
$taskProgressLabel.ForeColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$form.Controls.Add($taskProgressLabel)

$taskDetailLabel = New-Object System.Windows.Forms.Label
$taskDetailLabel.Text = "任务明细：未开启监控"
$taskDetailLabel.Location = New-Object System.Drawing.Point(24, 368)
$taskDetailLabel.Size = New-Object System.Drawing.Size(440, 42)
$taskDetailLabel.ForeColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$form.Controls.Add($taskDetailLabel)

$quotaProgressLabel = New-Object System.Windows.Forms.Label
$quotaProgressLabel.Text = "额度状态：未开启监控"
$quotaProgressLabel.Location = New-Object System.Drawing.Point(24, 414)
$quotaProgressLabel.Size = New-Object System.Drawing.Size(440, 42)
$quotaProgressLabel.ForeColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$form.Controls.Add($quotaProgressLabel)

$decisionProgressLabel = New-Object System.Windows.Forms.Label
$decisionProgressLabel.Text = "当前判断：未开启监控"
$decisionProgressLabel.Location = New-Object System.Drawing.Point(24, 462)
$decisionProgressLabel.Size = New-Object System.Drawing.Size(440, 44)
$decisionProgressLabel.ForeColor = [System.Drawing.Color]::FromArgb(45, 45, 45)
$form.Controls.Add($decisionProgressLabel)

$idleLabel = New-Object System.Windows.Forms.Label
$idleLabel.Text = "连续空闲"
$idleLabel.Location = New-Object System.Drawing.Point(24, 528)
$idleLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($idleLabel)

$idleMinutes = New-Object System.Windows.Forms.NumericUpDown
$idleMinutes.Minimum = 1
$idleMinutes.Maximum = 240
$idleMinutes.Value = 10
$idleMinutes.Location = New-Object System.Drawing.Point(160, 526)
$idleMinutes.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($idleMinutes)

$idleUnit = New-Object System.Windows.Forms.Label
$idleUnit.Text = "分钟后关机"
$idleUnit.Location = New-Object System.Drawing.Point(238, 528)
$idleUnit.Size = New-Object System.Drawing.Size(140, 24)
$form.Controls.Add($idleUnit)

$shutdownLabel = New-Object System.Windows.Forms.Label
$shutdownLabel.Text = "确认倒计时"
$shutdownLabel.Location = New-Object System.Drawing.Point(24, 564)
$shutdownLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($shutdownLabel)

$shutdownSeconds = New-Object System.Windows.Forms.NumericUpDown
$shutdownSeconds.Minimum = 60
$shutdownSeconds.Maximum = 36000
$shutdownSeconds.Value = 60
$shutdownSeconds.Increment = 30
$shutdownSeconds.Location = New-Object System.Drawing.Point(160, 562)
$shutdownSeconds.Size = New-Object System.Drawing.Size(84, 28)
$form.Controls.Add($shutdownSeconds)

$shutdownUnit = New-Object System.Windows.Forms.Label
$shutdownUnit.Text = "秒"
$shutdownUnit.Location = New-Object System.Drawing.Point(252, 564)
$shutdownUnit.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($shutdownUnit)

$shutdownButton = New-Object System.Windows.Forms.Button
$shutdownButton.Text = "全局完成后关机"
$shutdownButton.Location = New-Object System.Drawing.Point(22, 620)
$shutdownButton.Size = New-Object System.Drawing.Size(210, 38)
$form.Controls.Add($shutdownButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "取消关机/监控"
$cancelButton.Location = New-Object System.Drawing.Point(248, 620)
$cancelButton.Size = New-Object System.Drawing.Size(210, 38)
$form.Controls.Add($cancelButton)

$testShutdownButton = New-Object System.Windows.Forms.Button
$testShutdownButton.Text = "测试关机：60 秒后关机"
$testShutdownButton.Location = New-Object System.Drawing.Point(22, 676)
$testShutdownButton.Size = New-Object System.Drawing.Size(436, 38)
$form.Controls.Add($testShutdownButton)

$keepAwakeTimer = New-Object System.Windows.Forms.Timer
$keepAwakeTimer.Interval = 30000
$keepAwakeTimer.Add_Tick({
    if ($script:keepAwake) {
        Set-SystemAwake
    }
})

$monitorStatusTimer = New-Object System.Windows.Forms.Timer
$monitorStatusTimer.Interval = 5000
$monitorStatusTimer.Add_Tick({
    Update-MonitorProgress
})

$keepButton.Add_Click({
    try {
        $script:keepAwake = $true
        Set-SystemAwake
        $keepAwakeTimer.Start()
        Set-Status "防睡眠已开启。屏幕可以自动熄灭，电脑不会进入睡眠。"
    } catch {
        Set-Status "无法开启防睡眠：$($_.Exception.Message)"
    }
})

$stopButton.Add_Click({
    try {
        Stop-GlobalMonitor
        $script:keepAwake = $false
        $keepAwakeTimer.Stop()
        Clear-SystemAwake
        Set-Status "防睡眠和全局监控已停止。Windows 可以按原设置进入睡眠。"
    } catch {
        Set-Status "无法停止防睡眠：$($_.Exception.Message)"
    }
})

$powerButton.Add_Click({
    try {
        Apply-PowerSettings -ScreenOffMinutes ([int]$screenMinutes.Value) -BatterySleepMinutes ([int]$batteryMinutes.Value)
        Set-Status "电源设置已应用。插电时将息屏但不睡眠。"
    } catch {
        Set-Status "无法应用电源设置：$($_.Exception.Message)"
    }
})

$shutdownButton.Add_Click({
    try {
        $idle = [int]$idleMinutes.Value
        $delay = [int]$shutdownSeconds.Value
        $result = [System.Windows.Forms.MessageBox]::Show(
            "开启后会监控所有 Codex 会话。只有在未检测到活跃任务，并且连续空闲满 $idle 分钟后，才会弹出确认关机窗口。无人操作 $delay 秒后会使用锁屏可用的强制关机参数执行关机；点否会取消自动关机。",
            "全局完成后关机",
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Information
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            Start-GlobalMonitor
        }
    } catch {
        Set-Status "无法开启全局监控：$($_.Exception.Message)"
    }
})

$cancelButton.Add_Click({
    try {
        Stop-GlobalMonitor
        Cancel-Shutdown
        Set-Status "已取消全局监控，也已请求取消 Windows 关机。"
    } catch {
        Set-Status "无法取消关机：$($_.Exception.Message)"
    }
})

$testShutdownButton.Add_Click({
    try {
        $result = [System.Windows.Forms.MessageBox]::Show(
            "这会安排 Windows 在 60 秒后强制关机，用来验证锁屏/息屏后关机命令是否生效。你可以立刻点击取消关机/监控来取消。",
            "测试关机",
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $exitCode = Request-Shutdown -DelaySeconds 60 -Force
            if ($exitCode -eq 0) {
                Set-Status "测试关机已安排：60 秒后强制关机。需要取消请点击“取消关机/监控”。"
            } else {
                Set-Status "测试关机失败：$exitCode。请查看日志。"
            }
        }
    } catch {
        Write-AppLog "Test shutdown error: $($_.Exception.Message)"
        Set-Status "测试关机失败：$($_.Exception.Message)"
    }
})

$form.Add_FormClosing({
    $script:keepAwake = $false
    Stop-GlobalMonitor
    $keepAwakeTimer.Stop()
    $monitorStatusTimer.Stop()
    Clear-SystemAwake
})

[void]$form.ShowDialog()

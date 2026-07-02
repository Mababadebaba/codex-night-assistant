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
    param([int]$DelaySeconds)
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }
    Write-AppLog "Request shutdown: delay=$DelaySeconds"
    & "$env:SystemRoot\System32\shutdown.exe" /s /t $DelaySeconds /c "Codex appears idle or blocked. Automatic shutdown requested." | Out-Null
    Write-AppLog "Shutdown command exit code: $LASTEXITCODE"
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
        if ($RateLimits.primary -and [double]$RateLimits.primary.used_percent -ge 100) { return $true }
        if ($RateLimits.secondary -and [double]$RateLimits.secondary.used_percent -ge 100) { return $true }
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
    Set-SystemAwake
    $keepAwakeTimer.Start()
    Start-MonitorProcess -IdleMinutes $script:idleMinutesSetting -ShutdownDelaySeconds $script:shutdownDelaySetting
    Write-AppLog "Global monitor started: idleMinutes=$script:idleMinutesSetting shutdownDelay=$script:shutdownDelaySetting"
    Set-Status "全局监控进程已启动。它会在后台检测所有 Codex 会话。"
}

function Stop-GlobalMonitor {
    $script:globalMonitor = $false
    Stop-MonitorProcess
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = "Codex 守夜助手"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(460, 560)
$form.MinimumSize = New-Object System.Drawing.Size(460, 560)
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
$powerButton.Size = New-Object System.Drawing.Size(396, 38)
$form.Controls.Add($powerButton)

$idleLabel = New-Object System.Windows.Forms.Label
$idleLabel.Text = "连续空闲"
$idleLabel.Location = New-Object System.Drawing.Point(24, 322)
$idleLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($idleLabel)

$idleMinutes = New-Object System.Windows.Forms.NumericUpDown
$idleMinutes.Minimum = 1
$idleMinutes.Maximum = 240
$idleMinutes.Value = 10
$idleMinutes.Location = New-Object System.Drawing.Point(160, 320)
$idleMinutes.Size = New-Object System.Drawing.Size(70, 28)
$form.Controls.Add($idleMinutes)

$idleUnit = New-Object System.Windows.Forms.Label
$idleUnit.Text = "分钟后关机"
$idleUnit.Location = New-Object System.Drawing.Point(238, 322)
$idleUnit.Size = New-Object System.Drawing.Size(140, 24)
$form.Controls.Add($idleUnit)

$shutdownLabel = New-Object System.Windows.Forms.Label
$shutdownLabel.Text = "检测后延迟"
$shutdownLabel.Location = New-Object System.Drawing.Point(24, 358)
$shutdownLabel.Size = New-Object System.Drawing.Size(130, 24)
$form.Controls.Add($shutdownLabel)

$shutdownSeconds = New-Object System.Windows.Forms.NumericUpDown
$shutdownSeconds.Minimum = 0
$shutdownSeconds.Maximum = 36000
$shutdownSeconds.Value = 0
$shutdownSeconds.Increment = 30
$shutdownSeconds.Location = New-Object System.Drawing.Point(160, 356)
$shutdownSeconds.Size = New-Object System.Drawing.Size(84, 28)
$form.Controls.Add($shutdownSeconds)

$shutdownUnit = New-Object System.Windows.Forms.Label
$shutdownUnit.Text = "秒"
$shutdownUnit.Location = New-Object System.Drawing.Point(252, 358)
$shutdownUnit.Size = New-Object System.Drawing.Size(100, 24)
$form.Controls.Add($shutdownUnit)

$shutdownButton = New-Object System.Windows.Forms.Button
$shutdownButton.Text = "全局完成后关机"
$shutdownButton.Location = New-Object System.Drawing.Point(22, 406)
$shutdownButton.Size = New-Object System.Drawing.Size(190, 38)
$form.Controls.Add($shutdownButton)

$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = "取消关机/监控"
$cancelButton.Location = New-Object System.Drawing.Point(228, 406)
$cancelButton.Size = New-Object System.Drawing.Size(190, 38)
$form.Controls.Add($cancelButton)

$testShutdownButton = New-Object System.Windows.Forms.Button
$testShutdownButton.Text = "测试关机：60 秒后关机"
$testShutdownButton.Location = New-Object System.Drawing.Point(22, 456)
$testShutdownButton.Size = New-Object System.Drawing.Size(396, 38)
$form.Controls.Add($testShutdownButton)

$keepAwakeTimer = New-Object System.Windows.Forms.Timer
$keepAwakeTimer.Interval = 30000
$keepAwakeTimer.Add_Tick({
    if ($script:keepAwake) {
        Set-SystemAwake
    }
})

$monitorWorker = New-Object System.ComponentModel.BackgroundWorker
$monitorWorker.WorkerReportsProgress = $true
$monitorWorker.WorkerSupportsCancellation = $true

$monitorWorker.Add_DoWork({
    param($sender, $e)

    while (-not $sender.CancellationPending -and $script:globalMonitor) {
        try {
            Set-SystemAwake
            $activity = Get-CodexGlobalActivity

            if ($activity.LatestActivity -gt $script:lastCodexActivity) {
                $script:lastCodexActivity = $activity.LatestActivity
            }

            if ($activity.ActiveProcessCount -gt 0) {
                $script:lastCodexActivity = Get-Date
                Write-AppLog "Monitor: active Codex-launched processes detected: $($activity.ActiveProcessCount)"
                $sender.ReportProgress(0, "全局监控中：检测到 Codex 拉起的进程仍在运行，继续等待。")
            } elseif ($activity.RateLimitBlocked) {
                Write-AppLog "Monitor: rate limit blocked detected"
                $sender.ReportProgress(0, "检测到额度/速率限制已阻塞，准备自动关机。")
                $script:globalMonitor = $false
                Request-Shutdown -DelaySeconds $script:shutdownDelaySetting
                break
            } else {
                $idleFor = ((Get-Date) - $script:lastCodexActivity).TotalMinutes
                if ($idleFor -ge $script:idleMinutesSetting) {
                    Write-AppLog "Monitor: idle threshold reached idleFor=$idleFor threshold=$script:idleMinutesSetting"
                    $sender.ReportProgress(0, "Codex 已连续空闲 $([math]::Round($idleFor, 1)) 分钟，准备自动关机。")
                    $script:globalMonitor = $false
                    Request-Shutdown -DelaySeconds $script:shutdownDelaySetting
                    break
                }
                Write-AppLog "Monitor: idleFor=$([math]::Round($idleFor, 2)) threshold=$script:idleMinutesSetting activeProcesses=$($activity.ActiveProcessCount) recentFiles=$($activity.RecentFileCount)"
                $sender.ReportProgress(0, "全局监控中：最近活动 $([math]::Round($idleFor, 1)) 分钟前；空闲满 $script:idleMinutesSetting 分钟后关机。")
            }
        } catch {
            Write-AppLog "Monitor error: $($_.Exception.Message)"
            $sender.ReportProgress(0, "全局监控读取失败：$($_.Exception.Message)")
        }

        for ($i = 0; $i -lt 30; $i++) {
            if ($sender.CancellationPending -or -not $script:globalMonitor) {
                break
            }
            Start-Sleep -Seconds 1
        }
    }
})

$monitorWorker.Add_ProgressChanged({
    param($sender, $e)
    Set-Status ([string]$e.UserState)
})

$monitorWorker.Add_RunWorkerCompleted({
    if (-not $script:globalMonitor) {
        Set-Status "全局监控已停止。"
    }
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
            "开启后会在后台监控所有 Codex 会话。所有会话连续 $idle 分钟没有活动、且没有监控启动后由 Codex 拉起的进程仍在运行时，将在 $delay 秒后关闭 Windows。",
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
            "这会安排 Windows 在 60 秒后关机，用来验证关机命令是否生效。你可以立刻点击取消关机/监控来取消。",
            "测试关机",
            [System.Windows.Forms.MessageBoxButtons]::OKCancel,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            Request-Shutdown -DelaySeconds 60
            Set-Status "测试关机已安排：60 秒后关机。需要取消请点击“取消关机/监控”。"
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
    Clear-SystemAwake
})

[void]$form.ShowDialog()

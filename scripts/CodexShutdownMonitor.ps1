param(
    [int]$IdleMinutes = 10,
    [int]$ShutdownDelaySeconds = 0,
    [string]$BaseDir = $PSScriptRoot
)

$ErrorActionPreference = "Continue"

$LogPath = Join-Path $BaseDir "CodexNightAssistant.log"
$PidPath = Join-Path $BaseDir "CodexShutdownMonitor.pid"

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

function Write-MonitorLog {
    param([string]$Message)
    try {
        Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [monitor] $Message" -Encoding UTF8
    } catch {
    }
}

function Set-SystemAwake {
    [void][PowerState]::SetThreadExecutionState($keepAwakeFlags)
}

function Clear-SystemAwake {
    [void][PowerState]::SetThreadExecutionState($ES_CONTINUOUS)
}

function Request-Shutdown {
    param([int]$DelaySeconds)
    if ($DelaySeconds -lt 0) { $DelaySeconds = 0 }
    Write-MonitorLog "Request shutdown: delay=$DelaySeconds"
    & "$env:SystemRoot\System32\shutdown.exe" /s /t $DelaySeconds /c "Codex appears idle or blocked. Automatic shutdown requested." | Out-Null
    Write-MonitorLog "Shutdown command exit code: $LASTEXITCODE"
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
    param([datetime]$MonitorStartedAt)

    $sessionRoot = Join-Path $env:USERPROFILE ".codex\sessions"
    $processManagerPath = Join-Path $env:USERPROFILE ".codex\process_manager\chat_processes.json"
    $recentWindowStart = $MonitorStartedAt.AddMinutes(-30)
    $latestActivity = $MonitorStartedAt
    $rateLimitBlocked = $false
    $recentFileCount = 0
    $activeProcessCount = 0

    if (Test-Path -LiteralPath $processManagerPath) {
        try {
            $processEntries = Get-Content -Raw -LiteralPath $processManagerPath -Encoding UTF8 | ConvertFrom-Json
            $monitorStartMs = [int64](([DateTimeOffset]$MonitorStartedAt.AddMinutes(-5)).ToUnixTimeMilliseconds())
            foreach ($entry in $processEntries) {
                if ($null -eq $entry.osPid) { continue }
                if ($entry.startedAtMs -and ([int64]$entry.startedAtMs -lt $monitorStartMs)) { continue }
                try {
                    $proc = Get-Process -Id ([int]$entry.osPid) -ErrorAction Stop
                    if ($proc) { $activeProcessCount += 1 }
                } catch {
                }
            }
        } catch {
            Write-MonitorLog "Process manager read failed: $($_.Exception.Message)"
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

    $files = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -Filter "rollout-*.jsonl" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $recentWindowStart } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 40)

    foreach ($file in $files) {
        $recentFileCount += 1
        if ($file.LastWriteTime -gt $latestActivity) {
            $latestActivity = $file.LastWriteTime
        }
    }

    foreach ($file in ($files | Select-Object -First 5)) {
        foreach ($line in (Get-TailJsonLines -Path $file.FullName -Tail 120)) {
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

try {
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
    $monitorStartedAt = Get-Date
    $lastCodexActivity = Get-Date
    Write-MonitorLog "Started: pid=$PID idleMinutes=$IdleMinutes shutdownDelay=$ShutdownDelaySeconds"

    while ($true) {
        Set-SystemAwake
        $activity = Get-CodexGlobalActivity -MonitorStartedAt $monitorStartedAt

        if ($activity.LatestActivity -gt $lastCodexActivity) {
            $lastCodexActivity = $activity.LatestActivity
        }

        if ($activity.ActiveProcessCount -gt 0) {
            $lastCodexActivity = Get-Date
            Write-MonitorLog "Active Codex-launched processes detected: $($activity.ActiveProcessCount)"
        } elseif ($activity.RateLimitBlocked) {
            Write-MonitorLog "Rate limit blocked detected"
            Request-Shutdown -DelaySeconds $ShutdownDelaySeconds
            break
        } else {
            $idleFor = ((Get-Date) - $lastCodexActivity).TotalMinutes
            Write-MonitorLog "Idle check: idleFor=$([math]::Round($idleFor, 2)) threshold=$IdleMinutes recentFiles=$($activity.RecentFileCount)"
            if ($idleFor -ge $IdleMinutes) {
                Write-MonitorLog "Idle threshold reached"
                Request-Shutdown -DelaySeconds $ShutdownDelaySeconds
                break
            }
        }

        Start-Sleep -Seconds 30
    }
} catch {
    Write-MonitorLog "Fatal error: $($_.Exception.Message)"
} finally {
    Clear-SystemAwake
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    Write-MonitorLog "Stopped"
}

param(
    [int]$IdleMinutes = 10,
    [int]$ShutdownDelaySeconds = 0,
    [string]$BaseDir = $PSScriptRoot,
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

$LogPath = Join-Path $BaseDir "CodexNightAssistant.log"
$PidPath = Join-Path $BaseDir "CodexShutdownMonitor.pid"
$StatusPath = Join-Path $BaseDir "CodexShutdownMonitor.status.json"

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

function Write-MonitorStatus {
    param($Status)
    try {
        $Status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
    } catch {
        Write-MonitorLog "Status write failed: $($_.Exception.Message)"
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
    Write-MonitorLog "Blocked direct shutdown from background monitor. UI confirmation is required. requestedDelay=$DelaySeconds dryRun=$DryRun"
}

function Get-TailJsonLines {
    param([string]$Path, [int]$Tail = 300)
    $maxBytes = 2097152
    $stream = $null
    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $readSize = [int][Math]::Min([int64]$maxBytes, $stream.Length)
        if ($readSize -le 0) { return @() }

        [void]$stream.Seek(-1 * $readSize, [System.IO.SeekOrigin]::End)
        $buffer = New-Object byte[] $readSize
        $bytesRead = $stream.Read($buffer, 0, $readSize)
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $bytesRead)
        $lines = $text -split "`r?`n"
        if ($stream.Length -gt $readSize -and $lines.Count -gt 1) {
            $lines = $lines[1..($lines.Count - 1)]
        }
        return @($lines |
            ForEach-Object { ([string]$_).TrimStart([char]0xFEFF) } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last $Tail)
    } catch {
        @()
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function ConvertFrom-UnixMs {
    param($Value)
    try {
        return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value)).LocalDateTime
    } catch {
        return $null
    }
}

function Get-EventTime {
    param($Event, [datetime]$Fallback)
    try {
        if ($Event.timestamp) {
            return ([DateTimeOffset]::Parse([string]$Event.timestamp)).LocalDateTime
        }
    } catch {
    }
    return $Fallback
}

function Get-TurnId {
    param($Event)
    foreach ($value in @(
        $Event.payload.turn_id,
        $Event.payload.internal_chat_message_metadata_passthrough.turn_id,
        $Event.payload.item.internal_chat_message_metadata_passthrough.turn_id,
        $Event.internal_chat_message_metadata_passthrough.turn_id
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    return $null
}

function Test-RateLimitBlocked {
    param($RateLimits)
    if ($null -eq $RateLimits) { return $false }

    try {
        if ($RateLimits.rate_limit_reached_type) { return $true }
        foreach ($bucket in (Get-RateLimitBuckets -RateLimits $RateLimits)) {
            if ($null -ne $bucket.UsedPercent -and [double]$bucket.UsedPercent -ge 100) {
                return $true
            }
        }
    } catch {
        return $false
    }

    return $false
}

function Add-RateLimitBuckets {
    param($Object, [string]$Prefix, [ref]$Buckets, [int]$Depth = 0)

    if ($null -eq $Object -or $Depth -gt 4) { return }
    if ($Object -is [string] -or $Object -is [ValueType]) { return }

    foreach ($prop in $Object.PSObject.Properties) {
        $value = $prop.Value
        if ($null -eq $value) { continue }
        if ($prop.Name -eq "rate_limit_reached_type") { continue }

        $name = if ([string]::IsNullOrWhiteSpace($Prefix)) { $prop.Name } else { "$Prefix.$($prop.Name)" }
        if ($value -is [string] -or $value -is [ValueType]) { continue }

        $used = $null
        foreach ($field in @("used_percent", "usage_percent", "percent_used", "percent")) {
            $fieldProp = $value.PSObject.Properties[$field]
            if ($fieldProp -and $null -ne $fieldProp.Value) {
                try {
                    $used = [double]$fieldProp.Value
                    break
                } catch {
                }
            }
        }

        if ($null -ne $used) {
            $Buckets.Value += [pscustomobject]@{
                Name = $name
                UsedPercent = $used
            }
        }

        Add-RateLimitBuckets -Object $value -Prefix $name -Buckets $Buckets -Depth ($Depth + 1)
    }
}

function Get-RateLimitBuckets {
    param($RateLimits)

    $buckets = @()
    Add-RateLimitBuckets -Object $RateLimits -Prefix "" -Buckets ([ref]$buckets)
    return $buckets
}

function Get-RateLimitText {
    param($RateLimits)
    if ($null -eq $RateLimits) { return "rate info unavailable" }

    try {
        $parts = @()
        foreach ($bucket in (Get-RateLimitBuckets -RateLimits $RateLimits | Sort-Object Name | Select-Object -First 6)) {
            $parts += "$($bucket.Name) $([math]::Round([double]$bucket.UsedPercent, 1))%"
        }
        if ($RateLimits.rate_limit_reached_type) {
            $parts += "blocked $($RateLimits.rate_limit_reached_type)"
        }
        if ($parts.Count -gt 0) { return ($parts -join " / ") }
    } catch {
    }

    return "rate info read"
}

function Get-MaxRateLimitPercent {
    param($RateLimits)
    $max = $null
    try {
        foreach ($bucket in (Get-RateLimitBuckets -RateLimits $RateLimits)) {
            $number = [double]$bucket.UsedPercent
            if ($null -eq $max -or $number -gt $max) { $max = $number }
        }
    } catch {
    }
    return $max
}

function Get-CodexGlobalActivity {
    param([datetime]$MonitorStartedAt, [int]$ActiveGraceMinutes = 10)

    $sessionRoot = Join-Path $env:USERPROFILE ".codex\sessions"
    $processManagerPath = Join-Path $env:USERPROFILE ".codex\process_manager\chat_processes.json"
    $scanWindowStart = $MonitorStartedAt.AddHours(-6)
    $rateWindowStart = (Get-Date).AddHours(-6)
    $activeCutoff = (Get-Date).AddMinutes(-1 * [math]::Max(2, $ActiveGraceMinutes))
    $latestActivity = $MonitorStartedAt
    $rateLimitBlocked = $false
    $rateLimitText = "rate info unavailable"
    $rateLimitPercent = $null
    $rateLimitUpdatedAt = $null
    $recentFileCount = 0
    $activeProcessCount = 0
    $pendingToolCalls = @{}
    $turnStates = @{}

    if (Test-Path -LiteralPath $processManagerPath) {
        try {
            $processEntries = Get-Content -Raw -LiteralPath $processManagerPath -Encoding UTF8 | ConvertFrom-Json
            $monitorStartMs = [int64](([DateTimeOffset]$MonitorStartedAt.AddMinutes(-5)).ToUnixTimeMilliseconds())
            foreach ($entry in $processEntries) {
                $startedAt = ConvertFrom-UnixMs -Value $entry.startedAtMs
                $updatedAt = ConvertFrom-UnixMs -Value $entry.updatedAtMs
                if ($startedAt -and $startedAt -lt $MonitorStartedAt.AddHours(-6)) { continue }
                if ($updatedAt -and $updatedAt -gt $latestActivity) { $latestActivity = $updatedAt }

                if ($entry.osPid) {
                    try {
                        $proc = Get-Process -Id ([int]$entry.osPid) -ErrorAction Stop
                        if ($proc) { $activeProcessCount += 1 }
                    } catch {
                    }
                }
            }
        } catch {
            Write-MonitorLog "Process manager read failed: $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $sessionRoot) {
        $files = @(Get-ChildItem -LiteralPath $sessionRoot -Recurse -Filter "rollout-*.jsonl" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $scanWindowStart } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 12)

        foreach ($file in $files) {
            $recentFileCount += 1
            if ($file.LastWriteTime -gt $latestActivity) {
                $latestActivity = $file.LastWriteTime
            }

            foreach ($line in (Get-TailJsonLines -Path $file.FullName -Tail 300)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }

                try {
                    $event = $line | ConvertFrom-Json -ErrorAction Stop
                } catch {
                    continue
                }

                $eventTime = Get-EventTime -Event $event -Fallback $file.LastWriteTime
                $turnId = Get-TurnId -Event $event

                if ($eventTime -and $eventTime -gt $latestActivity) {
                    $latestActivity = $eventTime
                }

                if ($turnId -and $eventTime -and $eventTime -ge $scanWindowStart) {
                    if (-not $turnStates.ContainsKey($turnId)) {
                        $turnStates[$turnId] = [pscustomobject]@{
                            TurnId = $turnId
                            Started = $false
                            Completed = $false
                            LatestEvent = $eventTime
                        }
                    }
                    if ($eventTime -gt $turnStates[$turnId].LatestEvent) {
                        $turnStates[$turnId].LatestEvent = $eventTime
                    }
                }

                $eventType = [string]$event.type
                $eventPayloadType = [string]$event.payload.type

                if ($eventType -eq "response_item") {
                    $payloadType = [string]$event.payload.type
                    $callId = [string]$event.payload.call_id

                    if ($payloadType -eq "function_call" -or $payloadType -eq "custom_tool_call") {
                        if ($callId) { $pendingToolCalls[$callId] = $turnId }
                    } elseif ($payloadType -eq "function_call_output" -or $payloadType -eq "custom_tool_call_output") {
                        if ($callId -and $pendingToolCalls.ContainsKey($callId)) {
                            $pendingToolCalls.Remove($callId)
                        }
                    }
                }

                if ($eventType -eq "event_msg") {
                    if ($eventPayloadType -eq "task_started" -and $turnId) {
                        if ($turnStates.ContainsKey($turnId)) {
                            $turnStates[$turnId].Started = $true
                            $turnStates[$turnId].Completed = $false
                        }
                    } elseif ($eventPayloadType -eq "task_complete" -and $turnId) {
                        if ($turnStates.ContainsKey($turnId)) {
                            $turnStates[$turnId].Completed = $true
                        }
                    }

                    if ($eventPayloadType -eq "token_count") {
                        $effectiveRateTime = if ($eventTime) { $eventTime } else { $file.LastWriteTime }
                        if ($null -eq $rateLimitUpdatedAt -or $effectiveRateTime -gt $rateLimitUpdatedAt) {
                            $rateLimitUpdatedAt = $effectiveRateTime
                            $rateLimitText = Get-RateLimitText -RateLimits $event.payload.rate_limits
                            $rateLimitPercent = Get-MaxRateLimitPercent -RateLimits $event.payload.rate_limits
                            $rateLimitBlocked = Test-RateLimitBlocked -RateLimits $event.payload.rate_limits
                        }
                    }
                }
            }
        }
    }

    $activeTurns = @{}
    $recentTurns = @{}

    foreach ($state in $turnStates.Values) {
        if ($state.LatestEvent -and $state.LatestEvent -ge $activeCutoff) {
            $recentTurns[$state.TurnId] = $true
            if (-not $state.Completed) {
                $activeTurns[$state.TurnId] = $true
            }
        }
    }

    foreach ($key in @($pendingToolCalls.Keys)) {
        if ([string]::IsNullOrWhiteSpace([string]$key)) {
            $pendingToolCalls.Remove($key)
            continue
        }
        $pendingTurnId = [string]$pendingToolCalls[$key]
        if (-not [string]::IsNullOrWhiteSpace($pendingTurnId)) {
            $activeTurns[$pendingTurnId] = $true
        }
    }

    return [pscustomobject]@{
        LatestActivity = $latestActivity
        ActiveProcessCount = $activeProcessCount
        PendingToolCallCount = $pendingToolCalls.Count
        ActiveTurnCount = $activeTurns.Count
        RecentTurnCount = $recentTurns.Count
        RateLimitBlocked = $rateLimitBlocked
        RateLimitText = $rateLimitText
        RateLimitUsedPercent = $rateLimitPercent
        RateLimitUpdatedAt = $rateLimitUpdatedAt
        RecentFileCount = $recentFileCount
    }
}

try {
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII
    $monitorStartedAt = Get-Date
    $lastCodexActivity = Get-Date
    $readyChecks = 0
    Write-MonitorLog "Started: pid=$PID idleMinutes=$IdleMinutes shutdownDelay=$ShutdownDelaySeconds dryRun=$DryRun"
    Write-MonitorStatus -Status ([pscustomobject]@{
        MonitorStartedAt = $monitorStartedAt.ToString("yyyy-MM-dd HH:mm:ss")
        CheckedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        LatestActivity = $lastCodexActivity.ToString("yyyy-MM-dd HH:mm:ss")
        IdleForMinutes = 0
        IdleThresholdMinutes = $IdleMinutes
        ActiveProcessCount = 0
        PendingToolCallCount = 0
        ActiveTurnCount = 0
        RecentTurnCount = 0
        RateLimitBlocked = $false
        RateLimitText = "initializing"
        RateLimitUsedPercent = $null
        RateLimitUpdatedAt = $null
        RecentFileCount = 0
        ReadyChecks = 0
        ShutdownReady = $false
        Decision = "INITIALIZING"
    })

    while ($true) {
        Set-SystemAwake
        $activeGraceMinutes = [math]::Max(2, [math]::Min(30, $IdleMinutes))
        $activity = Get-CodexGlobalActivity -MonitorStartedAt $monitorStartedAt -ActiveGraceMinutes $activeGraceMinutes

        if ($activity.LatestActivity -gt $lastCodexActivity) {
            $lastCodexActivity = $activity.LatestActivity
        }

        $taskActive = (
            $activity.ActiveProcessCount -gt 0 -or
            $activity.PendingToolCallCount -gt 0 -or
            $activity.ActiveTurnCount -gt 0
        )
        $idleFor = ((Get-Date) - $lastCodexActivity).TotalMinutes
        $decision = ""
        $shutdownReady = $false

        if ($taskActive) {
            $readyChecks = 0
            if ($activity.RateLimitBlocked) {
                $decision = "RATE_BLOCKED_BUT_TASKS_ACTIVE"
            } else {
                $decision = "TASKS_ACTIVE_WAITING"
            }
        } elseif ($idleFor -ge $IdleMinutes) {
            $readyChecks += 1
            if ($activity.RateLimitBlocked) {
                $decision = "RATE_BLOCKED_IDLE_CONFIRM_$readyChecks"
            } else {
                $decision = "IDLE_CONFIRM_$readyChecks"
            }
            if ($readyChecks -ge 2) { $shutdownReady = $true }
        } else {
            $readyChecks = 0
            if ($activity.RateLimitBlocked) {
                $decision = "RATE_BLOCKED_WAITING_FOR_IDLE"
            } else {
                $decision = "WAITING_FOR_TASKS_OR_IDLE"
            }
        }

        $status = [pscustomobject]@{
            MonitorStartedAt = $monitorStartedAt.ToString("yyyy-MM-dd HH:mm:ss")
            CheckedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            LatestActivity = $lastCodexActivity.ToString("yyyy-MM-dd HH:mm:ss")
            IdleForMinutes = [math]::Round($idleFor, 1)
            IdleThresholdMinutes = $IdleMinutes
            ActiveProcessCount = $activity.ActiveProcessCount
            PendingToolCallCount = $activity.PendingToolCallCount
            ActiveTurnCount = $activity.ActiveTurnCount
            RecentTurnCount = $activity.RecentTurnCount
            RateLimitBlocked = [bool]$activity.RateLimitBlocked
            RateLimitText = $activity.RateLimitText
            RateLimitUsedPercent = $activity.RateLimitUsedPercent
            RateLimitUpdatedAt = if ($activity.RateLimitUpdatedAt) { $activity.RateLimitUpdatedAt.ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            RecentFileCount = $activity.RecentFileCount
            ReadyChecks = $readyChecks
            ShutdownReady = $shutdownReady
            Decision = $decision
        }
        Write-MonitorStatus -Status $status
        Write-MonitorLog "Check: active=$taskActive activeTurns=$($activity.ActiveTurnCount) recentTurns=$($activity.RecentTurnCount) tools=$($activity.PendingToolCallCount) processes=$($activity.ActiveProcessCount) idleFor=$([math]::Round($idleFor, 2)) rateLimit=$($activity.RateLimitBlocked) readyChecks=$readyChecks decision=$decision"

        if ($shutdownReady) {
            Write-MonitorLog "Shutdown condition confirmed. Waiting for UI confirmation."
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

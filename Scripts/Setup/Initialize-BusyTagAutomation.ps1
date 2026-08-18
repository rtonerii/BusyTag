<#
=============================================
Name:           Initialize-BusyTagAutomation.ps1
Author:         Rick Toner (Rick@XferWorx.com)
Create date:    08/17/2026
Description:    Validates and starts the BusyTag AutoHotkey listener.
Version:        1.00.000
Published:      
Modified By:    Rick Toner
Modified Date:  08/17/2026
Notes:          Setup and reset entry point for the public BusyTag-WisprFlow-Automation project.
Open Source:    This script is intended for public open-source distribution with the repository.
Restrictions:   See the repository README and license terms when published.
=============================================
#>

[CmdletBinding()]
param(
    [switch]$RestartListener
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.00.000'
$script:ScriptPublishedOn = ''
$script:ScriptDisplayName = [System.IO.Path]::GetFileName($PSCommandPath)
$script:ScriptPath = $PSCommandPath
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ahkPath = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
$ahkScriptPath = Join-Path $projectRoot 'Scripts\Runtime\BusyTag-WisprFlow.ahk'
$runtimeControllerPath = Join-Path $projectRoot 'Scripts\Runtime\Set-BusyTagDictationState.ps1'
$configPath = Join-Path $projectRoot 'Config\BusyTag.config.json'
$dictatingImagePath = Join-Path $projectRoot 'Images\Dictating-WisprFlow-240x280.png'
$statusPath = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Logs\BusyTagAutomation.status'
$runtimeDataDirectory = Split-Path -Parent $statusPath
$script:LogRetentionDays = 14

if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    try {
        $startupConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $configuredRetention = [int]$startupConfig.Runtime.LogRetentionDays
        if ($configuredRetention -ge 1 -and $configuredRetention -le 3650) {
            $script:LogRetentionDays = $configuredRetention
        }
    } catch {
        Write-Warning "Runtime log-retention setting could not be read; using default $($script:LogRetentionDays) days."
    }
}

<#
.SYNOPSIS
    Validates and starts the BusyTag AutoHotkey listener.

.DESCRIPTION
    Keeps setup and repair logic in PowerShell so the batch launcher remains a
    portable entry point. The listener writes a small status file when it has
    successfully loaded, allowing this script to verify the exact project
    script without depending only on process-command-line permissions.
#>
function Test-BusyTagRequiredFiles {
    <#
    .SYNOPSIS
        Verifies the files required by the BusyTag runtime are present.

    .DESCRIPTION
        Fails before starting AutoHotkey when a required runtime, configuration,
        or local image file is missing.
    #>
    $requiredFiles = @(
        $ahkPath,
        $ahkScriptPath,
        $runtimeControllerPath,
        $configPath,
        $dictatingImagePath
    )

    foreach ($path in $requiredFiles) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Required BusyTag file was not found: $path"
        }
    }
}

<#
.SYNOPSIS
    Checks whether the PowerShell runtime controller parses successfully.

.DESCRIPTION
    Performs a syntax-only validation before the AutoHotkey listener is started,
    catching malformed runtime edits during setup rather than during dictation.
#>
function Test-BusyTagPowerShellSyntax {
    $runtimeText = Get-Content -LiteralPath $runtimeControllerPath -Raw
    [void][scriptblock]::Create($runtimeText)
}

<#
.SYNOPSIS
    Removes old BusyTag log files from the current-user application-data folder.

.DESCRIPTION
    Keeps the local runtime history manageable without touching status markers,
    request flags, saved device state, or files elsewhere in the project. Logs
    older than 14 days are removed whenever the runtime is started.
#>
function Remove-BusyTagOldLogs {
    $runtimeDataDirectory = Split-Path -Parent $statusPath
    New-Item -ItemType Directory -Path $runtimeDataDirectory -Force | Out-Null
    $expirationDate = (Get-Date).AddDays(-$script:LogRetentionDays)
    $oldLogs = @(Get-ChildItem -LiteralPath $runtimeDataDirectory -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $expirationDate })

    foreach ($oldLog in $oldLogs) {
        Remove-Item -LiteralPath $oldLog.FullName -Force
    }

    Write-Host "Log cleanup: removed $($oldLogs.Count) file(s) older than $($script:LogRetentionDays) days."
}

<#
.SYNOPSIS
    Determines whether the current BusyTag listener reported itself as running.

.DESCRIPTION
    Uses the listener's status marker and validates the recorded PID. This is
    more reliable than requiring unrestricted access to Win32_Process command
    lines, while still confirming that the intended .ahk file loaded.
#>
function Test-BusyTagListenerRunning {
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
        return $false
    }

    $status = @{}
    foreach ($line in Get-Content -LiteralPath $statusPath) {
        if ($line -match '^(?<Name>[^=]+)=(?<Value>.*)$') {
            $status[$Matches.Name] = $Matches.Value
        }
    }

    if ($status.Status -ne 'Running' -or $status.Script -ne $ahkScriptPath) {
        return $false
    }

    $listenerPid = 0
    if (-not [int]::TryParse($status.PID, [ref]$listenerPid) -or $listenerPid -le 0) {
        return $false
    }

    try {
        $process = Get-Process -Id $listenerPid -ErrorAction Stop
        if ($process.ProcessName -notlike 'AutoHotkey*') {
            return $false
        }

        if ($process.Path -and ([System.IO.Path]::GetFullPath($process.Path) -ne [System.IO.Path]::GetFullPath($ahkPath))) {
            return $false
        }

        return $true
    } catch {
        return $false
    }
}

<#
.SYNOPSIS
    Waits for the listener to publish its running status.

.DESCRIPTION
    Gives AutoHotkey time to parse and load the listener, then verifies the
    status marker and PID rather than assuming Start-Process succeeded.
#>
function Wait-BusyTagListener {
    param(
        [int]$TimeoutMilliseconds = 5000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    do {
        if (Test-BusyTagListenerRunning) {
            return $true
        }

        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)

    return $false
}

<#
.SYNOPSIS
    Stops existing AutoHotkey processes before a deliberate runtime reset.

.DESCRIPTION
    The project launcher is a reset/reconfigure action, so it clears duplicate
    AutoHotkey listeners before loading the current project script. This avoids
    multiple wildcard hotkey handlers receiving the same Ctrl+Windows events.
#>
function Stop-BusyTagAutoHotkeyProcesses {
    $processes = @(Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        Write-Host 'No existing AutoHotkey processes were found.'
        return
    }

    $processes | Select-Object Id, ProcessName | Format-Table -AutoSize | Out-Host
    $processes | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    Write-Host "Stopped $($processes.Count) existing AutoHotkey process(es)."
}

Write-Host 'BusyTag automation setup' -ForegroundColor Cyan
Write-Host "Project root: $projectRoot"
Write-Host "AutoHotkey executable: $ahkPath"
Write-Host "AutoHotkey script:     $ahkScriptPath"
Write-Host "Runtime data folder:   $runtimeDataDirectory"
Write-Host "Log retention days:    $($script:LogRetentionDays)"
Remove-BusyTagOldLogs

$busyTagProcesses = @(Get-Process -Name 'BusyTag' -ErrorAction SilentlyContinue)
if ($busyTagProcesses.Count -gt 0) {
    Write-Warning "BusyTag.exe is currently running (PID $($busyTagProcesses[0].Id)) and may own COM3. The setup script does not close it."
} else {
    Write-Host 'BusyTag.exe: not running.'
}

Test-BusyTagRequiredFiles
Test-BusyTagPowerShellSyntax

# 2026-08-14: A batch launch is now an explicit reset/reconfigure action.
# Prior 2026-08-14 logic:
# if (Test-BusyTagListenerRunning) { ... exit 0 }
if ($RestartListener) {
    Stop-BusyTagAutoHotkeyProcesses
} elseif (Test-BusyTagListenerRunning) {
    Write-Host 'BusyTag automation is already running and verified.' -ForegroundColor Green
    Write-Host ((Get-Content -LiteralPath $statusPath) -join ' | ')
    exit 0
}

Write-Host 'Starting the BusyTag AutoHotkey listener...'
# Start-Process on Windows PowerShell does not consistently quote array arguments
# containing spaces, so quote the script path explicitly before passing it to AHK.
# Prior 2026-08-14 logic:
# Start-Process -FilePath $ahkPath -ArgumentList @($ahkScriptPath) -WorkingDirectory (Split-Path -Parent $ahkScriptPath)
Start-Process -FilePath $ahkPath -ArgumentList ('"' + $ahkScriptPath + '"') -WorkingDirectory (Split-Path -Parent $ahkScriptPath)

if (-not (Wait-BusyTagListener)) {
    throw "AutoHotkey started, but the BusyTag listener did not publish a valid running status. Check $statusPath and the runtime log."
}

Write-Host 'BusyTag automation started and was verified running.' -ForegroundColor Green
Write-Host ((Get-Content -LiteralPath $statusPath) -join ' | ')
exit 0

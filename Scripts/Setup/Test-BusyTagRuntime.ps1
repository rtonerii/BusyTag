<#
=============================================
Name:           Test-BusyTagRuntime.ps1
Author:         Rick Toner (Rick@XferWorx.com)
Create date:    08/17/2026
Description:    Runs a read-only BusyTag runtime diagnostic.
Version:        1.00.000
Published:      
Modified By:    Rick Toner
Modified Date:  08/17/2026
Notes:          Diagnostic script for the public BusyTag-WisprFlow-Automation project.
Open Source:    This script is intended for public open-source distribution with the repository.
Restrictions:   See the repository README and license terms when published.
=============================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.00.000'
$script:ScriptPublishedOn = ''
$script:ScriptDisplayName = [System.IO.Path]::GetFileName($PSCommandPath)
$script:ScriptPath = $PSCommandPath
$totalTimer = [System.Diagnostics.Stopwatch]::StartNew()
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$configPath = Join-Path $projectRoot 'Config\BusyTag.config.json'
$stateScriptPath = Join-Path $projectRoot 'Scripts\Setup\Get-BusyTagState.ps1'
$runtimeScriptPath = Join-Path $projectRoot 'Scripts\Runtime\Set-BusyTagDictationState.ps1'
$hotkeyScriptPath = Join-Path $projectRoot 'Scripts\Runtime\BusyTag-WisprFlow.ahk'
$logPath = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Logs\BusyTagAutomation.log'
$statusPath = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Logs\BusyTagAutomation.status'
# 2026-08-17: Validate the same user-local CLI path used by the runtime.
# Prior 2026-08-17 logic:
# $defaultCliPath = Join-Path $env:USERPROFILE 'busytag-cli\tools\net8.0\any\busytag-cli.dll'
$defaultCliPath = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Runtime\BusyTag.CLI\tools\net8.0\any\busytag-cli.dll'

Write-Host ''
Write-Host 'BusyTag Runtime Diagnostic' -ForegroundColor Cyan
Write-Host '==========================' -ForegroundColor Cyan
Write-Host "Timestamp:    $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Host "Project root: $projectRoot"
Write-Host 'Mode:         READ-ONLY (no applications, device files, or settings will be changed)'

Write-Host ''
Write-Host '[1] Project files' -ForegroundColor Yellow
$requiredFiles = @(
    $configPath,
    $stateScriptPath,
    $runtimeScriptPath,
    $hotkeyScriptPath,
    $defaultCliPath
)

foreach ($file in $requiredFiles) {
    $exists = Test-Path -LiteralPath $file
    Write-Host ('{0,-7} {1}' -f $(if ($exists) { 'OK' } else { 'MISSING' }), $file)
}

$config = $null
if (Test-Path -LiteralPath $configPath) {
    try {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "INVALID configuration: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$port = if ($null -ne $config -and $config.Port) { [string]$config.Port } else { 'COM3' }
$dictatingImageName = if ($null -ne $config -and $config.DictatingImage) {
    [string]$config.DictatingImage
} else {
    'Dictating-WisprFlow-240x280.png'
}
$localDictatingImage = Join-Path $projectRoot "Images\$dictatingImageName"

Write-Host ''
Write-Host '[2] Relevant processes' -ForegroundColor Yellow
$processTimer = [System.Diagnostics.Stopwatch]::StartNew()
$relevantProcesses = @()
$processQueryWarning = $null
# 2026-08-14: Added a permission-tolerant process fallback so diagnostics do
# not abort when Win32_Process command-line access is denied.
# Prior 2026-08-14 logic:
# $relevantProcesses = @(Get-CimInstance Win32_Process | Where-Object { ... })
try {
    $relevantProcesses = @(
        Get-CimInstance Win32_Process |
            Where-Object {
                $_.Name -match '^(BusyTag|Luxafor|AutoHotkey).*\.exe$' -or
                $_.CommandLine -match 'BusyTag-WisprFlow\.ahk'
            } |
            Select-Object ProcessId, Name, ExecutablePath, CommandLine
    )
} catch {
    $processQueryWarning = $_.Exception.Message
    $relevantProcesses = @(
        Get-Process -Name 'BusyTag','Luxafor*','AutoHotkey*' -ErrorAction SilentlyContinue |
            Select-Object @{Name='ProcessId'; Expression={$_.Id}}, @{Name='Name'; Expression={$_.ProcessName}}, Path
    )
}
$processTimer.Stop()

if ($null -ne $processQueryWarning) {
    Write-Host "Detailed process command lines unavailable: $processQueryWarning" -ForegroundColor Yellow
}

if ($relevantProcesses.Count -eq 0) {
    Write-Host 'No BusyTag, Luxafor, or AutoHotkey runtime processes were found.'
} else {
    $relevantProcesses | Format-Table ProcessId, Name, ExecutablePath -AutoSize
    foreach ($process in $relevantProcesses) {
        if ($process.CommandLine -match 'BusyTag-WisprFlow\.ahk') {
            Write-Host "Hotkey runtime PID $($process.ProcessId): $($process.CommandLine)"
        }
    }
}
Write-Host "Process-check time: $($processTimer.ElapsedMilliseconds) ms"

$busyTagRunning = @($relevantProcesses | Where-Object { $_.Name -match '^BusyTag(\.exe)?$' }).Count -gt 0
$luxaforRunning = @($relevantProcesses | Where-Object Name -match '^Luxafor.*\.exe$').Count -gt 0
$hotkeyRunning = $false
if (Test-Path -LiteralPath $statusPath) {
    $statusLines = Get-Content -LiteralPath $statusPath
    $statusMap = @{}
    foreach ($line in $statusLines) {
        if ($line -match '^(?<Name>[^=]+)=(?<Value>.*)$') {
            $statusMap[$Matches.Name] = $Matches.Value
        }
    }

    if ($statusMap.Status -eq 'Running' -and $statusMap.Script -eq $hotkeyScriptPath) {
        try {
            $hotkeyProcess = Get-Process -Id ([int]$statusMap.PID) -ErrorAction Stop
            $hotkeyRunning = $hotkeyProcess.ProcessName -like 'AutoHotkey*'
        } catch {
            $hotkeyRunning = $false
        }
    }
}

Write-Host ''
Write-Host '[3] Local Dictating image' -ForegroundColor Yellow
if (Test-Path -LiteralPath $localDictatingImage) {
    $localImageFile = Get-Item -LiteralPath $localDictatingImage
    $localImageHash = (Get-FileHash -LiteralPath $localDictatingImage -Algorithm SHA256).Hash
    Write-Host 'Status:  PRESENT'
    Write-Host "Path:    $localDictatingImage"
    Write-Host "Size:    $($localImageFile.Length) bytes"
    Write-Host "SHA-256: $localImageHash"
} else {
    Write-Host 'Status:  MISSING' -ForegroundColor Red
    Write-Host "Path:    $localDictatingImage"
}

Write-Host ''
Write-Host "[4] Device state and $port access" -ForegroundColor Yellow
$stateTimer = [System.Diagnostics.Stopwatch]::StartNew()
$deviceState = $null
$stateError = $null

if (-not (Test-Path -LiteralPath $stateScriptPath)) {
    $stateError = "State script is missing: $stateScriptPath"
} else {
    try {
        $deviceState = & $stateScriptPath
    } catch {
        $stateError = $_.Exception.Message
    }
}
$stateTimer.Stop()

if ($null -ne $deviceState) {
    Write-Host 'COM access:    ACCESSIBLE' -ForegroundColor Green
    Write-Host "Current image: $($deviceState.CurrentImage)"
    Write-Host "LED pins:      $($deviceState.LedPins)"
    Write-Host "LED color:     $($deviceState.LedHex)"
} else {
    Write-Host 'COM access:    BLOCKED OR UNAVAILABLE' -ForegroundColor Red
    Write-Host "Error:         $stateError"
    if ($busyTagRunning -or $luxaforRunning) {
        Write-Host 'Likely cause:  BusyTag or Luxafor currently owns the COM port.'
    }
}
Write-Host "State-query time: $($stateTimer.ElapsedMilliseconds) ms"

Write-Host ''
Write-Host '[5] Images stored on the device' -ForegroundColor Yellow
$filesTimer = [System.Diagnostics.Stopwatch]::StartNew()
$deviceFiles = @()
$fileListError = $null

if ($null -eq $deviceState) {
    $fileListError = 'Skipped because the COM port was not accessible.'
} elseif (-not (Test-Path -LiteralPath $defaultCliPath)) {
    $fileListError = "BusyTag CLI was not found: $defaultCliPath"
} else {
    try {
        $cliOutput = @(& dotnet $defaultCliPath files $port 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) {
            throw ($cliOutput -join [Environment]::NewLine)
        }

        foreach ($line in $cliOutput) {
            if ($line -match '^\s*\[IMG\]\s+(.+?)\s+-\s+') {
                $deviceFiles += $Matches[1].Trim()
            }
        }
    } catch {
        $fileListError = $_.Exception.Message
    }
}
$filesTimer.Stop()

if ($null -ne $fileListError) {
    Write-Host "Unable to list device files: $fileListError" -ForegroundColor Red
} else {
    Write-Host "Image count: $($deviceFiles.Count)"
    foreach ($deviceFile in $deviceFiles) {
        $marker = if ($deviceFile -ieq $dictatingImageName) { '  <== REQUIRED DICTATING IMAGE' } else { '' }
        Write-Host " - $deviceFile$marker"
    }
}

$dictatingImageOnDevice = @($deviceFiles | Where-Object { $_ -ieq $dictatingImageName }).Count -gt 0
if ($null -eq $fileListError) {
    if ($dictatingImageOnDevice) {
        Write-Host 'Dictating image on device: PRESENT' -ForegroundColor Green
    } else {
        Write-Host 'Dictating image on device: MISSING' -ForegroundColor Red
    }
}
Write-Host "Device-file-list time: $($filesTimer.ElapsedMilliseconds) ms"

Write-Host ''
Write-Host '[6] Recent automation log' -ForegroundColor Yellow
if (Test-Path -LiteralPath $logPath) {
    Get-Content -LiteralPath $logPath -Tail 12
} else {
    Write-Host "No automation log exists at $logPath"
}

$totalTimer.Stop()
Write-Host ''
Write-Host '[7] Summary' -ForegroundColor Yellow
Write-Host "AutoHotkey runtime: $(if ($hotkeyRunning) { 'RUNNING' } else { 'NOT RUNNING' })"
Write-Host "BusyTag app:        $(if ($busyTagRunning) { 'RUNNING' } else { 'NOT RUNNING' })"
Write-Host "Luxafor app:        $(if ($luxaforRunning) { 'RUNNING' } else { 'NOT RUNNING' })"
Write-Host "$port access:         $(if ($null -ne $deviceState) { 'ACCESSIBLE' } else { 'BLOCKED/UNAVAILABLE' })"
Write-Host "Local image:        $(if (Test-Path -LiteralPath $localDictatingImage) { 'PRESENT' } else { 'MISSING' })"
Write-Host "Device image:       $(if ($null -ne $fileListError) { 'UNKNOWN' } elseif ($dictatingImageOnDevice) { 'PRESENT' } else { 'MISSING' })"
Write-Host "Total diagnostic time: $($totalTimer.ElapsedMilliseconds) ms"
Write-Host ''
Write-Host 'No changes were made.' -ForegroundColor Cyan

<#
=============================================
Name:           Set-BusyTagDictationState.ps1
Author:         Rick Toner (Rick@XferWorx.com)
Create date:    08/17/2026
Description:    Captures, applies, and restores BusyTag dictation state.
Version:        1.00.000
Published:      
Modified By:    Rick Toner
Modified Date:  08/17/2026
Notes:          Runtime controller for the public BusyTag-WisprFlow-Automation project.
Open Source:    This script is intended for public open-source distribution with the repository.
Restrictions:   See the repository README and license terms when published.
=============================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Stop')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.00.000'
$script:ScriptPublishedOn = ''
$script:ScriptDisplayName = [System.IO.Path]::GetFileName($PSCommandPath)
$script:ScriptPath = $PSCommandPath
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$ConfigPath = Join-Path $ProjectRoot 'Config\BusyTag.config.json'
$LogDirectory = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Logs'
$StatePath = Join-Path $LogDirectory 'PreviousState.json'
$LogPath = Join-Path $LogDirectory 'BusyTagAutomation.log'
$RequestFlagPath = Join-Path $LogDirectory 'DictationRequested.flag'
# 2026-08-17: Use the user-local provisioned CLI so the project does not depend
# on a manually maintained installation under the user's profile root.
# Prior 2026-08-17 logic:
# $CliPath = Join-Path $env:USERPROFILE 'busytag-cli\tools\net8.0\any\busytag-cli.dll'
$CliPath = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Runtime\BusyTag.CLI\tools\net8.0\any\busytag-cli.dll'

# 2026-08-17: Avoid a directory metadata write on every Start/Stop action.
# Prior 2026-08-17 logic:
# New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

function Write-AutomationLog {
    param([string]$Message)
    Add-Content -LiteralPath $LogPath -Value ('{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] {2}' -f (Get-Date), $Action, $Message)
}

function Invoke-BusyTagCommand {
    param(
        [Parameter(Mandatory)] [System.IO.Ports.SerialPort]$SerialPort,
        [Parameter(Mandatory)] [string]$Command,
        [Parameter(Mandatory)] [string]$ExpectedPattern,
        [int]$TimeoutMilliseconds = 2500
    )

    $SerialPort.DiscardInBuffer()
    $SerialPort.Write("$Command`r`n")
    $response = ''
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        # 2026-08-17: Read before sleeping so fast device responses are handled
        # immediately instead of waiting through the polling interval.
        # Prior 2026-08-17 logic:
        # Start-Sleep -Milliseconds 40
        # $response += $SerialPort.ReadExisting()
        $response += $SerialPort.ReadExisting()

        if ($response -match 'ERROR:\d+') {
            throw "BusyTag rejected '$Command': $($response.Trim())"
        }
        if ($response -match $ExpectedPattern) {
            return $response.Trim()
        }

        Start-Sleep -Milliseconds 20
    }

    throw "Timed out waiting for BusyTag after '$Command'. Response: $($response.Trim())"
}

function Get-BusyTagState {
    param([System.IO.Ports.SerialPort]$SerialPort)

    $imageRaw = Invoke-BusyTagCommand -SerialPort $SerialPort -Command 'AT+SP?' -ExpectedPattern '\+SP:'
    $ledRaw = Invoke-BusyTagCommand -SerialPort $SerialPort -Command 'AT+SC?' -ExpectedPattern '\+SC:'

    if ($imageRaw -notmatch '\+SP:([^\r\n]+)') {
        throw "Could not parse the current BusyTag image: $imageRaw"
    }
    $imageName = $Matches[1].Trim()

    if ($ledRaw -notmatch '\+SC:(\d+),([0-9A-Fa-f]{6})') {
        throw "Could not parse the current BusyTag LED state: $ledRaw"
    }

    [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        Port = $SerialPort.PortName
        CurrentImage = $imageName
        LedPins = [int]$Matches[1]
        LedHex = $Matches[2].ToUpperInvariant()
    }
}

function Test-DictationRequested {
    <#
    .SYNOPSIS
        Checks whether the AutoHotkey listener still requests dictation mode.

    .DESCRIPTION
        Allows the slow upload fallback to cancel after a key release without
        continuing to change the device after the user has stopped dictating.
    #>
    return Test-Path -LiteralPath $RequestFlagPath -PathType Leaf
}

function Invoke-BusyTagImageUpload {
    <#
    .SYNOPSIS
        Uploads the configured dictation image to the BusyTag device.

    .DESCRIPTION
        Repairs the device when an application reconciliation removed the
        unmanaged dictation image. The capped retries handle transient COM/CLI
        failures without repeatedly listing the device contents.
    #>
    param(
        [Parameter(Mandatory)] [string]$Port,
        [Parameter(Mandatory)] [string]$ImagePath,
        [int]$MaximumAttempts = 3
    )

    if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) {
        throw "BusyTag CLI was not found: $CliPath"
    }

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        if (-not (Test-DictationRequested)) {
            Write-AutomationLog 'CANCELLED: dictation was released before image upload.'
            return $false
        }

        $uploadOutput = @(& dotnet $CliPath upload $Port $ImagePath 2>&1 | ForEach-Object { $_.ToString() })
        $uploadText = $uploadOutput -join ' '
        # 2026-08-14: Detect CLI-reported failures because this CLI can return
        # exit code 0 even when its output says "Upload failed".
        # Prior 2026-08-14 logic:
        # if ($LASTEXITCODE -eq 0) {
        if ($LASTEXITCODE -eq 0 -and $uploadText -notmatch '(?i)upload failed|access to the path|error') {
            Write-AutomationLog "Dictating image upload succeeded on attempt $attempt."
            return Test-DictationRequested
        }

        Write-AutomationLog "Dictating image upload attempt $attempt failed: $uploadText"
        if ($attempt -lt $MaximumAttempts) {
            Start-Sleep -Milliseconds 500
        }
    }

    throw 'The dictation image could not be uploaded after three attempts.'
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$mutex = [System.Threading.Mutex]::new($false, 'Local\XferWorx.BusyTag.WisprFlow')
$hasMutex = $false
$serialPort = $null

try {
    $hasMutex = $mutex.WaitOne(10000)
    if (-not $hasMutex) {
        throw 'Another BusyTag action did not finish within 10 seconds.'
    }

    if ($Action -eq 'Start') {
        if (-not (Test-DictationRequested)) {
            Write-AutomationLog 'CANCELLED: dictation was released before startup.'
            exit 0
        }

        # 2026-08-14: Expanded shutdown coverage to include Luxafor processes.
        # Prior 2026-08-14 logic:
        # $busyTagProcesses = Get-Process -Name 'BusyTag' -ErrorAction SilentlyContinue
        # if ($null -ne $busyTagProcesses) { $busyTagProcesses | Stop-Process -Force }
        $managedProcesses = @(
            @(Get-Process -Name 'BusyTag' -ErrorAction SilentlyContinue)
            @(Get-Process -Name 'Luxafor*' -ErrorAction SilentlyContinue)
        ) | Where-Object { $null -ne $_ }
        if ($managedProcesses.Count -gt 0) {
            $managedProcesses | Stop-Process -Force

            $processDeadline = (Get-Date).AddSeconds(5)
            while ((Get-Process -Name 'BusyTag' -ErrorAction SilentlyContinue) -and
                   (Get-Date) -lt $processDeadline) {
                Start-Sleep -Milliseconds 100
            }

            if ((Get-Process -Name 'BusyTag' -ErrorAction SilentlyContinue) -or
                (Get-Process -Name 'Luxafor*' -ErrorAction SilentlyContinue)) {
                throw 'BusyTag or Luxafor did not close within 5 seconds.'
            }

            Write-AutomationLog 'BusyTag/Luxafor desktop apps were closed and will remain closed.'
        }
    }

    $serialPort = [System.IO.Ports.SerialPort]::new([string]$config.Port, [int]$config.BaudRate)
    $serialPort.NewLine = "`r`n"
    $serialPort.ReadTimeout = 250
    $serialPort.WriteTimeout = 1000
    $serialPort.DtrEnable = $true
    $serialPort.RtsEnable = $true

    $openDeadline = (Get-Date).AddSeconds(5)
    while (-not $serialPort.IsOpen) {
        try {
            $serialPort.Open()
        } catch [System.UnauthorizedAccessException] {
            if ((Get-Date) -ge $openDeadline) {
                throw
            }
            Start-Sleep -Milliseconds 150
        }
    }
    Start-Sleep -Milliseconds 100

    if ($Action -eq 'Start') {
        $previousState = Get-BusyTagState -SerialPort $serialPort
        $previousState | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8

        if (-not (Test-DictationRequested)) {
            Write-AutomationLog 'CANCELLED: dictation was released before display.'
            exit 0
        }

        try {
            Invoke-BusyTagCommand -SerialPort $serialPort -Command "AT+SP=$($config.DictatingImage)" -ExpectedPattern 'OK' | Out-Null
        } catch {
            if ($_.Exception.Message -notmatch 'ERROR:3') {
                throw
            }

            # 2026-08-14: Added upload fallback because managed desktop apps can
            # remove the locally uploaded image from the device file set.
            if ($serialPort.IsOpen) {
                $serialPort.Close()
            }
            $imagePath = Join-Path $ProjectRoot "Images\$($config.DictatingImage)"
            if (-not (Invoke-BusyTagImageUpload -Port $serialPort.PortName -ImagePath $imagePath)) {
                exit 0
            }
            $serialPort.Open()
            Start-Sleep -Milliseconds 100
            Invoke-BusyTagCommand -SerialPort $serialPort -Command "AT+SP=$($config.DictatingImage)" -ExpectedPattern 'OK' | Out-Null
        }

        if (-not (Test-DictationRequested)) {
            Write-AutomationLog 'CANCELLED: dictation was released before LED override.'
            exit 0
        }

        Invoke-BusyTagCommand -SerialPort $serialPort -Command "AT+SC=$($config.DictatingLedPins),$($config.DictatingLedHex)" -ExpectedPattern 'OK' | Out-Null
        Write-AutomationLog "Dictating state enabled; saved image '$($previousState.CurrentImage)' and LED $($previousState.LedHex)."
    } else {
        if (-not (Test-Path -LiteralPath $StatePath)) {
            Write-AutomationLog 'No saved state was present; nothing was restored.'
            exit 0
        }

        $previousState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        Invoke-BusyTagCommand -SerialPort $serialPort -Command "AT+SP=$($previousState.CurrentImage)" -ExpectedPattern 'OK' | Out-Null
        Invoke-BusyTagCommand -SerialPort $serialPort -Command "AT+SC=$($previousState.LedPins),$($previousState.LedHex)" -ExpectedPattern 'OK' | Out-Null
        Remove-Item -LiteralPath $StatePath -Force
        Write-AutomationLog "Previous state restored: image '$($previousState.CurrentImage)' and LED $($previousState.LedHex)."
    }
} catch {
    Write-AutomationLog "ERROR: $($_.Exception.Message)"
    Write-Error $_
    exit 1
} finally {
    if ($null -ne $serialPort) {
        if ($serialPort.IsOpen) {
            $serialPort.Close()
        }
        $serialPort.Dispose()
    }
    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}

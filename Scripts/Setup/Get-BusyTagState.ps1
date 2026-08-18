<#
=============================================
Name:           Get-BusyTagState.ps1
Author:         Rick Toner (Rick@XferWorx.com)
Create date:    08/17/2026
Description:    Reads the current BusyTag image and LED state.
Version:        1.00.000
Published:      
Modified By:    Rick Toner
Modified Date:  08/17/2026
Notes:          Read-only device diagnostic for the public BusyTag-WisprFlow-Automation project.
Open Source:    This script is intended for public open-source distribution with the repository.
Restrictions:   See the repository README and license terms when published.
=============================================
#>

[CmdletBinding()]
param(
    [string]$Port = 'COM3',
    [int]$BaudRate = 1500000
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.00.000'
$script:ScriptPublishedOn = ''
$script:ScriptDisplayName = [System.IO.Path]::GetFileName($PSCommandPath)
$script:ScriptPath = $PSCommandPath

function Invoke-BusyTagReadCommand {
    param(
        [Parameter(Mandatory)]
        [System.IO.Ports.SerialPort]$SerialPort,

        [Parameter(Mandatory)]
        [string]$Command,

        [int]$TimeoutMilliseconds = 2000
    )

    $SerialPort.DiscardInBuffer()
    $SerialPort.WriteLine($Command)

    $response = [System.Text.StringBuilder]::new()
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)

    do {
        Start-Sleep -Milliseconds 50
        $chunk = $SerialPort.ReadExisting()

        if ($chunk) {
            [void]$response.Append($chunk)
        }

        $responseText = $response.ToString()
    }
    until (
        $responseText -match 'OK\r?\n' -or
        $responseText -match 'ERROR:\d+' -or
        [DateTime]::UtcNow -ge $deadline
    )

    return $response.ToString().Trim()
}

$serialPort = [System.IO.Ports.SerialPort]::new(
    $Port,
    $BaudRate,
    [System.IO.Ports.Parity]::None,
    8,
    [System.IO.Ports.StopBits]::One
)

$serialPort.NewLine = "`r`n"
$serialPort.ReadTimeout = 2000
$serialPort.WriteTimeout = 2000
$serialPort.DtrEnable = $false
$serialPort.RtsEnable = $true

try {
    $serialPort.Open()

    $imageResponse = Invoke-BusyTagReadCommand -SerialPort $serialPort -Command 'AT+SP?'
    $ledResponse = Invoke-BusyTagReadCommand -SerialPort $serialPort -Command 'AT+SC?'

    $currentImage = if ($imageResponse -match '\+SP:([^\r\n]+)') {
        $Matches[1]
    }
    else {
        $null
    }

    $ledPins = $null
    $ledHex = $null

    if ($ledResponse -match '\+SC:(\d+),([0-9A-Fa-f]{6})') {
        $ledPins = [int]$Matches[1]
        $ledHex = $Matches[2].ToUpperInvariant()
    }

    # 2026-08-14: Return the state object directly so diagnostic callers can
    # reliably inspect its properties instead of receiving formatting records.
    # Prior 2026-08-14 logic:
    # [pscustomobject]@{ ... } | Format-List
    [pscustomobject]@{
        Timestamp    = Get-Date
        Port         = $Port
        CurrentImage = $currentImage
        LedPins      = $ledPins
        LedHex       = $ledHex
        ImageRaw     = $imageResponse
        LedRaw       = $ledResponse
    }
}
finally {
    if ($serialPort.IsOpen) {
        $serialPort.Close()
    }

    $serialPort.Dispose()
}

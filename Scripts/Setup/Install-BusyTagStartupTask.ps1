<#
=============================================
Name:           Install-BusyTagStartupTask.ps1
Author:         Rick Toner (Rick@XferWorx.com)
Create date:    08/17/2026
Description:    Installs or removes the BusyTag logon scheduled task.
Version:        1.00.000
Published:      
Modified By:    Rick Toner
Modified Date:  08/17/2026
Notes:          Public open-source startup installer for BusyTag-WisprFlow-Automation.
Open Source:    This script is intended for public open-source distribution with the repository.
Restrictions:   See the repository README and license terms when published.
=============================================
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$ProvisionCliOnly
)

$ErrorActionPreference = 'Stop'
$script:ScriptVersion = '1.00.000'
$script:ScriptPublishedOn = ''
$script:ScriptDisplayName = [System.IO.Path]::GetFileName($PSCommandPath)
$script:ScriptPath = $PSCommandPath
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$startupDirectory = Join-Path $projectRoot 'Scripts\Startup'
$logDirectory = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Logs'
$runtimeDirectory = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Runtime'
$powerShellHostFile = Join-Path $runtimeDirectory 'PowerShellHost.txt'
# 2026-08-20: Persist the host that performed installation so scheduled and
# manual launches use the same PowerShell edition and executable.
$powerShellHostPath = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
} else {
    Join-Path $PSHOME 'powershell.exe'
}
$cliInstallDirectory = Join-Path $env:LOCALAPPDATA 'XferWorx\BusyTag-WisprFlow\Runtime\BusyTag.CLI'
$cliPath = Join-Path $cliInstallDirectory 'tools\net8.0\any\busytag-cli.dll'
$cliVersion = '0.6.2'
# 2026-08-17: NuGet flat-container paths are lowercase and case-sensitive.
# Prior 2026-08-17 logic:
# $cliPackageUri = "https://api.nuget.org/v3-flatcontainer/busyTag.cli/$cliVersion/busytag.cli.$cliVersion.nupkg"
$cliPackageUri = "https://api.nuget.org/v3-flatcontainer/busytag.cli/$cliVersion/busytag.cli.$cliVersion.nupkg"
$installLogPath = Join-Path $logDirectory 'StartupTaskInstall.log'
$taskPath = '\XferWorx\'
# 2026-08-17: Use a filename-safe task identifier; the description remains
# human-readable for Task Scheduler viewers.
# Prior 2026-08-17 logic:
# $taskName = 'BusyTag Automation'
$taskName = 'BusyTag-Automation'

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Write-BusyTagInstallLog {
    param([Parameter(Mandatory)] [string]$Message)

    try {
        Add-Content -LiteralPath $installLogPath -Value ('{0:yyyy-MM-dd HH:mm:ss.fff} {1}' -f (Get-Date), $Message)
    } catch {
        # Installation diagnostics must never prevent the actual install result.
    }
}

<#
.SYNOPSIS
    Verifies the host files required for a complete BusyTag installation.

.DESCRIPTION
    Checks the selected PowerShell executable, AutoHotkey v2, the project
    listener, and the scheduled-start batch file before changing Task Scheduler.
    The installer reports missing prerequisites clearly; it does not silently
    download or install host applications.
#>
function Test-BusyTagInstallPrerequisites {
    $autoHotkeyPath = Join-Path $env:ProgramFiles 'AutoHotkey\v2\AutoHotkey64.exe'
    $requiredFiles = [ordered]@{
        'Selected PowerShell host' = $powerShellHostPath
        'AutoHotkey v2' = $autoHotkeyPath
        'Runtime listener' = Join-Path $projectRoot 'Scripts\Runtime\BusyTag-WisprFlow.ahk'
        'Scheduled startup launcher' = Join-Path $startupDirectory 'Start-BusyTagAutomation-Scheduled.bat'
    }

    $missing = @(
        foreach ($entry in $requiredFiles.GetEnumerator()) {
            if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
                Write-BusyTagInstallLog "Missing prerequisite: $($entry.Key) at $($entry.Value)"
                "$($entry.Key): $($entry.Value)"
            }
        }
    )

    if ($missing.Count -gt 0) {
        throw "BusyTag installation prerequisites are missing:`n - $($missing -join "`n - ")"
    }

    Write-Host 'Installation prerequisites: present.' -ForegroundColor Green
    Write-BusyTagInstallLog 'Installation prerequisites validated.'
}

<#
.SYNOPSIS
    Saves the selected PowerShell executable for future launches.

.DESCRIPTION
    The scheduled task and AutoHotkey listener are launched indirectly through
    project-owned startup code. Persisting the installer host keeps those paths
    aligned when installation is performed from Windows PowerShell 5.1 or
    PowerShell Core.
#>
function Set-BusyTagPowerShellHost {
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText(
        $powerShellHostFile,
        $powerShellHostPath,
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host "PowerShell host selected: $powerShellHostPath"
    Write-BusyTagInstallLog "PowerShell host selected=$powerShellHostPath edition=$($PSVersionTable.PSEdition) version=$($PSVersionTable.PSVersion)"
}

<#
.SYNOPSIS
    Downloads, installs, and validates the BusyTag CLI for the current user.

.DESCRIPTION
    Keeps the CLI outside the Git/OneDrive project while making the runtime
    self-provisioning for a new user profile. The official NuGet package is
    downloaded only when the expected DLL is absent; an existing installation
    is still validated before scheduled-task registration continues.
#>
function Install-BusyTagCli {
    $dotnetCommand = Get-Command 'dotnet.exe' -ErrorAction SilentlyContinue
    if ($null -eq $dotnetCommand) {
        throw 'The .NET runtime was not found. Install the .NET 8 runtime before installing BusyTag automation.'
    }

    $runtimeList = @(& $dotnetCommand.Source '--list-runtimes' 2>&1 | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($runtimeList -notmatch 'Microsoft\.NETCore\.App\s+8\.') {
        throw 'The .NET 8 runtime was not found. Install the .NET 8 runtime before installing BusyTag automation.'
    }

    Write-Host "BusyTag CLI target:  $cliPath"
    Write-BusyTagInstallLog "BusyTag CLI target=$cliPath version=$cliVersion"

    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        # 2026-08-17: Expand-Archive requires a .zip extension even though a
        # NuGet .nupkg package uses the ZIP archive format.
        # Prior 2026-08-17 logic:
        # $downloadPath = Join-Path ([IO.Path]::GetTempPath()) "BusyTag.CLI.$cliVersion.nupkg"
        $downloadPath = Join-Path ([IO.Path]::GetTempPath()) "BusyTag.CLI.$cliVersion.zip"
        $stagingDirectory = Join-Path ([IO.Path]::GetTempPath()) "BusyTag.CLI.$cliVersion-$([guid]::NewGuid().ToString('N'))"

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Host "Downloading BusyTag CLI $cliVersion..."
            Write-BusyTagInstallLog "Downloading package $cliPackageUri"
            Invoke-WebRequest -Uri $cliPackageUri -OutFile $downloadPath -UseBasicParsing
            Expand-Archive -LiteralPath $downloadPath -DestinationPath $stagingDirectory -Force

            $stagedCliPath = Join-Path $stagingDirectory 'tools\net8.0\any\busytag-cli.dll'
            if (-not (Test-Path -LiteralPath $stagedCliPath -PathType Leaf)) {
                throw "The downloaded BusyTag CLI package did not contain the expected file: $stagedCliPath"
            }

            New-Item -ItemType Directory -Path $cliInstallDirectory -Force | Out-Null
            Get-ChildItem -LiteralPath $stagingDirectory -Force | Copy-Item -Destination $cliInstallDirectory -Recurse -Force
            Write-BusyTagInstallLog 'BusyTag CLI package deployed to the user-local runtime directory.'
        } finally {
            if (Test-Path -LiteralPath $downloadPath) {
                Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $stagingDirectory) {
                Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } else {
        Write-Host 'BusyTag CLI already exists; validating the installed copy.'
        Write-BusyTagInstallLog 'BusyTag CLI already existed; validating the installed copy.'
    }

    if (-not (Test-Path -LiteralPath $cliPath -PathType Leaf)) {
        throw "BusyTag CLI installation could not be validated: $cliPath"
    }

    $cliVersionOutput = @(& $dotnetCommand.Source $cliPath '--version' 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
    if ($LASTEXITCODE -ne 0) {
        throw "BusyTag CLI validation failed: $cliVersionOutput"
    }

    Write-Host "BusyTag CLI validated: $($cliVersionOutput.Trim())" -ForegroundColor Green
    Write-BusyTagInstallLog "BusyTag CLI validated successfully: $($cliVersionOutput.Trim())"
}

Write-BusyTagInstallLog "Installer started. Identity=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-BusyTagInstallLog "TaskPath=$taskPath TaskName=$taskName"
Write-Host "Runtime data folder: $logDirectory"
Write-BusyTagInstallLog "Runtime data folder=$logDirectory"

<#
.SYNOPSIS
    Installs or removes the BusyTag AutoHotkey logon task.

.DESCRIPTION
    Resolves the portable project path into the scheduled-task XML and registers
    the task for the interactive user session. A logon trigger is used instead
    of a boot trigger so the AutoHotkey tray listener starts in the desktop
    session where it can receive Ctrl+Windows input. The task uses the current
    user's SID and highest available run level when installed elevated.
#>
function Install-BusyTagStartupTask {
    <#
    .SYNOPSIS
        Registers the BusyTag listener to start at user logon.

    .DESCRIPTION
        Fills the XML template with the current project and Windows command
        paths, then replaces any previous task with the same stable task name.
    #>
    # 2026-08-17: Build the scheduled-task definition in this installer so no
    # separate XML startup file must be maintained or launched manually.
    # Prior 2026-08-17 logic:
    # $xml = Get-Content -LiteralPath $templatePath -Raw
    $xml = @'
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts and verifies the BusyTag Wispr Flow AutoHotkey listener when the user signs in.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>__BUSYTAG_USER_SID__</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>__BUSYTAG_COMSPEC__</Command>
      <Arguments>/c ""__BUSYTAG_STARTUP_BAT__""</Arguments>
      <WorkingDirectory>__BUSYTAG_STARTUP_DIR__</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentUserSid = $currentIdentity.User.Value
    Write-Host "Task identity: $($currentIdentity.Name)"
    Write-Host "Task user SID:  $currentUserSid"
    Write-BusyTagInstallLog "Task identity=$($currentIdentity.Name) SID=$currentUserSid"
    $xml = $xml.Replace('__BUSYTAG_USER_SID__', $currentUserSid)
    $xml = $xml.Replace('__BUSYTAG_COMSPEC__', $env:ComSpec)
    $xml = $xml.Replace('__BUSYTAG_STARTUP_BAT__', (Join-Path $startupDirectory 'Start-BusyTagAutomation-Scheduled.bat'))
    $xml = $xml.Replace('__BUSYTAG_STARTUP_DIR__', $startupDirectory)

    Ensure-BusyTagTaskFolders

    # 2026-08-17: Replaced in-place registration with explicit remove/reload so
    # changed paths, identities, and actions cannot remain from an older task.
    # Prior 2026-08-17 logic:
    # Register-ScheduledTask -TaskName $taskName -Xml $xml -Force -ErrorAction Stop | Out-Null
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    Write-BusyTagInstallLog 'Removed any existing scheduled task before registration.'
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Xml $xml -ErrorAction Stop | Out-Null
    $registeredTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    if ($registeredTask.TaskName -ne $taskName) {
        throw "Scheduled task verification returned an unexpected task name."
    }

    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'BusyTag Automation.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "Removed old Startup shortcut: $shortcutPath" -ForegroundColor Yellow
    }
    Write-Host "Installed scheduled task: $taskPath$taskName" -ForegroundColor Green
    Write-Host 'Trigger: when the current user signs in.'
    Write-BusyTagInstallLog "Registered and verified scheduled task $taskPath$taskName."
}

<#
.SYNOPSIS
    Creates the XferWorx and BusyTag Task Scheduler folders when needed.

.DESCRIPTION
    Task Scheduler folders are not created automatically by Register-ScheduledTask.
    This keeps the task directly under XferWorx while allowing a clean install
    on a computer where the XferWorx folder does not exist yet.
#>
function Ensure-BusyTagTaskFolders {
    Write-BusyTagInstallLog 'Ensuring Task Scheduler folder exists: \XferWorx'
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $rootFolder = $service.GetFolder('\')

    try {
        $xferWorxFolder = $service.GetFolder('\XferWorx')
    } catch {
        Write-BusyTagInstallLog 'XferWorx folder not found; creating it.'
        $xferWorxFolder = $rootFolder.CreateFolder('XferWorx', $null)
    }

    Write-BusyTagInstallLog 'Task Scheduler folder is ready.'

}

<#
.SYNOPSIS
    Determines whether the current PowerShell session is elevated.

.DESCRIPTION
    Scheduled-task registration with highest available privileges requires an
    elevated administrator session. This check lets the installer choose the
    user-level Startup shortcut cleanly when UAC elevation is unavailable.
#>
function Test-BusyTagElevated {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
.SYNOPSIS
    Removes the BusyTag listener logon task if it exists.

.DESCRIPTION
    Removes only the named BusyTag task and leaves the project files and
    AutoHotkey installation untouched.
#>
function Uninstall-BusyTagStartupTask {
    Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Removed scheduled task if present: $taskPath$taskName" -ForegroundColor Yellow

    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'BusyTag Automation.lnk'
    if (Test-Path -LiteralPath $shortcutPath) {
        Remove-Item -LiteralPath $shortcutPath -Force
        Write-Host "Removed per-user Startup shortcut: $shortcutPath" -ForegroundColor Yellow
    }
}

if ($Uninstall) {
    try {
        Uninstall-BusyTagStartupTask
        Write-BusyTagInstallLog 'Uninstall completed.'
    } catch {
        Write-BusyTagInstallLog "ERROR during uninstall: $($_.Exception.Message)"
        throw
    }
} else {
    try {
        if ($ProvisionCliOnly) {
            # 2026-08-17: Allow CLI-only provisioning to run at user level so
            # package deployment can be tested without changing Task Scheduler.
            # Prior 2026-08-17 logic:
            # $isElevated = Test-BusyTagElevated
            # if (-not $isElevated) { throw 'Administrator PowerShell is required.' }
            Install-BusyTagCli
            Write-Host 'BusyTag CLI provisioning and validation completed.' -ForegroundColor Green
            Write-BusyTagInstallLog 'CLI-only provisioning completed.'
        } else {
            $isElevated = Test-BusyTagElevated
            Write-Host "PowerShell elevated: $isElevated"
            Write-BusyTagInstallLog "PowerShell elevated=$isElevated"

            if (-not $isElevated) {
                throw 'Administrator PowerShell is required. Close this window, start PowerShell with Run as administrator, and run Install-BusyTagStartupTask.ps1 again.'
            }

            Test-BusyTagInstallPrerequisites
            Set-BusyTagPowerShellHost
            Install-BusyTagCli
            Install-BusyTagStartupTask
        }
    } catch {
        Write-BusyTagInstallLog "ERROR during installation: $($_.Exception.Message)"
        throw "Scheduled-task installation failed: $($_.Exception.Message)"
    }
}

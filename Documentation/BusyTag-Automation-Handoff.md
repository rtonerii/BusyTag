# BusyTag-WisprFlow-Automation maintainer handoff

<p align="center">
  <img src="../Images/Maintenance-240x280.png" alt="BusyTag automation maintenance" width="200">
</p>

See the repository [README](../README.md) for installation, configuration, startup, diagnostics, layout, and safety guidance. This document records the project history and the design decisions that future maintenance should preserve.

## Project history

The original approach attempted to coordinate BusyTag, Luxafor, Microsoft Teams presence, and Wispr Flow through the vendor applications, supported hotkeys, and webhook-style controls. Those interfaces did not provide a dependable way to save an arbitrary current image and LED state, apply a temporary override, and restore that exact state on key release.

The device uses firmware 2.0, and several older local-server commands are not available on this firmware. The selected solution therefore uses the device's direct serial commands, with AutoHotkey handling keyboard timing and PowerShell handling device state, process conflicts, retries, and restoration.

## Design decisions

- AutoHotkey detects the modifier-only Ctrl+Windows press and release while allowing the original keystrokes to reach Wispr Flow.
- PowerShell captures the current BusyTag image and LED state before applying the dictation display.
- BusyTag and Luxafor processes may be closed when they hold the serial port; they are not silently restarted afterward.
- The controller tries to display the configured image directly and uploads it only when the device reports that it is missing.
- A request flag and a named mutex coordinate the asynchronous Start and Stop operations.
- The previous device state is deleted only after restoration has been verified.
- Active runtime data belongs in the current user's `%LOCALAPPDATA%\XferWorx\BusyTag-WisprFlow\Logs` folder, not in the OneDrive/Git project.
- The scheduled task is created dynamically by the installer; a standalone XML file is not part of the current design.

## Maintenance boundaries

When changing the runtime, preserve these behaviors:

1. The original Ctrl+Windows keystroke must continue through to Wispr Flow.
2. State must be saved before the device is overridden.
3. Slow upload/retry work must recheck whether the request is still active.
4. Restoration must remain independent enough to run after an early key release or failed Start operation.
5. Unknown device images must not be deleted as part of routine repair.
6. User-specific logs, status markers, request flags, and saved state must not be committed to GitHub.

## Current implementation references

- Hotkey listener: `Scripts/Runtime/BusyTag-WisprFlow.ahk`
- Device controller: `Scripts/Runtime/Set-BusyTagDictationState.ps1`
- Startup/reset logic: `Scripts/Setup/Initialize-BusyTagAutomation.ps1`
- Scheduled-task installer: `Scripts/Setup/Install-BusyTagStartupTask.ps1`
- Read-only diagnostic: `Scripts/Setup/Test-BusyTagRuntime.ps1`
- Detailed runtime sequence: [WisprFlow-Runtime-Notes.md](WisprFlow-Runtime-Notes.md)

# BusyTag + Wispr Flow runtime notes

This file documents the runtime sequence implemented by `Scripts/Runtime/BusyTag-WisprFlow.ahk` and `Scripts/Runtime/Set-BusyTagDictationState.ps1`. For installation, configuration, paths, and diagnostics, use the repository [README](../README.md).

## Hotkey coordination

The AutoHotkey listener watches for the modifier-only **Ctrl+Windows** chord while passing the original keys through to Wispr Flow.

When both keys are down, it creates `DictationRequested.flag` and invokes the PowerShell controller with `Start`. When either key is released, it removes the flag and invokes the controller with `Stop`.

## Start sequence

`Set-BusyTagDictationState.ps1 -Action Start`:

1. Acquires a named mutex so Start and Stop cannot corrupt saved state.
2. Confirms that the request flag still exists.
3. Closes BusyTag and Luxafor processes when necessary to release the serial port.
4. Opens the configured port and saves the current image and LED state.
5. Attempts to show the configured dictation image directly.
6. If the device reports a missing image, uploads the local image with capped retries.
7. Rechecks the request flag between slow operations.
8. Shows the dictation image, sets the configured LED value, and verifies the result.

## Stop sequence

`Set-BusyTagDictationState.ps1 -Action Stop`:

1. Acquires the same named mutex.
2. Loads the saved image and LED state.
3. Restores both values.
4. Queries the device to verify the restored image.
5. Deletes the saved state only after successful restoration.

BusyTag and Luxafor remain closed after the override. They can be reopened when Teams synchronization or manual display selection is needed.

## Cancellation and reliability

The request flag is removed immediately when either key is released. A device upload cannot safely be interrupted halfway through, so the controller checks the flag before and after each slow command. If the request is gone, Start stops continuing and the queued Stop operation restores the saved state.

The fast path avoids listing every device image on each hotkey press. The slower upload path is used only when the expected image is missing. Retries are capped, and the named mutex prevents overlapping state transitions.

The AutoHotkey listener raises its hotkey interval threshold to tolerate rapid modifier events without showing the AutoHotkey flood-warning dialog.

## Runtime data location

Runtime logs, status markers, request flags, and temporary saved state are stored under the current user's profile:

```text
%LOCALAPPDATA%\XferWorx\BusyTag-WisprFlow\Logs
```

The folder is created automatically when the runtime starts. `.log` files older than the configured retention period are removed during startup; status and state files are not removed by that cleanup.

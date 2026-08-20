#Requires AutoHotkey v2.0
#SingleInstance Force
#MaxThreads 10
Persistent

; Modifier-only chords can generate repeated key events while a key is held.
; Keep AutoHotkey's flood protection enabled, but allow normal hold/retry use
; without showing the emergency hotkey-count dialog.
A_HotkeyInterval := 1000
A_MaxHotkeysPerInterval := 250

global BusyTagIsDictating := false
global BusyTagRuntimeScript := A_ScriptDir "\Set-BusyTagDictationState.ps1"
global BusyTagLogDirectory := EnvGet("LOCALAPPDATA") "\XferWorx\BusyTag-WisprFlow\Logs"
global BusyTagRequestFlag := BusyTagLogDirectory "\DictationRequested.flag"
global BusyTagStatusFile := BusyTagLogDirectory "\BusyTagAutomation.status"
global BusyTagPowerShellHostFile := EnvGet("LOCALAPPDATA") "\XferWorx\BusyTag-WisprFlow\Runtime\PowerShellHost.txt"
; 2026-08-20: Use the PowerShell host selected during installation.
; Prior 2026-08-20 logic:
; global WindowsPowerShell := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
global WindowsPowerShell := ResolveBusyTagPowerShellHost()

DirCreate(BusyTagLogDirectory)
WriteBusyTagRuntimeStatus("Running")
SetDictationRequested(false)
OnExit(ShutdownBusyTagRuntime)

; The tilde (~) lets the original Ctrl+Windows keystrokes continue to Wispr Flow.
; Watching each left/right modifier separately lets us react to a modifier-only chord.
~*LControl::UpdateBusyTagState()
~*RControl::UpdateBusyTagState()
~*LWin::UpdateBusyTagState()
~*RWin::UpdateBusyTagState()
~*LControl Up::UpdateBusyTagState()
~*RControl Up::UpdateBusyTagState()
~*LWin Up::UpdateBusyTagState()
~*RWin Up::UpdateBusyTagState()

UpdateBusyTagState(*) {
    global BusyTagIsDictating

    ctrlIsDown := GetKeyState("LControl", "P") || GetKeyState("RControl", "P")
    winIsDown := GetKeyState("LWin", "P") || GetKeyState("RWin", "P")
    chordIsDown := ctrlIsDown && winIsDown

    if (chordIsDown && !BusyTagIsDictating) {
        BusyTagIsDictating := true
        SetDictationRequested(true)
        RunBusyTagAction("Start")
    } else if (!chordIsDown && BusyTagIsDictating) {
        BusyTagIsDictating := false
        SetDictationRequested(false)
        RunBusyTagAction("Stop")
    }
}

SetDictationRequested(isRequested) {
    global BusyTagRequestFlag

    if (isRequested) {
        try FileDelete(BusyTagRequestFlag)
        FileAppend(A_Now, BusyTagRequestFlag, "UTF-8")
    } else {
        try FileDelete(BusyTagRequestFlag)
    }
}

RunBusyTagAction(action) {
    global BusyTagRuntimeScript, WindowsPowerShell

    command := Format('"{1}" -NoProfile -ExecutionPolicy Bypass -File "{2}" -Action {3}',
        WindowsPowerShell, BusyTagRuntimeScript, action)

    try {
        exitCode := RunWait(command, A_ScriptDir, "Hide")
        if (exitCode != 0)
            TrayTip("BusyTag automation", "The " action " action failed. Check the Logs folder.", 5)
    } catch as err {
        TrayTip("BusyTag automation", err.Message, 5)
    }
}

ResolveBusyTagPowerShellHost() {
    global BusyTagPowerShellHostFile

    try {
        selectedHost := Trim(FileRead(BusyTagPowerShellHostFile, "UTF-8"))
        if (selectedHost != "" && FileExist(selectedHost))
            return selectedHost
    }

    fallbackHost := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    if FileExist(fallbackHost)
        return fallbackHost

    throw Error("No usable PowerShell host was found. Run the BusyTag installer first.")
}

; Writes the final runtime state and attempts one last restoration when AHK exits.
ShutdownBusyTagRuntime(*) {
    SetDictationRequested(false)
    WriteBusyTagRuntimeStatus("Stopping")
    RunBusyTagAction("Stop")
    WriteBusyTagRuntimeStatus("Stopped")
}

; Publishes a local marker so setup can verify this exact listener loaded.
WriteBusyTagRuntimeStatus(status) {
    global BusyTagStatusFile

    try FileDelete(BusyTagStatusFile)
    statusText := "Status=" status "`nPID=" ProcessExist() "`nScript=" A_ScriptFullPath "`nUpdated=" A_Now "`n"
    FileAppend(statusText, BusyTagStatusFile, "UTF-8")
}

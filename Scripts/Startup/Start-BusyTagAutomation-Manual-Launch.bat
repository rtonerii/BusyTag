@echo off
setlocal

set "BUSYTAG_PROJECT_ROOT=%~dp0..\.."
set "BUSYTAG_SETUP_SCRIPT=%BUSYTAG_PROJECT_ROOT%\Scripts\Setup\Initialize-BusyTagAutomation.ps1"
set "BUSYTAG_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if not exist "%BUSYTAG_SETUP_SCRIPT%" (
    echo ERROR: BusyTag setup script was not found:
    echo %BUSYTAG_SETUP_SCRIPT%
    pause
    exit /b 1
)

if not exist "%BUSYTAG_POWERSHELL%" (
    echo ERROR: Windows PowerShell was not found:
    echo %BUSYTAG_POWERSHELL%
    pause
    exit /b 1
)

"%BUSYTAG_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%BUSYTAG_SETUP_SCRIPT%" -RestartListener
set "BUSYTAG_SETUP_EXITCODE=%ERRORLEVEL%"

if "%BUSYTAG_SETUP_EXITCODE%"=="0" (
    echo BusyTag automation manual launch completed successfully.
) else (
    echo BusyTag automation manual launch failed with exit code %BUSYTAG_SETUP_EXITCODE%.
)

pause
exit /b %BUSYTAG_SETUP_EXITCODE%

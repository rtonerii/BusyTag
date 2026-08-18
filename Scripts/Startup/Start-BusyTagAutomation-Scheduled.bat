@echo off
setlocal

set "BUSYTAG_PROJECT_ROOT=%~dp0..\.."
set "BUSYTAG_SETUP_SCRIPT=%BUSYTAG_PROJECT_ROOT%\Scripts\Setup\Initialize-BusyTagAutomation.ps1"
set "BUSYTAG_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "BUSYTAG_LOG_DIR=%LOCALAPPDATA%\XferWorx\BusyTag-WisprFlow\Logs"
set "BUSYTAG_LOG=%BUSYTAG_LOG_DIR%\ScheduledStartup.log"

if not exist "%BUSYTAG_LOG_DIR%" mkdir "%BUSYTAG_LOG_DIR%" >nul 2>&1

if not exist "%BUSYTAG_SETUP_SCRIPT%" (
    >>"%BUSYTAG_LOG%" echo [%date% %time%] ERROR: Setup script not found: %BUSYTAG_SETUP_SCRIPT%
    exit /b 1
)
if not exist "%BUSYTAG_POWERSHELL%" (
    >>"%BUSYTAG_LOG%" echo [%date% %time%] ERROR: Windows PowerShell not found: %BUSYTAG_POWERSHELL%
    exit /b 1
)

>>"%BUSYTAG_LOG%" echo.
>>"%BUSYTAG_LOG%" echo [%date% %time%] Runtime data folder: %BUSYTAG_LOG_DIR%
>>"%BUSYTAG_LOG%" echo [%date% %time%] Scheduled BusyTag startup beginning.
"%BUSYTAG_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%BUSYTAG_SETUP_SCRIPT%" -RestartListener >>"%BUSYTAG_LOG%" 2>&1
set "BUSYTAG_STARTUP_EXITCODE=%ERRORLEVEL%"
>>"%BUSYTAG_LOG%" echo [%date% %time%] Scheduled BusyTag startup finished with exit code %BUSYTAG_STARTUP_EXITCODE%.
exit /b %BUSYTAG_STARTUP_EXITCODE%
exit /b %ERRORLEVEL%

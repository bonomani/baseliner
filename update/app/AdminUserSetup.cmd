@echo off
SETLOCAL EnableExtensions EnableDelayedExpansion

:: ——————————————————————————————
:: Figure out current directory (where this script is located)
:: ——————————————————————————————
set "CurrentDir=%~dp0"
echo This bootstrap is running from: %CurrentDir%

:: ——————————————————————————————
:: Define list of PowerShell scripts relative to CurrentDir
:: ——————————————————————————————
set "Script1=%CurrentDir%UserSetup.ps1"
set "ScriptCount=1"

:: ——————————————————————————————
:: Remember current PowerShell execution policy
:: ——————————————————————————————
for /f "usebackq tokens=*" %%a in (`powershell -NoProfile -Command "Get-ExecutionPolicy"`) do (
    set "CurrentPolicy=%%a"
)
echo Current execution policy is %CurrentPolicy%

:: ——————————————————————————————
:: Temporarily allow scripts in this process
:: ——————————————————————————————
powershell -NoProfile -Command "Set-ExecutionPolicy Bypass -Scope Process -Force"
echo Execution policy set to Bypass for this process.

:: ——————————————————————————————
:: Run each PowerShell script
:: ——————————————————————————————
for /L %%i in (1,1,%ScriptCount%) do (
    call set "ScriptPath=%%Script%%i%%"
    echo Running command: powershell -NoProfile -ExecutionPolicy Bypass -File "!ScriptPath!" -Elevated
    powershell -NoProfile -ExecutionPolicy Bypass -File "!ScriptPath!" -Elevated
    echo Script exited with code !errorlevel!.
)

:: ——————————————————————————————
:: Restore original execution policy
:: ——————————————————————————————
powershell -NoProfile -Command "Set-ExecutionPolicy %CurrentPolicy% -Scope Process -Force"
echo Execution policy reverted to %CurrentPolicy%.

echo All operations completed.
pause
ENDLOCAL

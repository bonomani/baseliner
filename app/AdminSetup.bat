@echo off
SETLOCAL EnableExtensions EnableDelayedExpansion

:: 1) Determine the folder where this .cmd lives
set "AdminDir=%~dp0"
echo This bootstrap is running from: %AdminDir%

:: 2) Check for administrator privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This script requires administrative privileges. Please run as administrator.
    pause
    exit /b 1
)

:: 3) Dynamically build parallel arrays of script file names and their arguments
set "idx=0"
for %%L in (
  "AdminSetup.ps1"
) do (
    for /f "tokens=1,2 delims=;" %%A in ("%%~L") do (
        set "ScriptPath[!idx!]=%%A"
        set "ScriptArgs[!idx!]=%%B"
    )
    set /a idx+=1
)
set "ScriptCount=%idx%"
set /a LastIndex=ScriptCount - 1

:: 4) Remember & relax PowerShell execution policy
for /f "tokens=*" %%a in ('powershell -NoProfile -Command "Get-ExecutionPolicy"') do set "CurrentPolicy=%%a"
powershell -NoProfile -Command "Set-ExecutionPolicy Bypass -Scope Process -Force" >nul

:: 5) Loop from 0 to LastIndex, no gaps or extras
for /L %%i in (0,1,%LastIndex%) do (

    rem grab the Nᵗʰ script and its args
    call set "ps1=%%ScriptPath[%%i]%%"
    call set "args=%%ScriptArgs[%%i]%%"

    rem build full path to the .ps1
    set "fullPath=%AdminDir%!ps1!"

    echo.
    echo ==== Running [%%i]: "!fullPath!" !args! ====

    powershell -NoProfile -ExecutionPolicy Bypass -File "!fullPath!" !args!
    echo Script exited with code !errorlevel!.
)

:: 6) Restore original policy
powershell -NoProfile -Command "Set-ExecutionPolicy %CurrentPolicy% -Scope Process -Force" >nul

echo.
echo All operations completed.
pause
ENDLOCAL
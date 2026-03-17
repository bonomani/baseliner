@echo off
setlocal

REM Build path to a .ps1 with the same base name as this .bat/.cmd
set "ps1=%~dp0%~n0.ps1"

REM Ensure PowerShell exists
where powershell.exe >nul 2>&1 || (
  echo ERROR: PowerShell not found.
  endlocal & exit /b 1
)

REM Run the .ps1 next to this .bat/.cmd
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ps1%" || (
  echo ERROR: "%~n0.ps1" failed.
  endlocal & exit /b 1
)

endlocal

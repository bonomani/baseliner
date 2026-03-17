@echo off
setlocal

:: Define paths
set "firefoxProfilePath=%APPDATA%\Mozilla\Firefox\Profiles"
set "profilesIniPath=%APPDATA%\Mozilla\Firefox\profiles.ini"
set "psScriptName=AdminSetupFirefoxDefaultProfile.ps1"

:: Get the path of the current batch script
set "batchScriptPath=%~dp0"

:: Combine the batch script path with the PowerShell script name
set "psScriptPath=%batchScriptPath%%psScriptName%"

:: Correctly echo the resolved PowerShell script path for debugging
echo Resolved PowerShell script path: %psScriptPath%
	 

:: Check if the PowerShell script exists in the current folder
if not exist "%psScriptPath%" (
    echo The script %psScriptName% does not exist in the current folder.
    echo Please ensure %psScriptName% is in the same folder as this batch file.
    pause
    exit /b 1
)

:: Prompt user for confirmation
echo This script will reset your Firefox profile. This will delete all your bookmarks, settings, and data.
echo WARNING: You are about to delete all data in your Firefox profile, including bookmarks.
echo.
set /p confirm="Do you really want to proceed? (Y/N): "
if /i not "%confirm%"=="Y" (
    echo Operation cancelled.
    exit /b 0
)

:: Delete contents in the profile folder
echo Deleting all contents in the profile folder...
if exist "%firefoxProfilePath%" (
    for /d %%x in ("%firefoxProfilePath%\*") do rmdir /s /q "%%x"
								 
						 
	 
    for %%x in ("%firefoxProfilePath%\*") do del /q "%%x"
							   
					
	 
    echo Firefox profile folder contents deleted.
) else (
    echo Firefox profile folder does not exist.
)

:: Delete profiles.ini
echo Deleting profiles.ini...
if exist "%profilesIniPath%" (
    del /q "%profilesIniPath%"
    echo profiles.ini deleted.
) else (
    echo profiles.ini does not exist.
)

:: Start CreateFirefoxProfile.ps1
echo Starting %psScriptName%...
powershell -NoProfile -ExecutionPolicy Bypass -File "%psScriptPath%"
																				  

	 
echo Operation completed.
pause
endlocal

'——————————————————————————————
' runFromCurrentFolder.vbs
'——————————————————————————————

Dim fso, thisFolder, ps1Path, WshShell

Set fso = CreateObject("Scripting.FileSystemObject")
thisFolder = fso.GetParentFolderName(WScript.ScriptFullName)

ps1Path = thisFolder & "\" & "UserLogon.ps1"

Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = thisFolder

WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1Path & """", 1, True

Set WshShell = Nothing
Set fso = Nothing

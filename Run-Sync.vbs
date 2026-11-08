' Run-Sync.vbs
'
' Launches Sync-Monero.ps1 with no console window. Used as the scheduled
' task's action.
'
' Task Scheduler running powershell.exe directly shows a console window even
' with -WindowStyle Hidden, because the window is created before PowerShell
' can act on that argument. wscript.exe creates no console at all, so nothing
' ever flashes on screen.

Dim shell, fso, here
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)

' 0 = hidden window, True = wait, so the task's runtime reflects the real run.
WScript.Quit shell.Run("powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & here & "\Sync-Monero.ps1""", 0, True)

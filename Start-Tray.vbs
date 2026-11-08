' Start-Tray.vbs
'
' Launches MoneroTray.ps1 with no console window.
' Double-click this, or drop a shortcut to it in shell:startup to have the
' tray icon appear at login.

Dim shell, fso, here
Set shell = CreateObject("WScript.Shell")
Set fso   = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)

shell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "\MoneroTray.ps1""", 0, False

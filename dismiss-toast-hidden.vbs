Option Explicit

Dim fso, shell, rootDir, scriptPath, executable, command
Dim logDir, errorLog

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

rootDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(rootDir, "scripts\dismiss-honor-toast.ps1")
executable = fso.BuildPath( _
    shell.ExpandEnvironmentStrings("%SystemRoot%"), _
    "System32\WindowsPowerShell\v1.0\powershell.exe" _
)
logDir = fso.BuildPath(rootDir, "logs")
errorLog = fso.BuildPath(logDir, "dismiss-toast-launcher-error.log")

If Not fso.FolderExists(logDir) Then
    fso.CreateFolder logDir
End If

If Not fso.FileExists(executable) Then
    WriteError "Windows PowerShell not found: " & executable
    WScript.Quit 2
End If

If Not fso.FileExists(scriptPath) Then
    WriteError "Toast dismisser not found: " & scriptPath
    WScript.Quit 3
End If

command = """" & executable & """ -NoProfile -ExecutionPolicy Bypass -File """ & _
    scriptPath & """"
shell.Run command, 0, True

Sub WriteError(message)
    Dim stream
    Set stream = fso.OpenTextFile(errorLog, 8, True)
    stream.WriteLine Now & " " & message
    stream.Close
End Sub

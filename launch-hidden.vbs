Option Explicit

Dim fso, shell, rootDir, keepAliveScript, executable, command, logDir, errorLog
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

rootDir = fso.GetParentFolderName(WScript.ScriptFullName)
keepAliveScript = fso.BuildPath(rootDir, "keepalive.js")
executable = "C:\Program Files\Hihonornote\Hihonornote.exe"
logDir = fso.BuildPath(rootDir, "logs")

If Not fso.FolderExists(logDir) Then
    fso.CreateFolder logDir
End If

errorLog = fso.BuildPath(logDir, "launcher-error.log")

If Not fso.FileExists(executable) Then
    WriteError "Hihonornote.exe not found: " & executable
    WScript.Quit 2
End If

If Not fso.FileExists(keepAliveScript) Then
    WriteError "keepalive.js not found: " & keepAliveScript
    WScript.Quit 3
End If

shell.Environment("PROCESS")("ELECTRON_RUN_AS_NODE") = "1"
shell.CurrentDirectory = rootDir
command = """" & executable & """ """ & keepAliveScript & """"
shell.Run command, 0, True

Sub WriteError(message)
    Dim stream
    Set stream = fso.OpenTextFile(errorLog, 8, True)
    stream.WriteLine Now & " " & message
    stream.Close
End Sub

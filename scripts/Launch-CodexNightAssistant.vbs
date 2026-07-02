Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
appScript = fso.BuildPath(scriptDir, "CodexNightAssistant.ps1")
ps = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & ps & """ -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & appScript & """"
shell.Run cmd, 0, False

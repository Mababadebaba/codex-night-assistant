$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
$target = "$env:SystemRoot\System32\wscript.exe"
$launcherScript = Join-Path $scriptDir "Launch-CodexNightAssistant.vbs"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Codex 守夜助手.lnk"

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.Arguments = "`"$launcherScript`""
$shortcut.WorkingDirectory = $scriptDir
$shortcut.Description = "启动 Codex 守夜助手"
$shortcut.IconLocation = "$env:SystemRoot\System32\powercpl.dll,0"
$shortcut.Save()

Write-Host "桌面快捷方式已创建："
Write-Host $shortcutPath

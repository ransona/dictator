param(
    [switch]$StartOnLogin
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$publishDir = Join-Path $root "artifacts\publish\win-x64"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\Dictator"
$exePath = Join-Path $installDir "Dictator.exe"
$shortcutDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$shortcutPath = Join-Path $shortcutDir "Dictator.lnk"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

if (-not (Test-Path $publishDir)) {
    throw "Publish output not found at $publishDir. Run .\scripts\Publish-Dictator.ps1 first."
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item -Path (Join-Path $publishDir "*") -Destination $installDir -Recurse -Force

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $exePath
$shortcut.WorkingDirectory = $installDir
$shortcut.Save()

if ($StartOnLogin) {
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name "Dictator" -Value ('"{0}"' -f $exePath)
}

Write-Host "Installed Dictator to $installDir"

# feng-idweight-terrain plugin linker
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File link_plugin.ps1 -ProjectPath "C:\path\to\new_project"
#   powershell -ExecutionPolicy Bypass -File link_plugin.ps1 -ProjectPath "C:\path\to\new_project" -SourcePath "E:\somewhere\feng-idweight-terrain"
#
# Replaces the project's addons\feng-idweight-terrain with a junction pointing
# to the single source copy. After this, edits and DLL rebuilds take effect
# immediately (restart the Godot editor to reload the plugin).
#
# Source resolution:
#   1. If -SourcePath is given, use it.
#   2. Otherwise use the parent directory of this script
#      (keep link_plugin.ps1 and the feng-idweight-terrain folder in the same
#      parent directory, then this works on any machine and any drive).

param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,

    [string]$SourcePath = ""
)

$ErrorActionPreference = "Stop"

# Resolve source directory
if ($SourcePath -ne "") {
    $Source = $SourcePath
} else {
    # link_plugin.ps1 lives next to the plugin source folder:
    #   <parent>/link_plugin.ps1
    #   <parent>/feng-idweight-terrain/
    $Source = Join-Path $PSScriptRoot "feng-idweight-terrain"
}

$AddonsDir = Join-Path $ProjectPath "addons"
$Link = Join-Path $AddonsDir "feng-idweight-terrain"

if (-not (Test-Path $Source)) {
    Write-Host "ERROR: source directory not found: $Source" -ForegroundColor Red
    Write-Host "       Pass -SourcePath to point at the plugin source folder." -ForegroundColor Yellow
    exit 1
}
if (-not (Test-Path (Join-Path $ProjectPath "project.godot"))) {
    Write-Host "ERROR: not a Godot project (project.godot missing): $ProjectPath" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $AddonsDir)) {
    New-Item -ItemType Directory -Path $AddonsDir | Out-Null
}

if (Test-Path $Link) {
    $item = Get-Item $Link -Force
    if ($item.LinkType -eq "Junction") {
        Write-Host "OK: already a junction, nothing to do: $Link" -ForegroundColor Green
        exit 0
    }
    Write-Host "Old copy detected, replacing with junction..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $Link
}

cmd /c mklink /J "`"$Link`"" "`"$Source`"" | Out-Null
if (-not (Test-Path $Link)) {
    Write-Host "ERROR: failed to create junction" -ForegroundColor Red
    exit 1
}

Write-Host "OK: plugin linked to single source: $Link" -ForegroundColor Green
Write-Host "    -> $Source" -ForegroundColor Green
Write-Host "Edits and DLL rebuilds now take effect after restarting the Godot editor." -ForegroundColor Cyan

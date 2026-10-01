# feng-idweight-terrain plugin linker
# Usage (PowerShell):
#   powershell -ExecutionPolicy Bypass -File link_plugin.ps1 -ProjectPath "C:\path\to\new_project"
#   powershell -ExecutionPolicy Bypass -File link_plugin.ps1 -ProjectPath "C:\path\to\new_project" -SourcePath "E:\somewhere\feng-idweight-terrain"
#
# Links a missing project addons\feng-idweight-terrain to the source directory.
# Existing files, ordinary directories and links elsewhere are never replaced.
# Creates a junction pointing
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

$item = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
if ($null -ne $item) {
    $target = @($item.Target)[0]
    if ($item.LinkType -eq "Junction" -and $target -and
        [IO.Path]::GetFullPath($target) -eq [IO.Path]::GetFullPath($Source)) {
        Write-Host "OK: already linked to the requested source: $Link" -ForegroundColor Green
        exit 0
    }
    Write-Host "ERROR: keeping existing addon untouched: $Link" -ForegroundColor Red
    Write-Host "Move local changes somewhere safe and remove the conflict yourself before linking." -ForegroundColor Yellow
    exit 1
}

cmd /c mklink /J "`"$Link`"" "`"$Source`"" | Out-Null
if (-not (Test-Path $Link)) {
    Write-Host "ERROR: failed to create junction" -ForegroundColor Red
    exit 1
}

Write-Host "OK: plugin linked to single source: $Link" -ForegroundColor Green
Write-Host "    -> $Source" -ForegroundColor Green
Write-Host "Edits and DLL rebuilds now take effect after restarting the Godot editor." -ForegroundColor Cyan

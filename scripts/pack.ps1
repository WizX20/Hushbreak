<#
.SYNOPSIS
Builds the release zip: dist/Hushbreak-<version>.zip with a single top-level lua/ folder inside.

.DESCRIPTION
The zip is what a GitHub Release carries. Unzipping it into VLC's per-user data folder
(%APPDATA%\vlc on Windows) puts every script where VLC looks for it: lua/intf/,
lua/intf/modules/ and lua/extensions/. LICENSE and NOTICE ride along at the top level.
The version comes from src/lua/intf/modules/hushbreak_core.lua - stamp it first with
scripts/set-version.ps1. Prints the zip path and its SHA256.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$core = Join-Path $root 'src\lua\intf\modules\hushbreak_core.lua'
$version = [regex]::Match([IO.File]::ReadAllText($core), '(?m)^M\.VERSION\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $version) { throw "no M.VERSION line found in $core" }

$dist = Join-Path $root 'dist'
$stage = Join-Path $dist 'Hushbreak'
if (Test-Path $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item (Join-Path $root 'src\lua') (Join-Path $stage 'lua') -Recurse
Copy-Item (Join-Path $root 'LICENSE'), (Join-Path $root 'NOTICE'), (Join-Path $root 'README.md') $stage

$zip = Join-Path $dist "Hushbreak-$version.zip"
if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host "packed $zip" -ForegroundColor Green
Write-Host "sha256 $hash"
[pscustomobject]@{ Version = $version; Zip = $zip; Sha256 = $hash }

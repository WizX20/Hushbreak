<#
.SYNOPSIS
Checks the changelog fragments in changelog.d/, then runs luacheck over src/ and tests/.
Exits non-zero on a malformed fragment or any luacheck warning.

.DESCRIPTION
`task lint` and the CI workflow both call this, so the rule set (.luacheckrc) is applied
identically everywhere. Needs luacheck on PATH; on CI it is installed on the fly, locally
the script tells you how (scoop install luacheck, or luarocks install luacheck).
The fragment check (scripts/cut-changelog.ps1 -Check) comes first and needs nothing: a
misnamed fragment fails its pull request here, not the Tuesday release.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

& (Join-Path $PSScriptRoot 'cut-changelog.ps1') -Check

if (-not (Get-Command luacheck -ErrorAction SilentlyContinue)) {
    if ($env:CI -and $IsLinux) {
        sudo apt-get install -y -qq lua-check | Out-Null
    }
    else {
        throw 'luacheck is not installed. Run: scoop install luacheck  (or: luarocks install luacheck)'
    }
}

Push-Location $root
try {
    & luacheck src tests --no-color
    if ($LASTEXITCODE -ne 0) { throw "luacheck exited with $LASTEXITCODE" }
}
finally {
    Pop-Location
}
Write-Host 'luacheck: clean' -ForegroundColor Green

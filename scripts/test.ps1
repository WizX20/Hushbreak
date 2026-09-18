<#
.SYNOPSIS
Runs the Lua test suite in tests/. Exits non-zero when a test fails.

.DESCRIPTION
`task test` and the CI workflow both call this. The suite is plain Lua with a runner of
its own (tests/run.lua), so any interpreter from 5.1 up will do: `lua`, `lua5.1`,
`lua5.4`, ... The core module is written for the Lua 5.1 that VLC 3 embeds, and CI
runs the suite on 5.1 to prove it; locally whatever you have is fine.

.PARAMETER Filter
Only run test cases whose name contains this text, e.g. `task test -- drift`.
#>
[CmdletBinding()]
param(
    [string]$Filter
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$lua = @('lua5.1', 'lua51', 'lua', 'lua5.4', 'lua54', 'lua5.3', 'luajit') |
    ForEach-Object { Get-Command $_ -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $lua) {
    if ($env:CI -and $IsLinux) {
        sudo apt-get install -y -qq lua5.1 | Out-Null
        $lua = Get-Command lua5.1
    }
    else {
        throw 'No Lua interpreter found. Run: scoop install lua  (or apt install lua5.1)'
    }
}
Write-Host "using $($lua.Source)" -ForegroundColor DarkGray

& $lua.Source (Join-Path $root 'tests\run.lua') $Filter
if ($LASTEXITCODE -ne 0) { throw "tests failed (exit $LASTEXITCODE)" }

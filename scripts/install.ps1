<#
.SYNOPSIS
Installs Hushbreak into VLC's per-user Lua folder, or removes it again with -Remove.

.DESCRIPTION
Copies src/lua/** to VLC's user data folder: %APPDATA%\vlc\lua on Windows,
~/.local/share/vlc/lua on Linux, ~/Library/Application Support/org.videolan.vlc/lua on
macOS. VLC picks scripts up from there without touching the program folder, so no admin
rights are needed. Restart VLC afterwards; the interface script only starts when VLC is
told to load it (see README.md -> Run).

.PARAMETER Source
Folder to install from. Defaults to the src/lua tree of this checkout; `task pack` output
works too.

.PARAMETER Remove
Delete the installed files instead of copying them.
#>
[CmdletBinding()]
param(
    [string]$Source = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\lua'),
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'

$userLua = if ($IsMacOS) {
    Join-Path $HOME 'Library/Application Support/org.videolan.vlc/lua'
}
elseif ($IsLinux) {
    Join-Path $HOME '.local/share/vlc/lua'
}
else {
    Join-Path $env:APPDATA 'vlc\lua'
}

$files = @(
    'intf\hushbreak.lua',
    'intf\modules\hushbreak_core.lua',
    'extensions\hushbreak_calibrate.lua'
)

foreach ($relative in $files) {
    $target = Join-Path $userLua $relative
    if ($Remove) {
        if (Test-Path $target) {
            Remove-Item -LiteralPath $target -Force
            Write-Host "removed $target"
        }
        continue
    }
    $from = Join-Path $Source $relative
    if (-not (Test-Path $from)) { throw "missing $from" }
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Copy-Item -LiteralPath $from -Destination $target -Force
    Write-Host "installed $target"
}

if (-not $Remove) {
    Write-Host ''
    Write-Host 'Run VLC with the interface script enabled, for example:' -ForegroundColor Green
    Write-Host '  vlc --extraintf luaintf --lua-intf hushbreak KINK.pls'
    Write-Host 'or make it permanent in VLC: Preferences > Show all > Interface > Main interfaces >'
    Write-Host 'Extra interface modules = luaintf, and Main interfaces > Lua > Lua interface = hushbreak.'
}

<#
.SYNOPSIS
Stamps a version into the sources: M.VERSION in hushbreak_core.lua and the extension's
descriptor. Used by the Release workflow.

.PARAMETER Version
Semantic version without a leading "v", e.g. 1.2.0.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$targets = @(
    @{ Path = 'src\lua\intf\modules\hushbreak_core.lua'; Pattern = '(?m)^(M\.VERSION\s*=\s*")[^"]*(")' },
    @{ Path = 'src\lua\extensions\hushbreak_calibrate.lua'; Pattern = '(?m)^(\s*version\s*=\s*")[^"]*(")' }
)
foreach ($t in $targets) {
    $file = Join-Path $root $t.Path
    $text = [IO.File]::ReadAllText($file)
    if ($text -notmatch $t.Pattern) { throw "no version line found in $file" }
    $new = [regex]::Replace($text, $t.Pattern, "`${1}$Version`${2}")
    # Same version is fine: the first release ships the version the sources already carry.
    if ($new -ne $text) { [IO.File]::WriteAllText($file, $new, [Text.UTF8Encoding]::new($false)) }
    Write-Host "$($t.Path): version = $Version" -ForegroundColor Green
}

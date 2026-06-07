<#
.SYNOPSIS
    Install script for cora (`cr`) on Windows.

.DESCRIPTION
    Mirrors install.sh: downloads the latest matching cora-windows release
    asset from GitHub, verifies its SHA256, extracts cr.exe, and installs to
    a user-writable directory. Optionally adds the install directory to the
    user PATH.

    Each OS has its own release stream (cora-macos-v*, cora-linux-v*,
    cora-windows-v*). This script only queries the cora-windows-v* stream.

.PARAMETER Channel
    Release channel: stable | alpha | beta | rc. Default: stable.

.PARAMETER Version
    Pin a specific version. Accepts a bare semver (e.g. 0.9.5), which is
    auto-prefixed with cora-windows-v, or a fully-qualified tag
    (e.g. cora-windows-v0.9.5-alpha.2).

.PARAMETER BinDir
    Install directory. Default: $env:LOCALAPPDATA\Programs\cora.

.PARAMETER NoVerify
    Skip SHA256 verification. NOT recommended.

.PARAMETER NoPath
    Do not modify the user PATH.

.PARAMETER Help
    Print usage and exit.

.EXAMPLE
    irm https://raw.githubusercontent.com/keton-id/cora/main/install.ps1 | iex

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/keton-id/cora/main/install.ps1))) -Channel alpha
#>
[CmdletBinding()]
param(
    [ValidateSet('stable', 'alpha', 'beta', 'rc')]
    [string]$Channel = 'stable',

    [string]$Version = '',

    [string]$BinDir = '',

    [switch]$NoVerify,

    [switch]$NoPath,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest's progress bar makes large downloads ~30x slower on
# Windows PowerShell 5.1 because it repaints the console per chunk.
$ProgressPreference = 'SilentlyContinue'
$script:Repo = 'keton-id/cora'

# Force TLS 1.2+ on Windows PowerShell 5.1 (defaults to TLS 1.0).
try {
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # PowerShell 7+ on .NET 6 already negotiates TLS 1.2/1.3 by default.
}

function Show-Usage {
    # $PSCommandPath is empty when the script is run through `irm | iex`,
    # so Get-Help is unreliable. Print a static usage block instead.
    Write-Host @'
Usage:
  install.ps1 [-Channel <stable|alpha|beta|rc>]
              [-Version <X.Y.Z[-suffix]|tag>]
              [-BinDir <path>]
              [-NoVerify] [-NoPath] [-Help]

Defaults:
  -Channel stable
  -BinDir  %LOCALAPPDATA%\Programs\cora

Examples:
  install.ps1
  install.ps1 -Channel alpha
  install.ps1 -Version 1.0.0
  install.ps1 -BinDir C:\tools\cora -NoPath
'@
}

function Get-Arch {
    $proc = $env:PROCESSOR_ARCHITECTURE
    switch ($proc) {
        'AMD64' { return 'x86_64' }
        'ARM64' { return 'aarch64' }
        default {
            throw "unsupported arch: $proc (expected AMD64 or ARM64)"
        }
    }
}

function Resolve-Tag {
    param(
        [string]$Channel,
        [string]$PinVersion
    )

    $prefix = 'cora-windows-v'

    if ($PinVersion) {
        if ($PinVersion -like 'cora-*-v*') {
            return $PinVersion
        }
        if ($PinVersion -like 'v*') {
            return "$prefix$($PinVersion.Substring(1))"
        }
        return "$prefix$PinVersion"
    }

    $api = "https://api.github.com/repos/$script:Repo/releases?per_page=100"
    $headers = @{ 'User-Agent' = 'cora-install-ps1' }
    $releases = Invoke-RestMethod -Uri $api -Headers $headers -UseBasicParsing

    $tags = $releases | ForEach-Object { $_.tag_name }

    $stableRe = "^$([regex]::Escape($prefix))\d+\.\d+\.\d+$"
    $preRe = "^$([regex]::Escape($prefix))\d+\.\d+\.\d+-$Channel\."

    switch ($Channel) {
        'stable' {
            $match = $tags | Where-Object { $_ -match $stableRe } | Select-Object -First 1
        }
        default {
            $match = $tags | Where-Object { $_ -match $preRe } | Select-Object -First 1
        }
    }

    if ($match) { return $match }

    # Legacy fallback: bare v* releases pre-OS-split. The artifact filename
    # is OS-agnostic so the download path further down works either way.
    $legacyStableRe = '^v\d+\.\d+\.\d+$'
    $legacyPreRe = "^v\d+\.\d+\.\d+-$Channel\."

    switch ($Channel) {
        'stable' {
            $match = $tags | Where-Object { $_ -match $legacyStableRe } | Select-Object -First 1
        }
        default {
            $match = $tags | Where-Object { $_ -match $legacyPreRe } | Select-Object -First 1
        }
    }

    if ($match) {
        Write-Warning "no $prefix* release found — falling back to legacy $match"
        return $match
    }

    return $null
}

function Get-VersionFromTag {
    param([string]$Tag)

    # Match install.sh's SHORTEST-prefix strip: a prerelease suffix containing
    # "-v" later (e.g. cora-windows-v1.0.0-vendor.1) must survive.
    if ($Tag -match '^cora-[^-]+-v(.+)$') { return $Matches[1] }
    if ($Tag -match '^v(.+)$') { return $Matches[1] }
    throw "unrecognised tag shape: $Tag"
}

function Add-ToUserPath {
    param([string]$Dir)

    $current = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not $current) { $current = '' }

    $parts = $current.Split(';') | Where-Object { $_ -ne '' }
    foreach ($p in $parts) {
        if ([string]::Equals($p.TrimEnd('\'), $Dir.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }

    $new = if ($current) { "$current;$Dir" } else { $Dir }
    [Environment]::SetEnvironmentVariable('PATH', $new, 'User')
    return $true
}

function Invoke-Install {
    $arch = Get-Arch
    $target = "$arch-windows"
    $tag = Resolve-Tag -Channel $Channel -PinVersion $Version
    if (-not $tag) {
        throw "could not resolve a release for os='windows' channel='$Channel'"
    }
    $ver = Get-VersionFromTag -Tag $tag
    $artifact = "cr-$ver-$target.zip"
    $baseUrl = "https://github.com/$script:Repo/releases/download/$tag"

    if (-not $BinDir) {
        $script:BinDir = Join-Path $env:LOCALAPPDATA 'Programs\cora'
    } else {
        $script:BinDir = $BinDir
    }
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null

    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    try {
        Write-Host "downloading $artifact ($tag) -> $tmp"
        $zipPath = Join-Path $tmp $artifact
        Invoke-WebRequest -Uri "$baseUrl/$artifact" -OutFile $zipPath -UseBasicParsing

        if ($NoVerify) {
            Write-Warning "skipping SHA256 verification (-NoVerify)"
        } else {
            Write-Host 'fetching checksum'
            $shaPath = "$zipPath.sha256"
            Invoke-WebRequest -Uri "$baseUrl/$artifact.sha256" -OutFile $shaPath -UseBasicParsing
            $shaLine = (Get-Content -Path $shaPath -TotalCount 1)
            $expected = ($shaLine.Trim() -split '\s+')[0]
            $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLowerInvariant()
            if ($expected.ToLowerInvariant() -ne $actual) {
                throw "SHA256 mismatch! expected=$expected actual=$actual"
            }
            Write-Host 'checksum ok'
        }

        $extractDir = Join-Path $tmp 'extract'
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

        $exe = Get-ChildItem -Path $extractDir -Recurse -Filter 'cr.exe' | Select-Object -First 1
        if (-not $exe) { throw "cr.exe not found inside $artifact" }

        $dest = Join-Path $script:BinDir 'cr.exe'
        Copy-Item -Path $exe.FullName -Destination $dest -Force

        $verOut = & $dest version 2>&1
        Write-Host "installed $verOut"
        Write-Host "binary at: $dest"

        if ($NoPath) {
            Write-Host "note: -NoPath set, skipping PATH update"
        } else {
            $added = Add-ToUserPath -Dir $script:BinDir
            if ($added) {
                Write-Host "added $script:BinDir to user PATH (open a new shell to pick it up)"
            } else {
                Write-Host "$script:BinDir already in user PATH"
            }
        }
    } finally {
        Remove-Item -Recurse -Force -Path $tmp -ErrorAction SilentlyContinue
    }
}

if ($Help) {
    Show-Usage
    return
}

Invoke-Install

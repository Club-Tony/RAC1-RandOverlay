[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Bat','Zip','Exe')][string[]]$Format = @('Bat','Zip','Exe'),
    [string]$OutputRoot,
    [string]$LayerDll,
    [switch]$NoClean,
    [switch]$AllowDirty
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$InstallerRoot = $PSScriptRoot
$VulkanRoot = Split-Path $InstallerRoot -Parent
$RepoRoot = Split-Path $VulkanRoot -Parent
if (-not $Version) { $Version = (Get-Content -LiteralPath (Join-Path $RepoRoot 'VERSION') -Raw).Trim() }
if ($Version -notmatch '^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') { throw "Invalid release version: $Version" }
if (-not $OutputRoot) { $OutputRoot = Join-Path $VulkanRoot 'dist' }
if (-not $LayerDll) { $LayerDll = Join-Path $VulkanRoot 'build\RandOverlay_layer.dll' }
if (-not (Test-Path -LiteralPath $LayerDll -PathType Leaf)) { throw "Build the layer first; DLL missing at $LayerDll" }

function Get-Sha([string]$Path) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $hasher.Dispose() }
}
function Remove-Tree([string]$Path) { if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete([IO.Path]::GetFullPath($Path), $true) } }
function Write-Json([string]$Path, $Value) { $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8 }

# Archives only the files under $Source. Entry names are relative to $EntryRoot, so the
# package folder itself stays the single top-level entry and nothing else in the staging
# area can reach the ZIP.
function New-DeterministicZip([string]$Source, [string]$EntryRoot, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    $Source = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')
    $EntryRoot = (Get-Item -LiteralPath $EntryRoot).FullName.TrimEnd('\')
    if (-not $Source.StartsWith($EntryRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "ZIP source $Source is not inside $EntryRoot" }
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Delete($Destination) }
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $files = Get-ChildItem -LiteralPath $Source -File -Recurse | Sort-Object { $_.FullName.Substring($EntryRoot.Length) }
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($EntryRoot.Length).TrimStart('\').Replace('\','/')
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                $input = [IO.File]::OpenRead($file.FullName)
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

function New-SelfExtractingBat([string]$ZipPath, [string]$Destination) {
    $sha = Get-Sha $ZipPath
    $extractor = @'
param([Parameter(Mandatory)][string]$SelfPath, [Parameter(Mandatory)][string]$ExpectedSha256)
$ErrorActionPreference = 'Stop'
function Get-Sha256([string]$Path) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $hasher.Dispose() }
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('RandOverlaySetup-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $zipPath = Join-Path $tempRoot 'RandOverlay-Vulkan.zip'
    Write-Host 'RandOverlay one-click installer' -ForegroundColor Cyan
    Write-Host 'This BAT contains and automatically installs the current release ZIP.' -ForegroundColor DarkGray
    Write-Host 'Decoding embedded release ZIP...' -ForegroundColor Cyan
    $text = [IO.File]::ReadAllText($SelfPath)
    $marker = '#===PAYLOAD==='
    $index = $text.LastIndexOf($marker)
    if ($index -lt 0) { throw 'Embedded payload marker is missing. Re-download the installer.' }
    [IO.File]::WriteAllBytes($zipPath, [Convert]::FromBase64String($text.Substring($index + $marker.Length).Trim()))
    $actualSha = Get-Sha256 $zipPath
    if ($actualSha -ne $ExpectedSha256) { throw "Embedded ZIP failed verification. Expected $ExpectedSha256; got $actualSha." }
    Write-Host "[OK] Embedded ZIP verified: $actualSha" -ForegroundColor Green
    $expanded = Join-Path $tempRoot 'expanded'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $expanded
    Get-ChildItem -LiteralPath $expanded -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    $setup = Get-ChildItem -LiteralPath $expanded -Filter 'Setup-RandOverlay.ps1' -Recurse | Select-Object -First 1
    if (-not $setup) { throw 'Setup-RandOverlay.ps1 is missing from the embedded release.' }
    if ($env:RANDOVERLAY_BUNDLE_NOLAUNCH -eq '1') {
        Write-Host '[OK] Self-contained BAT decode/extract verification passed.' -ForegroundColor Green
        exit 0
    }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $setup.FullName
    exit $LASTEXITCODE
} catch {
    Write-Host ''
    Write-Host "Installer stopped safely: $($_.Exception.Message)" -ForegroundColor Red
    exit 9
} finally {
    if ([IO.Directory]::Exists($tempRoot)) { [IO.Directory]::Delete($tempRoot, $true) }
}
'@
    $stub = @"
@echo off
setlocal EnableExtensions DisableDelayedExpansion
title RAC RandOverlay Setup
set "RANDOVERLAY_SELF=%~f0"
set "RANDOVERLAY_EXTRACTOR=%TEMP%\RandOverlay-Extract-%RANDOM%-%RANDOM%.ps1"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "`$t=[IO.File]::ReadAllText(`$env:RANDOVERLAY_SELF);`$i=`$t.LastIndexOf('#===EXTRACTOR===');if(`$i -lt 0){exit 9};[IO.File]::WriteAllText(`$env:RANDOVERLAY_EXTRACTOR,`$t.Substring(`$i))"
if errorlevel 1 goto :stagefailed
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RANDOVERLAY_EXTRACTOR%" -SelfPath "%RANDOVERLAY_SELF%" -ExpectedSha256 "$sha"
set "RANDOVERLAY_EXIT=%ERRORLEVEL%"
del "%RANDOVERLAY_EXTRACTOR%" >nul 2>&1
if "%RANDOVERLAY_BUNDLE_NOLAUNCH%"=="1" exit /b %RANDOVERLAY_EXIT%
echo.
echo Press Enter to exit.
pause >nul
exit /b %RANDOVERLAY_EXIT%
:stagefailed
echo Could not stage the embedded installer. The BAT may be incomplete or corrupt.
del "%RANDOVERLAY_EXTRACTOR%" >nul 2>&1
echo.
echo Press Enter to exit.
pause >nul
exit /b 9
#===EXTRACTOR===
"@
    $payload = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ZipPath))
    $builder = [Text.StringBuilder]::new()
    foreach ($line in ($stub -split "`r?`n")) { [void]$builder.Append($line).Append("`r`n") }
    foreach ($line in ($extractor -split "`r?`n")) { [void]$builder.Append($line).Append("`r`n") }
    [void]$builder.Append("`r`n#===PAYLOAD===`r`n").Append($payload).Append("`r`n")
    [IO.File]::WriteAllText($Destination, $builder.ToString(), [Text.Encoding]::ASCII)
}

# release.json names the commit a release was built from. That only means something when
# the commit is known and nothing uncommitted went into the build, so git must be
# available, HEAD must resolve, and `git status --porcelain` must be empty.
function Get-SourceProvenance([string]$Root) {
    $provenance = [ordered]@{ Commit='unknown'; Dirty=$true; Problems=[System.Collections.Generic.List[string]]::new() }
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) {
        $provenance.Problems.Add('git is not available, so the source commit cannot be recorded')
        return $provenance
    }
    # Windows PowerShell 5.1 turns redirected native stderr into error records, which
    # 'Stop' would make terminating. Exit codes are checked explicitly instead.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $headOutput = @(& git -C $Root rev-parse --verify HEAD 2>&1)
        $headExit = $LASTEXITCODE
        $statusOutput = @(& git -C $Root status --porcelain 2>&1)
        $statusExit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    $headLines = @($headOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($headExit -eq 0 -and $headLines.Count -eq 1 -and $headLines[0] -match '^[0-9a-f]{40}([0-9a-f]{24})?$') {
        $provenance.Commit = $headLines[0]
    } else {
        $provenance.Problems.Add("the source commit is unknown (git rev-parse HEAD exited $headExit)")
    }
    $statusLines = @($statusOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { ([string]$_).TrimEnd() } | Where-Object { $_ })
    if ($statusExit -ne 0) {
        $provenance.Problems.Add("the working tree state is unknown (git status exited $statusExit)")
    } elseif ($statusLines.Count -gt 0) {
        $shown = @($statusLines | Select-Object -First 5 | ForEach-Object { $_.Trim() }) -join ', '
        if ($statusLines.Count -gt 5) { $shown += ', ...' }
        $provenance.Problems.Add("the working tree has $($statusLines.Count) uncommitted change(s): $shown")
    } else {
        $provenance.Dirty = $false
    }
    $provenance
}

# Checked before anything is written, so a refused build leaves no output behind.
# -AllowDirty is for local iteration and the test suites; it lifts the refusal only, and
# release.json still records the commit and state that were found.
$provenance = Get-SourceProvenance $RepoRoot
if ($provenance.Problems.Count -gt 0) {
    $reasons = $provenance.Problems -join '; '
    if (-not $AllowDirty) {
        throw "Refusing to build a release: $reasons. Build from a clean checkout of a commit, or pass -AllowDirty for a local test build."
    }
    Write-Warning "-AllowDirty: building from an unverified source tree ($reasons). release.json records sourceCommit=$($provenance.Commit), sourceDirty=$($provenance.Dirty.ToString().ToLowerInvariant())."
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$work = Join-Path $OutputRoot '.release-work'
# Build-time scratch, such as the generated bootstrap source, sits beside the staging
# area, never inside it.
$scratch = Join-Path $OutputRoot '.release-scratch'
if (-not $NoClean) { Remove-Tree $work; Remove-Tree $scratch }
$packageName = "RandOverlay-Vulkan-v$Version"
$packageRoot = Join-Path $work $packageName
# The package folder is restaged on every run, -NoClean included: copying lib onto an
# earlier run's copy would nest it as lib\lib, and files dropped from the source would
# linger. It is the only folder the ZIP archives.
Remove-Tree $packageRoot
$payload = Join-Path $packageRoot 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null

Copy-Item -LiteralPath $LayerDll -Destination (Join-Path $payload 'RandOverlay_layer.dll')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'RandOverlay.ini') -Destination (Join-Path $payload 'RandOverlay.ini')
$manifestSource = Join-Path $InstallerRoot 'stack-manifest.json'
$null = Get-Content -LiteralPath $manifestSource -Raw | ConvertFrom-Json   # fail fast on malformed JSON
Copy-Item -LiteralPath $manifestSource -Destination (Join-Path $payload 'stack-manifest.json')
Copy-Item -LiteralPath (Join-Path $InstallerRoot 'Setup-RandOverlay.ps1') -Destination (Join-Path $packageRoot 'Setup-RandOverlay.ps1')
$libSource = Join-Path $InstallerRoot 'lib'
if (-not (Test-Path -LiteralPath $libSource -PathType Container)) { throw "Installer library folder is missing: $libSource" }
Copy-Item -LiteralPath $libSource -Destination (Join-Path $packageRoot 'lib') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $InstallerRoot 'Install-RandOverlay.bat') -Destination (Join-Path $packageRoot 'Install-RandOverlay.bat')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination (Join-Path $packageRoot 'LICENSE.txt')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'PRIVACY.md') -Destination (Join-Path $packageRoot 'PRIVACY.md')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'THIRD-PARTY-NOTICES.md') -Destination (Join-Path $packageRoot 'THIRD-PARTY-NOTICES.md')

$manifest = [ordered]@{
    file_format_version='1.2.0'
    layer=[ordered]@{
        name='VK_LAYER_RANDOVERLAY_overlay'; type='GLOBAL'; library_path='.\RandOverlay_layer.dll'
        api_version='1.3.0'; implementation_version='1'
        description='Archipelago in-frame overlay for Ratchet & Clank randomizers'
        functions=[ordered]@{
            vkNegotiateLoaderLayerInterfaceVersion='RandOverlay_NegotiateLoaderLayerInterfaceVersion'
            vkGetInstanceProcAddr='RandOverlay_GetInstanceProcAddr'
            vkGetDeviceProcAddr='RandOverlay_GetDeviceProcAddr'
        }
        disable_environment=[ordered]@{ DISABLE_RANDOVERLAY='1' }
    }
}
Write-Json (Join-Path $payload 'RandOverlay_layer.json') $manifest

$trackedFiles = @('RandOverlay_layer.dll','RandOverlay_layer.json','RandOverlay.ini','stack-manifest.json')
$fileRecords = foreach ($name in $trackedFiles) {
    [ordered]@{ path=$name; sha256=(Get-Sha (Join-Path $payload $name)) }
}
$releaseMetadata = [ordered]@{
    schemaVersion=1; version=$Version; sourceRepository='https://github.com/Club-Tony/RAC1-RandOverlay'
    sourceCommit=$provenance.Commit; sourceDirty=$provenance.Dirty; files=@($fileRecords)
    games=[ordered]@{
        RAC1=[ordered]@{ emulator='RPCS3'; client='Ratchet & Clank Client' }
        RAC2=[ordered]@{ emulator='PCSX2'; client='Ratchet & Clank 2 Client' }
        RAC3=[ordered]@{ emulator='PCSX2'; client='Ratchet and Clank 3 Client' }
    }
    network=[ordered]@{ telemetry=$false; updateCheck='user-initiated'; automaticPackage='PCSX2Team.PCSX2' }
    authenticodeStatus=[string](Get-AuthenticodeSignature -LiteralPath $LayerDll).Status
}
Write-Json (Join-Path $payload 'release.json') $releaseMetadata

$installText = @"
RandOverlay Vulkan v$Version

RECOMMENDED: double-click Install-RandOverlay.bat.

Advanced users can instead open PowerShell in this folder and run:
  powershell -NoProfile -File .\Setup-RandOverlay.ps1

Windows may show Unknown Publisher or SmartScreen warnings while this project is
unsigned or has not established reputation. Download only from the official
Club-Tony/RAC1-RandOverlay GitHub Releases page and verify SHA256SUMS.txt.

The setup defaults to RAC1/RPCS3 and can select RAC1, RAC2, and/or RAC3.
It installs per-user under %LOCALAPPDATA%\RandOverlay and sends no telemetry.
"@
Set-Content -LiteralPath (Join-Path $packageRoot 'README-INSTALL.txt') -Value $installText -Encoding UTF8

$zipPath = Join-Path $OutputRoot "$packageName.zip"
New-DeterministicZip -Source $packageRoot -EntryRoot $work -Destination $zipPath
$outputs = [System.Collections.Generic.List[string]]::new()
$outputs.Add($zipPath)
$manifestAsset = Join-Path $OutputRoot 'stack-manifest.json'
Copy-Item -LiteralPath $manifestSource -Destination $manifestAsset -Force
$outputs.Add($manifestAsset)

if ($Format -contains 'Bat') {
    $batPath = Join-Path $OutputRoot "RandOverlay-Setup-v$Version.bat"
    New-SelfExtractingBat -ZipPath $zipPath -Destination $batPath
    $outputs.Insert(0, $batPath)
}

if ($Format -contains 'Exe') {
    $csc = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'),
        (Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not (Test-Path -LiteralPath $csc)) { throw 'The in-box C# compiler is unavailable; build with -Format Bat,Zip or install .NET Framework tools.' }
    $bootstrapSource = Get-Content -LiteralPath (Join-Path $InstallerRoot 'Bootstrap.cs') -Raw
    $bootstrapSource = $bootstrapSource.Replace('__PAYLOAD_SHA256__', (Get-Sha $zipPath))
    # AssemblyVersion accepts digits and dots only, so a prerelease suffix such as
    # 0.2.0-beta goes to AssemblyInformationalVersion and the numeric part is padded
    # to the four fields the attribute expects.
    $numeric = ([regex]::Match($Version, '^\d+(\.\d+){0,3}')).Value
    if (-not $numeric) { throw "Version '$Version' does not start with a number." }
    while (($numeric -split '\.').Count -lt 4) { $numeric = "$numeric.0" }
    $bootstrapSource = $bootstrapSource.Replace('__VERSION_NUMERIC__', $numeric)
    $bootstrapSource = $bootstrapSource.Replace('__VERSION_FULL__', $Version)
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $generatedSource = Join-Path $scratch 'Bootstrap.generated.cs'
    Set-Content -LiteralPath $generatedSource -Value $bootstrapSource -Encoding UTF8
    $exePath = Join-Path $OutputRoot "RandOverlay-Setup-v$Version.exe"
    & $csc /nologo /target:exe /optimize+ "/out:$exePath" "/resource:$zipPath,payload.zip" /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll $generatedSource
    if ($LASTEXITCODE -ne 0) { throw "csc.exe exited $LASTEXITCODE" }
    $outputs.Add($exePath)
}

$sumPath = Join-Path $OutputRoot 'SHA256SUMS.txt'
$sumLines = foreach ($path in $outputs) { "$(Get-Sha $path)  $([IO.Path]::GetFileName($path))" }
Set-Content -LiteralPath $sumPath -Value $sumLines -Encoding ASCII
$outputs.Add($sumPath)

$outputs | ForEach-Object { [pscustomobject]@{ File=[IO.Path]::GetFileName($_); SHA256=(Get-Sha $_); Path=$_ } } | Format-Table -AutoSize

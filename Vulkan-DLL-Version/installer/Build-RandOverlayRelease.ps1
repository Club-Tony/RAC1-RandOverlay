[CmdletBinding()]
param(
    [string]$Version,
    [ValidateSet('Zip','Exe')][string[]]$Format = @('Zip','Exe'),
    [string]$OutputRoot,
    [string]$LayerDll,
    [switch]$NoClean
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

function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Remove-Tree([string]$Path) { if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete([IO.Path]::GetFullPath($Path), $true) } }
function Write-Json([string]$Path, $Value) { $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8 }

function New-DeterministicZip([string]$Source, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression
    if (Test-Path -LiteralPath $Destination) { [IO.File]::Delete($Destination) }
    $stream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try {
            $files = Get-ChildItem -LiteralPath $Source -File -Recurse | Sort-Object { $_.FullName.Substring($Source.Length) }
            foreach ($file in $files) {
                $relative = $file.FullName.Substring($Source.Length).TrimStart('\').Replace('\','/')
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                $input = [IO.File]::OpenRead($file.FullName)
                $output = $entry.Open()
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            }
        } finally { $archive.Dispose() }
    } finally { $stream.Dispose() }
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$work = Join-Path $OutputRoot '.release-work'
if (-not $NoClean) { Remove-Tree $work }
$packageName = "RandOverlay-Vulkan-v$Version"
$packageRoot = Join-Path $work $packageName
$payload = Join-Path $packageRoot 'payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null

Copy-Item -LiteralPath $LayerDll -Destination (Join-Path $payload 'RandOverlay_layer.dll')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'RandOverlay.ini') -Destination (Join-Path $payload 'RandOverlay.ini')
Copy-Item -LiteralPath (Join-Path $InstallerRoot 'Setup-RandOverlay.ps1') -Destination (Join-Path $packageRoot 'Setup-RandOverlay.ps1')
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

$trackedFiles = @('RandOverlay_layer.dll','RandOverlay_layer.json','RandOverlay.ini')
$fileRecords = foreach ($name in $trackedFiles) {
    [ordered]@{ path=$name; sha256=(Get-Sha (Join-Path $payload $name)) }
}
$sourceCommit = (& git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
if (-not $sourceCommit) { $sourceCommit = 'unknown' }
$sourceDirty = [bool](& git -C $RepoRoot status --porcelain 2>$null | Select-Object -First 1)
$releaseMetadata = [ordered]@{
    schemaVersion=1; version=$Version; sourceRepository='https://github.com/Club-Tony/RAC1-RandOverlay'
    sourceCommit=$sourceCommit.Trim(); sourceDirty=$sourceDirty; files=@($fileRecords)
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
New-DeterministicZip $work $zipPath
$outputs = [System.Collections.Generic.List[string]]::new()
$outputs.Add($zipPath)

if ($Format -contains 'Exe') {
    $csc = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'),
        (Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not (Test-Path -LiteralPath $csc)) { throw 'The in-box C# compiler is unavailable; build with -Format Zip or install .NET Framework tools.' }
    $bootstrapSource = Get-Content -LiteralPath (Join-Path $InstallerRoot 'Bootstrap.cs') -Raw
    $bootstrapSource = $bootstrapSource.Replace('__PAYLOAD_SHA256__', (Get-Sha $zipPath))
    $generatedSource = Join-Path $work 'Bootstrap.generated.cs'
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

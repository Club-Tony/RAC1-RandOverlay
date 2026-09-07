[CmdletBinding()]
param([switch]$KeepArtifacts)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$TestsRoot = Split-Path $PSScriptRoot -Parent
$VulkanRoot = Split-Path $TestsRoot -Parent
$RepoRoot = Split-Path $VulkanRoot -Parent
$ArtifactRoot = Join-Path $PSScriptRoot 'artifacts'
$RunRoot = Join-Path $ArtifactRoot ([guid]::NewGuid().ToString('N'))
$InstallRoot = Join-Path $RunRoot 'LocalAppData\RandOverlay'
$TestHiveRelative = "Software\RandOverlayInstallerTests\$([guid]::NewGuid().ToString('N'))"
$RegistryPath = "HKCU:\$TestHiveRelative\ImplicitLayers"
$UninstallRoot = "HKCU:\$TestHiveRelative\Uninstall"
$Failures = [System.Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot 'TestCommon.ps1')

function Get-Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }
function Write-Bytes([string]$Path, [int]$Seed, [int]$Length) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    $random = New-Object System.Random($Seed)
    $bytes = New-Object byte[] $Length
    $random.NextBytes($bytes)
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function Get-FileUri([string]$Path) { ([uri]$Path).AbsoluteUri }
function Read-State { Get-Content -LiteralPath (Join-Path $InstallRoot 'setup-state.json') -Raw | ConvertFrom-Json }
function Get-Row($Rows, [string]$Id) { @($Rows | Where-Object { $_.Id -eq $Id })[0] }

New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
try {
    # --- Release payload carries the manifest -------------------------------------------------
    $layerDll = Join-Path $VulkanRoot 'build\RandOverlay_layer.dll'
    if (-not (Test-Path -LiteralPath $layerDll)) {
        $layerDll = Join-Path $RunRoot 'RandOverlay_layer.fixture.dll'
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\version.dll') -Destination $layerDll
    }
    & (Join-Path $VulkanRoot 'installer\Build-RandOverlayRelease.ps1') -Format Zip -LayerDll $layerDll -OutputRoot (Join-Path $RunRoot 'dist') | Out-Null
    $zip = Get-ChildItem -LiteralPath (Join-Path $RunRoot 'dist') -Filter 'RandOverlay-Vulkan-*.zip' | Select-Object -First 1
    Assert-True (Test-Path -LiteralPath (Join-Path $RunRoot 'dist\stack-manifest.json')) 'release publishes stack-manifest.json beside the ZIP'
    Assert-True ((Get-Content -LiteralPath (Join-Path $RunRoot 'dist\SHA256SUMS.txt') -Raw) -match 'stack-manifest\.json') 'SHA256SUMS.txt lists stack-manifest.json'
    $expanded = Join-Path $RunRoot 'expanded'
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
    $releaseRoot = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
    $setup = Join-Path $releaseRoot.FullName 'Setup-RandOverlay.ps1'
    $releaseJson = Get-Content -LiteralPath (Join-Path $releaseRoot.FullName 'payload\release.json') -Raw | ConvertFrom-Json
    Assert-True (@($releaseJson.files | Where-Object { $_.path -eq 'stack-manifest.json' }).Count -eq 1) 'release.json hash-covers the embedded stack manifest'

    # --- Fixtures: Archipelago with user data, RPCS3 with firmware/game/mod/config, uninstall key
    $fakeArch = Join-Path $RunRoot 'Archipelago'
    foreach ($name in @('ArchipelagoLauncher.exe','custom_worlds\other.apworld','Players\test.yaml','output\seed.zip','host.yaml')) {
        $p = Join-Path $fakeArch $name
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, "fixture $name")
    }
    $userFiles = @('Players\test.yaml','output\seed.zip','host.yaml','custom_worlds\other.apworld')
    $userDataBefore = @($userFiles | ForEach-Object { Get-Sha (Join-Path $fakeArch $_) })
    $fakeRpcs3Dir = Join-Path $RunRoot 'Emulators\rpcs3-v0.0.27-test'
    $fakeRpcs3 = Join-Path $fakeRpcs3Dir 'rpcs3.exe'
    foreach ($name in @('rpcs3.exe','dev_hdd0\game\NPEA00385\PARAM.SFO','dev_hdd0\game\BORD00001\PARAM.SFO','dev_hdd0\home\00000001\savedata\keep.bin')) {
        $p = Join-Path $fakeRpcs3Dir $name
        New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($p, "fixture $name")
    }
    New-Item -ItemType Directory -Path (Join-Path $fakeRpcs3Dir 'dev_flash\vsh\etc') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeRpcs3Dir 'dev_flash\vsh\etc\version.txt') -Value "release:04.9200:`nbuild:68466,20250218:test" -Encoding ASCII
    New-Item -ItemType Directory -Path (Join-Path $fakeRpcs3Dir 'config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeRpcs3Dir 'config\config.yml') -Value "Net:`n  Bind address: 0.0.0.0`n  Internet enabled: Disconnected`n  PSN status: Disconnected`nSystem:`n  Language: 1" -Encoding ASCII
    $saveFile = Join-Path $fakeRpcs3Dir 'dev_hdd0\home\00000001\savedata\keep.bin'
    $fakeVulkan = Join-Path $RunRoot 'vulkan-1.dll'
    [IO.File]::WriteAllText($fakeVulkan, '')
    $uninstallKey = Join-Path $UninstallRoot 'Archipelago_is1'
    New-Item -Path $uninstallKey -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayName -Value 'Archipelago 0.6.7' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name DisplayVersion -Value '' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $uninstallKey -Name InstallLocation -Value ($fakeArch + '\') -PropertyType String -Force | Out-Null

    # --- Apworld fixtures and a file:// manifest ----------------------------------------------
    $fixtures = Join-Path $RunRoot 'apworlds'
    Write-Bytes (Join-Path $fixtures 'A.apworld') 1 4096
    Write-Bytes (Join-Path $fixtures 'B.apworld') 2 5120
    Write-Bytes (Join-Path $fixtures 'C.apworld') 3 6144
    Write-Bytes (Join-Path $fixtures 'D.apworld') 4 3072
    $shaA = Get-Sha (Join-Path $fixtures 'A.apworld')
    $shaB = Get-Sha (Join-Path $fixtures 'B.apworld')
    $shaC = Get-Sha (Join-Path $fixtures 'C.apworld')
    $shaD = Get-Sha (Join-Path $fixtures 'D.apworld')

    # --- PopTracker archives and a multiplayer PKG fixture -------------------------------------
    function New-PopTrackerZip([string]$ZipPath, [string]$Version) {
        $stage = Join-Path $RunRoot ('popstage-' + $Version.Replace('.', '_'))
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
        New-Item -ItemType Directory -Path (Join-Path $stage 'poptracker\packs') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $stage 'poptracker\assets') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $stage 'poptracker\poptracker.exe') -Value "poptracker $Version" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $stage 'poptracker\CHANGELOG.md') -Value "changelog $Version" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $stage 'poptracker\assets\logo.txt') -Value "asset $Version" -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $stage 'poptracker\packs\README.txt') -Value 'shipped packs placeholder' -Encoding ASCII
        Compress-Archive -Path (Join-Path $stage 'poptracker') -DestinationPath $ZipPath -Force
    }
    $popZipOld = Join-Path $fixtures 'poptracker-old.zip'
    $popZipNew = Join-Path $fixtures 'poptracker-new.zip'
    New-PopTrackerZip $popZipOld '0.35.4'
    New-PopTrackerZip $popZipNew '0.36.0'
    $shaPopOld = Get-Sha $popZipOld; $sizePopOld = (Get-Item -LiteralPath $popZipOld).Length
    $shaPopNew = Get-Sha $popZipNew; $sizePopNew = (Get-Item -LiteralPath $popZipNew).Length
    $popBadZip = Join-Path $fixtures 'poptracker-noexe.zip'
    $badStage = Join-Path $RunRoot 'popstage-noexe'
    New-Item -ItemType Directory -Path (Join-Path $badStage 'poptracker') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $badStage 'poptracker\readme.txt') -Value 'no executable here' -Encoding ASCII
    Compress-Archive -Path (Join-Path $badStage 'poptracker') -DestinationPath $popBadZip -Force
    $shaPopBad = Get-Sha $popBadZip; $sizePopBad = (Get-Item -LiteralPath $popBadZip).Length
    $fixturePkg = Join-Path $fixtures 'multiplayer.pkg'
    Write-Bytes $fixturePkg 11 8192
    $shaPkg = Get-Sha $fixturePkg; $sizePkg = (Get-Item -LiteralPath $fixturePkg).Length
    $manifestPath = Join-Path $RunRoot 'test-manifest.json'
    $manifest = [ordered]@{
        schemaVersion = 1; manifestVersion = 'test'; generatedAt = '2026-09-02T00:00:00Z'
        originAllowlist = @('github.com')
        components = [ordered]@{
            archipelago = [ordered]@{ displayName='Archipelago Launcher'; kind='detect-only'; required=$true; origin='https://github.com/ArchipelagoMW/Archipelago/releases'; compatible=[ordered]@{ min='0.6.5'; maxExclusive='0.7.0'; tested=@('0.6.7') } }
            'rac1-apworld' = [ordered]@{ displayName='Ratchet & Clank 1 APWorld'; kind='managed-file'; required=$true; origin='https://github.com/Panda291/Archipelago/releases'; fileName='rac1.apworld'; versions=@(
                [ordered]@{ version='0.2.0-beta'; tag='vA'; status='tested'; url=(Get-FileUri (Join-Path $fixtures 'A.apworld')); sha256=$shaA; size=4096; revoked=$false; revokedReason=$null },
                [ordered]@{ version='0.1.0'; tag='vOld'; status='tested'; url=(Get-FileUri (Join-Path $fixtures 'D.apworld')); sha256=$shaD; size=3072; revoked=$false; revokedReason=$null },
                [ordered]@{ version='0.2.1-beta'; tag='vB'; status='untested'; url=(Get-FileUri (Join-Path $fixtures 'B.apworld')); sha256=$shaB; size=5120; revoked=$false; revokedReason=$null },
                [ordered]@{ version='0.3.0'; tag='vC'; status='tested'; url=(Get-FileUri (Join-Path $fixtures 'C.apworld')); sha256=$shaC; size=6144; revoked=$true; revokedReason='fixture revocation' },
                [ordered]@{ version='0.4.0'; tag='vBadHash'; status='untested'; url=(Get-FileUri (Join-Path $fixtures 'A.apworld')); sha256=('0' * 64); size=4096; revoked=$false; revokedReason=$null },
                [ordered]@{ version='0.5.0'; tag='vBadSize'; status='untested'; url=(Get-FileUri (Join-Path $fixtures 'A.apworld')); sha256=$shaA; size=4101; revoked=$false; revokedReason=$null }
            ) }
            rpcs3 = [ordered]@{ displayName='RPCS3'; kind='detect-only'; required=$true; origin='https://rpcs3.net/download'; minVersion='0.0.27'; knownBad=@('0.0.20'); gameTitleId='NPEA00385'; modTitleId='BORD00001' }
            'rac1-multiplayer' = [ordered]@{ displayName='Ratchet & Clank Multiplayer Client (PKG)'; kind='managed-file'; required=$true; origin='https://github.com/bordplate/rac1-multiplayer/releases'; license='AGPL-3.0'; fileName='BDUPS3-BORD00001_00-0000000000000000.pkg'; placement='staged'; installRelative='stack\downloads'; titleId='BORD00001'; handoffNote='RPCS3 installs the PKG; this tool only downloads and verifies it.'; versions=@(
                [ordered]@{ version='0.0.1-115'; tag='vPkg'; status='untested'; url=(Get-FileUri $fixturePkg); sha256=$shaPkg; size=$sizePkg; revoked=$false; revokedReason=$null }
            ) }
            poptracker = [ordered]@{ displayName='PopTracker (optional tracker)'; kind='managed-archive'; required=$false; origin='https://github.com/black-sliver/PopTracker/releases'; license='GPL-3.0'; installRelative='stack\PopTracker'; executable='poptracker.exe'; portableMarker='portable.txt'; archiveRoot='poptracker'; preserveRelative=@('packs','saves','settings.json'); packsNote='No Ratchet & Clank tracker pack ships with this tool.'; packsUrl='https://github.com/SomeLazyGamer/RaC-AP-Poptracker'; versions=@(
                [ordered]@{ version='0.35.4'; tag='vPopOld'; status='untested'; url=(Get-FileUri $popZipOld); sha256=$shaPopOld; size=$sizePopOld; revoked=$false; revokedReason=$null },
                [ordered]@{ version='0.36.0'; tag='vPopNew'; status='untested'; url=(Get-FileUri $popZipNew); sha256=$shaPopNew; size=$sizePopNew; revoked=$false; revokedReason=$null },
                [ordered]@{ version='0.37.0'; tag='vPopBad'; status='untested'; url=(Get-FileUri $popBadZip); sha256=$shaPopBad; size=$sizePopBad; revoked=$false; revokedReason=$null }
            ) }
        }
    }
    $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $common = @('-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-ArchipelagoRoot',$fakeArch,'-RPCS3Path',$fakeRpcs3,'-VulkanLoaderPath',$fakeVulkan,'-UninstallRegistryRoots',$UninstallRoot,'-ManifestPath',$manifestPath,'-AllowLocalOrigins')
    $installed = Join-Path $InstallRoot 'Setup-RandOverlay.ps1'
    $target = Join-Path $fakeArch 'custom_worlds\rac1.apworld'

    # --- Detection before anything is installed (the missing apworld is also a missing prerequisite, hence exit 2)
    $preflight = Invoke-Setup $setup (@('-Action','Preflight','-Games','RAC1','-Json') + $common) 2 | ConvertFrom-Json
    $arch = Get-Row $preflight.stack 'archipelago'
    Assert-True ($arch.Version -eq '0.6.7' -and $arch.Status -eq 'tested') 'archipelago version comes from the uninstall key and matches the tested list'
    $rp = Get-Row $preflight.stack 'rpcs3'
    Assert-True ($rp.Version -eq '0.0.27' -and $rp.Status -eq 'detected' -and $rp.Detail -match 'firmware 04\.9200' -and $rp.Detail -match 'game NPEA00385 present' -and $rp.Detail -match 'multiplayer PKG present') 'rpcs3 row reports version, firmware, game and mod from the emulator folder'
    $net = Get-Row $preflight.stack 'rpcs3-network'
    Assert-True ($net.Status -eq 'Disconnected' -and -not $net.Ready) 'rpcs3 network status is read from config\config.yml'
    Assert-True ((Get-Row $preflight.stack 'rac1-apworld').Status -eq 'missing') 'apworld row reports missing before installation'
    Assert-True ((Get-Row $preflight.stack 'lawrence').Optional -and (Get-Row $preflight.stack 'poptracker').Optional) 'lawrence and poptracker rows are optional'
    Assert-True (@($preflight.stack).Count -eq 9 -and -not (Test-Path -LiteralPath $InstallRoot)) 'preflight stack detection creates nothing under the install root'
    $embedded = Invoke-Setup $setup @('-Action','Preflight','-Games','RAC1','-Json','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-ArchipelagoRoot',$fakeArch,'-RPCS3Path',$fakeRpcs3,'-VulkanLoaderPath',$fakeVulkan,'-UninstallRegistryRoots',$UninstallRoot) 2 | ConvertFrom-Json
    Assert-True ((Get-Row $embedded.stack 'rac1-apworld').Detail -notmatch 'manifest unavailable') 'the embedded release manifest is used when no override exists'

    # --- Overlay install provides the state the stack actions need ---------------------------
    Invoke-Setup $setup (@('-Action','Install','-Games','RAC1','-SkipPrerequisiteChecks','-NonInteractive') + $common) | Out-Null
    Assert-True ((Read-State).status -eq 'installed') 'overlay install completes with the stack fixtures'

    # --- Newest tested version installs into custom_worlds ------------------------------------
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-NonInteractive') + $common) | Out-Null
    $state = Read-State
    Assert-True ((Test-Path -LiteralPath $target) -and (Get-Sha $target) -eq $shaA -and $state.stack.'rac1-apworld'.version -eq '0.2.0-beta' -and -not $state.stack.'rac1-apworld'.adopted) 'newest tested unrevoked apworld is downloaded, verified and placed'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'stack\downloads') -File).Count -eq 0) 'downloads folder is empty after placement'
    $userDataAfter = @($userFiles | ForEach-Object { Get-Sha (Join-Path $fakeArch $_) })
    Assert-True (@(Compare-Object $userDataBefore $userDataAfter).Count -eq 0) 'Archipelago user files are untouched by the apworld install'

    # --- Rerun adopts without rewriting -------------------------------------------------------
    $before = (Get-Item -LiteralPath $target).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-NonInteractive') + $common) | Out-Null
    Assert-True ((Get-Item -LiteralPath $target).LastWriteTimeUtc -eq $before -and (Read-State).stack.'rac1-apworld'.adopted) 'reinstalling the same version adopts the file without rewriting it'

    # --- Status reports the installed apworld -------------------------------------------------
    $status = Invoke-Setup $installed (@('-Action','Status','-Json') + $common) | ConvertFrom-Json
    $row = Get-Row $status.stack 'rac1-apworld'
    Assert-True ($status.healthy -and $row.Status -eq 'tested' -and $row.Version -eq '0.2.0-beta') 'status reports the tested apworld version'

    # --- Unknown existing file: confirmation required, then replace with backup ---------------
    Write-Bytes $target 99 2048
    $unknownSha = Get-Sha $target
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-NonInteractive') + $common) 3 | Out-Null
    Assert-True ((Get-Sha $target) -eq $unknownSha) 'an unknown existing apworld is not replaced without -ReplaceExisting (exit 3)'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-NonInteractive','-ReplaceExisting') + $common) | Out-Null
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'stack\rollback') -File)
    Assert-True ((Get-Sha $target) -eq $shaA -and $backups.Count -eq 1 -and (Get-Sha $backups[0].FullName) -eq $unknownSha) '-ReplaceExisting replaces the file and keeps one verified backup'

    # --- Untested needs -AllowUntested; revoked is refused even then --------------------------
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-ComponentVersion','0.2.1-beta','-NonInteractive','-ReplaceExisting') + $common) 1 | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaA) 'an untested version is refused without -AllowUntested'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-ComponentVersion','0.2.1-beta','-NonInteractive','-ReplaceExisting','-AllowUntested') + $common) | Out-Null
    $state = Read-State
    Assert-True ((Get-Sha $target) -eq $shaB -and $state.stack.'rac1-apworld'.untested -and $state.stack.'rac1-apworld'.previous.sha256 -eq $shaA) '-AllowUntested installs the untested version and records the previous one'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-ComponentVersion','vC','-NonInteractive','-ReplaceExisting','-AllowUntested') + $common) 1 | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaB) 'a revoked version is refused even with -AllowUntested'

    # --- Bad hash and bad size leave the target untouched and no temp files behind ------------
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-ComponentVersion','vBadHash','-NonInteractive','-ReplaceExisting','-AllowUntested') + $common) 1 | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaB -and @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'stack\downloads') -File).Count -eq 0) 'a checksum mismatch is refused and cleaned up'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-ComponentVersion','vBadSize','-NonInteractive','-ReplaceExisting','-AllowUntested') + $common) 1 | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaB) 'a size mismatch is refused'

    # --- Rollback restores the previous bytes -------------------------------------------------
    Invoke-Setup $installed (@('-Action','StackRollback','-Component','rac1-apworld') + $common) | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaA) 'StackRollback restores the previous apworld bytes'

    # --- Revoked bytes on disk are reported ---------------------------------------------------
    Copy-Item -LiteralPath (Join-Path $fixtures 'C.apworld') -Destination $target -Force
    $status = Invoke-Setup $installed (@('-Action','Status','-Json') + $common) | ConvertFrom-Json
    $row = Get-Row $status.stack 'rac1-apworld'
    Assert-True ($row.Status -eq 'revoked' -and -not $row.Ready -and $row.Detail -match 'fixture revocation') 'a revoked apworld on disk is reported with its reason'
    Copy-Item -LiteralPath (Join-Path $fixtures 'A.apworld') -Destination $target -Force

    # --- Origin allowlist ---------------------------------------------------------------------
    $commonNoLocal = @($common | Where-Object { $_ -ne '-AllowLocalOrigins' })
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-ComponentVersion','0.2.1-beta','-NonInteractive','-ReplaceExisting','-AllowUntested') + $commonNoLocal) 1 | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaA) 'file:// origins are refused unless -AllowLocalOrigins is given'
    $badOriginManifest = Join-Path $RunRoot 'bad-origin-manifest.json'
    ((Get-Content -LiteralPath $manifestPath -Raw) -replace 'file:///[^"]*?B\.apworld', 'https://example.invalid/rac1.apworld') | Set-Content -LiteralPath $badOriginManifest -Encoding UTF8
    $commonBadOrigin = @($common | ForEach-Object { if ($_ -eq $manifestPath) { $badOriginManifest } else { $_ } })
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-ComponentVersion','0.2.1-beta','-NonInteractive','-ReplaceExisting','-AllowUntested') + $commonBadOrigin) 1 | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaA) 'an https origin outside the allowlist is refused before any download'

    # --- RefreshManifest verifies against SHA256SUMS.txt ---------------------------------------
    $refreshDir = Join-Path $RunRoot 'refresh'
    New-Item -ItemType Directory -Path $refreshDir -Force | Out-Null
    $refreshedManifest = Join-Path $refreshDir 'stack-manifest.json'
    ((Get-Content -LiteralPath $manifestPath -Raw) -replace '"manifestVersion":\s*"test"', '"manifestVersion": "refreshed"') | Set-Content -LiteralPath $refreshedManifest -Encoding UTF8
    $sums = Join-Path $refreshDir 'SHA256SUMS.txt'
    Set-Content -LiteralPath $sums -Value "$(Get-Sha $refreshedManifest)  stack-manifest.json" -Encoding ASCII
    Invoke-Setup $installed (@('-Action','RefreshManifest','-ManifestUrl',(Get-FileUri $refreshedManifest),'-ChecksumUrl',(Get-FileUri $sums)) + $common) | Out-Null
    $saved = Get-Content -LiteralPath (Join-Path $InstallRoot 'stack\manifest.json') -Raw | ConvertFrom-Json
    Assert-True ($saved.manifestVersion -eq 'refreshed' -and (Test-Path -LiteralPath (Join-Path $InstallRoot 'stack\manifest.source.json'))) 'RefreshManifest verifies and saves a manifest from an allowlisted origin'
    Set-Content -LiteralPath $sums -Value "$('0' * 64)  stack-manifest.json" -Encoding ASCII
    Invoke-Setup $installed (@('-Action','RefreshManifest','-ManifestUrl',(Get-FileUri $refreshedManifest),'-ChecksumUrl',(Get-FileUri $sums)) + $common) 1 | Out-Null
    Assert-True (((Get-Content -LiteralPath (Join-Path $InstallRoot 'stack\manifest.json') -Raw | ConvertFrom-Json).manifestVersion) -eq 'refreshed') 'a manifest whose checksum does not match is rejected and the saved one is kept'

    # --- Uninstall keeps user data; -RemoveManagedStack removes only what Setup placed --------
    $saveBefore = Get-Sha $saveFile
    Invoke-Setup $installed (@('-Action','Uninstall','-NonInteractive') + $common) | Out-Null
    Assert-True ((Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath (Join-Path $fakeArch 'Players\test.yaml')) -and (Get-Sha $saveFile) -eq $saveBefore -and -not (Test-Path -LiteralPath $InstallRoot)) 'default uninstall removes the install root and leaves the apworld, YAML and RPCS3 data alone'
    Invoke-Setup $setup (@('-Action','Install','-Games','RAC1','-SkipPrerequisiteChecks','-NonInteractive') + $common) | Out-Null
    Write-Bytes $target 7 1024
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-NonInteractive','-ReplaceExisting') + $common) | Out-Null
    Assert-True ((Get-Sha $target) -eq $shaA -and -not (Read-State).stack.'rac1-apworld'.adopted) 'setup-placed apworld is recorded as managed'
    [IO.File]::AppendAllText($target, 'tamper')
    Invoke-Setup $installed (@('-Action','Uninstall','-NonInteractive','-RemoveManagedStack') + $common) | Out-Null
    Assert-True (Test-Path -LiteralPath $target) '-RemoveManagedStack keeps a managed apworld whose bytes changed'
    Invoke-Setup $setup (@('-Action','Install','-Games','RAC1','-SkipPrerequisiteChecks','-NonInteractive') + $common) | Out-Null
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-apworld','-NonInteractive','-ReplaceExisting') + $common) | Out-Null
    Invoke-Setup $installed (@('-Action','Uninstall','-NonInteractive','-RemoveManagedStack') + $common) | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath (Join-Path $fakeArch 'custom_worlds\other.apworld'))) '-RemoveManagedStack removes only the apworld Setup placed'

    # --- A fresh overlay install for the Phase 3 actions ---------------------------------------
    Invoke-Setup $setup (@('-Action','Install','-Games','RAC1','-SkipPrerequisiteChecks','-NonInteractive') + $common) | Out-Null

    # --- Manifest validation rejects a malformed managed-archive before any download -----------
    function Test-BrokenManifest([string]$Name, [scriptblock]$Mutate, [string]$Expected, [string]$Message) {
        $copy = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        & $Mutate $copy
        $brokenPath = Join-Path $RunRoot $Name
        $copy | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $brokenPath -Encoding UTF8
        $brokenArgs = @($common | ForEach-Object { if ($_ -eq $manifestPath) { $brokenPath } else { $_ } })
        $output = Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-NonInteractive','-AllowUntested') + $brokenArgs) 1
        Assert-True ($output -match $Expected) $Message
    }
    Test-BrokenManifest 'bad-archive-noexe.json' { param($m) $m.components.poptracker.PSObject.Properties.Remove('executable') } "no 'executable'" 'a managed-archive without an executable is rejected before any download'
    Test-BrokenManifest 'bad-archive-noinstall.json' { param($m) $m.components.poptracker.PSObject.Properties.Remove('installRelative') } "no 'installRelative'" 'a managed-archive without installRelative is rejected'
    Test-BrokenManifest 'bad-archive-escape.json' { param($m) $m.components.poptracker.installRelative = '..\..\escape' } 'unsafe installRelative' 'a managed-archive whose installRelative escapes the install root is rejected'
    Test-BrokenManifest 'bad-archive-rooted.json' { param($m) $m.components.poptracker.installRelative = 'C:\Windows' } 'unsafe installRelative' 'a managed-archive with an absolute installRelative is rejected'
    Test-BrokenManifest 'bad-archive-noversions.json' { param($m) $m.components.poptracker.versions = @() } 'has no versions' 'a managed component with no versions is rejected'
    Test-BrokenManifest 'bad-archive-badhash.json' { param($m) $m.components.poptracker.versions[0].sha256 = 'not-a-hash' } 'invalid sha256' 'a managed-archive version with a malformed sha256 is rejected'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'stack\PopTracker'))) 'no managed-archive files were written while validating broken manifests'

    # --- Multiplayer PKG is staged, never written into RPCS3 -----------------------------------
    function Get-TreeFingerprint([string]$Root) {
        @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($Root.Length) + '=' + (Get-Sha $_.FullName)
        }) -join '|'
    }
    $rpcs3Before = Get-TreeFingerprint $fakeRpcs3Dir
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-multiplayer','-NonInteractive') + $common) 1 | Out-Null
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'stack\downloads\BDUPS3-BORD00001_00-0000000000000000.pkg'))) 'the untested multiplayer PKG is refused without -AllowUntested'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','rac1-multiplayer','-NonInteractive','-AllowUntested') + $common) | Out-Null
    $pkgPath = Join-Path $InstallRoot 'stack\downloads\BDUPS3-BORD00001_00-0000000000000000.pkg'
    Assert-True ((Test-Path -LiteralPath $pkgPath) -and (Get-Sha $pkgPath) -eq $shaPkg) 'the multiplayer PKG lands verified under stack\downloads'
    Assert-True ((Get-TreeFingerprint $fakeRpcs3Dir) -eq $rpcs3Before) 'downloading the PKG leaves the RPCS3 folder byte-identical'
    $pkgState = (Read-State).stack.'rac1-multiplayer'
    Assert-True ($pkgState.version -eq '0.0.1-115' -and $pkgState.kind -eq 'managed-file') 'the staged PKG is recorded in setup-state.json'

    # --- The PKG row reflects RPCS3, then the staged download ----------------------------------
    $modFolder = Join-Path $fakeRpcs3Dir 'dev_hdd0\game\BORD00001'
    $modBackup = Join-Path $RunRoot 'mod-backup'
    Move-Item -LiteralPath $modFolder -Destination $modBackup
    $status = Invoke-Setup $installed (@('-Action','Status','-Json') + $common) | ConvertFrom-Json
    $pkgRow = Get-Row $status.stack 'rac1-multiplayer'
    Assert-True ($pkgRow.Status -eq 'downloaded' -and -not $pkgRow.Ready -and $pkgRow.Detail -match 'Install Packages') 'the PKG row reports the verified download and the manual RPCS3 step'
    Move-Item -LiteralPath $modBackup -Destination $modFolder
    $status = Invoke-Setup $installed (@('-Action','Status','-Json') + $common) | ConvertFrom-Json
    $pkgRow = Get-Row $status.stack 'rac1-multiplayer'
    Assert-True ($pkgRow.Status -eq 'present' -and $pkgRow.Ready) 'the PKG row flips to present once RPCS3 holds the title folder'

    # --- PopTracker managed portable copy ------------------------------------------------------
    $popRoot = Join-Path $InstallRoot 'stack\PopTracker'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-NonInteractive') + $common) 1 | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $popRoot)) 'an untested PopTracker release is refused without -AllowUntested'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-ComponentVersion','0.35.4','-NonInteractive','-AllowUntested') + $common) | Out-Null
    $popExe = Join-Path $popRoot 'poptracker.exe'
    Assert-True ((Test-Path -LiteralPath $popExe) -and (Get-Content -LiteralPath $popExe -Raw) -match '0\.35\.4') 'PopTracker is expanded into stack\PopTracker without its archive root folder'
    Assert-True (Test-Path -LiteralPath (Join-Path $popRoot 'portable.txt')) 'the portable marker is written beside poptracker.exe'
    Assert-True ((Test-Path -LiteralPath (Join-Path $popRoot 'assets\logo.txt')) -and (Test-Path -LiteralPath (Join-Path $popRoot 'packs\README.txt'))) 'nested archive folders survive expansion'
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'stack\downloads') -File | Where-Object { $_.Extension -eq '.zip' }).Count -eq 0) 'the downloaded archive is cleaned up after expansion'
    $popState = (Read-State).stack.poptracker
    Assert-True ($popState.version -eq '0.35.4' -and $popState.kind -eq 'managed-archive' -and -not $popState.adopted) 'the managed PopTracker copy is recorded as managed-archive'
    $status = Invoke-Setup $installed (@('-Action','Status','-Json') + $common) | ConvertFrom-Json
    $popRow = Get-Row $status.stack 'poptracker'
    Assert-True ($popRow.Status -eq 'managed' -and $popRow.Ready -and $popRow.Version -eq '0.35.4' -and $popRow.Optional) 'the poptracker row prefers the managed copy and stays optional'

    # --- Reinstalling the same version does nothing; upgrading keeps user packs ----------------
    $userPack = Join-Path $popRoot 'packs\my-rac-pack.json'
    Set-Content -LiteralPath $userPack -Value '{"pack":"mine"}' -Encoding ASCII
    $exeStamp = (Get-Item -LiteralPath $popExe).LastWriteTimeUtc
    Start-Sleep -Milliseconds 1100
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-ComponentVersion','0.35.4','-NonInteractive','-AllowUntested') + $common) | Out-Null
    Assert-True ((Get-Item -LiteralPath $popExe).LastWriteTimeUtc -eq $exeStamp) 'reinstalling the same PopTracker version rewrites nothing'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-ComponentVersion','0.36.0','-NonInteractive','-AllowUntested') + $common) 3 | Out-Null
    Assert-True ((Get-Content -LiteralPath $popExe -Raw) -match '0\.35\.4') 'upgrading over an existing managed copy needs -ReplaceExisting (exit 3)'
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-ComponentVersion','0.36.0','-NonInteractive','-AllowUntested','-ReplaceExisting') + $common) | Out-Null
    Assert-True ((Get-Content -LiteralPath $popExe -Raw) -match '0\.36\.0' -and (Test-Path -LiteralPath $userPack)) 'upgrading replaces the application files and keeps user packs'

    # --- A broken archive leaves the existing copy alone ---------------------------------------
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-ComponentVersion','0.37.0','-NonInteractive','-AllowUntested','-ReplaceExisting') + $common) 1 | Out-Null
    Assert-True ((Read-State).stack.poptracker.version -eq '0.36.0') 'an archive without the expected executable is refused and the record is unchanged'

    # --- A user-installed PopTracker is reported but never managed -----------------------------
    $userPopDir = Join-Path $RunRoot 'UserPopTracker'
    New-Item -ItemType Directory -Path $userPopDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $userPopDir 'poptracker.exe') -Value 'user copy' -Encoding ASCII

    # --- Lawrence is detected from a user-supplied path only -----------------------------------
    $fakeLawrence = Join-Path $RunRoot 'Lawrence\Lawrence.exe'
    New-Item -ItemType Directory -Path (Split-Path $fakeLawrence -Parent) -Force | Out-Null
    Set-Content -LiteralPath $fakeLawrence -Value 'fixture lawrence' -Encoding ASCII
    $status = Invoke-Setup $installed (@('-Action','Status','-Json','-LawrencePath',$fakeLawrence) + $common) | ConvertFrom-Json
    $lawrenceRow = Get-Row $status.stack 'lawrence'
    Assert-True ($lawrenceRow.Status -eq 'detected' -and $lawrenceRow.Optional -and $lawrenceRow.Detail -match 'Launch menu') 'a user-supplied Lawrence build is detected and stays optional'
    $status = Invoke-Setup $installed (@('-Action','Status','-Json') + $common) | ConvertFrom-Json
    Assert-True ((Get-Row $status.stack 'lawrence').Status -eq 'not running') 'Lawrence is never assumed present without a supplied path'

    # --- Launch is interactive only ------------------------------------------------------------
    Invoke-Setup $installed (@('-Action','Launch','-NonInteractive') + $common) 1 | Out-Null
    Assert-True $true 'Launch refuses to run under -NonInteractive'

    # --- Opt-in RPCS3 network fix --------------------------------------------------------------
    $configPath = Join-Path $fakeRpcs3Dir 'config\config.yml'
    $configBefore = @(Get-Content -LiteralPath $configPath)
    $configShaBefore = Get-Sha $configPath
    Invoke-Setup $installed (@('-Action','ConfigureRpcs3Network','-NonInteractive') + $common) | Out-Null
    $configAfter = @(Get-Content -LiteralPath $configPath)
    $changed = @(0..($configBefore.Count - 1) | Where-Object { $configBefore[$_] -ne $configAfter[$_] })
    Assert-True ($configBefore.Count -eq $configAfter.Count -and $changed.Count -eq 1 -and $configAfter[$changed[0]] -match 'Internet enabled:\s*Connected$') 'ConfigureRpcs3Network changes only the Internet enabled line'
    Assert-True (($configAfter -join "`n") -match 'PSN status:\s*Disconnected') 'PSN status is left untouched'
    $backup = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'stack\rollback') -File -Filter 'rpcs3-config.yml.*')
    Assert-True ($backup.Count -eq 1 -and (Get-Sha $backup[0].FullName) -eq $configShaBefore) 'the config backup is written and matches the original bytes'
    $status = Invoke-Setup $installed (@('-Action','Status','-Json') + $common) | ConvertFrom-Json
    Assert-True ((Get-Row $status.stack 'rpcs3-network').Ready) 'the network row reports Connected after the fix'
    Invoke-Setup $installed (@('-Action','ConfigureRpcs3Network','-NonInteractive') + $common) | Out-Null
    Assert-True ((Get-Sha $configPath) -ne $configShaBefore) 'rerunning the network fix when already Connected changes nothing'

    # --- Rollback restores the original configuration bytes ------------------------------------
    Invoke-Setup $installed (@('-Action','StackRollback','-Component','rpcs3-network') + $common) | Out-Null
    Assert-True ((Get-Sha $configPath) -eq $configShaBefore) 'StackRollback restores the original config.yml bytes'

    # --- The fix refuses to run while RPCS3 is running -----------------------------------------
    $fakeProcDir = Join-Path $RunRoot 'fakeproc'
    New-Item -ItemType Directory -Path $fakeProcDir -Force | Out-Null
    $fakeProcExe = Join-Path $fakeProcDir 'rpcs3.exe'
    Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\cmd.exe') -Destination $fakeProcExe
    $runningShaBefore = Get-Sha $configPath
    $fakeProcess = Start-Process -FilePath $fakeProcExe -ArgumentList '/c','ping -n 30 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
    try {
        Invoke-Setup $installed (@('-Action','ConfigureRpcs3Network','-NonInteractive') + $common) 1 | Out-Null
        Assert-True ((Get-Sha $configPath) -eq $runningShaBefore) 'ConfigureRpcs3Network refuses while a process named rpcs3 is running'
    } finally {
        Stop-Process -Id $fakeProcess.Id -Force -ErrorAction SilentlyContinue
        $fakeProcess.WaitForExit(10000) | Out-Null
    }

    # --- Uninstall keeps tracker content unless -RemoveTrackerData -----------------------------
    Invoke-Setup $installed (@('-Action','Uninstall','-NonInteractive') + $common) | Out-Null
    Assert-True ((Test-Path -LiteralPath $userPack) -and -not (Test-Path -LiteralPath $popExe)) 'uninstall removes the PopTracker application files and keeps the packs folder'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $InstallRoot 'current')) -and -not (Test-Path -LiteralPath (Join-Path $InstallRoot 'setup-state.json'))) 'uninstall still removes everything the tool owns'
    Invoke-Setup $setup (@('-Action','Install','-Games','RAC1','-SkipPrerequisiteChecks','-NonInteractive') + $common) | Out-Null
    Invoke-Setup $installed (@('-Action','InstallStackComponent','-Component','poptracker','-ComponentVersion','0.35.4','-NonInteractive','-AllowUntested','-ReplaceExisting') + $common) | Out-Null
    Assert-True (Test-Path -LiteralPath $userPack) 'reinstalling PopTracker over kept packs preserves them'
    Invoke-Setup $installed (@('-Action','Uninstall','-NonInteractive','-RemoveTrackerData') + $common) | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $popRoot) -and -not (Test-Path -LiteralPath $InstallRoot)) '-RemoveTrackerData removes the packs folder and the install root'
}
finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($TestHiveRelative, $false)
    if (-not $KeepArtifacts -and [IO.Directory]::Exists($RunRoot)) { [IO.Directory]::Delete($RunRoot, $true) }
}

if ($Failures.Count -gt 0) {
    Write-Host "`n$($Failures.Count) stack test(s) failed." -ForegroundColor Red
    $Failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}
Write-Host "`nAll stack tests passed." -ForegroundColor Green

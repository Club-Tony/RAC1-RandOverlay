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
$RegistryRelative = "Software\RandOverlayInstallerTests\$([guid]::NewGuid().ToString('N'))\ImplicitLayers"
$RegistryPath = "HKCU:\$RegistryRelative"
$Failures = [System.Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot 'TestCommon.ps1')

New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
try {
    $setupSource = Get-Content -LiteralPath (Join-Path $VulkanRoot 'installer\Setup-RandOverlay.ps1') -Raw
    Assert-True ($setupSource -match '(?s)\$cursorWasVisible\s*=\s*\[Console\]::CursorVisible.*\[Console\]::CursorVisible\s*=\s*\$false.*finally\s*\{\s*\[Console\]::CursorVisible\s*=\s*\$cursorWasVisible') 'interactive checklist hides and restores the console cursor'
    Assert-True ($setupSource -match 'CouldNotAutoloadMatchingModule' -and $setupSource -match 'exact SHA-256 payload verification passed') 'setup has a hash-verified fallback when Authenticode tooling is unavailable'

    $layerDll = Join-Path $VulkanRoot 'build\RandOverlay_layer.dll'
    if (-not (Test-Path -LiteralPath $layerDll)) {
        $layerDll = Join-Path $RunRoot 'RandOverlay_layer.fixture.dll'
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\version.dll') -Destination $layerDll
    }
    & (Join-Path $VulkanRoot 'installer\Build-RandOverlayRelease.ps1') -Format Bat,Zip,Exe -LayerDll $layerDll -OutputRoot (Join-Path $RunRoot 'dist')
    $zip = Get-ChildItem -LiteralPath (Join-Path $RunRoot 'dist') -Filter 'RandOverlay-Vulkan-*.zip' | Select-Object -First 1
    $selfExtractingBat = Get-ChildItem -LiteralPath (Join-Path $RunRoot 'dist') -Filter 'RandOverlay-Setup-*.bat' | Select-Object -First 1
    $exe = Get-ChildItem -LiteralPath (Join-Path $RunRoot 'dist') -Filter 'RandOverlay-Setup-*.exe' | Select-Object -First 1
    Assert-True ([bool]$zip) 'release ZIP built'
    Assert-True ([bool]$selfExtractingBat) 'primary self-contained BAT built'
    Assert-True ([bool]$exe) 'optional EXE bootstrapper built'
    $env:RANDOVERLAY_BUNDLE_NOLAUNCH = '1'
    try { $bundleOutput = & cmd.exe /d /c $selfExtractingBat.FullName 2>&1 | Out-String; $bundleExit = $LASTEXITCODE }
    finally { Remove-Item Env:RANDOVERLAY_BUNDLE_NOLAUNCH -ErrorAction SilentlyContinue }
    $bundlePassed = $bundleExit -eq 0 -and $bundleOutput -match 'Embedded ZIP verified' -and $bundleOutput -match 'decode/extract verification passed'
    if (-not $bundlePassed) {
        Write-Host "Self-contained BAT exit: $bundleExit" -ForegroundColor Yellow
        Write-Host $bundleOutput
    }
    Assert-True $bundlePassed 'self-contained BAT verifies and extracts embedded ZIP'
    & (Join-Path $VulkanRoot 'installer\Build-RandOverlayRelease.ps1') -Format Zip -LayerDll $layerDll -OutputRoot (Join-Path $RunRoot 'dist-second') | Out-Null
    $secondZip = Get-ChildItem -LiteralPath (Join-Path $RunRoot 'dist-second') -Filter 'RandOverlay-Vulkan-*.zip' | Select-Object -First 1
    Assert-True ((Get-FileHash $zip.FullName -Algorithm SHA256).Hash -eq (Get-FileHash $secondZip.FullName -Algorithm SHA256).Hash) 'release ZIP rebuild is deterministic'
    $expanded = Join-Path $RunRoot 'expanded'
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
    $releaseRoot = Get-ChildItem -LiteralPath $expanded -Directory | Select-Object -First 1
    $setup = Join-Path $releaseRoot.FullName 'Setup-RandOverlay.ps1'
    $batchSetup = Join-Path $releaseRoot.FullName 'Install-RandOverlay.bat'
    Assert-True (Test-Path -LiteralPath $setup) 'release contains setup entrypoint'
    Assert-True (Test-Path -LiteralPath $batchSetup) 'release contains double-click batch entrypoint'

    $fakeArch = Join-Path $RunRoot 'Archipelago'
    New-Item -ItemType Directory -Path (Join-Path $fakeArch 'custom_worlds') -Force | Out-Null
    foreach ($name in @('ArchipelagoLauncher.exe','custom_worlds\RAC1.apworld','custom_worlds\rac2.apworld','custom_worlds\rac3.apworld')) {
        [IO.File]::WriteAllText((Join-Path $fakeArch $name), '')
    }
    $fakeRpcs3 = Join-Path $RunRoot 'rpcs3.exe'
    $fakePcsx2 = Join-Path $RunRoot 'pcsx2-qt.exe'
    $fakeVulkan = Join-Path $RunRoot 'vulkan-1.dll'
    [IO.File]::WriteAllText($fakeRpcs3, '')
    [IO.File]::WriteAllText($fakePcsx2, '')
    [IO.File]::WriteAllText($fakeVulkan, '')

    $interactiveRoot = Join-Path $RunRoot 'InteractiveLocalAppData\RandOverlay'
    $interactive = Invoke-InteractiveSetup $setup @('-InstallRoot',$interactiveRoot,'-RegistryPath',$RegistryPath,'-SkipPrerequisiteChecks') "1,2,3`r`n"
    $interactivePassed = $interactive.ExitCode -eq 0 -and $interactive.Output -notmatch 'Initial active game'
    if (-not $interactivePassed) {
        Write-Host "Interactive setup exit: $($interactive.ExitCode)" -ForegroundColor Yellow
        Write-Host $interactive.Output
    }
    Assert-True $interactivePassed 'multi-game Enter flow installs without an active-game prompt or blank validation failure'
    $interactiveStatePath = Join-Path $interactiveRoot 'setup-state.json'
    if (-not (Test-Path -LiteralPath $interactiveStatePath)) {
        throw "Interactive setup did not create setup-state.json.`n$($interactive.Output)"
    }
    $interactiveState = Get-Content -LiteralPath $interactiveStatePath -Raw | ConvertFrom-Json
    Assert-True (@($interactiveState.enabledGames).Count -eq 3 -and $interactiveState.activeGame -eq 'RAC1') 'interactive multi-game install records all games with RAC1 fallback'
    Assert-True ([bool](Select-String -LiteralPath (Join-Path $interactiveRoot 'RandOverlay.ini') -Pattern '^EnabledPresets=RAC1,RAC2,RAC3$')) 'interactive install writes the automatic-detection enabled set'
    Invoke-Setup (Join-Path $interactiveRoot 'Setup-RandOverlay.ps1') @('-Action','Uninstall','-InstallRoot',$interactiveRoot,'-RegistryPath',$RegistryPath,'-NonInteractive') | Out-Null

    $preflightArgs = @('-Action','Preflight','-Games','RAC1','-ArchipelagoRoot',$fakeArch,'-RPCS3Path',$fakeRpcs3,'-VulkanLoaderPath',$fakeVulkan,'-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-Json')
    $preflightJson = Invoke-Setup $setup $preflightArgs
    $preflight = $preflightJson | ConvertFrom-Json
    Assert-True (@($preflight.games).Count -eq 1 -and @($preflight.games)[0] -eq 'RAC1') 'RAC1 is the single-game default contract'
    Assert-True (@($preflight.prerequisites | Where-Object id -eq 'rpcs3').Count -eq 1) 'RAC1 requires RPCS3'
    Assert-True (@($preflight.prerequisites | Where-Object id -eq 'pcsx2').Count -eq 0) 'RAC1 does not require PCSX2'
    $batchOutput = & cmd.exe /d /c $batchSetup @preflightArgs 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $batchOutput -match '"games"') 'batch entrypoint launches setup and forwards arguments'
    $exeOutput = & $exe.FullName @preflightArgs 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0 -and $exeOutput -match '"games"') 'EXE bootstrapper extracts and launches setup'
    Assert-True (-not (Test-Path -LiteralPath $InstallRoot)) 'preflight does not create the install root'

    $probe = Join-Path $RunRoot 'loadonly-probe.ps1'
    $loadRoot = Join-Path $RunRoot 'LoadOnlyLocalAppData\RandOverlay'
    @'
param([string]$Setup, [string]$Root, [string]$Registry)
. $Setup -LoadOnly -InstallRoot $Root -RegistryPath $Registry
"FUNCTIONS=$([bool](Get-Command Get-PrerequisiteStatus -ErrorAction SilentlyContinue))"
"CMP=$(Compare-ReleaseVersion '0.2.0-rc1' '0.1.0'),$(Compare-ReleaseVersion '0.2.0-rc1' '0.2.0'),$(Compare-ReleaseVersion 'v0.2.1-beta' '0.2.1-alpha'),$(Compare-ReleaseVersion '0.0.42-19909-677e13da' '0.0.42-19908-abcdef00'),$(Compare-ReleaseVersion '0.1.0' '0.1.0')"
'@ | Set-Content -LiteralPath $probe -Encoding ASCII
    $probeOutput = Invoke-Setup $probe @('-Setup',$setup,'-Root',$loadRoot,'-Registry',$RegistryPath)
    Assert-True ($probeOutput -match 'FUNCTIONS=True' -and -not (Test-Path -LiteralPath $loadRoot)) 'LoadOnly exposes engine functions without running an action'
    Assert-True ($probeOutput -match 'CMP=1,-1,1,1,0') 'release version comparison handles prerelease and rolling-build tags'

    $pendingRoot = Join-Path $RunRoot 'PendingLocalAppData\RandOverlay'
    $emptyArch = Join-Path $RunRoot 'EmptyArchipelago'
    New-Item -ItemType Directory -Path $emptyArch -Force | Out-Null
    Invoke-Setup $setup @('-Action','Install','-Games','RAC1','-InstallRoot',$pendingRoot,'-RegistryPath',$RegistryPath,'-ArchipelagoRoot',$emptyArch,'-RPCS3Path',$fakeRpcs3,'-VulkanLoaderPath',$fakeVulkan,'-NonInteractive') 2 | Out-Null
    $pendingState = Get-Content -LiteralPath (Join-Path $pendingRoot 'setup-state.json') -Raw | ConvertFrom-Json
    Assert-True ($pendingState.status -eq 'pending-prerequisites' -and @(Get-RegistryNames).Count -eq 0) 'non-interactive install with missing prerequisites exits 2 and registers nothing'
    Invoke-Setup (Join-Path $pendingRoot 'Setup-RandOverlay.ps1') @('-Action','Uninstall','-InstallRoot',$pendingRoot,'-RegistryPath',$RegistryPath,'-NonInteractive') | Out-Null

    Invoke-Setup $setup @('-Action','Install','-Games','RAC1','-ActiveGame','RAC1','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-ArchipelagoRoot',$fakeArch,'-RPCS3Path',$fakeRpcs3,'-SkipPrerequisiteChecks','-NonInteractive') | Out-Null
    $state = Get-Content -LiteralPath (Join-Path $InstallRoot 'setup-state.json') -Raw | ConvertFrom-Json
    Assert-True ($state.status -eq 'installed' -and $state.activeGame -eq 'RAC1') 'fresh RAC1 install completes'
    Assert-True ($state.dependencyPaths.archipelagoRoot -eq $fakeArch -and $state.dependencyPaths.rpcs3Path -eq $fakeRpcs3) 'portable dependency paths persist for repair'
    Assert-True (Test-Path -LiteralPath (Join-Path $InstallRoot 'current\RandOverlay_layer.dll')) 'layer DLL installed'
    Assert-True (@(Get-RegistryNames).Count -eq 1) 'one canonical Vulkan registration created'
    Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Configure','-Games','RAC1,RAC2','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-ArchipelagoRoot',$emptyArch,'-RPCS3Path',$fakeRpcs3,'-PCSX2Path',$fakePcsx2,'-VulkanLoaderPath',$fakeVulkan) 2 | Out-Null
    $unchanged = Get-Content -LiteralPath (Join-Path $InstallRoot 'setup-state.json') -Raw | ConvertFrom-Json
    Assert-True (@($unchanged.enabledGames).Count -eq 1) 'configure with missing prerequisites exits 2 and leaves the selection unchanged'
    $logFiles = @(Get-ChildItem -LiteralPath (Join-Path $InstallRoot 'logs') -Filter 'setup-*.log' -File)
    $logText = ($logFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    Assert-True ($logFiles.Count -ge 1 -and $logText -match 'Action=Install' -and $logText -match 'Exit code 2') 'setup writes a local log under the install root'
    Assert-True (-not ($logText -match [regex]::Escape($env:USERPROFILE))) 'setup log redacts the user profile path'

    $unrelated = Join-Path $RunRoot 'unrelated\OtherLayer.json'
    $stale = Join-Path $RunRoot 'stale\RandOverlay_layer.json'
    Write-Manifest $unrelated 'VK_LAYER_SOMEONE_ELSE'
    Write-Manifest $stale 'VK_LAYER_RANDOVERLAY_overlay'
    New-ItemProperty -Path $RegistryPath -Name $unrelated -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $RegistryPath -Name $stale -PropertyType DWord -Value 0 -Force | Out-Null
    Invoke-Setup $setup @('-Action','Install','-Games','RAC1','-ActiveGame','RAC1','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-SkipPrerequisiteChecks','-NonInteractive') | Out-Null
    $registryNames = @(Get-RegistryNames)
    Assert-True ($registryNames -contains $unrelated) 'unrelated Vulkan registration preserved'
    Assert-True ($registryNames -notcontains $stale) 'stale owned registration removed'
    Assert-True (@($registryNames | Where-Object { $_ -like '*RandOverlay_layer.json' }).Count -eq 1) 'idempotent rerun keeps one RandOverlay registration'

    Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Configure','-Games','RAC1,RAC2,RAC3','-ActiveGame','RAC3','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-SkipPrerequisiteChecks','-NonInteractive') | Out-Null
    $state = Get-Content -LiteralPath (Join-Path $InstallRoot 'setup-state.json') -Raw | ConvertFrom-Json
    Assert-True (@($state.enabledGames).Count -eq 3 -and $state.activeGame -eq 'RAC3') 'multi-game selection and active preset persist'
    Assert-True ([bool](Select-String -LiteralPath (Join-Path $InstallRoot 'RandOverlay.ini') -Pattern '^ActivePreset=RAC3$')) 'configuration active preset updated'
    Assert-True ([bool](Select-String -LiteralPath (Join-Path $InstallRoot 'RandOverlay.ini') -Pattern '^EnabledPresets=RAC1,RAC2,RAC3$')) 'configuration persists automatic-detection enabled presets'

    $status = Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Status','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-Json') | ConvertFrom-Json
    Assert-True $status.healthy 'installed status is healthy'
    [IO.File]::AppendAllText((Join-Path $InstallRoot 'current\RandOverlay_layer.dll'), 'tamper')
    $tampered = Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Status','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-Json') | ConvertFrom-Json
    Assert-True (-not $tampered.healthy) 'tampered installed DLL is detected'
    Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Repair','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-SkipPrerequisiteChecks','-NonInteractive') | Out-Null
    $repaired = Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Status','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-Json') | ConvertFrom-Json
    Assert-True $repaired.healthy 'repair restores verified payload'
    Assert-True (Test-Path -LiteralPath (Join-Path $InstallRoot 'rollback\previous\RandOverlay_layer.dll')) 'one rollback payload retained'

    $tamperRoot = Join-Path $RunRoot 'tampered-release'
    Copy-Item -LiteralPath $releaseRoot.FullName -Destination $tamperRoot -Recurse
    [IO.File]::AppendAllText((Join-Path $tamperRoot 'payload\RandOverlay_layer.dll'), 'tamper')
    Invoke-Setup (Join-Path $tamperRoot 'Setup-RandOverlay.ps1') @('-Action','Install','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-SkipPrerequisiteChecks','-NonInteractive') 1 | Out-Null
    Assert-True ((Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Status','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-Json') | ConvertFrom-Json).healthy) 'tampered update cannot damage healthy install'

    (Get-Content -LiteralPath (Join-Path $InstallRoot 'RandOverlay.ini') -Raw) -replace 'DisplayMs=5000','DisplayMs=7777' |
        Set-Content -LiteralPath (Join-Path $InstallRoot 'RandOverlay.ini') -Encoding ASCII
    Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Uninstall','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-KeepConfig','-NonInteractive') | Out-Null
    Assert-True (Test-Path -LiteralPath (Join-Path $InstallRoot 'RandOverlay.ini')) 'uninstall can preserve configuration'
    Assert-True ((Get-RegistryNames) -contains $unrelated) 'uninstall preserves unrelated Vulkan layer'

    Invoke-Setup $setup @('-Action','Install','-Games','RAC1','-ActiveGame','RAC1','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-SkipPrerequisiteChecks','-NonInteractive') | Out-Null
    Assert-True ([bool](Select-String -LiteralPath (Join-Path $InstallRoot 'RandOverlay.ini') -Pattern '^DisplayMs=7777$')) 'reinstall preserves customized configuration'
    Invoke-Setup (Join-Path $InstallRoot 'Setup-RandOverlay.ps1') @('-Action','Uninstall','-InstallRoot',$InstallRoot,'-RegistryPath',$RegistryPath,'-NonInteractive') | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $InstallRoot)) 'complete uninstall removes owned install root'
    Assert-True ((Get-RegistryNames) -contains $unrelated) 'complete uninstall still preserves unrelated registration'
}
finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($RegistryRelative, $false)
    if (-not $KeepArtifacts -and [IO.Directory]::Exists($RunRoot)) { [IO.Directory]::Delete($RunRoot, $true) }
}

if ($Failures.Count -gt 0) {
    Write-Host "`n$($Failures.Count) installer test(s) failed." -ForegroundColor Red
    $Failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}
Write-Host "`nAll installer tests passed." -ForegroundColor Green

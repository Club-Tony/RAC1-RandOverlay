[CmdletBinding()]
param(
    [ValidateSet('Interactive','Install','Status','Repair','Configure','CheckForUpdates','Uninstall','Preflight')]
    [string]$Action = 'Interactive',
    [string[]]$Games,
    [ValidateSet('RAC1','RAC2','RAC3')][string]$ActiveGame,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RandOverlay'),
    [string]$PayloadRoot,
    [string]$RegistryPath = 'HKCU:\SOFTWARE\Khronos\Vulkan\ImplicitLayers',
    [string]$ArchipelagoRoot,
    [string]$RPCS3Path,
    [string]$PCSX2Path,
    [string]$VulkanLoaderPath,
    [switch]$SkipPrerequisiteChecks,
    [switch]$NonInteractive,
    [switch]$Json,
    [switch]$ConfirmUpdate,
    [switch]$KeepConfig
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

try { [Console]::Title = 'RAC RandOverlay Setup' } catch { }

$script:LayerName = 'VK_LAYER_RANDOVERLAY_overlay'
$script:RepoApi = 'https://api.github.com/repos/Club-Tony/RAC1-RandOverlay'
$script:GameCatalog = [ordered]@{
    RAC1 = [pscustomobject]@{ Name='Ratchet & Clank 1'; Emulator='RPCS3'; Client='Ratchet & Clank Client'; Apworld='RAC1.apworld'; Url='https://rpcs3.net/download' }
    RAC2 = [pscustomobject]@{ Name='Ratchet & Clank 2'; Emulator='PCSX2'; Client='Ratchet & Clank 2 Client'; Apworld='rac2.apworld'; Url='https://pcsx2.net/downloads/' }
    RAC3 = [pscustomobject]@{ Name='Ratchet & Clank 3'; Emulator='PCSX2'; Client='Ratchet and Clank 3 Client'; Apworld='rac3.apworld'; Url='https://pcsx2.net/downloads/' }
}

function Write-Step([string]$Message) { Write-Host "`n== $Message ==" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[MISSING] $Message" -ForegroundColor Red }

function Get-FullPath([string]$Path) {
    [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Assert-SafeRoot([string]$Path) {
    $full = Get-FullPath $Path
    $driveRoot = [IO.Path]::GetPathRoot($full)
    if ($full -eq $driveRoot -or $full.Length -lt ($driveRoot.Length + 8) -or $full -match '[*?]') {
        throw "Unsafe root: $full"
    }
    $full.TrimEnd('\')
}

function Assert-ChildPath([string]$Parent, [string]$Child) {
    $parentFull = (Get-FullPath $Parent).TrimEnd('\') + '\'
    $childFull = Get-FullPath $Child
    if (-not $childFull.StartsWith($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing operation outside allowed root: $childFull"
    }
    $childFull
}

function Remove-ExactOwnedPath([string]$Parent, [string]$Path) {
    $safe = Assert-ChildPath $Parent $Path
    if ([IO.Directory]::Exists($safe)) { [IO.Directory]::Delete($safe, $true) }
    elseif ([IO.File]::Exists($safe)) { [IO.File]::Delete($safe) }
}

$InstallRoot = Assert-SafeRoot $InstallRoot
$script:StatePath = Join-Path $InstallRoot 'setup-state.json'
$script:ConfigPath = Join-Path $InstallRoot 'RandOverlay.ini'
$script:InstalledSetupPath = Join-Path $InstallRoot 'Setup-RandOverlay.ps1'
$script:CurrentRoot = Join-Path $InstallRoot 'current'
$script:CachedPayloadRoot = Join-Path $InstallRoot 'package\payload'
$script:RollbackRoot = Join-Path $InstallRoot 'rollback\previous'

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Write-JsonFile([string]$Path, $Value) {
    $parent = Split-Path $Path -Parent
    if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = "$Path.tmp"
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-State { Read-JsonFile $script:StatePath }

function Get-OptionalProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    $null
}

function Get-DependencyPaths {
    $state = Get-State
    $saved = Get-OptionalProperty $state 'dependencyPaths'
    $savedArch = Get-OptionalProperty $saved 'archipelagoRoot'
    $savedRpcs3 = Get-OptionalProperty $saved 'rpcs3Path'
    $savedPcsx2 = Get-OptionalProperty $saved 'pcsx2Path'
    [ordered]@{
        archipelagoRoot = if ($ArchipelagoRoot) { $ArchipelagoRoot } elseif ($savedArch) { $savedArch } else { 'C:\ProgramData\Archipelago' }
        rpcs3Path = if ($RPCS3Path) { $RPCS3Path } else { $savedRpcs3 }
        pcsx2Path = if ($PCSX2Path) { $PCSX2Path } else { $savedPcsx2 }
    }
}

function Save-DependencyPathsToState {
    $state = Get-State
    if (-not $state) { return }
    $state | Add-Member -NotePropertyName dependencyPaths -NotePropertyValue ([pscustomobject](Get-DependencyPaths)) -Force
    $state.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonFile $script:StatePath $state
}

function Normalize-Games([string[]]$Selected) {
    if (-not $Selected -or $Selected.Count -eq 0) { return ,@('RAC1') }
    $normalized = @($Selected | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpperInvariant() } |
        Where-Object { $script:GameCatalog.Contains($_) } | Select-Object -Unique)
    if ($normalized.Count -eq 0) { throw 'At least one game must be selected.' }
    return ,$normalized
}

function Get-FileSha256([string]$Path) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $hasher.Dispose() }
}

function Resolve-PayloadRoot {
    if ($PayloadRoot) { return Get-FullPath $PayloadRoot }
    $besideSetup = Join-Path $PSScriptRoot 'payload'
    if (Test-Path -LiteralPath $besideSetup) { return Get-FullPath $besideSetup }
    if (Test-Path -LiteralPath $script:CachedPayloadRoot) { return Get-FullPath $script:CachedPayloadRoot }
    throw 'No release payload found. Run Setup from a release package or provide -PayloadRoot.'
}

function Test-Payload([string]$Root) {
    $metadata = Read-JsonFile (Join-Path $Root 'release.json')
    if (-not $metadata) { throw 'Payload release.json is missing.' }
    foreach ($file in @($metadata.files)) {
        $path = Join-Path $Root ([string]$file.path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Payload file missing: $($file.path)" }
        if ((Get-FileSha256 $path) -ne ([string]$file.sha256).ToUpperInvariant()) { throw "Payload hash mismatch: $($file.path)" }
    }
    $layerDll = Join-Path $Root 'RandOverlay_layer.dll'
    $signature = $null
    $signatureUnavailable = $false
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $layerDll -ErrorAction Stop
    } catch {
        $signatureUnavailable =
            $_.Exception -is [System.Management.Automation.CommandNotFoundException] -or
            ([string]$_.FullyQualifiedErrorId) -match 'CommandNotFound|CouldNotAutoloadMatchingModule'
        if (-not $signatureUnavailable) { throw }
        Write-Warn 'Authenticode inspection is unavailable; exact SHA-256 payload verification passed.'
    }
    if (-not $signatureUnavailable -and -not $signature) {
        throw 'Authenticode inspection returned no result.'
    }
    if ($signature -and $signature.Status -notin @('Valid','NotSigned')) {
        throw "Layer DLL has an invalid Authenticode status: $($signature.Status)"
    }
    $metadata
}

function Copy-DirectoryContents([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function Find-Executable([string[]]$Names, [string[]]$Candidates) {
    foreach ($candidate in @($Candidates)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return Get-FullPath $candidate }
    }
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
        $process = Get-Process ([IO.Path]::GetFileNameWithoutExtension($name)) -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($process -and $process.Path) { return $process.Path }
    }
    $null
}

function Test-WinGetPackage([string]$Id) {
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { return $false }
    $output = & winget.exe list --id $Id --exact --accept-source-agreements 2>$null | Out-String
    ($LASTEXITCODE -eq 0 -and $output -match [regex]::Escape($Id))
}

function Get-PrerequisiteStatus([string[]]$SelectedGames) {
    $results = [System.Collections.Generic.List[object]]::new()
    $dependencyPaths = Get-DependencyPaths
    $results.Add([pscustomobject]@{ Id='windows-x64'; Name='64-bit Windows'; Required=$true; Ready=[Environment]::Is64BitOperatingSystem; Detail=[Environment]::OSVersion.VersionString; Url='https://support.microsoft.com/windows'; AutoInstall=$null })
    $vulkanLoader = if ($VulkanLoaderPath) { $VulkanLoaderPath } else { Join-Path $env:WINDIR 'System32\vulkan-1.dll' }
    $results.Add([pscustomobject]@{ Id='vulkan'; Name='Vulkan GPU driver/runtime'; Required=$true; Ready=(Test-Path -LiteralPath $vulkanLoader); Detail=$vulkanLoader; Url='https://www.khronos.org/vulkan/'; AutoInstall=$null })
    $launcher = Join-Path $dependencyPaths.archipelagoRoot 'ArchipelagoLauncher.exe'
    $results.Add([pscustomobject]@{ Id='archipelago'; Name='Archipelago Launcher'; Required=$true; Ready=(Test-Path -LiteralPath $launcher); Detail=$launcher; Url='https://github.com/ArchipelagoMW/Archipelago/releases'; AutoInstall=$null })

    foreach ($game in $SelectedGames) {
        $entry = $script:GameCatalog[$game]
        $apworld = Join-Path $dependencyPaths.archipelagoRoot (Join-Path 'custom_worlds' $entry.Apworld)
        $results.Add([pscustomobject]@{ Id="client-$($game.ToLowerInvariant())"; Name="$game Archipelago client"; Required=$true; Ready=(Test-Path -LiteralPath $apworld); Detail=$apworld; Url='https://archipelago.gg/tutorial/'; AutoInstall=$null })
    }

    if ($SelectedGames -contains 'RAC1') {
        $rpcs3 = Find-Executable @('rpcs3.exe') @($dependencyPaths.rpcs3Path,(Join-Path $env:LOCALAPPDATA 'Programs\RPCS3\rpcs3.exe'),(Join-Path $env:ProgramFiles 'RPCS3\rpcs3.exe'))
        $results.Add([pscustomobject]@{ Id='rpcs3'; Name='RPCS3 (selected by RAC1)'; Required=$true; Ready=[bool]$rpcs3; Detail=$(if($rpcs3){$rpcs3}else{'Not found in known locations'}); Url='https://rpcs3.net/download'; AutoInstall=$null })
    }
    if (($SelectedGames -contains 'RAC2') -or ($SelectedGames -contains 'RAC3')) {
        $pcsx2 = Find-Executable @('pcsx2-qt.exe','pcsx2.exe') @($dependencyPaths.pcsx2Path,(Join-Path $env:LOCALAPPDATA 'Programs\PCSX2\pcsx2-qt.exe'),(Join-Path $env:ProgramFiles 'PCSX2\pcsx2-qt.exe'))
        if (-not $pcsx2 -and (Test-WinGetPackage 'PCSX2Team.PCSX2')) { $pcsx2 = 'Installed: PCSX2Team.PCSX2' }
        $results.Add([pscustomobject]@{ Id='pcsx2'; Name='PCSX2 (selected by RAC2/RAC3)'; Required=$true; Ready=[bool]$pcsx2; Detail=$(if($pcsx2){$pcsx2}else{'Not found in known locations'}); Url='https://pcsx2.net/downloads/'; AutoInstall='PCSX2Team.PCSX2' })
    }
    @($results)
}

function Write-Hyperlink([string]$Label, [string]$Url) {
    $esc = [char]27
    if ($Host.UI.SupportsVirtualTerminal) { Write-Host "$esc]8;;$Url$esc\$Label$esc]8;;$esc\ ($Url)" }
    else { Write-Host "${Label}: $Url" }
}

function Show-Prerequisites([object[]]$Results) {
    foreach ($item in $Results) {
        if ($item.Ready) { Write-Ok "$($item.Name) - $($item.Detail)" }
        else { Write-Fail "$($item.Name) - $($item.Detail)"; Write-Hyperlink 'Official download/help' $item.Url }
    }
}

function Resolve-PrerequisitesInteractive([string[]]$SelectedGames) {
    while ($true) {
        $results = Get-PrerequisiteStatus $SelectedGames
        Show-Prerequisites $results
        $missing = @($results | Where-Object { $_.Required -and -not $_.Ready })
        if ($missing.Count -eq 0) { return $true }
        Write-Host "`n[R] Recheck  [O] Open official page  [P] Set custom path  [I] Install PCSX2 with WinGet  [S] Save and exit"
        switch ((Read-Host 'Selection').Trim().ToUpperInvariant()) {
            'R' { continue }
            'O' {
                for ($i=0; $i -lt $missing.Count; $i++) { Write-Host "[$($i+1)] $($missing[$i].Name)" }
                $number = 0
                if ([int]::TryParse((Read-Host 'Dependency number'), [ref]$number) -and $number -ge 1 -and $number -le $missing.Count) { Start-Process $missing[$number-1].Url }
            }
            'I' {
                $pcsx2 = $missing | Where-Object { $_.AutoInstall -eq 'PCSX2Team.PCSX2' } | Select-Object -First 1
                if (-not $pcsx2) { Write-Warn 'No missing allowlisted dependency supports automatic installation.'; continue }
                if ((Read-Host 'Install PCSX2 from WinGet? [y/N]') -match '^(?i)y(es)?$') {
                    & winget.exe install --id PCSX2Team.PCSX2 --exact --accept-source-agreements --accept-package-agreements
                    if ($LASTEXITCODE -ne 0) { Write-Warn "WinGet exited $LASTEXITCODE." }
                }
            }
            'P' {
                $pathItems = @($missing | Where-Object { $_.Id -in @('archipelago','rpcs3','pcsx2') })
                if ($pathItems.Count -eq 0) { Write-Warn 'No missing dependency accepts a custom path.'; continue }
                for ($i=0; $i -lt $pathItems.Count; $i++) { Write-Host "[$($i+1)] $($pathItems[$i].Name)" }
                $number = 0
                if ([int]::TryParse((Read-Host 'Dependency number'), [ref]$number) -and $number -ge 1 -and $number -le $pathItems.Count) {
                    $entered = (Read-Host 'Exact executable or Archipelago folder path').Trim('"')
                    $item = $pathItems[$number-1]
                    if ($item.Id -eq 'archipelago') {
                        if ([IO.Path]::GetFileName($entered) -ieq 'ArchipelagoLauncher.exe') { $entered = Split-Path $entered -Parent }
                        $script:ArchipelagoRoot = $entered
                    } elseif ($item.Id -eq 'rpcs3') { $script:RPCS3Path = $entered }
                    elseif ($item.Id -eq 'pcsx2') { $script:PCSX2Path = $entered }
                    Save-DependencyPathsToState
                }
            }
            'S' { Save-DependencyPathsToState; return $false }
            default { Write-Warn 'Unknown selection.' }
        }
    }
}

function Test-EmulatorsStopped {
    $running = @(Get-Process rpcs3,pcsx2-qt,pcsx2 -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) { throw 'Close RPCS3 and PCSX2 before changing the Vulkan layer.' }
}

function Set-GeneralIniValue([string]$Content, [string]$Name, [string]$Value) {
    if ($Content -match "(?m)^$([regex]::Escape($Name))=.*$") {
        return $Content -replace "(?m)^$([regex]::Escape($Name))=.*$", "$Name=$Value"
    }
    $Content -replace '(?m)^\[General\]\s*', "[General]`r`n$Name=$Value`r`n"
}

function Update-PresetSelection([string]$Path, [string[]]$SelectedGames, [string]$FallbackPreset) {
    $content = Get-Content -LiteralPath $Path -Raw
    $content = Set-GeneralIniValue $content 'EnabledPresets' (@($SelectedGames) -join ',')
    $content = Set-GeneralIniValue $content 'ActivePreset' $FallbackPreset
    Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

function Get-OwnedRegistryValues {
    if (-not (Test-Path $RegistryPath)) { return @() }
    $properties = (Get-ItemProperty -Path $RegistryPath).PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' -and $_.Name -like '*.json' }
    $owned = [System.Collections.Generic.List[string]]::new()
    foreach ($property in $properties) {
        $manifestPath = [string]$property.Name
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            if ([IO.Path]::GetFileName($manifestPath) -eq 'RandOverlay_layer.json') { $owned.Add($manifestPath) }
            continue
        }
        try {
            $manifest = Read-JsonFile $manifestPath
            if ($manifest.layer.name -eq $script:LayerName) { $owned.Add($manifestPath) }
        } catch { }
    }
    @($owned)
}

function Set-CanonicalRegistration {
    $manifestPath = Join-Path $script:CurrentRoot 'RandOverlay_layer.json'
    if (-not (Test-Path $RegistryPath)) { New-Item -Path $RegistryPath -Force | Out-Null }
    foreach ($ownedPath in @(Get-OwnedRegistryValues)) {
        Remove-ItemProperty -Path $RegistryPath -Name $ownedPath -ErrorAction SilentlyContinue
    }
    New-ItemProperty -Path $RegistryPath -Name $manifestPath -PropertyType DWord -Value 0 -Force | Out-Null
}

function Remove-OwnedRegistrations {
    foreach ($ownedPath in @(Get-OwnedRegistryValues)) {
        Remove-ItemProperty -Path $RegistryPath -Name $ownedPath -ErrorAction SilentlyContinue
    }
}

function Get-InstalledFileRecords([string]$Root) {
    $records = [System.Collections.Generic.List[object]]::new()
    Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
        $records.Add([ordered]@{ path=$relative; sha256=(Get-FileSha256 $_.FullName) })
    }
    @($records)
}

function Save-PendingPackage([string]$SourcePayload, $Metadata, [string[]]$SelectedGames, [string]$SelectedActive) {
    $oldState = Get-State
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    if ((Get-FullPath $SourcePayload) -ne (Get-FullPath $script:CachedPayloadRoot)) {
        if (Test-Path -LiteralPath $script:CachedPayloadRoot) { Remove-ExactOwnedPath $InstallRoot $script:CachedPayloadRoot }
        Copy-DirectoryContents $SourcePayload $script:CachedPayloadRoot
    }
    if ((Get-FullPath $PSCommandPath) -ne (Get-FullPath $script:InstalledSetupPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledSetupPath -Force
    }
    $state = [ordered]@{
        schemaVersion=1; status='pending-prerequisites'
        installedVersion=$(if($oldState){$oldState.installedVersion}else{$null})
        pendingVersion=[string]$Metadata.version; enabledGames=@($SelectedGames); activeGame=$SelectedActive
        installRoot=$InstallRoot; dependencyPaths=(Get-DependencyPaths)
        updatedAt=(Get-Date).ToUniversalTime().ToString('o'); files=@()
    }
    Write-JsonFile $script:StatePath $state
}

function Complete-Install($Metadata, [string[]]$SelectedGames, [string]$SelectedActive) {
    Test-EmulatorsStopped
    $payload = Resolve-PayloadRoot
    Test-Payload $payload | Out-Null
    $stage = Join-Path $InstallRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
    $stageCurrent = Join-Path $stage 'current'
    New-Item -ItemType Directory -Path $stageCurrent -Force | Out-Null
    foreach ($name in @('RandOverlay_layer.dll','RandOverlay_layer.json')) {
        Copy-Item -LiteralPath (Join-Path $payload $name) -Destination (Join-Path $stageCurrent $name) -Force
    }
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        Copy-Item -LiteralPath (Join-Path $payload 'RandOverlay.ini') -Destination $script:ConfigPath -Force
    }
    Update-PresetSelection $script:ConfigPath $SelectedGames $SelectedActive

    if (Test-Path -LiteralPath $script:RollbackRoot) { Remove-ExactOwnedPath $InstallRoot $script:RollbackRoot }
    $oldMoved = $false
    try {
        if (Test-Path -LiteralPath $script:CurrentRoot) {
            New-Item -ItemType Directory -Path (Split-Path $script:RollbackRoot -Parent) -Force | Out-Null
            Move-Item -LiteralPath $script:CurrentRoot -Destination $script:RollbackRoot
            $oldMoved = $true
        }
        Move-Item -LiteralPath $stageCurrent -Destination $script:CurrentRoot
    } catch {
        if ($oldMoved -and -not (Test-Path -LiteralPath $script:CurrentRoot) -and (Test-Path -LiteralPath $script:RollbackRoot)) {
            Move-Item -LiteralPath $script:RollbackRoot -Destination $script:CurrentRoot
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-ExactOwnedPath $InstallRoot $stage }
    }
    if ((Get-FullPath $PSCommandPath) -ne (Get-FullPath $script:InstalledSetupPath)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledSetupPath -Force
    }
    Set-CanonicalRegistration

    $state = [ordered]@{
        schemaVersion=1; status='installed'; installedVersion=[string]$Metadata.version; pendingVersion=$null
        enabledGames=@($SelectedGames); activeGame=$SelectedActive; installRoot=$InstallRoot
        dependencyPaths=(Get-DependencyPaths)
        updatedAt=(Get-Date).ToUniversalTime().ToString('o'); files=@(Get-InstalledFileRecords $script:CurrentRoot)
    }
    Write-JsonFile $script:StatePath $state
    Write-Ok "RandOverlay $($Metadata.version) installed for $($SelectedGames -join ', ')"
    Write-Ok "Automatic preset detection enabled; fallback preset: $SelectedActive"
}

function Invoke-Install {
    $selected = Normalize-Games $Games
    $selectedActive = if ($ActiveGame) { $ActiveGame } else { $selected[0] }
    if ($selected -notcontains $selectedActive) { throw 'ActiveGame must be one of the selected Games.' }
    $payload = Resolve-PayloadRoot
    $metadata = Test-Payload $payload
    Save-PendingPackage $payload $metadata $selected $selectedActive
    if (-not $SkipPrerequisiteChecks) {
        $results = Get-PrerequisiteStatus $selected
        if ($NonInteractive) {
            Show-Prerequisites $results
            if (@($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) {
                Write-Warn 'Progress saved. Install missing prerequisites, then run Repair.'
                exit 2
            }
        } elseif (-not (Resolve-PrerequisitesInteractive $selected)) {
            Write-Warn 'Progress saved. Run Setup or Repair when prerequisites are ready.'
            return
        }
    }
    Complete-Install $metadata $selected $selectedActive
}

function Get-HealthStatus {
    $state = Get-State
    $owned = @(Get-OwnedRegistryValues)
    $issues = [System.Collections.Generic.List[string]]::new()
    if (-not $state) { $issues.Add('No setup state exists.') }
    if (-not (Test-Path -LiteralPath (Join-Path $script:CurrentRoot 'RandOverlay_layer.dll'))) { $issues.Add('Layer DLL is missing.') }
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { $issues.Add('RandOverlay.ini is missing.') }
    if ($owned.Count -ne 1) { $issues.Add("Expected one owned Vulkan registration; found $($owned.Count).") }
    if ($state -and $state.files) {
        foreach ($file in @($state.files)) {
            $path = Join-Path $script:CurrentRoot ([string]$file.path)
            if (-not (Test-Path -LiteralPath $path) -or (Get-FileSha256 $path) -ne ([string]$file.sha256)) {
                $issues.Add("Installed file failed verification: $($file.path)")
            }
        }
    }
    [pscustomobject]@{ healthy=($issues.Count -eq 0); state=$state; ownedRegistrations=$owned; issues=@($issues) }
}

function Invoke-Status {
    $health = Get-HealthStatus
    if ($Json) { $health | ConvertTo-Json -Depth 10; return }
    Write-Step 'RandOverlay status'
    if ($health.state) {
        Write-Host "Version: $($health.state.installedVersion)"
        Write-Host "State: $($health.state.status)"
        Write-Host "Games: $(@($health.state.enabledGames) -join ', ')"
        Write-Host "Fallback preset: $($health.state.activeGame)"
        Write-Host "Location: $InstallRoot"
    }
    if ($health.healthy) { Write-Ok 'Installation is healthy.' }
    else { foreach ($issue in $health.issues) { Write-Warn $issue } }
}

function Invoke-Repair {
    $state = Get-State
    if (-not $state) { throw 'No saved installation exists. Run Install first.' }
    $selected = Normalize-Games @($state.enabledGames)
    if (-not $SkipPrerequisiteChecks) {
        $results = Get-PrerequisiteStatus $selected
        if ($NonInteractive -and @($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) {
            Show-Prerequisites $results
            exit 2
        }
        if (-not $NonInteractive -and -not (Resolve-PrerequisitesInteractive $selected)) { return }
    }
    $payload = Resolve-PayloadRoot
    $metadata = Test-Payload $payload
    Complete-Install $metadata $selected ([string]$state.activeGame)
}

function Invoke-Configure {
    $state = Get-State
    if (-not $state) { throw 'No installation exists. Run Install first.' }
    $requestedGames = if ($Games) { $Games } else { @($state.enabledGames) }
    $selected = Normalize-Games $requestedGames
    $selectedActive = if ($ActiveGame) { $ActiveGame } elseif ($selected -contains [string]$state.activeGame) { [string]$state.activeGame } else { $selected[0] }
    if ($selected -notcontains $selectedActive) { throw 'ActiveGame must be one of the selected Games.' }
    if (-not $SkipPrerequisiteChecks) {
        $results = Get-PrerequisiteStatus $selected
        if (@($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) {
            Show-Prerequisites $results
            throw 'Selected games have missing prerequisites.'
        }
    }
    Update-PresetSelection $script:ConfigPath $selected $selectedActive
    $state.enabledGames = @($selected)
    $state.activeGame = $selectedActive
    $state.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonFile $script:StatePath $state
    Write-Ok "Enabled games: $($selected -join ', '); automatic detection on; fallback preset: $selectedActive"
}

function Invoke-Uninstall {
    Test-EmulatorsStopped
    Remove-OwnedRegistrations
    if (-not $KeepConfig -and (Test-Path -LiteralPath $script:ConfigPath)) { Remove-ExactOwnedPath $InstallRoot $script:ConfigPath }
    foreach ($relative in @('current','package','rollback','setup-state.json','Setup-RandOverlay.ps1')) {
        $target = Join-Path $InstallRoot $relative
        if (Test-Path -LiteralPath $target) { Remove-ExactOwnedPath $InstallRoot $target }
    }
    if ((Test-Path -LiteralPath $InstallRoot) -and @(Get-ChildItem -LiteralPath $InstallRoot -Force).Count -eq 0) {
        [IO.Directory]::Delete($InstallRoot)
    }
    Write-Ok 'RandOverlay Vulkan layer uninstalled.'
}

function Read-GameSelection {
    $items = @(
        [pscustomobject]@{ Game='RAC1'; Emulator='RPCS3' },
        [pscustomobject]@{ Game='RAC2'; Emulator='PCSX2' },
        [pscustomobject]@{ Game='RAC3'; Emulator='PCSX2' }
    )

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Write-Host 'Select games (comma-separated; default RAC1):'
        for ($i = 0; $i -lt $items.Count; $i++) { Write-Host "[$($i + 1)] $($items[$i].Game) - $($items[$i].Emulator)" }
        # Redirected Windows PowerShell input can prefix the first token with
        # a UTF-8 BOM. Strip it so selection 1 is not silently discarded.
        $answer = (Read-Host 'Selection').Trim() -replace '^[^0-9A-Za-z]+', ''
        if (-not $answer) { return @('RAC1') }
        $map = @{ '1'='RAC1'; '2'='RAC2'; '3'='RAC3'; 'RAC1'='RAC1'; 'RAC2'='RAC2'; 'RAC3'='RAC3' }
        return Normalize-Games @($answer -split ',' | ForEach-Object { $map[$_.Trim().ToUpperInvariant()] } | Where-Object { $_ } | Select-Object -Unique)
    }

    $checked = @($true, $false, $false)
    $cursor = 0
    Write-Step 'Choose games'
    Write-Host 'This installer contains and verifies the current RandOverlay release ZIP automatically.' -ForegroundColor DarkGray
    Write-Host 'Use Up/Down to move, Space to toggle, and Enter to continue.' -ForegroundColor DarkGray
    $menuTop = [Console]::CursorTop
    $cursorWasVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false

    try {
        while ($true) {
            [Console]::SetCursorPosition(0, $menuTop)
            for ($i = 0; $i -lt $items.Count; $i++) {
                $pointer = if ($i -eq $cursor) { '>' } else { ' ' }
                $mark = if ($checked[$i]) { 'x' } else { ' ' }
                $line = " $pointer [$mark] $($items[$i].Game) - $($items[$i].Emulator)"
                $padding = ' ' * [Math]::Max(0, [Console]::WindowWidth - $line.Length - 1)
                Write-Host ($line + $padding) -ForegroundColor $(if ($i -eq $cursor) { 'Cyan' } else { 'Gray' })
            }
            $selectedCount = @($checked | Where-Object { $_ }).Count
            $status = " Selected: $selectedCount  "
            Write-Host ($status + (' ' * [Math]::Max(0, [Console]::WindowWidth - $status.Length - 1))) -ForegroundColor DarkGray

            $key = [Console]::ReadKey($true).Key
            switch ($key) {
                'UpArrow'   { $cursor = ($cursor + $items.Count - 1) % $items.Count }
                'DownArrow' { $cursor = ($cursor + 1) % $items.Count }
                'Spacebar'  { $checked[$cursor] = -not $checked[$cursor] }
                'Enter' {
                    if ($selectedCount -gt 0) {
                        Write-Host ''
                        return Normalize-Games @($(for ($i = 0; $i -lt $items.Count; $i++) { if ($checked[$i]) { $items[$i].Game } }))
                    }
                    [Console]::Beep()
                }
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorWasVisible
    }
}

function Invoke-Preflight {
    $selected = Normalize-Games $Games
    $results = Get-PrerequisiteStatus $selected
    if ($Json) { [pscustomobject]@{ games=$selected; prerequisites=$results } | ConvertTo-Json -Depth 8 }
    else { Show-Prerequisites $results }
    if (@($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) { exit 2 }
}

function Invoke-CheckForUpdates {
    $state = Get-State
    if (-not $state) { throw 'No installation exists.' }
    Write-Step 'Checking official GitHub Releases'
    $release = Invoke-RestMethod -Uri "$script:RepoApi/releases/latest" -Headers @{ 'User-Agent'='RandOverlay-Setup' }
    $latest = ([string]$release.tag_name).TrimStart('v')
    if ([version]$latest -le [version]([string]$state.installedVersion)) { Write-Ok 'Already up to date.'; return }
    Write-Host "Installed: $($state.installedVersion)"
    Write-Host "Available: $latest"
    Write-Host ([string]$release.body)
    if (-not $ConfirmUpdate -and $NonInteractive) { Write-Warn 'Update available; rerun with -ConfirmUpdate to install.'; return }
    if (-not $ConfirmUpdate -and (Read-Host 'Download and install? [y/N]') -notmatch '^(?i)y(es)?$') { return }
    $zipAsset = @($release.assets | Where-Object { $_.name -match '^RandOverlay-Vulkan-.*\.zip$' }) | Select-Object -First 1
    $sumAsset = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
    if (-not $zipAsset -or -not $sumAsset) { throw 'Release is missing ZIP or SHA256SUMS.txt.' }
    $tempParent = Assert-SafeRoot ([IO.Path]::GetTempPath())
    $temp = Join-Path $tempParent ('RandOverlayUpdate-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $zip = Join-Path $temp $zipAsset.name
        $sums = Join-Path $temp 'SHA256SUMS.txt'
        Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip
        Invoke-WebRequest -Uri $sumAsset.browser_download_url -OutFile $sums
        $line = Get-Content -LiteralPath $sums | Where-Object { $_ -match [regex]::Escape($zipAsset.name) } | Select-Object -First 1
        if (-not $line) { throw 'Release checksum does not list the ZIP.' }
        if ((Get-FileSha256 $zip) -ne (($line -split '\s+')[0].ToUpperInvariant())) { throw 'Downloaded ZIP failed SHA-256 verification.' }
        $expanded = Join-Path $temp 'expanded'
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded
        $setup = Get-ChildItem -LiteralPath $expanded -Filter 'Setup-RandOverlay.ps1' -Recurse | Select-Object -First 1
        if (-not $setup) { throw 'Downloaded release has no setup script.' }
        $arguments = @('-NoProfile','-File',$setup.FullName,'-Action','Install','-Games',(@($state.enabledGames) -join ','),'-ActiveGame',$state.activeGame,'-InstallRoot',$InstallRoot)
        & powershell.exe @arguments
        if ($LASTEXITCODE -ne 0) { throw "Updated setup exited $LASTEXITCODE" }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-ExactOwnedPath $tempParent $temp }
    }
}

function Invoke-Interactive {
    $state = Get-State
    if (-not $state -or $state.status -ne 'installed') {
        $script:Games = Read-GameSelection
        $script:ActiveGame = $script:Games[0] # fallback only; runtime detects the game
        Invoke-Install
        return
    }
    Write-Host '[1] Status  [2] Repair  [3] Configure  [4] Check for updates  [5] Uninstall'
    switch ((Read-Host 'Selection').Trim()) {
        '1' { Invoke-Status }
        '2' { Invoke-Repair }
        '3' {
            $script:Games = Read-GameSelection
            $script:ActiveGame = if ($script:Games -contains [string]$state.activeGame) { [string]$state.activeGame } else { $script:Games[0] }
            Invoke-Configure
        }
        '4' { Invoke-CheckForUpdates }
        '5' { if ((Read-Host 'Uninstall RandOverlay? [y/N]') -match '^(?i)y(es)?$') { Invoke-Uninstall } }
        default { Write-Warn 'Unknown selection.' }
    }
}

switch ($Action) {
    'Interactive' { Invoke-Interactive }
    'Install' { Invoke-Install }
    'Status' { Invoke-Status }
    'Repair' { Invoke-Repair }
    'Configure' { Invoke-Configure }
    'CheckForUpdates' { Invoke-CheckForUpdates }
    'Uninstall' { Invoke-Uninstall }
    'Preflight' { Invoke-Preflight }
}

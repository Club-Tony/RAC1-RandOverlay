# -------------------------------------------------------------------------
# RAC1 stack, part 2 of 3: read-only detection and the status rows.
# Nothing in this file writes to disk. Rows never change the exit code.
# Dot-sourced by Setup-RandOverlay.ps1.
# -------------------------------------------------------------------------

function Get-ManagedFileInfo([string]$Id, $Component) {
    # One shape for every managed-file component. The apworld belongs in Archipelago's
    # custom_worlds; everything else is staged inside the install root at installRelative
    # and is never written into another program's folders.
    if ($Id -eq 'rac1-apworld') { return Get-ApworldInfo $Component }
    $fileName = [string](Get-OptionalProperty $Component 'fileName')
    if (-not $fileName) { throw "Component $Id has no fileName." }
    $directory = Resolve-StackRelativePath ([string](Get-OptionalProperty $Component 'installRelative'))
    $info = [ordered]@{ FileName=$fileName; TargetDirectory=$directory; Path=$null; Present=$false; Sha256=$null; Size=0; Version=$null; Tag=$null; Status='missing'; Entry=$null }
    $candidate = Join-Path $directory $fileName
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $item = Get-Item -LiteralPath $candidate
        $info.Path = $item.FullName; $info.Present = $true; $info.Size = $item.Length
        $info.Sha256 = Get-FileSha256 $item.FullName; $info.Status = 'unknown'
        foreach ($entry in @(Get-OptionalProperty $Component 'versions')) {
            if ($null -eq $entry) { continue }
            if (([string]$entry.sha256).ToUpperInvariant() -eq $info.Sha256) {
                $info.Version = [string]$entry.version; $info.Tag = [string]$entry.tag; $info.Entry = $entry
                $info.Status = if ([bool](Get-OptionalProperty $entry 'revoked')) { 'revoked' } else { [string]$entry.status }
                break
            }
        }
    }
    [pscustomobject]$info
}

function Get-PopTrackerInfo($Component) {
    # Prefers the managed portable copy under the install root, then reports a user install.
    # A user install is only ever reported, never modified or removed.
    $executable = [string](Get-OptionalProperty $Component 'executable')
    if (-not $executable) { $executable = 'poptracker.exe' }
    $managedRoot = $null
    $managedPath = $null
    $relative = [string](Get-OptionalProperty $Component 'installRelative')
    if ($relative) {
        try {
            $managedRoot = Resolve-StackRelativePath $relative
            $candidate = Join-Path $managedRoot $executable
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $managedPath = $candidate }
        } catch { $managedRoot = $null }
    }
    $userPath = Find-Executable @($executable) @((Join-Path $env:LOCALAPPDATA 'Programs\PopTracker\poptracker.exe'),(Join-Path $env:ProgramFiles 'PopTracker\poptracker.exe'))
    if ($managedPath -and $userPath -and ((Get-FullPath $userPath) -eq (Get-FullPath $managedPath))) { $userPath = $null }
    $managedVersion = $null
    if ($managedPath) {
        $record = Get-OptionalProperty (Get-OptionalProperty (Get-State) 'stack') 'poptracker'
        $managedVersion = [string](Get-OptionalProperty $record 'version')
    }
    [pscustomobject]@{
        ManagedRoot=$managedRoot; ManagedPath=$managedPath; ManagedVersion=$managedVersion; UserPath=$userPath
        Path=$(if ($managedPath) { $managedPath } else { $userPath })
        Managed=[bool]$managedPath; Present=[bool]($managedPath -or $userPath)
    }
}

function Get-LawrencePath {
    # User-supplied only. Lawrence carries no license, so this tool never downloads,
    # mirrors or bundles it; it only remembers where you put your own build.
    # Get-DependencyPaths returns an ordered hashtable, whose keys are not PSObject
    # properties, so read the key directly rather than through Get-OptionalProperty.
    $paths = Get-DependencyPaths
    $saved = [string]$paths.lawrencePath
    if ($saved -and (Test-Path -LiteralPath $saved -PathType Leaf)) { return (Get-FullPath $saved) }
    $null
}

function Get-ArchipelagoInfo {
    # Read-only. Version comes from the uninstall registry entry (DisplayVersion, else the
    # version embedded in DisplayName such as "Archipelago 0.6.7"), else the launcher's file version.
    $root = (Get-DependencyPaths).archipelagoRoot
    $launcher = Join-Path $root 'ArchipelagoLauncher.exe'
    $present = Test-Path -LiteralPath $launcher -PathType Leaf
    $version = $null
    $source = $null
    if ($present) {
        foreach ($uninstallRoot in @($UninstallRegistryRoots)) {
            if (-not $uninstallRoot -or -not (Test-Path -Path $uninstallRoot)) { continue }
            foreach ($key in @(Get-ChildItem -Path $uninstallRoot -ErrorAction SilentlyContinue)) {
                $values = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                $displayName = [string](Get-OptionalProperty $values 'DisplayName')
                if ($displayName -notlike 'Archipelago*') { continue }
                $displayVersion = [string](Get-OptionalProperty $values 'DisplayVersion')
                if ($displayVersion) { $version = $displayVersion.Trim(); $source = 'uninstall registry DisplayVersion' }
                elseif ($displayName -match 'Archipelago\s+v?(\d+\.\d+\.\d+[^\s]*)') { $version = $matches[1]; $source = 'uninstall registry DisplayName' }
                if ($version) { break }
            }
            if ($version) { break }
        }
        if (-not $version) {
            $productVersion = [string](Get-Item -LiteralPath $launcher).VersionInfo.ProductVersion
            if ($productVersion -and $productVersion -notmatch '^0\.0\.0(\.0)?$') { $version = $productVersion.Trim(); $source = 'launcher file version' }
        }
    }
    [pscustomobject]@{ Root=$root; LauncherPath=$launcher; Present=$present; Version=$version; Source=$source }
}

function Get-Rpcs3Info($Component) {
    # Read-only. RPCS3 keeps config\config.yml, dev_flash and dev_hdd0 beside rpcs3.exe.
    $dependencyPaths = Get-DependencyPaths
    $exe = Find-Executable @('rpcs3.exe') @($dependencyPaths.rpcs3Path,(Join-Path $env:LOCALAPPDATA 'Programs\RPCS3\rpcs3.exe'),(Join-Path $env:ProgramFiles 'RPCS3\rpcs3.exe'))
    $info = [ordered]@{ Path=$exe; Present=[bool]$exe; Root=$null; Version=$null; Firmware=$null; GamePresent=$false; ModPresent=$false; Network=$null }
    if ($exe) {
        $root = Split-Path $exe -Parent
        $info.Root = $root
        $productVersion = [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
        if ($productVersion -and $productVersion -notmatch '^0\.0\.0(\.0)?$') { $info.Version = $productVersion.Trim() }
        elseif ((Split-Path $root -Leaf) -match 'rpcs3-v?(\d+\.\d+\.\d+(?:-\d+)?)') { $info.Version = $matches[1] }
        $firmwareFile = Join-Path $root 'dev_flash\vsh\etc\version.txt'
        if (Test-Path -LiteralPath $firmwareFile -PathType Leaf) {
            $firstLine = [string](Get-Content -LiteralPath $firmwareFile -TotalCount 1)
            $info.Firmware = if ($firstLine -match 'release:(\d+\.\d+)') { $matches[1] } else { 'installed' }
        }
        $gameTitleId = [string](Get-OptionalProperty $Component 'gameTitleId'); if (-not $gameTitleId) { $gameTitleId = 'NPEA00385' }
        $modTitleId = [string](Get-OptionalProperty $Component 'modTitleId'); if (-not $modTitleId) { $modTitleId = 'BORD00001' }
        $info.GamePresent = Test-Path -LiteralPath (Join-Path $root "dev_hdd0\game\$gameTitleId") -PathType Container
        $info.ModPresent = Test-Path -LiteralPath (Join-Path $root "dev_hdd0\game\$modTitleId") -PathType Container
        foreach ($configPath in @((Join-Path $root 'config\config.yml'), (Join-Path $root 'config.yml'))) {
            if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { continue }
            $configText = Get-Content -LiteralPath $configPath -Raw
            $info.Network = if ($configText -match '(?m)^\s*Internet enabled:\s*(\S+)') { $matches[1] } else { 'unknown' }
            break
        }
    }
    [pscustomobject]$info
}

function Get-ApworldInfo($Component) {
    # Read-only. Finds the apworld case-insensitively in custom_worlds (or the per-user worlds
    # folder) and maps its hash to a manifest version.
    $fileName = [string](Get-OptionalProperty $Component 'fileName'); if (-not $fileName) { $fileName = 'rac1.apworld' }
    $archipelagoRoot = (Get-DependencyPaths).archipelagoRoot
    $searchDirs = @((Join-Path $archipelagoRoot 'custom_worlds'), (Join-Path $env:USERPROFILE 'Archipelago\worlds'))
    $file = $null
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $file = Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Name -ieq $fileName } | Select-Object -First 1
        if ($file) { break }
    }
    $info = [ordered]@{ FileName=$fileName; TargetDirectory=(Join-Path $archipelagoRoot 'custom_worlds'); Path=$null; Present=$false; Sha256=$null; Size=0; Version=$null; Tag=$null; Status='missing'; Entry=$null }
    if ($file) {
        $info.Path = $file.FullName; $info.Present = $true; $info.Size = $file.Length; $info.Sha256 = Get-FileSha256 $file.FullName; $info.Status = 'unknown'
        foreach ($entry in @(Get-OptionalProperty $Component 'versions')) {
            if ($null -eq $entry) { continue }
            if (([string]$entry.sha256).ToUpperInvariant() -eq $info.Sha256) {
                $info.Version = [string]$entry.version; $info.Tag = [string]$entry.tag; $info.Entry = $entry
                $info.Status = if ([bool](Get-OptionalProperty $entry 'revoked')) { 'revoked' } else { [string]$entry.status }
                break
            }
        }
    }
    [pscustomobject]$info
}

function Get-StackStatus([string[]]$SelectedGames) {
    # One row per stack element. Rows never change the exit code; prerequisites do.
    $rows = [System.Collections.Generic.List[object]]::new()
    if ($SelectedGames -notcontains 'RAC1') { return @($rows) }
    $manifest = $null
    $manifestError = $null
    try { $manifest = Get-StackManifest } catch { $manifestError = $_.Exception.Message }

    $archipelagoComponent = Get-StackComponent $manifest 'archipelago'
    $archipelago = Get-ArchipelagoInfo
    $compatibility = Get-VersionCompatibility $archipelago.Version (Get-OptionalProperty $archipelagoComponent 'compatible')
    $archipelagoVersionText = if ($archipelago.Version) { $archipelago.Version } else { 'unknown' }
    $rows.Add([pscustomobject]@{
        Id='archipelago'; Name='Archipelago Launcher'; Kind='detect-only'; Required=$true; Optional=$false
        Ready=$archipelago.Present; Version=$archipelago.Version
        Status=$(if ($archipelago.Present) { $compatibility } else { 'missing' })
        Detail=$(if ($archipelago.Present) { "$($archipelago.LauncherPath) (version $archipelagoVersionText, $compatibility)" } else { $archipelago.LauncherPath })
        Url='https://github.com/ArchipelagoMW/Archipelago/releases'
    })

    $apworldComponent = Get-StackComponent $manifest 'rac1-apworld'
    $apworld = Get-ApworldInfo $apworldComponent
    $apworldDetail = if (-not $apworld.Present) { "$($apworld.TargetDirectory)\$($apworld.FileName) (missing; run -Action InstallStackComponent -Component rac1-apworld)" }
        elseif ($apworld.Version) { "$($apworld.Path) (version $($apworld.Version), $($apworld.Status))" }
        else { "$($apworld.Path) (not a known release; sha256 $($apworld.Sha256.Substring(0, 12))...)" }
    if ($apworld.Status -eq 'revoked') { $apworldDetail += " REVOKED: $(Get-OptionalProperty $apworld.Entry 'revokedReason')" }
    if (-not $manifest) { $apworldDetail += ' [stack manifest unavailable' + $(if ($manifestError) { ": $manifestError" } else { '' }) + ']' }
    $rows.Add([pscustomobject]@{
        Id='rac1-apworld'; Name='Ratchet & Clank 1 APWorld'; Kind='managed-file'; Required=$true; Optional=$false
        Ready=($apworld.Present -and $apworld.Status -ne 'revoked'); Version=$apworld.Version; Status=$apworld.Status
        Detail=$apworldDetail; Url='https://github.com/Panda291/Archipelago/releases'
    })

    $rpcs3Component = Get-StackComponent $manifest 'rpcs3'
    $rpcs3 = Get-Rpcs3Info $rpcs3Component
    $rpcs3Status = 'missing'
    if ($rpcs3.Present) {
        $rpcs3Status = 'detected'
        if ($rpcs3.Version) {
            try {
                $minVersion = [string](Get-OptionalProperty $rpcs3Component 'minVersion')
                if ($minVersion -and (Compare-ReleaseVersion $rpcs3.Version $minVersion) -lt 0) { $rpcs3Status = 'below-minimum' }
                foreach ($bad in @(Get-OptionalProperty $rpcs3Component 'knownBad')) {
                    if ($null -eq $bad -or [string]$bad -eq '') { continue }
                    if ((Compare-ReleaseVersion $rpcs3.Version ([string]$bad)) -eq 0) { $rpcs3Status = 'known-bad' }
                }
            } catch { }
        }
    }
    $rpcs3VersionText = if ($rpcs3.Version) { $rpcs3.Version } else { 'unknown' }
    $rpcs3Detail = if ($rpcs3.Present) {
        "$($rpcs3.Path) (version $rpcs3VersionText; firmware $(if ($rpcs3.Firmware) { $rpcs3.Firmware } else { 'missing' }); game NPEA00385 $(if ($rpcs3.GamePresent) { 'present' } else { 'missing' }); multiplayer PKG $(if ($rpcs3.ModPresent) { 'present' } else { 'missing' }); network $(if ($rpcs3.Network) { $rpcs3.Network } else { 'unknown' }))"
    } else { 'Not found in known locations' }
    $rows.Add([pscustomobject]@{
        Id='rpcs3'; Name='RPCS3'; Kind='detect-only'; Required=$true; Optional=$false
        Ready=$rpcs3.Present; Version=$rpcs3.Version; Status=$rpcs3Status; Detail=$rpcs3Detail; Url='https://rpcs3.net/download'
    })
    $rows.Add([pscustomobject]@{
        Id='rpcs3-firmware'; Name='PS3 firmware in RPCS3'; Kind='user-supplied'; Required=$true; Optional=$false
        Ready=[bool]$rpcs3.Firmware; Version=$rpcs3.Firmware; Status=$(if ($rpcs3.Firmware) { 'present' } else { 'missing' })
        Detail='Obtain PS3UPDAT.PUP from Sony, then RPCS3 File > Install Firmware. Never bundled by this tool.'
        Url='https://www.playstation.com/en-us/support/hardware/ps3/system-software/'
    })
    $rows.Add([pscustomobject]@{
        Id='rac1-game'; Name='Ratchet & Clank (NPEA00385) in RPCS3'; Kind='user-supplied'; Required=$true; Optional=$false
        Ready=$rpcs3.GamePresent; Version=$null; Status=$(if ($rpcs3.GamePresent) { 'present' } else { 'missing' })
        Detail='Your own legitimately owned copy, installed in RPCS3. Never bundled by this tool.'
        Url='https://github.com/Panda291/Archipelago/blob/main/worlds/RAC1/docs/setup_en.md'
    })
    $multiplayerComponent = Get-StackComponent $manifest 'rac1-multiplayer'
    $multiplayerStaged = $null
    if ((Get-OptionalProperty $multiplayerComponent 'kind') -eq 'managed-file') {
        try { $multiplayerStaged = Get-ManagedFileInfo 'rac1-multiplayer' $multiplayerComponent } catch { }
    }
    $multiplayerDetail = if ($rpcs3.ModPresent) { 'dev_hdd0\game\BORD00001 present' }
        elseif ($multiplayerStaged -and $multiplayerStaged.Present) { "Downloaded and verified at $($multiplayerStaged.Path); install it with RPCS3 File > Install Packages/Raps/Edats" }
        else { 'Run -Action InstallStackComponent -Component rac1-multiplayer to download it, then install it with RPCS3 File > Install Packages/Raps/Edats' }
    $rows.Add([pscustomobject]@{
        Id='rac1-multiplayer'; Name='Ratchet & Clank Multiplayer Client (PKG)'; Kind='managed-file'; Required=$true; Optional=$false
        Ready=$rpcs3.ModPresent; Version=$(if ($multiplayerStaged) { $multiplayerStaged.Version } else { $null })
        Status=$(if ($rpcs3.ModPresent) { 'present' } elseif ($multiplayerStaged -and $multiplayerStaged.Present) { 'downloaded' } else { 'missing' })
        Detail=$multiplayerDetail
        Url='https://github.com/bordplate/rac1-multiplayer/releases'
    })
    $rows.Add([pscustomobject]@{
        Id='rpcs3-network'; Name='RPCS3 network status'; Kind='detect-only'; Required=$true; Optional=$false
        Ready=($rpcs3.Network -eq 'Connected'); Version=$null; Status=$(if ($rpcs3.Network) { $rpcs3.Network } else { 'unknown' })
        Detail='RPCS3 Configuration > System > Network > Network Status must be Connected (-Action ConfigureRpcs3Network sets it, after backing up config.yml)'
        Url='https://github.com/Panda291/Archipelago/blob/main/worlds/RAC1/docs/setup_en.md'
    })

    $lawrenceProcess = Get-Process -Name Lawrence -ErrorAction SilentlyContinue | Select-Object -First 1
    $lawrencePath = Get-LawrencePath
    $lawrenceDetail = if ($lawrenceProcess) { 'Running; point the multiplayer client at 127.0.0.1 with Direct Connect' }
        elseif ($lawrencePath) { "$lawrencePath (your own build; start it from the Launch menu when self-hosting)" }
        else { 'Only needed to host a multiworld locally. Not redistributable, so this tool never downloads it; pass -LawrencePath to point at your own build.' }
    $rows.Add([pscustomobject]@{
        Id='lawrence'; Name='Lawrence server (self-hosting only)'; Kind='user-supplied'; Required=$false; Optional=$true
        Ready=[bool]($lawrenceProcess -or $lawrencePath); Version=$null
        Status=$(if ($lawrenceProcess) { 'running' } elseif ($lawrencePath) { 'detected' } else { 'not running' })
        Detail=$lawrenceDetail
        Url='https://github.com/bordplate/Lawrence/releases'
    })
    $popTrackerComponent = Get-StackComponent $manifest 'poptracker'
    $popTracker = Get-PopTrackerInfo $popTrackerComponent
    $popTrackerDetail = if ($popTracker.Managed) { "$($popTracker.ManagedPath) (managed portable copy$(if ($popTracker.ManagedVersion) { ", version $($popTracker.ManagedVersion)" } else { '' }); no tracker pack ships with this tool)" }
        elseif ($popTracker.UserPath) { "$($popTracker.UserPath) (your own install; this tool leaves it alone)" }
        else { 'Optional companion tracker; -Action InstallStackComponent -Component poptracker keeps a portable copy under the install root' }
    $rows.Add([pscustomobject]@{
        Id='poptracker'; Name='PopTracker (optional tracker)'; Kind='managed-archive'; Required=$false; Optional=$true
        Ready=$popTracker.Present; Version=$popTracker.ManagedVersion
        Status=$(if ($popTracker.Managed) { 'managed' } elseif ($popTracker.UserPath) { 'detected' } else { 'not detected' })
        Detail=$popTrackerDetail
        Url='https://github.com/black-sliver/PopTracker/releases'
    })
    @($rows)
}

function Show-StackStatus([object[]]$Rows) {
    if (@($Rows).Count -eq 0) { return }
    Write-Step 'RAC1 stack'
    foreach ($row in $Rows) {
        if ($row.Ready) { Write-Ok "$($row.Name) - $($row.Detail)" }
        elseif ($row.Optional) { Write-Log "$($row.Name) - $($row.Detail)" 'INFO'; Write-Host "[INFO] $($row.Name) - $($row.Detail)" -ForegroundColor DarkGray }
        else { Write-Fail "$($row.Name) - $($row.Detail)"; Write-Hyperlink 'Official page' $row.Url }
    }
}

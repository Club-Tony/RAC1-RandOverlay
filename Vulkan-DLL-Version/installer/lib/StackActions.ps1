# -------------------------------------------------------------------------
# RAC1 stack, part 3 of 3: stack state and the actions that change disk.
# Only components the manifest marks managed are ever written by Setup.
# Dot-sourced by Setup-RandOverlay.ps1.
# -------------------------------------------------------------------------

function Get-StackState {
    $state = Get-State
    if (-not $state) { throw 'No installation exists. Run Install first.' }
    $stack = Get-OptionalProperty $state 'stack'
    if ($null -eq $stack) { $stack = [pscustomobject]@{} }
    [pscustomobject]@{ State=$state; Stack=$stack }
}

function Save-StackState($State, $Stack) {
    $State | Add-Member -NotePropertyName stack -NotePropertyValue $Stack -Force
    $State | Add-Member -NotePropertyName updatedAt -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    Write-JsonFile $script:StatePath $State
}

function Set-StackComponentState($StackState, [string]$Id, $Entry, [string]$Path, [bool]$Adopted, $Previous, $Extra) {
    $existingRecord = Get-OptionalProperty $StackState.Stack $Id
    if ($null -eq $Previous -and $existingRecord) { $Previous = Get-OptionalProperty $existingRecord 'previous' }
    $record = [ordered]@{
        version=[string]$Entry.version; tag=[string]$Entry.tag; sha256=([string]$Entry.sha256).ToUpperInvariant(); status=[string]$Entry.status
        path=$Path; adopted=$Adopted; untested=([string]$Entry.status -ne 'tested')
        installedAt=(Get-Date).ToUniversalTime().ToString('o'); previous=$Previous
    }
    if ($Extra) { foreach ($key in @($Extra.Keys)) { $record[$key] = $Extra[$key] } }
    $StackState.Stack | Add-Member -NotePropertyName $Id -NotePropertyValue ([pscustomobject]$record) -Force
    Save-StackState $StackState.State $StackState.Stack
}

function Remove-ManagedStackFiles {
    # Deletes only files Setup itself placed (adopted=false) whose bytes still match the record.
    # These live outside the install root by design, so the containment helper is not used.
    $state = Get-State
    $stack = if ($state) { Get-OptionalProperty $state 'stack' } else { $null }
    if (-not $stack) { Write-Warn 'No managed stack files are recorded.'; return }
    foreach ($property in $stack.PSObject.Properties) {
        $record = $property.Value
        $kind = [string](Get-OptionalProperty $record 'kind')
        # Archives and config edits live inside the install root; Remove-StackTree and
        # Invoke-StackRollback own those. This loop only reaches files placed elsewhere.
        if ($kind -and $kind -ne 'managed-file') { continue }
        $path = [string](Get-OptionalProperty $record 'path')
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        if ((Get-FullPath $path).StartsWith(((Get-FullPath $InstallRoot).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ([bool](Get-OptionalProperty $record 'adopted')) { Write-Warn "$path was adopted, not placed by Setup; leaving it in place."; continue }
        $expected = ([string](Get-OptionalProperty $record 'sha256')).ToUpperInvariant()
        if ((Get-FileSha256 $path) -ne $expected) { Write-Warn "$path no longer matches what Setup placed; leaving it in place."; continue }
        [IO.File]::Delete($path)
        Write-Ok "Removed managed file $path"
    }
}

function Clear-StackDownloadRoot {
    if (-not (Test-Path -LiteralPath $script:StackDownloadRoot)) { return }
    Get-ChildItem -LiteralPath $script:StackDownloadRoot -Force | ForEach-Object {
        Remove-ExactOwnedPath $script:StackDownloadRoot $_.FullName
    }
}

function Get-PreservedTrackerPaths {
    # Packs, saves and settings are things the user added, so a plain Uninstall keeps them.
    $record = Get-OptionalProperty (Get-OptionalProperty (Get-State) 'stack') 'poptracker'
    $root = [string](Get-OptionalProperty $record 'root')
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $kept = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in @(Get-OptionalProperty $record 'preserveRelative')) {
        if (-not $relative) { continue }
        $candidate = Join-Path $root ([string]$relative)
        if (Test-Path -LiteralPath $candidate) { $kept.Add((Get-FullPath $candidate).TrimEnd('\')) }
    }
    @($kept)
}

function Remove-TreeExcept([string]$Root, [string[]]$KeepFull) {
    # Deletes everything under Root except the given full paths and the folders leading
    # to them. Returns $true when Root itself was removed.
    $safe = Assert-ChildPath $InstallRoot $Root
    if (-not (Test-Path -LiteralPath $safe -PathType Container)) { return $true }
    foreach ($item in @(Get-ChildItem -LiteralPath $safe -Force)) {
        $itemFull = (Get-FullPath $item.FullName).TrimEnd('\')
        if ($KeepFull -contains $itemFull) { continue }
        $hasKeptChild = @($KeepFull | Where-Object { $_.StartsWith($itemFull + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if ($hasKeptChild) { Remove-TreeExcept $item.FullName $KeepFull | Out-Null; continue }
        Remove-ExactOwnedPath $safe $item.FullName
    }
    if (@(Get-ChildItem -LiteralPath $safe -Force).Count -eq 0) { [IO.Directory]::Delete($safe); return $true }
    $false
}

function Remove-StackTree {
    # Uninstall owns everything under stack\, except tracker content the user added.
    if (-not (Test-Path -LiteralPath $script:StackRoot)) { return }
    $keep = @()
    if (-not $RemoveTrackerData) { $keep = @(Get-PreservedTrackerPaths) }
    if ($keep.Count -eq 0) { Remove-ExactOwnedPath $InstallRoot $script:StackRoot; return }
    Remove-TreeExcept $script:StackRoot $keep | Out-Null
    foreach ($kept in $keep) {
        if (Test-Path -LiteralPath $kept) { Write-Warn "Kept $kept; rerun Uninstall with -RemoveTrackerData to remove it." }
    }
}

function Select-ManagedVersion($ComponentEntry) {
    # Newest tested version by default. Untested needs -AllowUntested; revoked is always refused.
    $versions = @(Get-OptionalProperty $ComponentEntry 'versions' | Where-Object { $_ })
    if ($ComponentVersion) {
        $requested = $versions | Where-Object { [string]$_.version -eq $ComponentVersion -or [string]$_.tag -eq $ComponentVersion } | Select-Object -First 1
        if (-not $requested) { throw "Version '$ComponentVersion' is not listed for $Component." }
        if ([bool](Get-OptionalProperty $requested 'revoked')) { throw "Version $($requested.version) is revoked: $(Get-OptionalProperty $requested 'revokedReason')" }
        if ([string]$requested.status -ne 'tested' -and -not $AllowUntested) { throw "Version $($requested.version) is untested. Rerun with -AllowUntested to install it anyway." }
        return $requested
    }
    $candidates = @($versions | Where-Object { [string]$_.status -eq 'tested' -and -not [bool](Get-OptionalProperty $_ 'revoked') })
    if ($candidates.Count -eq 0 -and $AllowUntested) {
        $candidates = @($versions | Where-Object { -not [bool](Get-OptionalProperty $_ 'revoked') })
    }
    if ($candidates.Count -eq 0) { throw "No tested, unrevoked version of $Component is listed. Rerun with -AllowUntested to take the newest untested release." }
    $requested = $candidates[0]
    foreach ($candidate in $candidates) {
        if ((Compare-ReleaseVersion ([string]$candidate.version) ([string]$requested.version)) -gt 0) { $requested = $candidate }
    }
    $requested
}

function Show-ComponentHandoff($ComponentEntry, [string]$Path) {
    # Some components are verified here but installed by another program. Say so plainly
    # rather than writing into that program's folders.
    $note = [string](Get-OptionalProperty $ComponentEntry 'handoffNote')
    if (-not $note) { return }
    Write-Warn $note
    Write-Host "[INFO] Verified file: $Path" -ForegroundColor DarkGray
    Write-Host '[INFO] In RPCS3: File > Install Packages/Raps/Edats, then pick that file.' -ForegroundColor DarkGray
    if ($NonInteractive) { return }
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $Path + '"') | Out-Null } catch { }
}

function Install-ManagedFileComponent($ComponentEntry, $Manifest) {
    $displayName = [string](Get-OptionalProperty $ComponentEntry 'displayName')
    $stackState = Get-StackState
    Clear-StackDownloadRoot
    $requested = Select-ManagedVersion $ComponentEntry
    $existing = Get-ManagedFileInfo $Component $ComponentEntry
    $targetPath = if ($existing.Present) { $existing.Path } else { Join-Path $existing.TargetDirectory $existing.FileName }
    if ($existing.Present -and $existing.Sha256 -eq ([string]$requested.sha256).ToUpperInvariant()) {
        Write-Ok "$displayName $($requested.version) is already present at $targetPath; adopted without changes."
        Set-StackComponentState $stackState $Component $requested $targetPath $true $null @{ kind='managed-file' }
        Show-ComponentHandoff $ComponentEntry $targetPath
        return
    }
    if ($existing.Present) {
        $description = if ($existing.Version) { "version $($existing.Version) ($($existing.Status))" } else { 'a file that is not a known release' }
        Write-Warn "$targetPath already contains $description."
        $confirmed = [bool]$ReplaceExisting
        if (-not $confirmed -and -not $NonInteractive) {
            $confirmed = (Read-Host "Replace it with $($requested.version)? A backup is kept under $script:StackRollbackRoot [y/N]") -match '^(?i)y(es)?$'
        }
        if (-not $confirmed) {
            Write-Warn "Nothing was changed. Rerun with -ReplaceExisting to replace it with $($requested.version); a backup is kept under $script:StackRollbackRoot."
            $script:ExitCode = 3
            return
        }
    }
    if ($Component -eq 'rac1-apworld' -and (Get-Process -Name 'Archipelago*' -ErrorAction SilentlyContinue)) {
        Write-Warn 'Archipelago is running; restart the Launcher afterwards so it loads the new apworld.'
    }

    Write-ProgressEvent 'download' 0 "Downloading $displayName $($requested.version) from $($requested.url)"
    $staged = Save-VerifiedDownload ([string]$requested.url) ([string]$requested.sha256) ([int64]$requested.size) (Join-Path $script:StackDownloadRoot ("$Component-" + [string]$requested.tag + '.verified')) $Manifest
    $previous = $null
    if ($existing.Present) {
        New-Item -ItemType Directory -Path $script:StackRollbackRoot -Force | Out-Null
        Get-ChildItem -LiteralPath $script:StackRollbackRoot -File -Filter "$Component.*" | ForEach-Object { Remove-ExactOwnedPath $script:StackRollbackRoot $_.FullName }
        $suffix = if ($existing.Version) { $existing.Version } else { $existing.Sha256.Substring(0, 8).ToLowerInvariant() }
        $backupPath = Join-Path $script:StackRollbackRoot "$Component.$suffix"
        Copy-Item -LiteralPath $existing.Path -Destination $backupPath -Force
        $previous = [pscustomobject]@{ path=$existing.Path; sha256=$existing.Sha256; version=$existing.Version; backupPath=$backupPath }
        Write-Log "Backed up $($existing.Path) to $backupPath"
    }
    Write-ProgressEvent 'install' 90 "Placing $($existing.FileName) into $(Split-Path $targetPath -Parent)"
    New-Item -ItemType Directory -Path (Split-Path $targetPath -Parent) -Force | Out-Null
    Move-Item -LiteralPath $staged -Destination $targetPath -Force
    Set-StackComponentState $stackState $Component $requested $targetPath $false $previous @{ kind='managed-file' }
    Write-ProgressEvent 'done' 100 "$displayName $($requested.version) ready"
    Write-Ok "$displayName $($requested.version) ($($requested.status)) placed at $targetPath"
    if ([string]$requested.status -ne 'tested') { Write-Warn 'This version is untested with the overlay; report problems through the project issue form.' }
    Show-ComponentHandoff $ComponentEntry $targetPath
}

function Install-ManagedArchiveComponent($ComponentEntry, $Manifest) {
    # Portable copy under the install root. A user's own installation is never touched.
    $displayName = [string](Get-OptionalProperty $ComponentEntry 'displayName')
    $installDir = Resolve-StackRelativePath ([string](Get-OptionalProperty $ComponentEntry 'installRelative'))
    $executable = [string](Get-OptionalProperty $ComponentEntry 'executable')
    $portableMarker = [string](Get-OptionalProperty $ComponentEntry 'portableMarker')
    $archiveRoot = [string](Get-OptionalProperty $ComponentEntry 'archiveRoot')
    $preserve = @(Get-OptionalProperty $ComponentEntry 'preserveRelative' | Where-Object { $_ })
    $stackState = Get-StackState
    Clear-StackDownloadRoot
    $requested = Select-ManagedVersion $ComponentEntry
    $targetExe = Join-Path $installDir $executable
    $record = Get-OptionalProperty $stackState.Stack $Component
    $installedVersion = [string](Get-OptionalProperty $record 'version')

    if ((Test-Path -LiteralPath $targetExe -PathType Leaf) -and $installedVersion -eq [string]$requested.version) {
        Write-Ok "$displayName $($requested.version) is already installed at $installDir."
        return
    }
    if (Test-Path -LiteralPath $targetExe -PathType Leaf) {
        $described = if ($installedVersion) { "version $installedVersion" } else { 'an unrecognised copy' }
        Write-Warn "$installDir already holds $described."
        $confirmed = [bool]$ReplaceExisting
        if (-not $confirmed -and -not $NonInteractive) {
            $confirmed = (Read-Host "Replace it with $($requested.version)? Packs and saves are kept [y/N]") -match '^(?i)y(es)?$'
        }
        if (-not $confirmed) {
            Write-Warn "Nothing was changed. Rerun with -ReplaceExisting to move to $($requested.version)."
            $script:ExitCode = 3
            return
        }
    }

    Write-ProgressEvent 'download' 0 "Downloading $displayName $($requested.version) from $($requested.url)"
    $archive = Save-VerifiedDownload ([string]$requested.url) ([string]$requested.sha256) ([int64]$requested.size) (Join-Path $script:StackDownloadRoot ("$Component-" + [string]$requested.tag + '.zip')) $Manifest
    $expandRoot = Join-Path $script:StackDownloadRoot ("$Component-expand-" + [guid]::NewGuid().ToString('N'))
    try {
        Write-ProgressEvent 'install' 70 "Expanding $displayName $($requested.version)"
        New-Item -ItemType Directory -Path $expandRoot -Force | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $expandRoot -Force
        $source = $expandRoot
        if ($archiveRoot) {
            $nested = Join-Path $expandRoot $archiveRoot
            if (-not (Test-Path -LiteralPath $nested -PathType Container)) { throw "The archive does not contain the expected '$archiveRoot' folder." }
            $source = $nested
        }
        if (-not (Test-Path -LiteralPath (Join-Path $source $executable) -PathType Leaf)) { throw "The archive does not contain $executable." }

        # Replace application files, keep anything the user added.
        if (Test-Path -LiteralPath $installDir -PathType Container) {
            $keep = [System.Collections.Generic.List[string]]::new()
            foreach ($relative in $preserve) {
                $candidate = Join-Path $installDir ([string]$relative)
                if (Test-Path -LiteralPath $candidate) { $keep.Add((Get-FullPath $candidate).TrimEnd('\')) }
            }
            Remove-TreeExcept $installDir @($keep) | Out-Null
        }
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        Copy-DirectoryContents $source $installDir

        if ($portableMarker) {
            $markerPath = Join-Path $installDir $portableMarker
            if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
                Set-Content -LiteralPath $markerPath -Value 'Managed portable copy placed by RandOverlay Setup. Packs and settings stay in this folder.' -Encoding ASCII
            }
        }
    } finally {
        if (Test-Path -LiteralPath $expandRoot) { Remove-ExactOwnedPath $script:StackDownloadRoot $expandRoot }
        if (Test-Path -LiteralPath $archive) { Remove-ExactOwnedPath $script:StackDownloadRoot $archive }
    }

    Set-StackComponentState $stackState $Component $requested $targetExe $false $null @{ kind='managed-archive'; root=$installDir; preserveRelative=@($preserve) }
    Write-ProgressEvent 'done' 100 "$displayName $($requested.version) ready"
    Write-Ok "$displayName $($requested.version) ($($requested.status)) installed at $installDir"
    if ([string]$requested.status -ne 'tested') { Write-Warn 'This version is untested with the overlay; report problems through the project issue form.' }
    $packsNote = [string](Get-OptionalProperty $ComponentEntry 'packsNote')
    if ($packsNote) {
        Write-Host "[INFO] $packsNote" -ForegroundColor DarkGray
        $packsUrl = [string](Get-OptionalProperty $ComponentEntry 'packsUrl')
        if ($packsUrl) { Write-Hyperlink 'Community tracker packs' $packsUrl }
    }
}

function Invoke-InstallStackComponent {
    # Every managed component enters here; the manifest's kind decides how it is installed.
    if (-not $Component) { throw 'Name the component with -Component, for example -Component rac1-apworld.' }
    $manifest = Get-StackManifest
    if (-not $manifest) { throw 'No stack manifest is available. Run Setup from a release package, or Repair first.' }
    $componentEntry = Get-StackComponent $manifest $Component
    if (-not $componentEntry) { throw "Component '$Component' is not listed in this manifest." }
    switch ([string](Get-OptionalProperty $componentEntry 'kind')) {
        'managed-file' { Install-ManagedFileComponent $componentEntry $manifest }
        'managed-archive' { Install-ManagedArchiveComponent $componentEntry $manifest }
        default { throw "Component '$Component' is detected only; Setup does not install it." }
    }
}

function Invoke-StackRollback {
    # Restores the one backup this tool keeps per component, after verifying its bytes.
    if (-not $Component) { throw 'Name the component with -Component, for example -Component rac1-apworld.' }
    $stackState = Get-StackState
    $record = Get-OptionalProperty $stackState.Stack $Component
    if (-not $record) { throw "No $Component change is recorded; nothing to roll back." }
    if ([string](Get-OptionalProperty $record 'kind') -eq 'config-edit') { Test-EmulatorsStopped }
    $previous = Get-OptionalProperty $record 'previous'
    if (-not $previous) { throw "No previous $Component state is recorded; nothing to roll back." }
    $backupPath = [string](Get-OptionalProperty $previous 'backupPath')
    if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) { throw "Rollback file is missing: $backupPath" }
    $expected = ([string](Get-OptionalProperty $previous 'sha256')).ToUpperInvariant()
    if ((Get-FileSha256 $backupPath) -ne $expected) { throw "Rollback file failed verification: $backupPath" }
    $targetPath = [string](Get-OptionalProperty $record 'path')
    if (-not $targetPath) { $targetPath = [string](Get-OptionalProperty $previous 'path') }
    Copy-Item -LiteralPath $backupPath -Destination $targetPath -Force
    $restored = [ordered]@{
        version=(Get-OptionalProperty $previous 'version'); tag=$null; sha256=$expected; status='rolled-back'
        path=$targetPath; adopted=$true; untested=$true; installedAt=(Get-Date).ToUniversalTime().ToString('o'); previous=$null
    }
    $stackState.Stack | Add-Member -NotePropertyName $Component -NotePropertyValue ([pscustomobject]$restored) -Force
    Save-StackState $stackState.State $stackState.Stack
    Write-Ok "$Component restored from $backupPath to $targetPath"
}

function Invoke-RefreshManifest {
    # User-initiated only. Downloads stack-manifest.json and SHA256SUMS.txt from the project's own
    # GitHub release (or explicit -ManifestUrl/-ChecksumUrl), verifies, validates, then saves.
    $current = Get-StackManifest
    if (-not $current) { throw 'No embedded stack manifest is available to validate origins against.' }
    $manifestSource = $ManifestUrl
    $checksumSource = $ChecksumUrl
    if (-not $manifestSource -or -not $checksumSource) {
        Write-Step 'Checking official GitHub Releases for a newer stack manifest'
        $release = Invoke-RestMethod -Uri "$script:RepoApi/releases/latest" -Headers @{ 'User-Agent'='RandOverlay-Setup' }
        $manifestAsset = @($release.assets | Where-Object { $_.name -eq 'stack-manifest.json' }) | Select-Object -First 1
        $sumAsset = @($release.assets | Where-Object { $_.name -eq 'SHA256SUMS.txt' }) | Select-Object -First 1
        if (-not $manifestAsset -or -not $sumAsset) { throw 'The latest release does not publish stack-manifest.json and SHA256SUMS.txt.' }
        $manifestSource = [string]$manifestAsset.browser_download_url
        $checksumSource = [string]$sumAsset.browser_download_url
    }
    foreach ($url in @($manifestSource, $checksumSource)) {
        if (-not (Test-ManifestOrigin $url $current)) { throw "Refresh origin is not allowlisted: $url" }
    }
    $tempParent = Assert-SafeRoot ([IO.Path]::GetTempPath())
    $temp = Join-Path $tempParent ('RandOverlayManifest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        $manifestFile = Join-Path $temp 'stack-manifest.json'
        $sumsFile = Join-Path $temp 'SHA256SUMS.txt'
        Write-ProgressEvent 'download' 20 'Downloading stack-manifest.json'
        Receive-WebFile $manifestSource $manifestFile 1048576 0 | Out-Null
        Receive-WebFile $checksumSource $sumsFile 65536 0 | Out-Null
        Write-ProgressEvent 'verify' 60 'Verifying the manifest against SHA256SUMS.txt'
        $line = Get-Content -LiteralPath $sumsFile | Where-Object { $_ -match '\sstack-manifest\.json$' } | Select-Object -First 1
        if (-not $line) { throw 'SHA256SUMS.txt does not list stack-manifest.json.' }
        $actual = Get-FileSha256 $manifestFile
        if ($actual -ne (($line -split '\s+')[0].ToUpperInvariant())) { throw 'Downloaded stack manifest failed SHA-256 verification.' }
        $candidate = Read-JsonFile $manifestFile
        Test-StackManifestObject $candidate | Out-Null
        New-Item -ItemType Directory -Path $script:StackRoot -Force | Out-Null
        Copy-Item -LiteralPath $manifestFile -Destination (Join-Path $script:StackRoot 'manifest.json') -Force
        Write-JsonFile (Join-Path $script:StackRoot 'manifest.source.json') ([ordered]@{ url=$manifestSource; sha256=$actual; fetchedAt=(Get-Date).ToUniversalTime().ToString('o'); manifestVersion=[string](Get-OptionalProperty $candidate 'manifestVersion') })
        Write-ProgressEvent 'done' 100 'Stack manifest saved'
        Write-Ok "Stack manifest $(Get-OptionalProperty $candidate 'manifestVersion') verified and saved."
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-ExactOwnedPath $tempParent $temp }
    }
}

function Invoke-ConfigureRpcs3Network {
    # The only place this tool writes to another program's configuration, and only when
    # asked for by name. config.yml is backed up and the backup is verified before the edit,
    # and only the 'Internet enabled:' line changes.
    Test-EmulatorsStopped
    $manifest = $null
    try { $manifest = Get-StackManifest } catch { }
    $rpcs3 = Get-Rpcs3Info (Get-StackComponent $manifest 'rpcs3')
    if (-not $rpcs3.Present) {
        Write-Fail 'RPCS3 was not found, so there is no configuration to change.'
        Write-Hyperlink 'Official page' 'https://rpcs3.net/download'
        $script:ExitCode = 2
        return
    }
    $configPath = $null
    foreach ($candidate in @((Join-Path $rpcs3.Root 'config\config.yml'), (Join-Path $rpcs3.Root 'config.yml'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $configPath = $candidate; break }
    }
    if (-not $configPath) {
        Write-Fail "No config.yml under $($rpcs3.Root); start RPCS3 once so it writes one, then rerun."
        $script:ExitCode = 2
        return
    }

    $desired = if ($NetworkStatus) { $NetworkStatus } else { 'Connected' }
    $pattern = '(?m)^([ \t]*Internet enabled:[ \t]*)(\S+)([ \t]*\r?)$'
    $originalBytes = [IO.File]::ReadAllBytes($configPath)
    $text = [IO.File]::ReadAllText($configPath)
    $found = [Regex]::Matches($text, $pattern)
    if ($found.Count -ne 1) {
        Write-Fail "config.yml has $($found.Count) 'Internet enabled:' lines; change it in RPCS3 Configuration > System > Network instead."
        $script:ExitCode = 2
        return
    }
    $current = $found[0].Groups[2].Value
    if ($current -eq $desired) { Write-Ok "RPCS3 network status is already $desired; nothing was changed."; return }

    $stackState = Get-StackState
    Write-Step "Setting RPCS3 network status to $desired"
    $originalHash = Get-FileSha256 $configPath
    New-Item -ItemType Directory -Path $script:StackRollbackRoot -Force | Out-Null
    $backupPath = Join-Path $script:StackRollbackRoot ('rpcs3-config.yml.' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))
    [IO.File]::WriteAllBytes($backupPath, $originalBytes)
    if ((Get-FileSha256 $backupPath) -ne $originalHash) { throw "Backup verification failed for $backupPath; nothing was changed." }
    Write-Ok "Backed up config.yml to $backupPath"

    [IO.File]::WriteAllText($configPath, [Regex]::Replace($text, $pattern, ('${1}' + $desired + '${3}')))
    $verify = [Regex]::Matches([IO.File]::ReadAllText($configPath), $pattern)
    if ($verify.Count -ne 1 -or $verify[0].Groups[2].Value -ne $desired) {
        [IO.File]::WriteAllBytes($configPath, $originalBytes)
        throw 'Rewriting config.yml did not take effect; the original file was put back.'
    }

    $stackState.Stack | Add-Member -NotePropertyName 'rpcs3-network' -NotePropertyValue ([pscustomobject][ordered]@{
        kind='config-edit'; version=$desired; tag=$null; sha256=$originalHash; status='configured'
        path=$configPath; adopted=$true; untested=$false
        installedAt=(Get-Date).ToUniversalTime().ToString('o')
        previous=[pscustomobject]@{ path=$configPath; sha256=$originalHash; version=$current; backupPath=$backupPath }
    }) -Force
    Save-StackState $stackState.State $stackState.Stack
    Write-Ok "RPCS3 network status set to $desired; it was $current."
    Write-Host "[INFO] Undo with -Action StackRollback -Component rpcs3-network" -ForegroundColor DarkGray
}

function Get-LaunchTargets {
    # Everything this tool can start. Only the managed PopTracker copy is ever downloaded;
    # Archipelago, RPCS3 and Lawrence are whatever you installed yourself.
    $manifest = $null
    try { $manifest = Get-StackManifest } catch { }
    $targets = [ordered]@{}
    $archipelago = Get-ArchipelagoInfo
    if ($archipelago.Present) {
        $targets['archipelago'] = [pscustomobject]@{ Name='Archipelago Launcher'; Path=$archipelago.LauncherPath
            Note='To host a multiworld on this machine use Generate, then Host, in the Launcher. Nothing here writes to your Players, output or host.yaml files.' }
    }
    $rpcs3 = Get-Rpcs3Info (Get-StackComponent $manifest 'rpcs3')
    if ($rpcs3.Present) { $targets['rpcs3'] = [pscustomobject]@{ Name='RPCS3'; Path=$rpcs3.Path; Note=$null } }
    $popTracker = Get-PopTrackerInfo (Get-StackComponent $manifest 'poptracker')
    if ($popTracker.Present) {
        $targets['poptracker'] = [pscustomobject]@{ Name='PopTracker'; Path=$popTracker.Path
            Note='No Ratchet & Clank tracker pack ships with this tool; add one to the packs folder yourself.' }
    }
    $lawrence = Get-LawrencePath
    if ($lawrence) {
        $targets['lawrence'] = [pscustomobject]@{ Name='Lawrence server'; Path=$lawrence
            Note='Self-hosting only. In the multiplayer client use Direct Connect to 127.0.0.1.' }
    }
    $targets
}

function Invoke-Launch {
    # Starting another program is an interactive convenience, never something a script does.
    if ($NonInteractive) { throw 'Launch is interactive; it does not run under -NonInteractive.' }
    $targets = Get-LaunchTargets
    if ($targets.Count -eq 0) {
        Write-Fail 'Nothing to launch: none of Archipelago, RPCS3, PopTracker or Lawrence was found.'
        $script:ExitCode = 2
        return
    }
    $keys = @($targets.Keys)
    $chosen = $Target
    if (-not $chosen) {
        Write-Step 'Launch or host'
        for ($index = 0; $index -lt $keys.Count; $index++) {
            Write-Host ("[{0}] {1} - {2}" -f ($index + 1), $targets[$keys[$index]].Name, $targets[$keys[$index]].Path)
        }
        $selection = 0
        if (-not [int]::TryParse((Read-Host 'Selection').Trim(), [ref]$selection) -or $selection -lt 1 -or $selection -gt $keys.Count) {
            Write-Warn 'Unknown selection.'
            return
        }
        $chosen = $keys[$selection - 1]
    }
    if (-not $targets.Contains($chosen)) {
        Write-Fail "$chosen was not found on this machine."
        $script:ExitCode = 2
        return
    }
    $entry = $targets[$chosen]
    if ($entry.Note) { Write-Host "[INFO] $($entry.Note)" -ForegroundColor DarkGray }
    Start-Process -FilePath $entry.Path -WorkingDirectory (Split-Path $entry.Path -Parent) | Out-Null
    Write-Ok "Started $($entry.Name)."
}

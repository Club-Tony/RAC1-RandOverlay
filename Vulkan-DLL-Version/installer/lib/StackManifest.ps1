# -------------------------------------------------------------------------
# RAC1 stack, part 1 of 3: manifest loading, validation and verified download.
# Dot-sourced by Setup-RandOverlay.ps1; every $script: variable and parameter
# it reads belongs to that script, so this file is never run on its own.
# -------------------------------------------------------------------------

function Get-StackManifestCandidates {
    # Highest priority first: explicit override, refreshed copy, embedded payload copy.
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($ManifestPath) { $candidates.Add((Get-FullPath $ManifestPath)) }
    $candidates.Add((Join-Path $script:StackRoot 'manifest.json'))
    try { $candidates.Add((Join-Path (Resolve-PayloadRoot) 'stack-manifest.json')) } catch { }
    @($candidates)
}

function Test-StackManifestObject($Manifest) {
    # Throws on any structural problem so a bad manifest can never drive a download.
    if ($null -eq $Manifest) { throw 'Stack manifest is empty.' }
    if ((Get-OptionalProperty $Manifest 'schemaVersion') -ne 1) { throw "Unsupported stack manifest schemaVersion: $(Get-OptionalProperty $Manifest 'schemaVersion')" }
    $components = Get-OptionalProperty $Manifest 'components'
    if ($null -eq $components) { throw 'Stack manifest has no components.' }
    $allowlist = @(Get-OptionalProperty $Manifest 'originAllowlist' | Where-Object { $_ })
    if ($allowlist.Count -eq 0) { throw 'Stack manifest has no originAllowlist.' }
    foreach ($property in $components.PSObject.Properties) {
        $component = $property.Value
        $kind = [string](Get-OptionalProperty $component 'kind')
        if (@('managed-file','managed-archive') -notcontains $kind) { continue }
        if ($kind -eq 'managed-file' -and -not (Get-OptionalProperty $component 'fileName')) { throw "Managed component $($property.Name) has no fileName." }
        if ($kind -eq 'managed-archive') {
            foreach ($required in @('installRelative','executable')) {
                if (-not (Get-OptionalProperty $component $required)) { throw "Managed archive $($property.Name) has no '$required'." }
            }
        }
        $relative = [string](Get-OptionalProperty $component 'installRelative')
        if ($relative) { Test-StackRelativePath $relative $property.Name | Out-Null }
        $entries = @(Get-OptionalProperty $component 'versions' | Where-Object { $_ })
        if ($entries.Count -eq 0) { throw "Managed component $($property.Name) has no versions." }
        foreach ($entry in $entries) {
            foreach ($required in @('version','tag','status','url','sha256','size')) {
                if ($null -eq (Get-OptionalProperty $entry $required)) { throw "Component $($property.Name) has a version entry without '$required'." }
            }
            if ([string]$entry.sha256 -notmatch '^[0-9A-Fa-f]{64}$') { throw "Component $($property.Name) $($entry.version) has an invalid sha256." }
            if ([int64]$entry.size -le 0) { throw "Component $($property.Name) $($entry.version) has an invalid size." }
            if (@('tested','untested') -notcontains [string]$entry.status) { throw "Component $($property.Name) $($entry.version) has an unknown status '$($entry.status)'." }
            ConvertTo-ComparableVersion ([string]$entry.version) | Out-Null
        }
    }
    $true
}

function Test-StackRelativePath([string]$Relative, [string]$ComponentName) {
    # A managed component may only be placed inside the install root, so the manifest
    # may not name an absolute path, a drive, a UNC share or a parent traversal.
    if ([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)' -or $Relative -match ':') {
        throw "Component $ComponentName has an unsafe installRelative path: $Relative"
    }
    $true
}

function Resolve-StackRelativePath([string]$Relative) {
    # Turns a manifest installRelative value into a full path under the install root,
    # and refuses anything that would escape it.
    if (-not $Relative) { throw 'Component has no installRelative path.' }
    Test-StackRelativePath $Relative 'component' | Out-Null
    Assert-ChildPath $InstallRoot (Join-Path $InstallRoot $Relative)
}

function Get-StackManifest {
    foreach ($candidate in Get-StackManifestCandidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $manifest = Read-JsonFile $candidate
        Test-StackManifestObject $manifest | Out-Null
        $manifest | Add-Member -NotePropertyName sourcePath -NotePropertyValue $candidate -Force
        return $manifest
    }
    $null
}

function Get-StackComponent($Manifest, [string]$Id) {
    if ($null -eq $Manifest) { return $null }
    Get-OptionalProperty (Get-OptionalProperty $Manifest 'components') $Id
}

function Test-ManifestOrigin([string]$Url, $Manifest) {
    # Only https hosts named in the verified manifest, or file:// when a test says so.
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -eq 'file') { return [bool]$AllowLocalOrigins }
    if ($uri.Scheme -ne 'https') { return $false }
    $allowlist = @(Get-OptionalProperty $Manifest 'originAllowlist' | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $allowlist -contains $uri.Host.ToLowerInvariant()
}

function Receive-WebFile([string]$Url, [string]$Destination, [int64]$MaxBytes, [int64]$ExpectedBytes) {
    # Streams a URL to a file. Supports https:// and file:// (the latter only for tests).
    # Aborts once MaxBytes is exceeded; reports progress against ExpectedBytes when known.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $request = [Net.WebRequest]::Create($Url)
    if ($request -is [Net.HttpWebRequest]) { $request.UserAgent = 'RandOverlay-Setup'; $request.AllowAutoRedirect = $true; $request.Timeout = 60000 }
    $response = $request.GetResponse()
    try {
        $sourceStream = $response.GetResponseStream()
        $targetStream = [IO.File]::Create($Destination)
        try {
            $buffer = New-Object byte[] 65536
            [int64]$total = 0
            $nextReport = 10
            while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $total += $read
                if ($MaxBytes -gt 0 -and $total -gt $MaxBytes) { throw "Download exceeded $MaxBytes bytes." }
                $targetStream.Write($buffer, 0, $read)
                if ($ExpectedBytes -gt 0) {
                    $percent = [int][Math]::Min(100, [Math]::Floor(($total * 100) / $ExpectedBytes))
                    if ($percent -ge $nextReport) { Write-ProgressEvent 'download' $percent "Downloaded $total of $ExpectedBytes bytes"; $nextReport = $percent + 10 }
                }
            }
        } finally { $targetStream.Dispose(); $sourceStream.Dispose() }
    } finally { $response.Close() }
    $total
}

function Save-VerifiedDownload([string]$Url, [string]$Sha256, [int64]$Size, [string]$Destination, $Manifest) {
    # Downloads to a temp file under stack\downloads, checks size and SHA-256, then moves it
    # to Destination. Nothing outside stack\downloads is touched unless verification passed.
    if (-not (Test-ManifestOrigin $Url $Manifest)) { throw "Download origin is not allowlisted: $Url" }
    New-Item -ItemType Directory -Path $script:StackDownloadRoot -Force | Out-Null
    $temp = Join-Path $script:StackDownloadRoot ([guid]::NewGuid().ToString('N') + '.part')
    Write-Log "Download $Url (expected $Size bytes, sha256 $Sha256)"
    try {
        Receive-WebFile $Url $temp $Size $Size | Out-Null
        $actualSize = (Get-Item -LiteralPath $temp).Length
        if ($actualSize -ne $Size) { throw "Download size mismatch: expected $Size bytes, got $actualSize." }
        $actualHash = Get-FileSha256 $temp
        if ($actualHash -ne $Sha256.ToUpperInvariant()) { throw "Download SHA-256 mismatch: expected $($Sha256.ToUpperInvariant()), got $actualHash." }
        $parent = Split-Path $Destination -Parent
        if ($parent) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
        Write-Log "Verified download placed at $Destination"
        $Destination
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-ExactOwnedPath $script:StackDownloadRoot $temp }
    }
}

function Get-VersionCompatibility([string]$Version, $Compatible) {
    # 'unknown', 'tested', 'compatible', 'too-old' or 'too-new' against a { min, maxExclusive, tested[] } block.
    if (-not $Version) { return 'unknown' }
    try { ConvertTo-ComparableVersion $Version | Out-Null } catch { return 'unknown' }
    if ($null -eq $Compatible) { return 'unknown' }
    foreach ($tested in @(Get-OptionalProperty $Compatible 'tested')) {
        if ($null -eq $tested -or [string]$tested -eq '') { continue }
        if ((Compare-ReleaseVersion $Version ([string]$tested)) -eq 0) { return 'tested' }
    }
    $min = [string](Get-OptionalProperty $Compatible 'min')
    $maxExclusive = [string](Get-OptionalProperty $Compatible 'maxExclusive')
    if ($min -and (Compare-ReleaseVersion $Version $min) -lt 0) { return 'too-old' }
    if ($maxExclusive -and (Compare-ReleaseVersion $Version $maxExclusive) -ge 0) { return 'too-new' }
    'compatible'
}

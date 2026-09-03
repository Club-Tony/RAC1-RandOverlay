[CmdletBinding()]
param(
    [ValidateSet('Interactive','Install','Status','Repair','Configure','CheckForUpdates','Uninstall','Preflight','InstallStackComponent','StackRollback','RefreshManifest','ConfigureRpcs3Network','Launch')]
    [string]$Action = 'Interactive',
    [string[]]$Games,
    [ValidateSet('RAC1','RAC2','RAC3')][string]$ActiveGame,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'RandOverlay'),
    [string]$PayloadRoot,
    [string]$RegistryPath = 'HKCU:\SOFTWARE\Khronos\Vulkan\ImplicitLayers',
    [string]$ArchipelagoRoot,
    [string]$RPCS3Path,
    [string]$PCSX2Path,
    [string]$LawrencePath,
    [string]$VulkanLoaderPath,
    [switch]$SkipPrerequisiteChecks,
    [switch]$NonInteractive,
    [switch]$Json,
    [switch]$ConfirmUpdate,
    [switch]$KeepConfig,
    [switch]$LoadOnly,
    [string]$Component,
    [string]$ComponentVersion,
    [string]$ManifestPath,
    [string]$ManifestUrl,
    [string]$ChecksumUrl,
    [string[]]$UninstallRegistryRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'),
    [switch]$AllowUntested,
    [switch]$ReplaceExisting,
    [switch]$AllowLocalOrigins,
    [switch]$RemoveManagedStack,
    [switch]$RemoveTrackerData,
    [ValidateSet('Connected','Disconnected')][string]$NetworkStatus,
    [ValidateSet('archipelago','rpcs3','poptracker','lawrence')][string]$Target
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Exit codes:
#   0  success (including an interactive "Save and exit")
#   1  unhandled error
#   2  required prerequisites are missing
#   3  an action needs explicit confirmation (InstallStackComponent over an unknown file or an
#      existing managed copy without -ReplaceExisting)
#   9  bootstrapper payload failure (set by the BAT/EXE wrappers, never here)
# -LoadOnly defines every function and script variable without running an
# action, so a front-end or test can dot-source this file:
#   . .\Setup-RandOverlay.ps1 -LoadOnly -InstallRoot X -RegistryPath Y
$script:ExitCode = 0
$script:LogEnabled = $true
$script:LogRoot = $null
$script:LogPath = $null
$script:ProgressCallback = $null

if (-not $LoadOnly) { try { [Console]::Title = 'RAC RandOverlay Setup' } catch { } }

$script:LayerName = 'VK_LAYER_RANDOVERLAY_overlay'
$script:RepoApi = 'https://api.github.com/repos/Club-Tony/RAC1-RandOverlay'
$script:GameCatalog = [ordered]@{
    RAC1 = [pscustomobject]@{ Name='Ratchet & Clank 1'; Emulator='RPCS3'; Client='Ratchet & Clank Client'; Apworld='RAC1.apworld'; Url='https://rpcs3.net/download' }
    RAC2 = [pscustomobject]@{ Name='Ratchet & Clank 2'; Emulator='PCSX2'; Client='Ratchet & Clank 2 Client'; Apworld='rac2.apworld'; Url='https://pcsx2.net/downloads/' }
    RAC3 = [pscustomobject]@{ Name='Ratchet & Clank 3'; Emulator='PCSX2'; Client='Ratchet and Clank 3 Client'; Apworld='rac3.apworld'; Url='https://pcsx2.net/downloads/' }
}
# The only packages Setup may install automatically, keyed by the short name shown in menus.
# Every other dependency is remediated through its official download page.
$script:WinGetPackages = [ordered]@{ PCSX2 = 'PCSX2Team.PCSX2' }
$script:AutoInstallAllowlist = @($script:WinGetPackages.Values)

function Protect-LogText([string]$Text) {
    # Setup logs stay local, but they should still not carry the account name verbatim.
    if ($Text -and $env:USERPROFILE) { return $Text.Replace($env:USERPROFILE, '%USERPROFILE%') }
    $Text
}

function Write-Log([string]$Message, [string]$Level = 'INFO') {
    # Append-only diagnostics under <InstallRoot>\logs; the newest five files are kept.
    # Logging never fails an action: every error here is swallowed on purpose.
    if (-not $script:LogEnabled -or -not $script:LogRoot) { return }
    try {
        if (-not $script:LogPath) {
            New-Item -ItemType Directory -Path $script:LogRoot -Force | Out-Null
            Get-ChildItem -LiteralPath $script:LogRoot -Filter 'setup-*.log' -File |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -Skip 4 |
                ForEach-Object { Remove-ExactOwnedPath $script:LogRoot $_.FullName }
            $script:LogPath = Join-Path $script:LogRoot ('setup-{0}-{1}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'), $PID)
        }
        $line = '{0} [{1}] {2}' -f (Get-Date).ToUniversalTime().ToString('o'), $Level, (Protect-LogText $Message)
        [IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    } catch { }
}

function Write-Step([string]$Message) { Write-Log $Message 'STEP'; Write-Host "`n== $Message ==" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Log $Message 'OK'; Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Log $Message 'WARN'; Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Log $Message 'MISSING'; Write-Host "[MISSING] $Message" -ForegroundColor Red }

function Write-ProgressEvent([string]$Stage, [int]$Percent, [string]$Message) {
    # One structured progress record per install step. A host that set
    # $script:ProgressCallback receives it directly; -Json callers get one
    # compact JSON line; the console gets a short status line.
    Write-Log ('{0}% {1}: {2}' -f $Percent, $Stage, $Message) 'PROGRESS'
    if ($script:ProgressCallback) {
        try { & $script:ProgressCallback $Stage $Percent $Message } catch { }
        return
    }
    if ($Json) {
        [pscustomobject]@{ event='progress'; stage=$Stage; percent=$Percent; message=$Message } | ConvertTo-Json -Compress
        return
    }
    Write-Host ('[{0,3}%] {1}' -f $Percent, $Message) -ForegroundColor DarkGray
}

function ConvertTo-ComparableVersion([string]$Text) {
    # Accepts "0.1.0", "v0.2.1-beta", "1.2.3+build" and rolling forms such as
    # "0.0.42-19909-677e13da". Windows PowerShell has no SemanticVersion type.
    $value = ([string]$Text).Trim()
    if ($value -match '^[vV]\d') { $value = $value.Substring(1) }
    if (-not ($value -match '^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?(?:[-+](.+))?$')) { throw "Unrecognized version: $Text" }
    $numbers = @(1..4 | ForEach-Object { if ($matches[$_]) { [int]$matches[$_] } else { 0 } })
    $suffix = if ($matches[5]) { [string]$matches[5] } else { '' }
    [pscustomobject]@{ Numbers=$numbers; Suffix=$suffix; IsPrerelease=($suffix -ne ''); Text=$value }
}

function Compare-ReleaseVersion([string]$Left, [string]$Right) {
    # Returns -1, 0 or 1. Numeric parts win; a suffixed version sorts below the
    # bare release with the same numbers; two suffixes compare token by token,
    # numerically where both tokens are numbers.
    $a = ConvertTo-ComparableVersion $Left
    $b = ConvertTo-ComparableVersion $Right
    for ($i = 0; $i -lt 4; $i++) {
        if ($a.Numbers[$i] -ne $b.Numbers[$i]) { return [Math]::Sign($a.Numbers[$i] - $b.Numbers[$i]) }
    }
    if ($a.IsPrerelease -ne $b.IsPrerelease) { if ($a.IsPrerelease) { return -1 } else { return 1 } }
    if (-not $a.IsPrerelease) { return 0 }
    $leftTokens = @($a.Suffix -split '[.+-]')
    $rightTokens = @($b.Suffix -split '[.+-]')
    for ($i = 0; $i -lt [Math]::Max($leftTokens.Count, $rightTokens.Count); $i++) {
        if ($i -ge $leftTokens.Count) { return -1 }
        if ($i -ge $rightTokens.Count) { return 1 }
        $leftNumber = 0; $rightNumber = 0
        if ([int]::TryParse($leftTokens[$i], [ref]$leftNumber) -and [int]::TryParse($rightTokens[$i], [ref]$rightNumber)) {
            if ($leftNumber -ne $rightNumber) { return [Math]::Sign($leftNumber - $rightNumber) }
        } else {
            $order = [string]::CompareOrdinal($leftTokens[$i].ToLowerInvariant(), $rightTokens[$i].ToLowerInvariant())
            if ($order -ne 0) { return [Math]::Sign($order) }
        }
    }
    0
}

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
$script:SetupLibRoot = Join-Path $PSScriptRoot 'lib'
$script:InstalledLibRoot = Join-Path $InstallRoot 'lib'
$script:CurrentRoot = Join-Path $InstallRoot 'current'
$script:CachedPayloadRoot = Join-Path $InstallRoot 'package\payload'
$script:RollbackRoot = Join-Path $InstallRoot 'rollback\previous'
$script:LogRoot = Join-Path $InstallRoot 'logs'
$script:StackRoot = Join-Path $InstallRoot 'stack'
$script:StackDownloadRoot = Join-Path $script:StackRoot 'downloads'
$script:StackRollbackRoot = Join-Path $script:StackRoot 'rollback'

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
    $savedLawrence = Get-OptionalProperty $saved 'lawrencePath'
    [ordered]@{
        archipelagoRoot = if ($ArchipelagoRoot) { $ArchipelagoRoot } elseif ($savedArch) { $savedArch } else { 'C:\ProgramData\Archipelago' }
        rpcs3Path = if ($RPCS3Path) { $RPCS3Path } else { $savedRpcs3 }
        pcsx2Path = if ($PCSX2Path) { $PCSX2Path } else { $savedPcsx2 }
        lawrencePath = if ($LawrencePath) { $LawrencePath } else { $savedLawrence }
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
        $pcsx2Package = $script:WinGetPackages.PCSX2
        if (-not $pcsx2 -and (Test-WinGetPackage $pcsx2Package)) { $pcsx2 = "Installed: $pcsx2Package" }
        $results.Add([pscustomobject]@{ Id='pcsx2'; Name='PCSX2 (selected by RAC2/RAC3)'; Required=$true; Ready=[bool]$pcsx2; Detail=$(if($pcsx2){$pcsx2}else{'Not found in known locations'}); Url='https://pcsx2.net/downloads/'; AutoInstall=$pcsx2Package })
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
        $autoInstallLabel = "Install $(@($script:WinGetPackages.Keys) -join '/') with WinGet"
        Write-Host "`n[R] Recheck  [O] Open official page  [P] Set custom path  [I] $autoInstallLabel  [S] Save and exit"
        switch ((Read-Host 'Selection').Trim().ToUpperInvariant()) {
            'R' { continue }
            'O' {
                for ($i=0; $i -lt $missing.Count; $i++) { Write-Host "[$($i+1)] $($missing[$i].Name)" }
                $number = 0
                if ([int]::TryParse((Read-Host 'Dependency number'), [ref]$number) -and $number -ge 1 -and $number -le $missing.Count) { Start-Process $missing[$number-1].Url }
            }
            'I' {
                $autoItem = $missing | Where-Object { $_.AutoInstall -and ($script:AutoInstallAllowlist -contains $_.AutoInstall) } | Select-Object -First 1
                if (-not $autoItem) { Write-Warn 'No missing allowlisted dependency supports automatic installation.'; continue }
                $packageId = [string]$autoItem.AutoInstall
                $packageName = @($script:WinGetPackages.GetEnumerator() | Where-Object { $_.Value -eq $packageId } | ForEach-Object { $_.Key })[0]
                if ((Read-Host "Install $packageName from WinGet? [y/N]") -match '^(?i)y(es)?$') {
                    Write-Log "WinGet install requested: $packageId"
                    & winget.exe install --id $packageId --exact --accept-source-agreements --accept-package-agreements
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

# -------------------------------------------------------------------------
# RAC1 stack: manifest, detection, verified download, managed components.
# Only components the manifest marks managed are ever written by Setup.
# Everything else is detect-only.
#
# The implementation lives in lib\ so each part stays reviewable. The folder
# travels with this script into the release package and into the install root,
# so a released install and a repo checkout run exactly the same code.
# -------------------------------------------------------------------------

foreach ($libName in @('StackManifest.ps1', 'StackDetect.ps1', 'StackActions.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $script:SetupLibRoot $libName) -PathType Leaf)) {
        throw "Installer library file is missing: $(Join-Path $script:SetupLibRoot $libName). Re-extract the release package."
    }
}
. (Join-Path $script:SetupLibRoot 'StackManifest.ps1')
. (Join-Path $script:SetupLibRoot 'StackDetect.ps1')
. (Join-Path $script:SetupLibRoot 'StackActions.ps1')

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

function Copy-SetupToInstallRoot {
    # The installed copy is what Repair, Uninstall and CheckForUpdates run later, so it
    # needs the lib\ folder this script dot-sources. Both travel together or not at all.
    if ((Get-FullPath $PSCommandPath) -eq (Get-FullPath $script:InstalledSetupPath)) { return }
    Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledSetupPath -Force
    if ((Get-FullPath $script:SetupLibRoot) -eq (Get-FullPath $script:InstalledLibRoot)) { return }
    if (Test-Path -LiteralPath $script:InstalledLibRoot) { Remove-ExactOwnedPath $InstallRoot $script:InstalledLibRoot }
    Copy-DirectoryContents $script:SetupLibRoot $script:InstalledLibRoot
}

function Save-PendingPackage([string]$SourcePayload, $Metadata, [string[]]$SelectedGames, [string]$SelectedActive) {
    $oldState = Get-State
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    if ((Get-FullPath $SourcePayload) -ne (Get-FullPath $script:CachedPayloadRoot)) {
        if (Test-Path -LiteralPath $script:CachedPayloadRoot) { Remove-ExactOwnedPath $InstallRoot $script:CachedPayloadRoot }
        Copy-DirectoryContents $SourcePayload $script:CachedPayloadRoot
    }
    Copy-SetupToInstallRoot
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
    Write-ProgressEvent 'install' 60 'Staging verified layer files'
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
    Copy-SetupToInstallRoot
    Write-ProgressEvent 'register' 85 'Registering the Vulkan implicit layer'
    Set-CanonicalRegistration

    $state = [ordered]@{
        schemaVersion=1; status='installed'; installedVersion=[string]$Metadata.version; pendingVersion=$null
        enabledGames=@($SelectedGames); activeGame=$SelectedActive; installRoot=$InstallRoot
        dependencyPaths=(Get-DependencyPaths)
        updatedAt=(Get-Date).ToUniversalTime().ToString('o'); files=@(Get-InstalledFileRecords $script:CurrentRoot)
    }
    Write-JsonFile $script:StatePath $state
    Write-ProgressEvent 'done' 100 'Installation complete'
    Write-Ok "RandOverlay $($Metadata.version) installed for $($SelectedGames -join ', ')"
    Write-Ok "Automatic preset detection enabled; fallback preset: $SelectedActive"
}

function Invoke-Install {
    $selected = Normalize-Games $Games
    $selectedActive = if ($ActiveGame) { $ActiveGame } else { $selected[0] }
    if ($selected -notcontains $selectedActive) { throw 'ActiveGame must be one of the selected Games.' }
    $payload = Resolve-PayloadRoot
    $metadata = Test-Payload $payload
    Write-ProgressEvent 'verify' 10 "Release payload $($metadata.version) verified"
    Save-PendingPackage $payload $metadata $selected $selectedActive
    Write-ProgressEvent 'stage' 25 'Release payload cached for repair'
    if (-not $SkipPrerequisiteChecks) {
        Write-ProgressEvent 'prerequisites' 40 'Checking prerequisites'
        $results = Get-PrerequisiteStatus $selected
        if ($NonInteractive) {
            Show-Prerequisites $results
            if (@($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) {
                Write-Warn 'Progress saved. Install missing prerequisites, then run Repair.'
                $script:ExitCode = 2
                return
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
    $games = if ($health.state) { @(Get-OptionalProperty $health.state 'enabledGames' | Where-Object { $_ }) } else { @() }
    $stack = @(Get-StackStatus (Normalize-Games $games))
    $health | Add-Member -NotePropertyName stack -NotePropertyValue $stack -Force
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
    Show-StackStatus $stack
}

function Invoke-Repair {
    $state = Get-State
    if (-not $state) { throw 'No saved installation exists. Run Install first.' }
    $selected = Normalize-Games @($state.enabledGames)
    if (-not $SkipPrerequisiteChecks) {
        $results = Get-PrerequisiteStatus $selected
        if ($NonInteractive -and @($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) {
            Show-Prerequisites $results
            $script:ExitCode = 2
            return
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
            Write-Warn 'Selected games have missing prerequisites. Nothing was changed.'
            $script:ExitCode = 2
            return
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
    if ($RemoveManagedStack) { Remove-ManagedStackFiles }
    Write-Log "Uninstall starting (KeepConfig=$KeepConfig RemoveManagedStack=$RemoveManagedStack); the logs folder is removed with the install"
    $script:LogEnabled = $false
    Remove-OwnedRegistrations
    if (-not $KeepConfig -and (Test-Path -LiteralPath $script:ConfigPath)) { Remove-ExactOwnedPath $InstallRoot $script:ConfigPath }
    Remove-StackTree
    foreach ($relative in @('current','package','rollback','logs','lib','setup-state.json','Setup-RandOverlay.ps1')) {
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
    $stack = @(Get-StackStatus $selected)
    if ($Json) { [pscustomobject]@{ games=$selected; prerequisites=$results; stack=$stack } | ConvertTo-Json -Depth 8 }
    else { Show-Prerequisites $results; Show-StackStatus $stack }
    if (@($results | Where-Object { $_.Required -and -not $_.Ready }).Count -gt 0) { $script:ExitCode = 2 }
}

function Invoke-CheckForUpdates {
    $state = Get-State
    if (-not $state) { throw 'No installation exists.' }
    Write-Step 'Checking official GitHub Releases'
    $release = Invoke-RestMethod -Uri "$script:RepoApi/releases/latest" -Headers @{ 'User-Agent'='RandOverlay-Setup' }
    $latest = ([string]$release.tag_name).TrimStart('v')
    if ((Compare-ReleaseVersion $latest ([string]$state.installedVersion)) -le 0) { Write-Ok 'Already up to date.'; return }
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
        Write-ProgressEvent 'download' 20 "Downloading $($zipAsset.name)"
        Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -UseBasicParsing
        Invoke-WebRequest -Uri $sumAsset.browser_download_url -OutFile $sums -UseBasicParsing
        Write-ProgressEvent 'verify' 50 'Verifying the download against SHA256SUMS.txt'
        $line = Get-Content -LiteralPath $sums | Where-Object { $_ -match [regex]::Escape($zipAsset.name) } | Select-Object -First 1
        if (-not $line) { throw 'Release checksum does not list the ZIP.' }
        if ((Get-FileSha256 $zip) -ne (($line -split '\s+')[0].ToUpperInvariant())) { throw 'Downloaded ZIP failed SHA-256 verification.' }
        Write-ProgressEvent 'install' 70 "Handing off to the $latest setup"
        $expanded = Join-Path $temp 'expanded'
        Expand-Archive -LiteralPath $zip -DestinationPath $expanded
        $setup = Get-ChildItem -LiteralPath $expanded -Filter 'Setup-RandOverlay.ps1' -Recurse | Select-Object -First 1
        if (-not $setup) { throw 'Downloaded release has no setup script.' }
        $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$setup.FullName,'-Action','Install','-Games',(@($state.enabledGames) -join ','),'-ActiveGame',$state.activeGame,'-InstallRoot',$InstallRoot)
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
    Write-Host '[6] Install RAC1 APWorld  [7] Install PopTracker  [8] Download multiplayer PKG'
    Write-Host '[9] Set RPCS3 network to Connected  [10] Launch or host'
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
        '6' { $script:Component = 'rac1-apworld'; Invoke-InstallStackComponent }
        '7' { $script:Component = 'poptracker'; Invoke-InstallStackComponent }
        '8' { $script:Component = 'rac1-multiplayer'; Invoke-InstallStackComponent }
        '9' { Invoke-ConfigureRpcs3Network }
        '10' { Invoke-Launch }
        default { Write-Warn 'Unknown selection.' }
    }
}

if (-not $LoadOnly) {
    # Read-only actions must not create the install folder just to hold a log.
    if (($Action -eq 'Status' -or $Action -eq 'Preflight') -and -not (Test-Path -LiteralPath $InstallRoot)) { $script:LogEnabled = $false }
    Write-Log ("Action={0} Games={1} ActiveGame={2} InstallRoot={3} NonInteractive={4} Json={5} SkipPrerequisiteChecks={6} Component={7} ComponentVersion={8}" -f `
        $Action, (@($Games) -join ','), $ActiveGame, $InstallRoot, [bool]$NonInteractive, [bool]$Json, [bool]$SkipPrerequisiteChecks, $Component, $ComponentVersion)
    try {
        switch ($Action) {
            'Interactive' { Invoke-Interactive }
            'Install' { Invoke-Install }
            'Status' { Invoke-Status }
            'Repair' { Invoke-Repair }
            'Configure' { Invoke-Configure }
            'CheckForUpdates' { Invoke-CheckForUpdates }
            'Uninstall' { Invoke-Uninstall }
            'Preflight' { Invoke-Preflight }
            'InstallStackComponent' { Invoke-InstallStackComponent }
            'StackRollback' { Invoke-StackRollback }
            'RefreshManifest' { Invoke-RefreshManifest }
            'ConfigureRpcs3Network' { Invoke-ConfigureRpcs3Network }
            'Launch' { Invoke-Launch }
        }
    } catch {
        Write-Log ("Failed: {0}" -f $_.Exception.Message) 'ERROR'
        throw
    }
    Write-Log "Exit code $script:ExitCode"
    if ($script:ExitCode -ne 0) { exit $script:ExitCode }
}

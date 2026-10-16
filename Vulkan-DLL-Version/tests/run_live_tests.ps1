[CmdletBinding()]
param(
    [ValidateSet("all", "validation", "visual", "preflight")]
    [string]$Mode = "all",
    [switch]$KeepArtifacts,
    # Which RandOverlay layer the mock hosts load. Installed uses the copy registered
    # for the current user. Build points the loader at this checkout's
    # build\RandOverlay_layer.dll through a scratch manifest and VK_IMPLICIT_LAYER_PATH,
    # and leaves the Vulkan layer registrations and the installed copy untouched.
    [ValidateSet("Installed", "Build")]
    [string]$LayerSource = "Installed",
    # x64 MinGW-w64 g++. Default: RANDOVERLAY_GCC, then C:\mingw64\bin\g++.exe,
    # then C:\msys64\mingw64\bin\g++.exe, then g++ on PATH.
    [string]$GccPath,
    # Vulkan SDK root. Default: VULKAN_SDK, then C:\VulkanSDK\1.4.341.1.
    [string]$VulkanSdk
)

$ErrorActionPreference = "Stop"
$TestsRoot = $PSScriptRoot
$VulkanRoot = Split-Path $TestsRoot -Parent
$RepoRoot = Split-Path $VulkanRoot -Parent
$BuildRoot = Join-Path $VulkanRoot "build"
$ArtifactRoot = Join-Path $RepoRoot "tests\live\artifacts"
$RunRoot = Join-Path $ArtifactRoot (Get-Date -Format "yyyyMMdd-HHmmss")
$Failures = [System.Collections.Generic.List[string]]::new()
$RandOverlayLayerName = "VK_LAYER_RANDOVERLAY_overlay"
$ObsLayerName = "VK_LAYER_OBS_HOOK"
$LayerManifestTemplate = Join-Path $VulkanRoot "RandOverlay_layer.json.in"
# The layer writes layer_debug.log next to its own DLL.
$BuildLayerDll = Join-Path $BuildRoot "RandOverlay_layer.dll"
$BuildLayerLog = Join-Path $BuildRoot "layer_debug.log"
$BuildLayerManifestPath = $null
# Sampled overlay-band pixels allowed to differ when a scenario expects no overlay.
$IdleBandTolerance = 10

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class RandOverlayTestWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
}
"@

function Write-Pass([string]$Name) { Write-Host "PASS $Name" -ForegroundColor Green }
function Add-Failure([string]$Name, [string]$Message) {
    $Failures.Add("${Name}: $Message") | Out-Null
    Write-Host "FAIL $Name - $Message" -ForegroundColor Red
}

function Test-RequiredPath([string]$Name, [string]$Path, [bool]$Required = $true) {
    $exists = Test-Path -LiteralPath $Path
    $label = if ($exists) { "OK" } elseif ($Required) { "MISSING" } else { "OPTIONAL-MISSING" }
    Write-Host ("[{0}] {1}: {2}" -f $label, $Name, $Path)
    if ($Required -and -not $exists) { $script:Failures.Add("preflight: missing $Name at $Path") | Out-Null }
}

function Get-RegisteredRandOverlayManifestPath {
    $registry = Get-ItemProperty -Path "HKCU:\SOFTWARE\Khronos\Vulkan\ImplicitLayers" -ErrorAction SilentlyContinue
    $registeredPaths = @($registry.PSObject.Properties | Where-Object { $_.Name -like "*.json" } | ForEach-Object { $_.Name })
    foreach ($path in $registeredPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $registeredManifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($registeredManifest.layer.name -ne 'VK_LAYER_RANDOVERLAY_overlay') { continue }
            $libraryPath = [string]$registeredManifest.layer.library_path
            $libraryFullPath = if ([IO.Path]::IsPathRooted($libraryPath)) {
                $libraryPath
            } else {
                Join-Path (Split-Path $path -Parent) $libraryPath
            }
            if (Test-Path -LiteralPath $libraryFullPath -PathType Leaf) { return $path }
        } catch { }
    }
    return $null
}

# --- Toolchain ---------------------------------------------------------------
# Accepts build.bat-style values: a bare command name, or a path without ".exe".
function Resolve-ToolPath([string]$Path) {
    $Path = $Path.Trim().Trim('"')
    if (-not ($Path.Contains('\') -or $Path.Contains('/'))) {
        $command = Get-Command $Path -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Path }
        return $Path
    }
    if (-not [IO.Path]::IsPathRooted($Path)) { $Path = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $Path)) }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -and (Test-Path -LiteralPath "$Path.exe" -PathType Leaf)) { return "$Path.exe" }
    return $Path
}

# An explicit -GccPath or RANDOVERLAY_GCC is authoritative even when missing, so
# preflight reports that path instead of silently using another compiler.
function Resolve-GccPath([string]$Requested) {
    if ($Requested) { return @{ Path = (Resolve-ToolPath $Requested); Source = "-GccPath" } }
    if ($env:RANDOVERLAY_GCC) { return @{ Path = (Resolve-ToolPath $env:RANDOVERLAY_GCC); Source = "RANDOVERLAY_GCC" } }
    foreach ($candidate in @("C:\mingw64\bin\g++.exe", "C:\msys64\mingw64\bin\g++.exe")) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return @{ Path = $candidate; Source = "default" } }
    }
    $onPath = Get-Command "g++" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return @{ Path = $onPath.Path; Source = "PATH" } }
    return @{ Path = "C:\mingw64\bin\g++.exe"; Source = "default" }
}

function Resolve-VulkanSdk([string]$Requested) {
    $source = "default"
    $path = "C:\VulkanSDK\1.4.341.1"
    if ($Requested) { $source = "-VulkanSdk"; $path = $Requested }
    elseif ($env:VULKAN_SDK) { $source = "VULKAN_SDK"; $path = $env:VULKAN_SDK }
    $path = $path.Trim().Trim('"').TrimEnd('\', '/')
    if (-not [IO.Path]::IsPathRooted($path)) { $path = [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location).ProviderPath, $path)) }
    return @{ Path = $path; Source = $source }
}

# gcc/ar/windres from the same directory as g++, honouring a target prefix such
# as x86_64-w64-mingw32- when that variant exists.
function Get-GccSiblingPath([string]$Gpp, [string]$Tool) {
    $directory = [IO.Path]::GetDirectoryName($Gpp)
    if (-not $directory) { return $null }
    $leaf = [IO.Path]::GetFileName($Gpp)
    $prefix = if ($leaf -match '^(?<prefix>.*)g\+\+(\.exe)?$') { $Matches['prefix'] } else { "" }
    foreach ($name in @("$prefix$Tool.exe", "$Tool.exe")) {
        $candidate = [IO.Path]::Combine($directory, $name)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

# What build.bat needs to use the same compiler as the mock hosts (build.bat:17-37).
function Get-ToolchainEnvironment {
    $environment = [ordered]@{ RANDOVERLAY_GCC = $GccPath; VULKAN_SDK = $VulkanSdk }
    $siblings = [ordered]@{ RANDOVERLAY_GCC_C = "gcc"; RANDOVERLAY_AR = "ar"; RANDOVERLAY_WINDRES = "windres" }
    foreach ($entry in $siblings.GetEnumerator()) {
        $sibling = Get-GccSiblingPath $GccPath $entry.Value
        if ($sibling) { $environment[$entry.Key] = $sibling }
    }
    # g++ runs cc1plus, which loads its runtime DLLs from the compiler's own bin
    # folder. MSYS2 does not put that folder on PATH, so put it first here.
    if ([IO.Path]::IsPathRooted($GccPath)) {
        $environment["PATH"] = [IO.Path]::GetDirectoryName($GccPath) + [IO.Path]::PathSeparator + $env:PATH
    }
    return $environment
}

# Sets variables for the child processes started by $Action only, then restores
# the parent's values (or their absence).
function Invoke-WithEnvironment([System.Collections.IDictionary]$Environment, [scriptblock]$Action) {
    $saved = @{}
    foreach ($name in @($Environment.Keys)) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], "Process")
    }
    try {
        & $Action
    } finally {
        foreach ($name in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($name, $saved[$name], "Process") }
    }
}

# --- Build-layer source ------------------------------------------------------
function Get-BuildLayerManifestText([string]$TemplateText, [string]$LibraryPath) {
    $token = '"@RANDOVERLAY_LIBRARY_PATH@"'
    if (-not $TemplateText.Contains($token)) { throw "layer manifest template has no $token placeholder" }
    return $TemplateText.Replace($token, (ConvertTo-Json -InputObject $LibraryPath -Compress))
}

function Assert-BuildLayerManifest([string]$ManifestText, [string]$LibraryPath) {
    $manifest = $ManifestText | ConvertFrom-Json
    if ($manifest.layer.name -cne $RandOverlayLayerName) { throw "rendered manifest names layer '$($manifest.layer.name)'" }
    if ($manifest.layer.library_path -cne $LibraryPath) { throw "rendered manifest library_path is '$($manifest.layer.library_path)', not '$LibraryPath'" }
    if ([string]$manifest.layer.disable_environment.DISABLE_RANDOVERLAY -ne "1") { throw "rendered manifest lost disable_environment" }
}

# Renders the scratch manifest the Build scenarios hand to VK_IMPLICIT_LAYER_PATH.
function Initialize-BuildLayerManifest {
    if (-not (Test-Path -LiteralPath $BuildLayerDll -PathType Leaf)) { throw "build layer DLL not found at $BuildLayerDll" }
    $libraryPath = [IO.Path]::GetFullPath($BuildLayerDll)
    $text = Get-BuildLayerManifestText (Get-Content -LiteralPath $LayerManifestTemplate -Raw) $libraryPath
    Assert-BuildLayerManifest $text $libraryPath
    $manifestPath = Join-Path $RunRoot "RandOverlay_layer.json"
    if ($manifestPath.Contains(";")) { throw "scratch manifest path contains the loader's list separator: $manifestPath" }
    [IO.File]::WriteAllText($manifestPath, $text, [System.Text.UTF8Encoding]::new($false))
    $script:BuildLayerManifestPath = $manifestPath
    Write-Host "[layer] $manifestPath -> $libraryPath"
}

function Get-PeMachine([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return 0 }
        $stream.Position = 0x3C
        $stream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x00004550) { return 0 }
        return [int]$reader.ReadUInt16()
    } finally {
        $stream.Dispose()
    }
}

# The OBS Vulkan hook's 64-bit manifest FILE, read-only from the registered
# implicit layers. Its folder also holds the 32-bit manifest, so it is matched by
# layer name and by the machine type of the library it points at.
function Get-ObsVulkanHookManifestPath {
    foreach ($hive in @([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryHive]::CurrentUser)) {
        $base = $null
        $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
            $key = $base.OpenSubKey("SOFTWARE\Khronos\Vulkan\ImplicitLayers")
            if (-not $key) { continue }
            foreach ($path in $key.GetValueNames()) {
                if ($path -notlike "*.json" -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                try {
                    if ([int]$key.GetValue($path, 1) -ne 0) { continue }
                    $manifest = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                    if ($manifest.layer.name -ne $ObsLayerName) { continue }
                    $library = [string]$manifest.layer.library_path
                    $libraryFullPath = if ([IO.Path]::IsPathRooted($library)) { $library } else { Join-Path (Split-Path $path -Parent) $library }
                    if ((Get-PeMachine $libraryFullPath) -eq 0x8664) { return $path }
                } catch { }
            }
        } finally {
            if ($key) { $key.Dispose() }
            if ($base) { $base.Dispose() }
        }
    }
    return $null
}

# The loader ignores VK_IMPLICIT_LAYER_PATH in an elevated process.
function Test-ElevatedSession {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ComparablePath([string]$Path) {
    $comparable = $Path.Trim().Trim('"').Replace('/', '\')
    if ($comparable.StartsWith('\\?\')) { $comparable = $comparable.Substring(4) }
    try { $comparable = [IO.Path]::GetFullPath($comparable) } catch { }
    return $comparable.ToLowerInvariant()
}

# The loader logs every layer it activates, with the library it actually loaded:
#   [Vulkan Loader] INFO | LAYER:  Insert instance layer "<name>" (<library>)
function Get-LoaderInsertedLayerPaths([string]$LoaderOutput, [string]$LayerName) {
    $pattern = 'Insert instance layer "' + [regex]::Escape($LayerName) + '" \((?<path>[^\r\n]*)\)'
    return @([regex]::Matches($LoaderOutput, $pattern) | ForEach-Object { $_.Groups['path'].Value })
}

function Assert-LoaderUsedBuildLayer([string]$LoaderOutput) {
    $inserted = @(Get-LoaderInsertedLayerPaths $LoaderOutput $RandOverlayLayerName)
    if ($inserted.Count -eq 0) {
        throw "loader output does not show $RandOverlayLayerName being inserted; VK_IMPLICIT_LAYER_PATH was not honoured (elevated session?)"
    }
    $expected = ConvertTo-ComparablePath $BuildLayerDll
    foreach ($path in $inserted) {
        if ((ConvertTo-ComparablePath $path) -ne $expected) { throw "loader inserted $RandOverlayLayerName from '$path', not $BuildLayerDll" }
    }
}

# True when the loader's implicit-layer search listed this manifest, i.e. the
# VK_IMPLICIT_LAYER_PATH override was in effect even if the layer was then skipped.
function Test-LoaderSearchedManifest([string]$LoaderOutput, [string]$ManifestPath) {
    $expected = ConvertTo-ComparablePath $ManifestPath
    foreach ($line in ($LoaderOutput -split "\r?\n")) {
        $text = ($line -replace '^\[Vulkan Loader\][^:]*:', '').Trim()
        if ($text -and (ConvertTo-ComparablePath $text) -eq $expected) { return $true }
    }
    return $false
}

function Invoke-Preflight {
    Write-Host "[info] layer source: $LayerSource"
    Write-Host "[info] g++ from $GccSource; Vulkan SDK from $VulkanSdkSource"
    Test-RequiredPath "x64 g++" $GccPath
    foreach ($tool in @("gcc", "ar", "windres")) {
        $sibling = Get-GccSiblingPath $GccPath $tool
        if ($sibling) { Write-Host "[OK] $tool beside g++: $sibling" } else { Write-Host "[OPTIONAL-MISSING] $tool beside g++ (build.bat falls back to its own default)" }
    }
    Test-RequiredPath "Vulkan headers" ([IO.Path]::Combine($VulkanSdk, "Include\vulkan\vulkan.h"))
    Test-RequiredPath "Khronos validation layer" ([IO.Path]::Combine($VulkanSdk, "Bin\VkLayer_khronos_validation.dll"))
    Test-RequiredPath "mock host source" (Join-Path $TestsRoot "mock_vk_host.cpp")
    Test-RequiredPath "layer manifest" (Join-Path $VulkanRoot "RandOverlay_layer.json")
    Test-RequiredPath "OBS Studio" "C:\Program Files\obs-studio\bin\64bit\obs64.exe" $false

    if ($LayerSource -eq "Build") {
        Test-RequiredPath "layer manifest template" $LayerManifestTemplate
        # A full run builds the DLL after preflight; -Mode preflight checks what exists now.
        Test-RequiredPath "build layer DLL" $BuildLayerDll ($Mode -eq "preflight")
        if (Test-Path -LiteralPath $LayerManifestTemplate) {
            try {
                $libraryPath = [IO.Path]::GetFullPath($BuildLayerDll)
                Assert-BuildLayerManifest (Get-BuildLayerManifestText (Get-Content -LiteralPath $LayerManifestTemplate -Raw) $libraryPath) $libraryPath
                Write-Host "[OK] build-layer manifest renders from the template"
            } catch {
                Write-Host "[MISSING] build-layer manifest renders from the template: $($_.Exception.Message)"
                $script:Failures.Add("preflight: layer manifest template does not render: $($_.Exception.Message)") | Out-Null
            }
        }
        $obsManifest = Get-ObsVulkanHookManifestPath
        Write-Host ("[{0}] OBS Vulkan hook 64-bit manifest: {1}" -f $(if ($obsManifest) { "OK" } else { "OPTIONAL-MISSING" }), $(if ($obsManifest) { $obsManifest } else { "(not registered)" }))
        $elevated = Test-ElevatedSession
        Write-Host ("[{0}] non-elevated session (the loader ignores VK_IMPLICIT_LAYER_PATH when elevated)" -f $(if ($elevated) { "MISSING" } else { "OK" }))
        if ($elevated) { $script:Failures.Add("preflight: -LayerSource Build needs a non-elevated session") | Out-Null }
    } else {
        $isRegistered = [bool](Get-RegisteredRandOverlayManifestPath)
        Write-Host ("[{0}] RandOverlay implicit-layer registration" -f $(if ($isRegistered) { "OK" } else { "MISSING" }))
        if (-not $isRegistered) { $script:Failures.Add("preflight: RandOverlay layer is not registered for the current user") | Out-Null }
    }

    $interactive = [Environment]::UserInteractive
    Write-Host ("[{0}] interactive desktop" -f $(if ($interactive) { "OK" } else { "MISSING" }))
    if (-not $interactive) { $script:Failures.Add("preflight: visual capture requires an unlocked interactive desktop") | Out-Null }
}

function Invoke-Checked([string]$Name, [string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory) {
    Write-Host "[run] $Name"
    Push-Location $WorkingDirectory
    try { & $FilePath @ArgumentList } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "$Name exited $LASTEXITCODE" }
    Write-Pass $Name
}

function Build-MockHosts {
    foreach ($name in @("rpcs3.exe", "pcsx2-qt.exe")) {
        $compilerArgs = @(
            "-O2", "-std=c++17",
            "-I", ([IO.Path]::Combine($VulkanSdk, "Include")),
            (Join-Path $TestsRoot "mock_vk_host.cpp"),
            "-o", (Join-Path $BuildRoot $name),
            "-L", ([IO.Path]::Combine($VulkanSdk, "Lib")), "-lvulkan-1",
            "-lkernel32", "-luser32", "-lgdi32",
            "-static", "-static-libgcc", "-static-libstdc++"
        )
        Invoke-Checked "build mock $name" $GccPath $compilerArgs $VulkanRoot
    }
}

# Sets Key=Value in [Section]: replaces an existing line, or inserts one under the
# section header (the shipped ini has no EnabledPresets line, so a plain -replace
# would silently change nothing). A missing [General] goes first, any other
# missing section last.
function Set-IniValue([string]$Content, [string]$Section, [string]$Key, [string]$Value) {
    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($Content -split "\r?\n"))
    $current = ""
    $headerIndex = -1
    $replaced = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(?<name>[^\]]+)\]\s*$') {
            $current = $Matches['name'].Trim()
            if ($current -eq $Section -and $headerIndex -lt 0) { $headerIndex = $i }
        } elseif ($current -eq $Section -and $lines[$i] -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $lines[$i] = "$Key=$Value"
            $replaced = $true
        }
    }
    if (-not $replaced) {
        if ($headerIndex -ge 0) {
            $lines.Insert($headerIndex + 1, "$Key=$Value")
        } elseif ($Section -eq "General") {
            $lines.Insert(0, "$Key=$Value")
            $lines.Insert(0, "[General]")
        } else {
            $lines.Add("[$Section]")
            $lines.Add("$Key=$Value")
        }
    }
    return ($lines -join $newline)
}

function Set-IniGeneralValue([string]$Content, [string]$Key, [string]$Value) {
    Set-IniValue $Content "General" $Key $Value
}

# -IniValues sets extra keys, as @{ "Preset.RAC3/VulkanFontSize" = "80" }.
function New-TestConfig([string]$Preset, [string]$ScenarioRoot, [string]$EnabledPresets, [hashtable]$IniValues) {
    $logDir = Join-Path $ScenarioRoot "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $configPath = Join-Path $ScenarioRoot "RandOverlay.ini"
    $content = Get-Content -LiteralPath (Join-Path $RepoRoot "RandOverlay.ini") -Raw
    $content = $content -replace '(?m)^ActivePreset=.*$', "ActivePreset=$Preset"
    $content = $content -replace '(?m)^LogDir=.*$', ("LogDir=" + $logDir)
    if ($EnabledPresets) { $content = Set-IniGeneralValue $content "EnabledPresets" $EnabledPresets }
    if ($IniValues) {
        foreach ($entry in $IniValues.GetEnumerator()) {
            $section, $key = ([string]$entry.Key) -split '/', 2
            $content = Set-IniValue $content $section $key ([string]$entry.Value)
        }
    }
    Set-Content -LiteralPath $configPath -Value $content -Encoding ASCII
    $logPath = Join-Path $logDir "Launcher_Automation.txt"
    Set-Content -LiteralPath $logPath -Value "[FileLog at 00:00:00]: automation seed" -Encoding ASCII
    return @{ Config = $configPath; Log = $logPath }
}

function Get-WindowRect([IntPtr]$Hwnd) {
    $rect = New-Object RandOverlayTestWin32+RECT
    if (-not [RandOverlayTestWin32]::GetWindowRect($Hwnd, [ref]$rect)) { throw "GetWindowRect failed for $Hwnd" }
    return $rect
}

function Save-WindowScreenshot([IntPtr]$Hwnd, [string]$Path) {
    $rect = Get-WindowRect $Hwnd
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { throw "invalid capture bounds ${width}x${height}" }
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Measure-OverlayBandDifference([string]$BeforePath, [string]$AfterPath, [double]$VerticalPercent) {
    $before = [System.Drawing.Bitmap]::new($BeforePath)
    $after = [System.Drawing.Bitmap]::new($AfterPath)
    try {
        if ($before.Width -ne $after.Width -or $before.Height -ne $after.Height) { throw "screenshot dimensions differ" }
        $top = [Math]::Max(0, [int]($before.Height * ($VerticalPercent - 0.03)))
        $bottom = [Math]::Min($before.Height - 1, [int]($before.Height * ($VerticalPercent + 0.20)))
        $changed = 0
        for ($y = $top; $y -le $bottom; $y += 2) {
            for ($x = 0; $x -lt $before.Width; $x += 2) {
                $a = $before.GetPixel($x, $y)
                $b = $after.GetPixel($x, $y)
                $delta = [Math]::Abs([int]$a.R - [int]$b.R) + [Math]::Abs([int]$a.G - [int]$b.G) + [Math]::Abs([int]$a.B - [int]$b.B)
                if ($delta -ge 48) { $changed++ }
            }
        }
        return $changed
    } finally {
        $before.Dispose()
        $after.Dispose()
    }
}

# Height in pixels of the region that differs between two captures: the overlay
# panel, whose height follows the font size (plus fixed padding). Only rows from
# 10% to 65% of the capture are compared, which leaves out the title bar (a
# retitle changes it) and still holds a two-line panel placed at 17%, and an
# 8 px margin is skipped at each side, where the window border recolours when
# the window gains or loses activation.
function Measure-ChangedRowSpan([string]$BeforePath, [string]$AfterPath) {
    $before = [System.Drawing.Bitmap]::new($BeforePath)
    $after = [System.Drawing.Bitmap]::new($AfterPath)
    try {
        if ($before.Width -ne $after.Width -or $before.Height -ne $after.Height) { throw "screenshot dimensions differ" }
        $first = -1
        $last = -1
        for ($y = [int]($before.Height * 0.10); $y -lt [int]($before.Height * 0.65); $y++) {
            for ($x = 8; $x -lt $before.Width - 8; $x += 3) {
                $a = $before.GetPixel($x, $y)
                $b = $after.GetPixel($x, $y)
                $delta = [Math]::Abs([int]$a.R - [int]$b.R) + [Math]::Abs([int]$a.G - [int]$b.G) + [Math]::Abs([int]$a.B - [int]$b.B)
                if ($delta -ge 48) {
                    if ($first -lt 0) { $first = $y }
                    $last = $y
                    break
                }
            }
        }
        if ($first -lt 0) { return 0 }
        return $last - $first + 1
    } finally {
        $before.Dispose()
        $after.Dispose()
    }
}

function Format-ExitCode([int]$ExitCode) {
    $bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes($ExitCode), 0)
    return "0x{0:X8}" -f $bits
}

function Invoke-MockScenario {
    param(
        [string]$Name,
        [ValidateSet("RAC1", "RAC2", "RAC3")][string]$Preset,
        [ValidateSet("rpcs3.exe", "pcsx2-qt.exe")][string]$Executable,
        [ValidateSet("windowed", "borderless")][string]$WindowMode = "windowed",
        [switch]$Validation,
        [switch]$Disabled,
        [switch]$Visual,
        [switch]$ObsActive,
        # The layer only activates once the emulator's window title shows a
        # supported game, so each preset defaults to a matching title.
        [string]$WindowTitle,
        # Expect the layer to stay idle: no banner, no event, no Archipelago check.
        # With -Visual, the overlay band must also stay unchanged after the event.
        [switch]$ExpectIdle,
        # Written to [General] EnabledPresets; ActivePreset stays -Preset.
        [string]$EnabledPresets,
        # Extra ini keys, as @{ "Preset.RAC3/VulkanFontSize" = "80" }.
        [hashtable]$IniValues,
        # Extra environment for the mock host, e.g. @{ MOCK_RECREATE = "3" }.
        [hashtable]$MockEnv,
        # Regexes the layer log must / must not match.
        [string[]]$ExpectLog,
        [string[]]$RejectLog,
        # Exact number of "[mock] swapchain recreated" lines expected on stdout.
        [int]$ExpectRecreates = 0,
        # Require the mock's ordered-teardown line.
        [switch]$ExpectTeardown,
        # The Archipelago event the scenario writes to the log.
        [string]$EventText = "Ratchet found their automated Vulkan overlay test",
        # With -Visual and a mid-run MOCK_RETITLE at 9 s: capture the event before
        # and after the preset switch and require the overlay panel to grow.
        [switch]$MeasureFontSwitch
    )
    if (-not $WindowTitle) {
        $WindowTitle = switch ($Preset) {
            "RAC2" { "Ratchet & Clank: Going Commando | PCSX2" }
            "RAC3" { "Ratchet & Clank: Up Your Arsenal | PCSX2" }
            default { "FPS: 60.00 | Vulkan | Ratchet & Clank [NPEA00385]" }
        }
    }

    $scenarioRoot = Join-Path $RunRoot $Name
    New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
    $testData = New-TestConfig $Preset $scenarioRoot $EnabledPresets $IniValues
    $obsManifestPath = $null
    if ($LayerSource -eq "Build") {
        if (-not (Test-Path -LiteralPath $BuildLayerDll -PathType Leaf)) { throw "build layer DLL not found at $BuildLayerDll" }
        if (-not $BuildLayerManifestPath) { throw "build-layer manifest was not rendered" }
        if ($ObsActive) {
            $obsManifestPath = Get-ObsVulkanHookManifestPath
            if (-not $obsManifestPath) { throw "OBS Vulkan hook 64-bit manifest is not registered" }
            if ($obsManifestPath.Contains(";")) { throw "OBS manifest path contains the loader's list separator: $obsManifestPath" }
        }
        $layerLog = $BuildLayerLog
        Remove-Item -LiteralPath $layerLog -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $layerLog) { throw "could not clear $layerLog before the scenario" }
    } else {
        $registeredManifestPath = Get-RegisteredRandOverlayManifestPath
        if (-not $registeredManifestPath) { throw "registered RandOverlay manifest not found" }
        $layerLog = Join-Path (Split-Path $registeredManifestPath -Parent) "layer_debug.log"
        Remove-Item -LiteralPath $layerLog -Force -ErrorAction SilentlyContinue
    }

    $obsStarted = $false
    $obsProcess = Get-Process -Name obs64 -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ObsActive -and -not $obsProcess) {
        $obsPath = "C:\Program Files\obs-studio\bin\64bit\obs64.exe"
        if (-not (Test-Path -LiteralPath $obsPath)) { throw "OBS Studio is not installed" }
        $obsProcess = Start-Process -FilePath $obsPath -ArgumentList "--minimize-to-tray", "--disable-shutdown-check" -WorkingDirectory (Split-Path $obsPath) -PassThru
        $obsStarted = $true
        Start-Sleep -Seconds 4
    }

    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = Join-Path $BuildRoot $Executable
        $psi.WorkingDirectory = $BuildRoot
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables["RANDOVERLAY_INI"] = $testData.Config
        $psi.EnvironmentVariables["RANDOVERLAY_NO_PROMPT"] = "1"
        $psi.EnvironmentVariables["MOCK_SECONDS"] = $(if ($Visual) { "10" } else { "3" })
        $psi.EnvironmentVariables["MOCK_STATIC_FRAME"] = "1"
        $psi.EnvironmentVariables["MOCK_WINDOW_MODE"] = $WindowMode
        $psi.EnvironmentVariables["MOCK_WINDOW_TITLE"] = $WindowTitle
        $psi.EnvironmentVariables.Remove("VK_ADD_IMPLICIT_LAYER_PATH")
        if ($Validation) {
            $psi.EnvironmentVariables["VK_LOADER_LAYERS_ENABLE"] = "VK_LAYER_KHRONOS_validation"
            $psi.EnvironmentVariables["VK_LAYER_KHRONOS_VALIDATION_REPORT_FLAGS"] = "error,warn,perf"
        }
        if ($Disabled) { $psi.EnvironmentVariables["DISABLE_RANDOVERLAY"] = "1" }
        if ($ObsActive) { $psi.EnvironmentVariables["VK_LOADER_DEBUG"] = "layer" }
        if ($LayerSource -eq "Build") {
            # Replaces the registry's implicit-layer list for this process only, so
            # the installed copy is not loaded. Accepts manifest files, ';'-separated.
            $implicitLayerPaths = @($BuildLayerManifestPath)
            if ($obsManifestPath) { $implicitLayerPaths += $obsManifestPath }
            $psi.EnvironmentVariables["VK_IMPLICIT_LAYER_PATH"] = $implicitLayerPaths -join ";"
            $psi.EnvironmentVariables["VK_LOADER_DEBUG"] = "layer"
        }
        if ($MockEnv) {
            foreach ($entry in $MockEnv.GetEnumerator()) { $psi.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value }
        }

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadline = (Get-Date).AddSeconds(8)
        do {
            Start-Sleep -Milliseconds 100
            $process.Refresh()
            $hwnd = $process.MainWindowHandle
        } until ($hwnd -ne [IntPtr]::Zero -or $process.HasExited -or (Get-Date) -gt $deadline)
        if ($hwnd -eq [IntPtr]::Zero) { throw "mock window did not become ready" }

        $rect = Get-WindowRect $hwnd
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
        if ($WindowMode -eq "windowed" -and ($width -lt 900 -or $height -lt 500)) { throw "unexpected windowed geometry ${width}x${height}" }
        if ($WindowMode -eq "borderless") {
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            if ($rect.Left -ne $screen.Left -or $rect.Top -ne $screen.Top -or $width -ne $screen.Width -or $height -ne $screen.Height) {
                throw "borderless geometry ${width}x${height} at $($rect.Left),$($rect.Top) does not fill primary screen"
            }
        }

        $eventLine = "[FileLog at 00:00:01]: $EventText"
        if ($Visual -and $MeasureFontSwitch) {
            # Startup banner gone by 6.2 s; event at the old preset's size; the
            # retitle at 9 s switches presets within one 1.5 s poll; a second event
            # after the first has faded is drawn at the new size.
            [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(0, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Bottom - 1)
            Start-Sleep -Milliseconds 6200
            $blankPath = Join-Path $ArtifactRoot "$Name-blank.png"
            $beforePath = Join-Path $ArtifactRoot "$Name-before-switch.png"
            $afterPath = Join-Path $ArtifactRoot "$Name-after-switch.png"
            Save-WindowScreenshot $hwnd $blankPath
            Add-Content -LiteralPath $testData.Log -Value $eventLine
            Start-Sleep -Milliseconds 2200
            Save-WindowScreenshot $hwnd $beforePath
            Start-Sleep -Milliseconds 4000
            Add-Content -LiteralPath $testData.Log -Value $eventLine
            Start-Sleep -Milliseconds 2200
            Save-WindowScreenshot $hwnd $afterPath
            $beforeRows = Measure-ChangedRowSpan $blankPath $beforePath
            $afterRows = Measure-ChangedRowSpan $blankPath $afterPath
            Write-Host "[artifact] $beforePath"
            Write-Host "[artifact] $afterPath"
            Write-Host "[visual] overlay panel height: $beforeRows px before the switch, $afterRows px after"
            if ($beforeRows -lt 10) { throw "no overlay panel before the preset switch ($beforeRows px)" }
            if ($afterRows -lt 1.3 * $beforeRows) { throw "overlay panel did not grow after the preset switch ($beforeRows -> $afterRows px)" }
        } elseif ($Visual) {
            [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(0, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Bottom - 1)
            Start-Sleep -Milliseconds 6200
            $beforePath = Join-Path $ArtifactRoot "$Name-before.png"
            $afterPath = Join-Path $ArtifactRoot "$Name-after.png"
            Save-WindowScreenshot $hwnd $beforePath
            Add-Content -LiteralPath $testData.Log -Value $eventLine
            Start-Sleep -Milliseconds 2200
            Save-WindowScreenshot $hwnd $afterPath
            $changed = Measure-OverlayBandDifference $beforePath $afterPath 0.17
            if ($ExpectIdle) {
                if ($changed -gt $IdleBandTolerance) { throw "idle overlay band changed $changed sampled pixels after the event" }
            } elseif ($changed -lt 75) { throw "overlay band changed only $changed sampled pixels" }
            Write-Host "[artifact] $beforePath"
            Write-Host "[artifact] $afterPath"
            Write-Host "[visual] changed overlay-band samples: $changed"
        } elseif (-not $Disabled) {
            Start-Sleep -Milliseconds 700
            Add-Content -LiteralPath $testData.Log -Value $eventLine
        }

        if (-not $process.WaitForExit(20000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "mock process timed out"
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        Set-Content -LiteralPath (Join-Path $scenarioRoot "stdout.txt") -Value $stdout -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $scenarioRoot "stderr.txt") -Value $stderr -Encoding UTF8
        if (Test-Path -LiteralPath $layerLog) { Copy-Item -LiteralPath $layerLog -Destination (Join-Path $scenarioRoot "layer_debug.log") -Force }

        if ($process.ExitCode -ne 0) { throw "mock exited $(Format-ExitCode $process.ExitCode)" }
        if ($stdout -notmatch '\[mock\] exiting after \d+ frames') { throw "missing clean mock exit line" }
        $logText = if (Test-Path -LiteralPath $layerLog) { Get-Content -LiteralPath $layerLog -Raw } else { "" }
        if ($null -eq $logText) { $logText = "" }
        if ($LayerSource -eq "Build") {
            # Fail closed: prove the loader used this checkout's DLL. An elevated
            # session ignores VK_IMPLICIT_LAYER_PATH and would load the installed copy.
            $loaderOutput = $stdout + "`n" + $stderr
            if ($Disabled) {
                if (-not (Test-LoaderSearchedManifest $loaderOutput $BuildLayerManifestPath)) {
                    throw "loader output does not list $BuildLayerManifestPath; VK_IMPLICIT_LAYER_PATH was not honoured (elevated session?)"
                }
                if (Test-Path -LiteralPath $layerLog) { throw "disabled build layer wrote $layerLog" }
            } else {
                Assert-LoaderUsedBuildLayer $loaderOutput
            }
        }
        if ($Disabled) {
            # The manifest-level disable is strongest: the loader may skip the DLL entirely,
            # producing no layer log. If a loader still loads it, the runtime guard must be inert.
            if ($logText -and ($logText -notmatch 'disabled=1' -or $logText -match 'Render resources ready')) {
                throw "disabled layer was not inert"
            }
        } elseif ($ExpectIdle) {
            if ($logText -notmatch 'No supported R&C game in the emulator window title yet' -or
                $logText -match 'Automatic preset:' -or $logText -match 'Message: ' -or
                $logText -match 'Archipelago is not running') {
                throw "layer did not stay idle for a non-R&C game"
            }
        } elseif ($logText -notmatch 'Render resources ready' -or $logText -notmatch ('Message: ' + [regex]::Escape($EventText))) {
            throw "layer did not initialize and ingest the injected event"
        }
        if ($Validation -and (($stdout + "`n" + $stderr) -match 'Validation (Error|Warning)|WARNING-vkGetDeviceProcAddr-device')) {
            throw "validation emitted errors or warnings"
        }
        if ($ObsActive -and (($stdout + $stderr) -notmatch 'VK_LAYER_OBS_HOOK')) { throw "loader output did not confirm VK_LAYER_OBS_HOOK" }
        foreach ($pattern in $ExpectLog) {
            if ($logText -notmatch $pattern) { throw "layer log does not match /$pattern/" }
        }
        foreach ($pattern in $RejectLog) {
            if ($logText -match $pattern) { throw "layer log unexpectedly matches /$pattern/" }
        }
        if ($ExpectRecreates -gt 0) {
            $recreated = [regex]::Matches($stdout, '\[mock\] swapchain recreated').Count
            if ($recreated -ne $ExpectRecreates) { throw "expected $ExpectRecreates swapchain recreations, mock reported $recreated" }
            $created = [regex]::Matches($logText, 'vkCreateSwapchainKHR entry').Count
            if ($created -lt $ExpectRecreates + 1) { throw "layer saw $created swapchain creations, expected at least $($ExpectRecreates + 1)" }
        }
        if ($ExpectTeardown -and $stdout -notmatch '\[mock\] teardown complete') { throw "missing mock teardown line" }
        Write-Pass $Name
    } finally {
        if ($obsStarted -and $obsProcess -and -not $obsProcess.HasExited) { Stop-Process -Id $obsProcess.Id -Force -ErrorAction SilentlyContinue }
    }
}

$gccResolution = Resolve-GccPath $GccPath
$GccPath = $gccResolution.Path
$GccSource = $gccResolution.Source
$sdkResolution = Resolve-VulkanSdk $VulkanSdk
$VulkanSdk = $sdkResolution.Path
$VulkanSdkSource = $sdkResolution.Source
# PCSX2 title naming both RAC2 and RAC3: the layer must refuse to guess.
$AmbiguousRac2Rac3Title = "Ratchet & Clank: Going Commando / Up Your Arsenal | PCSX2"
# A game switch with the swapchain kept: PCSX2 boots RAC2, then RAC3, whose preset
# has a bigger font. At the mock's height (<= 720 px) the layout scale is 0.75, so
# 48 -> 36 px and 80 -> 60 px. The short event fits one line at 60 px, so the
# primary face (not the wrap fallback) is what gets drawn.
$FontSwitchTitle = "Ratchet & Clank: Up Your Arsenal | PCSX2"
$FontSwitchEvent = "Clank found their Bolt"
# RAC2 gets a stock face too: with HandelGothic BT absent, RAC2 would fall back to
# Bahnschrift alone and load no separate digit font, leaving the digit-font removal
# untested. Segoe UI + Bahnschrift before, Consolas + Bahnschrift after.
$FontFaceSwitchIni = @{ "Preset.RAC2/FontFamily" = "Segoe UI"; "Preset.RAC3/VulkanFontSize" = "80"; "Preset.RAC3/FontFamily" = "Consolas" }
# Consolas plus the Bahnschrift digit font: two fonts once the old ones are removed.
$FontFaceSwitchLog = @('font=36px', 'Automatic preset: RAC2 -> RAC3', '(?i)Font loaded: \S*consola\S* \(60px\)',
                       'Font set replaced; the atlas holds 2 fonts')
$FontSizeSwitchIni = @{ "Preset.RAC3/VulkanFontSize" = "80" }
$FontSizeSwitchLog = @('font=36px', 'Automatic preset: RAC2 -> RAC3', 'Font size now 60px')

New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null
if ($Mode -eq "preflight") {
    Invoke-Preflight
} else {
    New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
    try {
        Invoke-Preflight
        if ($Failures.Count -gt 0) { throw "preflight failed" }
        # The layer, the unit tests and the mock hosts share one toolchain.
        Invoke-WithEnvironment (Get-ToolchainEnvironment) {
            Invoke-Checked "Vulkan build" "cmd.exe" @("/d", "/c", ".\build.bat", "--no-pause") $VulkanRoot
            Build-MockHosts
        }
        if ($LayerSource -eq "Build") { Initialize-BuildLayerManifest }
        if ($Mode -eq "all") {
            Invoke-WithEnvironment (Get-ToolchainEnvironment) {
                Invoke-Checked "unit tests" "cmd.exe" @("/d", "/c", ".\tests\run_tests.bat") $VulkanRoot
            }
            Invoke-Checked "AHK and PowerShell regression" "powershell.exe" @("-NoProfile", "-File", (Join-Path $RepoRoot "Test-RandOverlay.ps1")) $RepoRoot
            Invoke-Checked "installer lifecycle" "powershell.exe" @("-NoProfile", "-File", (Join-Path $TestsRoot "installer\Test-Installer.ps1")) $RepoRoot
            Invoke-MockScenario -Name "rac1-normal" -Preset RAC1 -Executable rpcs3.exe
            Invoke-MockScenario -Name "rac1-disabled" -Preset RAC1 -Executable rpcs3.exe -Disabled
            Invoke-MockScenario -Name "rac1-other-game" -Preset RAC1 -Executable rpcs3.exe -WindowTitle "FPS: 30.00 | Vulkan | Demon's Souls [BLUS30443]" -ExpectIdle
            Invoke-MockScenario -Name "rac1-obs" -Preset RAC1 -Executable rpcs3.exe -ObsActive
            # RAC2 and RAC3 both enabled: the PCSX2 window title decides.
            Invoke-MockScenario -Name "rac2-rac3-resolved" -Preset RAC2 -EnabledPresets "RAC2,RAC3" -Executable pcsx2-qt.exe `
                -WindowTitle "Ratchet & Clank: Up Your Arsenal | PCSX2" `
                -ExpectLog @('enabled=RAC2,RAC3', 'Automatic preset: \S* -> RAC3') -RejectLog @('Automatic preset: \S* -> RAC2')
            Invoke-MockScenario -Name "rac2-rac3-ambiguous" -Preset RAC2 -EnabledPresets "RAC2,RAC3" -Executable pcsx2-qt.exe `
                -WindowTitle $AmbiguousRac2Rac3Title -ExpectIdle -ExpectLog @('enabled=RAC2,RAC3')
        }
        if ($Mode -in @("all", "validation")) {
            Invoke-MockScenario -Name "rac1-validation" -Preset RAC1 -Executable rpcs3.exe -Validation
            # Destroy-then-create and cross-thread swapchain rebuilds, then ordered teardown.
            Invoke-MockScenario -Name "rac1-swapchain-lifecycle-validation" -Preset RAC1 -Executable rpcs3.exe -Validation `
                -MockEnv @{ MOCK_SECONDS = "10"; MOCK_RECREATE = "3"; MOCK_RECREATE_DESTROY_FIRST = "1"; MOCK_RECREATE_THREAD = "1" } `
                -ExpectRecreates 3 -ExpectTeardown
            # A face and size switch with the swapchain kept: the old fonts are
            # removed from the atlas and the new face drawn (the event stays on
            # screen across the switch) under validation. The mock keeps one frame
            # in flight, so this cannot speak for frames still queued on the GPU.
            Invoke-MockScenario -Name "rac2-rac3-font-switch-validation" -Preset RAC2 -EnabledPresets "RAC2,RAC3" -Executable pcsx2-qt.exe -Validation `
                -IniValues $FontFaceSwitchIni -ExpectLog $FontFaceSwitchLog -EventText $FontSwitchEvent `
                -MockEnv @{ MOCK_SECONDS = "8"; MOCK_RETITLE = $FontSwitchTitle; MOCK_RETITLE_MS = "2000" }
        }
        if ($Mode -in @("all", "visual")) {
            Invoke-MockScenario -Name "rac1-windowed-visual" -Preset RAC1 -Executable rpcs3.exe -Visual
            Invoke-MockScenario -Name "rac2-borderless-visual" -Preset RAC2 -Executable pcsx2-qt.exe -WindowMode borderless -Visual
            Invoke-MockScenario -Name "rac3-visual" -Preset RAC3 -Executable pcsx2-qt.exe -Visual
            Invoke-MockScenario -Name "rac2-rac3-ambiguous-visual" -Preset RAC2 -EnabledPresets "RAC2,RAC3" -Executable pcsx2-qt.exe `
                -WindowTitle $AmbiguousRac2Rac3Title -ExpectIdle -Visual -ExpectLog @('enabled=RAC2,RAC3')
            # A size-only switch: the same event drawn before and after it, and the
            # overlay panel must grow with the font; no face is reloaded.
            Invoke-MockScenario -Name "rac2-rac3-font-switch-visual" -Preset RAC2 -EnabledPresets "RAC2,RAC3" -Executable pcsx2-qt.exe -Visual `
                -MeasureFontSwitch -IniValues $FontSizeSwitchIni -ExpectLog $FontSizeSwitchLog -RejectLog @('Font loaded: .*\(60px\)') `
                -EventText $FontSwitchEvent -MockEnv @{ MOCK_SECONDS = "17"; MOCK_RETITLE = $FontSwitchTitle; MOCK_RETITLE_MS = "9000" }
        }
    } catch {
        Add-Failure $Mode $_.Exception.Message
    }
}

if ($Failures.Count -gt 0) {
    [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString("o")
        target = "rac-overlay"
        mode = $Mode
        failures = @($Failures)
        run_artifacts = $RunRoot
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ArtifactRoot "last-failure.json") -Encoding UTF8
    Write-Host "`nValidation failed:" -ForegroundColor Red
    $Failures | ForEach-Object { Write-Host " - $_" }
    exit 1
}

Remove-Item -LiteralPath (Join-Path $ArtifactRoot "last-failure.json") -Force -ErrorAction SilentlyContinue
Write-Host "All RAC overlay $Mode checks passed." -ForegroundColor Green

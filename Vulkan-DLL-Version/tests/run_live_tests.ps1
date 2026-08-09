[CmdletBinding()]
param(
    [ValidateSet("all", "validation", "visual", "preflight")]
    [string]$Mode = "all",
    [switch]$KeepArtifacts
)

$ErrorActionPreference = "Stop"
$TestsRoot = $PSScriptRoot
$VulkanRoot = Split-Path $TestsRoot -Parent
$RepoRoot = Split-Path $VulkanRoot -Parent
$BuildRoot = Join-Path $VulkanRoot "build"
$ArtifactRoot = Join-Path $RepoRoot "tests\live\artifacts"
$RunRoot = Join-Path $ArtifactRoot (Get-Date -Format "yyyyMMdd-HHmmss")
$Failures = [System.Collections.Generic.List[string]]::new()

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

function Invoke-Preflight {
    Test-RequiredPath "x64 g++" "C:\mingw64\bin\g++.exe"
    Test-RequiredPath "Vulkan headers" "C:\VulkanSDK\1.4.341.1\Include\vulkan\vulkan.h"
    Test-RequiredPath "Khronos validation layer" "C:\VulkanSDK\1.4.341.1\Bin\VkLayer_khronos_validation.dll"
    Test-RequiredPath "mock host source" (Join-Path $TestsRoot "mock_vk_host.cpp")
    Test-RequiredPath "layer manifest" (Join-Path $VulkanRoot "RandOverlay_layer.json")
    Test-RequiredPath "OBS Studio" "C:\Program Files\obs-studio\bin\64bit\obs64.exe" $false

    $manifest = Join-Path $VulkanRoot "RandOverlay_layer.json"
    $expectedHash = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
    $registry = Get-ItemProperty -Path "HKCU:\SOFTWARE\Khronos\Vulkan\ImplicitLayers" -ErrorAction SilentlyContinue
    $registeredPaths = @($registry.PSObject.Properties | Where-Object { $_.Name -like "*.json" } | ForEach-Object { $_.Name })
    $isRegistered = $false
    foreach ($path in $registeredPaths) {
        if ((Test-Path -LiteralPath $path) -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $expectedHash) {
            $isRegistered = $true
            break
        }
    }
    Write-Host ("[{0}] RandOverlay implicit-layer registration" -f $(if ($isRegistered) { "OK" } else { "MISSING" }))
    if (-not $isRegistered) { $script:Failures.Add("preflight: RandOverlay layer is not registered for the current user") | Out-Null }

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
        $args = @(
            "-O2", "-std=c++17",
            "-I", "C:\VulkanSDK\1.4.341.1\Include",
            (Join-Path $TestsRoot "mock_vk_host.cpp"),
            "-o", (Join-Path $BuildRoot $name),
            "-L", "C:\VulkanSDK\1.4.341.1\Lib", "-lvulkan-1",
            "-lkernel32", "-luser32", "-lgdi32",
            "-static", "-static-libgcc", "-static-libstdc++"
        )
        Invoke-Checked "build mock $name" "C:\mingw64\bin\g++.exe" $args $VulkanRoot
    }
}

function New-TestConfig([string]$Preset, [string]$ScenarioRoot) {
    $logDir = Join-Path $ScenarioRoot "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $configPath = Join-Path $ScenarioRoot "RandOverlay.ini"
    $content = Get-Content -LiteralPath (Join-Path $RepoRoot "RandOverlay.ini") -Raw
    $content = $content -replace '(?m)^ActivePreset=.*$', "ActivePreset=$Preset"
    $content = $content -replace '(?m)^LogDir=.*$', ("LogDir=" + $logDir)
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

function Format-ExitCode([int]$ExitCode) {
    $bits = [BitConverter]::ToUInt32([BitConverter]::GetBytes($ExitCode), 0)
    return "0x{0:X8}" -f $bits
}

function Invoke-MockScenario {
    param(
        [string]$Name,
        [ValidateSet("RAC1", "RAC2")][string]$Preset,
        [ValidateSet("rpcs3.exe", "pcsx2-qt.exe")][string]$Executable,
        [ValidateSet("windowed", "borderless")][string]$WindowMode = "windowed",
        [switch]$Validation,
        [switch]$Disabled,
        [switch]$Visual,
        [switch]$ObsActive
    )

    $scenarioRoot = Join-Path $RunRoot $Name
    New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
    $testData = New-TestConfig $Preset $scenarioRoot
    $layerLog = Join-Path $BuildRoot "layer_debug.log"
    Remove-Item -LiteralPath $layerLog -Force -ErrorAction SilentlyContinue

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
        $psi.EnvironmentVariables.Remove("VK_ADD_IMPLICIT_LAYER_PATH")
        if ($Validation) {
            $psi.EnvironmentVariables["VK_LOADER_LAYERS_ENABLE"] = "VK_LAYER_KHRONOS_validation"
            $psi.EnvironmentVariables["VK_LAYER_KHRONOS_VALIDATION_REPORT_FLAGS"] = "error,warn,perf"
        }
        if ($Disabled) { $psi.EnvironmentVariables["DISABLE_RANDOVERLAY"] = "1" }
        if ($ObsActive) { $psi.EnvironmentVariables["VK_LOADER_DEBUG"] = "layer" }

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

        if ($Visual) {
            [System.Windows.Forms.Cursor]::Position = [System.Drawing.Point]::new(0, [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Bottom - 1)
            Start-Sleep -Milliseconds 6200
            $beforePath = Join-Path $ArtifactRoot "$Name-before.png"
            $afterPath = Join-Path $ArtifactRoot "$Name-after.png"
            Save-WindowScreenshot $hwnd $beforePath
            Add-Content -LiteralPath $testData.Log -Value "[FileLog at 00:00:01]: Ratchet found their automated Vulkan overlay test"
            Start-Sleep -Milliseconds 2200
            Save-WindowScreenshot $hwnd $afterPath
            $changed = Measure-OverlayBandDifference $beforePath $afterPath 0.17
            if ($changed -lt 75) { throw "overlay band changed only $changed sampled pixels" }
            Write-Host "[artifact] $beforePath"
            Write-Host "[artifact] $afterPath"
            Write-Host "[visual] changed overlay-band samples: $changed"
        } elseif (-not $Disabled) {
            Start-Sleep -Milliseconds 700
            Add-Content -LiteralPath $testData.Log -Value "[FileLog at 00:00:01]: Ratchet found their automated Vulkan overlay test"
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
        if ($Disabled) {
            # The manifest-level disable is strongest: the loader may skip the DLL entirely,
            # producing no layer log. If a loader still loads it, the runtime guard must be inert.
            if ($logText -and ($logText -notmatch 'disabled=1' -or $logText -match 'Render resources ready')) {
                throw "disabled layer was not inert"
            }
        } elseif ($logText -notmatch 'Render resources ready' -or $logText -notmatch 'Message: Ratchet found their automated Vulkan overlay test') {
            throw "layer did not initialize and ingest the injected event"
        }
        if ($Validation -and (($stdout + "`n" + $stderr) -match 'Validation (Error|Warning)|WARNING-vkGetDeviceProcAddr-device')) {
            throw "validation emitted errors or warnings"
        }
        if ($ObsActive -and (($stdout + $stderr) -notmatch 'VK_LAYER_OBS_HOOK')) { throw "loader output did not confirm VK_LAYER_OBS_HOOK" }
        Write-Pass $Name
    } finally {
        if ($obsStarted -and $obsProcess -and -not $obsProcess.HasExited) { Stop-Process -Id $obsProcess.Id -Force -ErrorAction SilentlyContinue }
    }
}

New-Item -ItemType Directory -Path $ArtifactRoot -Force | Out-Null
if ($Mode -eq "preflight") {
    Invoke-Preflight
} else {
    New-Item -ItemType Directory -Path $RunRoot -Force | Out-Null
    try {
        Invoke-Preflight
        if ($Failures.Count -gt 0) { throw "preflight failed" }
        Invoke-Checked "Vulkan build" "cmd.exe" @("/d", "/c", "build.bat", "--no-pause") $VulkanRoot
        Build-MockHosts
        if ($Mode -eq "all") {
            Invoke-Checked "unit tests" "cmd.exe" @("/d", "/c", "tests\run_tests.bat") $VulkanRoot
            Invoke-Checked "AHK and PowerShell regression" "powershell.exe" @("-NoProfile", "-File", (Join-Path $RepoRoot "Test-RandOverlay.ps1")) $RepoRoot
            Invoke-Checked "installer lifecycle" "powershell.exe" @("-NoProfile", "-File", (Join-Path $TestsRoot "installer\Test-Installer.ps1")) $RepoRoot
            Invoke-MockScenario -Name "rac1-normal" -Preset RAC1 -Executable rpcs3.exe
            Invoke-MockScenario -Name "rac1-disabled" -Preset RAC1 -Executable rpcs3.exe -Disabled
            Invoke-MockScenario -Name "rac1-obs" -Preset RAC1 -Executable rpcs3.exe -ObsActive
        }
        if ($Mode -in @("all", "validation")) {
            Invoke-MockScenario -Name "rac1-validation" -Preset RAC1 -Executable rpcs3.exe -Validation
        }
        if ($Mode -in @("all", "visual")) {
            Invoke-MockScenario -Name "rac1-windowed-visual" -Preset RAC1 -Executable rpcs3.exe -Visual
            Invoke-MockScenario -Name "rac2-borderless-visual" -Preset RAC2 -Executable pcsx2-qt.exe -WindowMode borderless -Visual
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

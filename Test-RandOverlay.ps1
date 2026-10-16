[CmdletBinding()]
param(
    [string]$AutoHotkeyPath,
    [string]$GitDiffRange,
    [switch]$SkipAhkRuntime,
    [switch]$SkipGit
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Failures = New-Object System.Collections.Generic.List[string]

function Add-Failure([string]$Name, [string]$Message) {
    $script:Failures.Add("${Name}: $Message") | Out-Null
}

function Write-Pass([string]$Name) {
    Write-Host "PASS $Name" -ForegroundColor Green
}

function Write-Skip([string]$Name, [string]$Reason) {
    Write-Host "SKIP $Name - $Reason" -ForegroundColor Yellow
}

function Invoke-Check([string]$Name, [scriptblock]$Script) {
    Write-Host ""
    Write-Host "== $Name"
    try {
        & $Script
        Write-Pass $Name
    } catch {
        Add-Failure $Name $_.Exception.Message
        Write-Host "FAIL $Name" -ForegroundColor Red
        Write-Host $_.Exception.Message
    }
}

function Join-CommandLineArgs([string[]]$CommandArgs) {
    return ($CommandArgs | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join " "
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $Root,
        [int]$TimeoutSeconds = 30,
        [hashtable]$Environment = @{}
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = Join-CommandLineArgs -CommandArgs $ArgumentList
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[$key] = [string]$Environment[$key]
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    # Drain both pipes while the child runs. A child that fills a pipe buffer
    # blocks on write and never exits if nothing reads until it is done.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $readTasks = [System.Threading.Tasks.Task[]]@($stdoutTask, $stderrTask)

    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        # Still drain what was written, without waiting forever on a grandchild
        # that inherited the pipes.
        $partial = ""
        if ([System.Threading.Tasks.Task]::WaitAll($readTasks, 5000)) {
            $partial = ($stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()).Trim()
        }
        throw "Timed out after ${TimeoutSeconds}s: $FilePath $($psi.Arguments)`n$partial"
    }

    if (-not [System.Threading.Tasks.Task]::WaitAll($readTasks, $TimeoutSeconds * 1000)) {
        throw "Output pipes stayed open after exit: $FilePath $($psi.Arguments)"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        Command = "$FilePath $($psi.Arguments)"
    }
}

function Resolve-AutoHotkey {
    param([string]$Preferred)

    $candidates = @()
    if ($Preferred) { $candidates += $Preferred }

    # CI installs the autohotkey.portable package. Use its real executable rather
    # than the Chocolatey shim on PATH, which may neither wait for the script nor
    # pass its output through, so a check could pass without running anything.
    # The package renames the build for the machine's bitness to AutoHotkey.exe.
    $chocolateyRoot = if ($env:ChocolateyInstall) { $env:ChocolateyInstall } else { "C:\ProgramData\chocolatey" }
    $chocolateyTools = Join-Path $chocolateyRoot "lib\autohotkey.portable\tools"
    $candidates += Join-Path $chocolateyTools "AutoHotkey.exe"
    $candidates += Join-Path $chocolateyTools "AutoHotkeyU64.exe"

    # The v2 installer keeps each v1 release in its own v1.* folder; newest first.
    $installRoot = "C:\Program Files\AutoHotkey"
    $candidates += @(Get-ChildItem -LiteralPath $installRoot -Directory -Filter "v1.*" -ErrorAction SilentlyContinue |
        Sort-Object -Descending -Property @{ Expression = {
            $version = $null
            if ([version]::TryParse($_.Name.Substring(1), [ref]$version)) { $version } else { [version]"0.0" }
        } } |
        ForEach-Object { Join-Path $_.FullName "AutoHotkeyU64.exe" })

    # The standalone v1 installer layout.
    $candidates += Join-Path $installRoot "AutoHotkeyU64.exe"
    $candidates += Join-Path $installRoot "AutoHotkey.exe"

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    foreach ($commandName in @("AutoHotkeyU64.exe", "AutoHotkey.exe")) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }

    throw "AutoHotkey v1 executable was not found. Pass -AutoHotkeyPath if it is installed elsewhere."
}

# Returns the source of named functions from a script without running the script,
# so callers can dot-source just those functions into their own scope.
function Get-ScriptFunctionSource([string]$Path, [string[]]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) {
        throw "${Path}: " + (($errors | ForEach-Object { $_.Message }) -join "; ")
    }

    $sources = foreach ($functionName in $Name) {
        $definitions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true))
        if ($definitions.Count -ne 1) {
            throw "Expected one definition of $functionName in $Path, found $($definitions.Count)."
        }
        $definitions[0].Extent.Text
    }
    return ($sources -join [Environment]::NewLine)
}

# Reads tests\fixtures\archipelago-log-lines.tsv: <input><TAB><expected>, split on
# the last tab, with <none> meaning the line is not shown.
function Get-ArchipelagoFixtureRows {
    $rows = @()
    $lineNumber = 0
    foreach ($rawLine in [System.IO.File]::ReadAllText($FixturePath).Split("`n")) {
        $lineNumber++
        $row = $rawLine.Replace("`r", "")
        if (-not $row -or $row.StartsWith("#", [StringComparison]::Ordinal)) { continue }

        $tab = $row.LastIndexOf("`t")
        if ($tab -lt 0) { throw "Fixture line $lineNumber has no tab." }
        $expected = $row.Substring($tab + 1)
        if ($expected -ceq "<none>") { $expected = $null }
        $rows += [pscustomobject]@{ Line = $lineNumber; Input = $row.Substring(0, $tab); Expected = $expected }
    }
    if ($rows.Count -eq 0) { throw "Fixture has no rows: $FixturePath" }
    return $rows
}

$OverlayScript = Join-Path $Root "PS+WPF-Version\RandOverlay.ps1"
$FixturePath = Join-Path $Root "tests\fixtures\archipelago-log-lines.tsv"

$Ahk = $null
Invoke-Check "Resolve AutoHotkey" {
    $script:Ahk = Resolve-AutoHotkey $AutoHotkeyPath
    $ahkVersion = (Get-Item -LiteralPath $script:Ahk).VersionInfo.FileVersion
    Write-Host "Using $script:Ahk (FileVersion $ahkVersion)"
}

if (-not $SkipGit) {
    Invoke-Check "Git diff whitespace" {
        $git = Get-Command git -ErrorAction SilentlyContinue
        if (-not $git) {
            Write-Skip "Git diff whitespace" "git is not on PATH"
            return
        }

        $gitArgs = @("diff", "--check")
        if ($GitDiffRange) {
            $gitArgs += $GitDiffRange
        }

        $result = Invoke-NativeCommand -FilePath $git.Source -ArgumentList $gitArgs
        if ($result.ExitCode -ne 0) {
            throw (($result.Stdout + $result.Stderr).Trim())
        }
    }
}

Invoke-Check "PowerShell parser" {
    foreach ($relativePath in @(
        "PS+WPF-Version\RandOverlay.ps1",
        "Vulkan-DLL-Version\installer\Setup-RandOverlay.ps1",
        "Vulkan-DLL-Version\installer\lib\StackManifest.ps1",
        "Vulkan-DLL-Version\installer\lib\StackDetect.ps1",
        "Vulkan-DLL-Version\installer\lib\StackActions.ps1",
        "Vulkan-DLL-Version\installer\Build-RandOverlayRelease.ps1",
        "Vulkan-DLL-Version\tests\installer\Test-Installer.ps1",
        "Vulkan-DLL-Version\tests\installer\TestCommon.ps1",
        "Vulkan-DLL-Version\tests\installer\Test-Stack.ps1"
    )) {
        $tokens = $null
        $errors = $null
        $scriptPath = Join-Path $Root $relativePath
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) > $null
        if ($errors.Count) {
            throw "$relativePath`: " + (($errors | ForEach-Object { $_.Message }) -join "; ")
        }
    }
}

Invoke-Check "GitHub issue form shape" {
    $formPath = Join-Path $Root ".github\ISSUE_TEMPLATE\feedback.yml"
    if (-not (Test-Path -LiteralPath $formPath)) {
        throw "Missing .github\ISSUE_TEMPLATE\feedback.yml"
    }

    $content = Get-Content -LiteralPath $formPath -Raw
    foreach ($required in @("name:", "description:", "body:")) {
        if ($content -notmatch "(?m)^$([regex]::Escape($required))") {
            throw "Missing top-level $required"
        }
    }

    $allowedTypes = @("checkboxes", "dropdown", "input", "markdown", "textarea", "upload")
    $typeMatches = [regex]::Matches($content, "(?m)^\s*-\s+type:\s+([A-Za-z0-9_-]+)\s*$")
    if ($typeMatches.Count -eq 0) {
        throw "No issue form body types found."
    }

    foreach ($match in $typeMatches) {
        $type = $match.Groups[1].Value
        if ($allowedTypes -notcontains $type) {
            throw "Unsupported issue form body type: $type"
        }
    }
}

Invoke-Check "GitHub Actions workflow shape" {
    $workflowPath = Join-Path $Root ".github\workflows\validate.yml"
    if (-not (Test-Path -LiteralPath $workflowPath)) {
        throw "Missing .github\workflows\validate.yml"
    }

    $content = Get-Content -LiteralPath $workflowPath -Raw
    foreach ($required in @(
        "name:",
        "on:",
        "jobs:",
        "runs-on: windows-latest",
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        "git rev-parse --verify --quiet",
        "git merge-base",
        "Test-RandOverlay.ps1"
    )) {
        if ($content -notmatch [regex]::Escape($required)) {
            throw "Missing workflow marker: $required"
        }
    }
}

Invoke-Check "Release workflow test gates" {
    $workflowPath = Join-Path $Root ".github\workflows\release-vulkan.yml"
    if (-not (Test-Path -LiteralPath $workflowPath)) {
        throw "Missing .github\workflows\release-vulkan.yml"
    }

    # Index of the first line that runs the script: comments and step names do not count.
    $lines = @(Get-Content -LiteralPath $workflowPath)
    $findRun = {
        param([string]$ScriptName)
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*#' -or $lines[$i] -match '^\s*(-\s+)?name:') { continue }
            if ($lines[$i] -match [regex]::Escape($ScriptName)) { return $i }
        }
        return -1
    }

    $buildLine = & $findRun "Build-RandOverlayRelease.ps1"
    if ($buildLine -lt 0) { throw "release-vulkan.yml never runs Build-RandOverlayRelease.ps1" }
    foreach ($gate in @("Test-Installer.ps1", "Test-Stack.ps1")) {
        $gateLine = & $findRun $gate
        if ($gateLine -lt 0) { throw "release-vulkan.yml never runs $gate" }
        if ($gateLine -gt $buildLine) {
            throw "release-vulkan.yml runs $gate (line $($gateLine + 1)) after Build-RandOverlayRelease.ps1 (line $($buildLine + 1))"
        }
    }
}

Invoke-Check "PowerShell Archipelago fixture" {
    . ([scriptblock]::Create((Get-ScriptFunctionSource $OverlayScript @("ConvertFrom-ArchipelagoLine"))))

    $mismatches = @()
    foreach ($row in Get-ArchipelagoFixtureRows) {
        $actual = ConvertFrom-ArchipelagoLine $row.Input
        if ($actual -cne $row.Expected) {
            $mismatches += "line $($row.Line): expected [$($row.Expected)] got [$actual]"
        }
    }
    if ($mismatches.Count) { throw ($mismatches -join "`n") }
}

Invoke-Check "PowerShell VerticalPercent range" {
    . ([scriptblock]::Create((Get-ScriptFunctionSource $OverlayScript @("Set-ConfigWarning", "Get-IniValue", "Get-ConfigDouble"))))
    function Write-Log($msg) { }

    $section = "Preset.RAC1"
    $warning = "Invalid $section.VerticalPercent; using default."
    $problems = @()
    foreach ($case in @(
        @{ Raw = $null;  Expected = 0.17; Warns = $false },
        @{ Raw = "0.5";  Expected = 0.5;  Warns = $false },
        @{ Raw = "0";    Expected = 0.0;  Warns = $false },
        @{ Raw = "1";    Expected = 1.0;  Warns = $false },
        @{ Raw = "1.5";  Expected = 0.17; Warns = $true },
        @{ Raw = "-0.1"; Expected = 0.17; Warns = $true },
        @{ Raw = "0,5";  Expected = 0.17; Warns = $true },
        @{ Raw = "1e-1"; Expected = 0.17; Warns = $true },
        @{ Raw = "high"; Expected = 0.17; Warns = $true }
    )) {
        $script:ConfigWarning = $null
        $ini = @{ $section = @{} }
        if ($null -ne $case.Raw) { $ini[$section]["VerticalPercent"] = $case.Raw }

        $value = Get-ConfigDouble $ini $section "VerticalPercent" 0.17 0 1
        $expectedWarning = if ($case.Warns) { $warning } else { $null }
        if ($value -ne $case.Expected -or $script:ConfigWarning -cne $expectedWarning) {
            $problems += "VerticalPercent=[$($case.Raw)] gave $value with warning [$script:ConfigWarning]"
        }
    }
    $script:ConfigWarning = $null
    if ($problems.Count) { throw ($problems -join "`n") }
}

Invoke-Check "PowerShell integer settings" {
    . ([scriptblock]::Create((Get-ScriptFunctionSource $OverlayScript @("Set-ConfigWarning", "Get-IniValue", "Get-ConfigInt"))))
    function Write-Log($msg) { }

    $warning = "Invalid General.PollMs; using default."
    $problems = @()
    foreach ($case in @(
        @{ Raw = $null;   Expected = 1500; Warns = $false },
        @{ Raw = "250";   Expected = 250;  Warns = $false },
        @{ Raw = "1";     Expected = 1;    Warns = $false },
        @{ Raw = "0";     Expected = 1500; Warns = $true },
        @{ Raw = "-5";    Expected = 1500; Warns = $true },
        @{ Raw = "+5";    Expected = 1500; Warns = $true },
        @{ Raw = "12abc"; Expected = 1500; Warns = $true },
        @{ Raw = "1.5";   Expected = 1500; Warns = $true }
    )) {
        $script:ConfigWarning = $null
        $ini = @{ General = @{} }
        if ($null -ne $case.Raw) { $ini["General"]["PollMs"] = $case.Raw }

        $value = Get-ConfigInt $ini "General" "PollMs" 1500 1
        $expectedWarning = if ($case.Warns) { $warning } else { $null }
        if ($value -ne $case.Expected -or $script:ConfigWarning -cne $expectedWarning) {
            $problems += "PollMs=[$($case.Raw)] gave $value with warning [$script:ConfigWarning]"
        }
    }
    $script:ConfigWarning = $null
    if ($problems.Count) { throw ($problems -join "`n") }
}

Invoke-Check "PowerShell DIP conversion" {
    Add-Type -AssemblyName WindowsBase
    . ([scriptblock]::Create((Get-ScriptFunctionSource $OverlayScript @("ConvertTo-DipBounds"))))

    # A 150% display: 144 DPI device pixels, so TransformFromDevice scales by 96/144.
    $scale = 96.0 / 144.0
    $fromDevice = New-Object System.Windows.Media.Matrix($scale, 0, 0, $scale, 0, 0)
    $device = @{ Left = -1920; Top = 150; Width = 1920; Height = 1080 }

    $dip = ConvertTo-DipBounds $device $fromDevice
    $expected = @{ Left = -1280; Top = 100; Width = 1280; Height = 720 }
    foreach ($key in $expected.Keys) {
        if ([math]::Abs($dip[$key] - $expected[$key]) -gt 1e-9) {
            throw "150% $key was $($dip[$key]), expected $($expected[$key])"
        }
    }

    $unscaled = ConvertTo-DipBounds $device $null
    foreach ($key in $device.Keys) {
        if ($unscaled[$key] -ne $device[$key]) { throw "No transform changed $key to $($unscaled[$key])" }
    }
}

Invoke-Check "Native command output drain" {
    # More than a pipe buffer on both streams: this times out unless both are
    # read while the child is still running.
    $hostExe = (Get-Process -Id $PID).Path
    $result = Invoke-NativeCommand -FilePath $hostExe -ArgumentList @(
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "[Console]::Out.Write('o' * 200000); [Console]::Error.Write('e' * 100000)"
    ) -TimeoutSeconds 60

    if ($result.ExitCode -ne 0) { throw "Child exited $($result.ExitCode)" }
    if ($result.Stdout.Length -ne 200000) { throw "Read $($result.Stdout.Length) of 200000 stdout characters" }
    if ($result.Stderr.Length -ne 100000) { throw "Read $($result.Stderr.Length) of 100000 stderr characters" }
}

Invoke-Check "AHK /iLib parse" {
    if (-not $Ahk) { throw "AutoHotkey was not resolved." }

    $libOut = Join-Path $env:TEMP ("RandOverlay-AHK-iLib-{0}.txt" -f [Guid]::NewGuid().ToString("N"))
    try {
        foreach ($relativePath in @(
            "RandOverlay.ahk",
            "Lib\RandOverlayParse.ahk",
            "tests\ahk\ParseFixture.ahk"
        )) {
            $result = Invoke-NativeCommand -FilePath $Ahk -ArgumentList @(
                "/ErrorStdOut",
                "/iLib",
                $libOut,
                (Join-Path $Root $relativePath)
            ) -TimeoutSeconds 20

            if ($result.ExitCode -ne 0) {
                throw "$relativePath`: " + (($result.Stdout + $result.Stderr).Trim())
            }
        }
    } finally {
        if (Test-Path -LiteralPath $libOut) {
            Remove-Item -LiteralPath $libOut -Force
        }
    }
}

# Runs even with -SkipAhkRuntime: the harness opens no window, so CI can run it.
Invoke-Check "AHK Archipelago fixture" {
    if (-not $Ahk) { throw "AutoHotkey was not resolved." }

    $expectedRows = @(Get-ArchipelagoFixtureRows).Count
    $result = Invoke-NativeCommand -FilePath $Ahk -ArgumentList @(
        "/force",
        "/ErrorStdOut",
        (Join-Path $Root "tests\ahk\ParseFixture.ahk"),
        $FixturePath
    ) -TimeoutSeconds 20

    $combined = (($result.Stdout + $result.Stderr) -split "\r?\n" | Where-Object { $_ -and $_ -notmatch '^ok line ' }) -join "`n"
    if ($result.ExitCode -ne 0) { throw "ParseFixture.ahk exited $($result.ExitCode)`n$combined" }
    if ($combined -match "(?i)\b(error|warning)\b") { throw $combined }
    # An executable that runs nothing also exits 0 with no output, so the
    # harness must account for every fixture row.
    if ($result.Stdout -notmatch "(?m)^rows=(\d+) failures=0\r?$") {
        throw "ParseFixture.ahk printed no passing summary: $combined"
    }
    if ([int]$Matches[1] -ne $expectedRows) {
        throw "ParseFixture.ahk checked $($Matches[1]) rows; the fixture has $expectedRows"
    }
}

if (-not $SkipAhkRuntime) {
    Invoke-Check "AHK startup self-test" {
        if (-not $Ahk) { throw "AutoHotkey was not resolved." }

        $testLogDir = Join-Path $env:TEMP ("RandOverlaySelfTest-{0}" -f [Guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $testLogDir -Force > $null
        Set-Content -LiteralPath (Join-Path $testLogDir "Client_Test.txt") `
            -Value "[Client at 00:00:00]: self-test seed" -Encoding ASCII

        try {
            $result = Invoke-NativeCommand -FilePath $Ahk -ArgumentList @(
                "/ErrorStdOut",
                (Join-Path $Root "RandOverlay.ahk"),
                "--self-test"
            ) -TimeoutSeconds 8 -Environment @{
                RANDO_OVERLAY_TEST_LOGDIR = $testLogDir
            }

            $combined = ($result.Stdout + $result.Stderr).Trim()
            if ($result.ExitCode -ne 0) {
                throw $combined
            }
            if ($combined -match "(?i)\b(error|warning)\b") {
                throw $combined
            }
        } finally {
            if (Test-Path -LiteralPath $testLogDir) {
                Remove-Item -LiteralPath $testLogDir -Recurse -Force
            }
        }
    }
}

Write-Host ""
if ($Failures.Count -gt 0) {
    Write-Host "Validation failed:" -ForegroundColor Red
    foreach ($failure in $Failures) {
        Write-Host " - $failure"
    }
    exit 1
}

Write-Host "All validation checks passed." -ForegroundColor Green

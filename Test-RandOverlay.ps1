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

    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        throw "Timed out after ${TimeoutSeconds}s: $FilePath $($psi.Arguments)"
    }

    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()

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
    $candidates += "C:\Program Files\AutoHotkey\v1.1.37.02\AutoHotkeyU64.exe"
    $candidates += "C:\Program Files\AutoHotkey\AutoHotkeyU64.exe"
    $candidates += "C:\Program Files\AutoHotkey\AutoHotkey.exe"

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

$Ahk = $null
Invoke-Check "Resolve AutoHotkey" {
    $script:Ahk = Resolve-AutoHotkey $AutoHotkeyPath
    Write-Host "Using $script:Ahk"
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
        "Vulkan-DLL-Version\installer\Build-RandOverlayRelease.ps1",
        "Vulkan-DLL-Version\tests\installer\Test-Installer.ps1"
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
    foreach ($required in @("name:", "on:", "jobs:", "runs-on: windows-latest", "Test-RandOverlay.ps1")) {
        if ($content -notmatch [regex]::Escape($required)) {
            throw "Missing workflow marker: $required"
        }
    }
}

Invoke-Check "AHK /iLib parse" {
    if (-not $Ahk) { throw "AutoHotkey was not resolved." }

    $libOut = Join-Path $env:TEMP "RandOverlay-AHK-iLib.txt"
    if (Test-Path -LiteralPath $libOut) {
        Remove-Item -LiteralPath $libOut -Force
    }

    try {
        $result = Invoke-NativeCommand -FilePath $Ahk -ArgumentList @(
            "/ErrorStdOut",
            "/iLib",
            $libOut,
            (Join-Path $Root "RandOverlay.ahk")
        ) -TimeoutSeconds 20

        if ($result.ExitCode -ne 0) {
            throw (($result.Stdout + $result.Stderr).Trim())
        }
    } finally {
        if (Test-Path -LiteralPath $libOut) {
            Remove-Item -LiteralPath $libOut -Force
        }
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

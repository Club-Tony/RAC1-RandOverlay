# Shared helpers for the installer test scripts. Dot-source this after defining
# $Failures (a List[string]) and $RegistryPath in the calling script.

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { Write-Host "PASS $Message" -ForegroundColor Green }
    else { $Failures.Add($Message); Write-Host "FAIL $Message" -ForegroundColor Red }
}

function Invoke-Setup([string]$Script, [string[]]$Arguments, [int]$ExpectedExit = 0) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne $ExpectedExit) { throw "Setup exit $exitCode, expected $ExpectedExit`n$output" }
    $output
}

function Invoke-InteractiveSetup([string]$Script, [string[]]$Arguments, [string]$InputText) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $quotedArgs = @($Arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' })
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '" ' + ($quotedArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $process.StandardInput.Write($InputText)
    $process.StandardInput.Close()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode=$process.ExitCode; Output=($stdout + $stderr) }
}

function Get-RegistryNames {
    if (-not (Test-Path $RegistryPath)) { return @() }
    @((Get-ItemProperty $RegistryPath).PSObject.Properties |
        Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { $_.Name })
}

function Write-Manifest([string]$Path, [string]$LayerName) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    @{ file_format_version='1.2.0'; layer=@{ name=$LayerName; type='GLOBAL'; library_path='.\test.dll' } } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding UTF8
}

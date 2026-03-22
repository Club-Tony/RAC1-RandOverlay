param([switch]$Debug)

$ErrorActionPreference = "Stop"
$logFile = Join-Path $PSScriptRoot "RandOverlay.log"

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $msg" | Out-File -Append -FilePath $logFile -Encoding utf8
    if ($Debug) { Write-Host "[$ts] $msg" }
}

try {

# ── Configuration ──────────────────────────────────────────────────────────────
$LogDir           = "C:\ProgramData\Archipelago\logs"
$LauncherExe      = "C:\ProgramData\Archipelago\ArchipelagoLauncher.exe"
$DisplaySeconds   = 5
$FontFamily       = "HandelGothic BT"
$FontFallback     = "Bahnschrift"
$script:currentFont = $null
$FontSize         = 38
$VerticalPercent  = 0.17
$BgColor          = "#1E1E1E"
$BgOpacity        = 0.80
$CornerRadius     = 12
$PollMs           = 1500
$Rpcs3Process     = "rpcs3"

# ── Message color map ──────────────────────────────────────────────────────────
$OverlayColor = "#80A0D0"   # RAC1 steel blue (brighter)
$ColorMap = [ordered]@{
    "test"                   = $OverlayColor
    "found their"            = $OverlayColor
    "completed their goal"   = $OverlayColor
    "Congratulations"        = $OverlayColor
    "released all remaining" = $OverlayColor
}

# ── Assemblies ─────────────────────────────────────────────────────────────────
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try { [OverlayWinApi] | Out-Null } catch {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class OverlayWinApi {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hwnd, int index, int newStyle);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hwnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hwnd);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    public const int  GWL_EXSTYLE       = -20;
    public const int  WS_EX_TRANSPARENT = 0x00000020;
    public const int  WS_EX_LAYERED     = 0x00080000;
    public const int  WS_EX_TOOLWINDOW  = 0x00000080;
    public const int  WS_EX_NOACTIVATE  = 0x08000000;
    public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_FRAMECHANGED = 0x0020;

    public static void MakeClickThrough(IntPtr hwnd) {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
    }
    public static void KeepTopmost(IntPtr hwnd) {
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}
"@
}

Write-Log "Assemblies loaded"

# ── State ──────────────────────────────────────────────────────────────────────
$script:lastLineCount  = 0
$script:currentLogFile = $null
$script:overlayEnabled = $true
$script:displayTimer   = $null
$script:window         = $null
$script:textBlock      = $null
# ── Helper functions ───────────────────────────────────────────────────────────
function Find-NewestLog {
    $logs = Get-ChildItem -Path $LogDir -Filter "Launcher_*.txt" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    if ($logs -and $logs.Count -gt 0) { return $logs[0].FullName }
    return $null
}

function Get-Rpcs3Bounds {
    $proc = Get-Process -Name $Rpcs3Process -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $proc -or $proc.MainWindowHandle -eq [IntPtr]::Zero) { return $null }
    $rect = New-Object OverlayWinApi+RECT
    [OverlayWinApi]::GetWindowRect($proc.MainWindowHandle, [ref]$rect) | Out-Null
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0 -or $h -le 0) { return $null }
    return @{ Left = $rect.Left; Top = $rect.Top; Width = $w; Height = $h }
}

function Get-MessageColor($text) {
    foreach ($pattern in $ColorMap.Keys) {
        if ($text.Contains($pattern)) { return $ColorMap[$pattern] }
    }
    return $null
}

function Read-NewLines {
    $newest = Find-NewestLog
    if ($newest -and $newest -ne $script:currentLogFile) {
        Write-Log "Switched to log: $newest"
        $script:currentLogFile = $newest
        # #8 HIGH: Seed new log instead of resetting to 0 (prevents message flood)
        try {
            $seedLines = @(Get-Content -Path $newest -ErrorAction Stop)
            $script:lastLineCount = $seedLines.Count
        } catch { $script:lastLineCount = 0 }
    }
    if (-not $script:currentLogFile -or -not (Test-Path $script:currentLogFile)) { return @() }

    try {
        $lines = @(Get-Content -Path $script:currentLogFile -ErrorAction Stop)
    } catch {
        Write-Host "  [read error] $($_.Exception.Message)"
        return @()
    }
    $newMessages = @()

    if ($lines.Count -gt $script:lastLineCount) {
        for ($i = $script:lastLineCount; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\[(FileLog|Client) at [^\]]+\]:\s*(.*)') {
                $msg = $Matches[2]
                $color = Get-MessageColor $msg
                if ($color) {
                    $msg = ($msg -replace '\s*\(.*\)\s*$', '').Trim()
                    $newMessages += @{ Text = $msg; Color = $color }
                }
            }
        }
        $script:lastLineCount = $lines.Count
    }
    return $newMessages
}

function Position-Overlay {
    if (-not $script:window) { return }
    $bounds = Get-Rpcs3Bounds
    if (-not $bounds) {
        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $bounds = @{ Left = $screen.Left; Top = $screen.Top; Width = $screen.Width; Height = $screen.Height }
    }
    $script:window.UpdateLayout()
    $w = $script:window.ActualWidth
    if ($w -le 0) { $w = 500 }
    $script:window.Left = $bounds.Left + ($bounds.Width / 2) - ($w / 2)
    $script:window.Top  = $bounds.Top + ($bounds.Height * $VerticalPercent)
}

function Show-Message($text, $color) {
    if (-not $script:overlayEnabled -or -not $script:window) { return }

    Write-Log "Show: $text [$color]"

    if ($script:displayTimer) { $script:displayTimer.Stop(); $script:displayTimer = $null }

    # Set text and position
    $script:textBlock.Text = $text
    $script:window.Visibility = "Visible"
    Position-Overlay

    # Re-assert topmost
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
    [OverlayWinApi]::KeepTopmost($helper.Handle)

    # Set text color (static — no glow animation)
    $targetColor = [System.Windows.Media.ColorConverter]::ConvertFromString($color)
    $script:activeBrush = New-Object System.Windows.Media.SolidColorBrush($targetColor)
    $script:activeBrush.Freeze()
    $script:textBlock.Foreground = $script:activeBrush

    # Fade in (300ms)
    $script:window.Opacity = 0
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fadeIn.From = 0.0
    $fadeIn.To = 1.0
    $fadeIn.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(300))
    $fadeIn.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
    $script:window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)

    # Schedule fade-out after display duration
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($DisplaySeconds)
    $timer.Add_Tick({
        $script:displayTimer.Stop()
        $script:displayTimer = $null
        if ($script:window) {
            $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation
            $fadeOut.From = 1.0
            $fadeOut.To = 0.0
            $fadeOut.Duration = New-Object System.Windows.Duration([TimeSpan]::FromMilliseconds(500))
            $fadeOut.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::HoldEnd
            $fadeOut.Add_Completed({
                if ($script:window) {
                    $script:window.Visibility = "Hidden"
                    $script:window.BeginAnimation([System.Windows.Window]::OpacityProperty, $null)
                }
            })
            $script:window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeOut)
        }
    })
    $script:displayTimer = $timer
    $timer.Start()
}

# ── Startup ────────────────────────────────────────────────────────────────────
Write-Log "Starting Archipelago Overlay"

if (-not (Get-Process -Name "ArchipelagoLauncher" -ErrorAction SilentlyContinue)) {
    $result = [System.Windows.MessageBox]::Show(
        "Archipelago Launcher is not running. Launch it?",
        "Archipelago Overlay",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($result -eq "Yes") {
        Start-Process $LauncherExe
        Start-Sleep -Seconds 3
    }
}

$script:currentLogFile = Find-NewestLog
if (-not $script:currentLogFile) {
    [System.Windows.MessageBox]::Show(
        "No Archipelago log files found in:`n$LogDir",
        "Archipelago Overlay",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning)
    exit 1
}

Write-Log "Using log: $($script:currentLogFile)"

# Seed line count (skip existing content)
try {
    $seedLines = @(Get-Content -Path $script:currentLogFile -ErrorAction Stop)
    $script:lastLineCount = $seedLines.Count
    Write-Host "Seeded at $($script:lastLineCount) lines"
    Write-Log "Seeded at line $($script:lastLineCount)"
} catch {
    Write-Host "Seed failed: $($_.Exception.Message)"
    $script:lastLineCount = 0
}

# ── Build WPF window ──────────────────────────────────────────────────────────
$font = $FontFamily
try {
    $sysFonts = [System.Windows.Media.Fonts]::SystemFontFamilies | ForEach-Object { $_.Source }
    if ($font -notin $sysFonts) { $font = $FontFallback }
    $script:currentFont = $font
} catch { $font = $FontFallback }
Write-Log "Font: $font"

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ArchipelagoOverlay"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        SizeToContent="WidthAndHeight" Opacity="0">
    <Border CornerRadius="$CornerRadius" Padding="20,10,20,10"
            Background="$BgColor" Opacity="$BgOpacity">
        <Border.Effect>
            <DropShadowEffect Color="Black" BlurRadius="20" ShadowDepth="4" Opacity="0.6" />
        </Border.Effect>
        <TextBlock x:Name="MsgText" FontFamily="$font" FontSize="$FontSize"
                   FontWeight="SemiBold" Foreground="White" TextAlignment="Center" />
    </Border>
</Window>
"@

$xmlReader = New-Object System.Xml.XmlNodeReader $xaml
$script:window = [System.Windows.Markup.XamlReader]::Load($xmlReader)
$script:textBlock = $script:window.FindName("MsgText")
Write-Log "WPF window created"

$script:window.Add_Loaded({
    Write-Log "Window loaded, setting up click-through"
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
    [OverlayWinApi]::MakeClickThrough($helper.Handle)
    [OverlayWinApi]::KeepTopmost($helper.Handle)
    $script:window.Visibility = "Hidden"

    # ── Poll timer ─────────────────────────────────────────────────────────
    $poll = New-Object System.Windows.Threading.DispatcherTimer
    $poll.Interval = [TimeSpan]::FromMilliseconds($PollMs)
    $poll.Add_Tick({
        try {
            $msgs = @(Read-NewLines)
            if ($msgs.Count -gt 0) {
                $latest = $msgs[$msgs.Count - 1]
                Write-Host "  >> $($latest.Text)"
                Show-Message $latest.Text $latest.Color
            }
        } catch {
            Write-Log "Poll error: $($_.Exception.Message)"
        }
    })
    $poll.Start()
    Write-Log "Poll timer started (${PollMs}ms)"

    # ── Hotkey poll (Ctrl+Alt+A) ───────────────────────────────────────────
    $hk = New-Object System.Windows.Threading.DispatcherTimer
    $hk.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:hkDown = $false
    $hk.Add_Tick({
        try {
            $ctrl = [System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control
            $alt  = [System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Alt
            $aKey = [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::A)
            if ($ctrl -and $alt -and $aKey) {
                if (-not $script:hkDown) {
                    $script:hkDown = $true
                    $script:overlayEnabled = -not $script:overlayEnabled
                    Write-Log "Overlay toggled: $($script:overlayEnabled)"
                    if ($script:overlayEnabled) {
                        Write-Host "  >> Overlay ON"
                        if ($script:displayTimer) { $script:displayTimer.Stop(); $script:displayTimer = $null }
                        $script:textBlock.Text = "Overlay ON"
                        $tc = [System.Windows.Media.ColorConverter]::ConvertFromString($OverlayColor)
                        $b = New-Object System.Windows.Media.SolidColorBrush($tc); $b.Freeze()
                        $script:textBlock.Foreground = $b
                        $script:window.Opacity = 1.0
                        $script:window.Visibility = "Visible"
                        Position-Overlay
                        $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
                        [OverlayWinApi]::KeepTopmost($helper.Handle)
                        if ($script:toggleTimer) { $script:toggleTimer.Stop() }
                        $script:toggleTimer = New-Object System.Windows.Threading.DispatcherTimer
                        $script:toggleTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
                        $script:toggleTimer.Add_Tick({
                            $script:toggleTimer.Stop()
                            $script:window.Opacity = 0
                            $script:window.Visibility = "Hidden"
                        })
                        $script:toggleTimer.Start()
                    } else {
                        Write-Host "  >> Overlay OFF"
                        if ($script:displayTimer) { $script:displayTimer.Stop(); $script:displayTimer = $null }
                        $script:textBlock.Text = "Overlay OFF"
                        $tc = [System.Windows.Media.ColorConverter]::ConvertFromString($OverlayColor)
                        $b = New-Object System.Windows.Media.SolidColorBrush($tc); $b.Freeze()
                        $script:textBlock.Foreground = $b
                        $script:window.Opacity = 1.0
                        $script:window.Visibility = "Visible"
                        Position-Overlay
                        if ($script:toggleTimer) { $script:toggleTimer.Stop() }
                        $script:toggleTimer = New-Object System.Windows.Threading.DispatcherTimer
                        $script:toggleTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
                        $script:toggleTimer.Add_Tick({
                            $script:toggleTimer.Stop()
                            $script:window.Opacity = 0
                            $script:window.Visibility = "Hidden"
                        })
                        $script:toggleTimer.Start()
                    }
                }
            } else { $script:hkDown = $false }
        } catch {
            $script:hkDown = $false
            Write-Log "Hotkey error: $($_.Exception.Message)"
        }
    })
    $hk.Start()

    # ── Font toggle poll (Ctrl+Alt+F) ─────────────────────────────────────
    $fk = New-Object System.Windows.Threading.DispatcherTimer
    $fk.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:fkDown = $false
    $fk.Add_Tick({
        try {
            $ctrl = [System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Control
            $alt  = [System.Windows.Forms.Control]::ModifierKeys -band [System.Windows.Forms.Keys]::Alt
            $fKey = [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::F)
            if ($ctrl -and $alt -and $fKey) {
                if (-not $script:fkDown) {
                    $script:fkDown = $true
                    if ($script:currentFont -eq "HandelGothic BT") {
                        $script:currentFont = "Bahnschrift"
                    } else {
                        $script:currentFont = "HandelGothic BT"
                    }
                    $script:textBlock.FontFamily = New-Object System.Windows.Media.FontFamily($script:currentFont)
                    Write-Host "  >> Font: $($script:currentFont)"
                    Show-Message "Font: $($script:currentFont)" $OverlayColor
                }
            } else { $script:fkDown = $false }
        } catch {
            $script:fkDown = $false
        }
    })
    $fk.Start()

    # ── Topmost re-assert ──────────────────────────────────────────────────
    $tm = New-Object System.Windows.Threading.DispatcherTimer
    $tm.Interval = [TimeSpan]::FromSeconds(2)
    $tm.Add_Tick({
        if ($script:window.Visibility -eq "Visible") {
            $h = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
            [OverlayWinApi]::KeepTopmost($h.Handle)
        }
    })
    $tm.Start()

    Write-Log "All timers running. Overlay ready."
})

# ── Tray icon ──────────────────────────────────────────────────────────────────
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$notifyIcon.Text = "Archipelago Overlay (Ctrl+Alt+A to toggle)"
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add("Toggle Overlay", $null, {
    $script:overlayEnabled = -not $script:overlayEnabled
    Write-Log "Tray toggle: $($script:overlayEnabled)"
    $msg = if ($script:overlayEnabled) { "Overlay ON" } else { "Overlay OFF" }
    Write-Host "  >> $msg"
    if ($script:displayTimer) { $script:displayTimer.Stop(); $script:displayTimer = $null }
    $script:textBlock.Text = $msg
    $tc = [System.Windows.Media.ColorConverter]::ConvertFromString($OverlayColor)
    $b = New-Object System.Windows.Media.SolidColorBrush($tc); $b.Freeze()
    $script:textBlock.Foreground = $b
    $script:window.Opacity = 1.0
    $script:window.Visibility = "Visible"
    Position-Overlay
    if ($script:toggleTimer) { $script:toggleTimer.Stop() }
    $script:toggleTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:toggleTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:toggleTimer.Add_Tick({
        $script:toggleTimer.Stop()
        $script:window.Opacity = 0
        $script:window.Visibility = "Hidden"
    })
    $script:toggleTimer.Start()
})
[void]$menu.Items.Add("Exit", $null, {
    Write-Log "Exit requested"
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    if ($script:window) { $script:window.Close() }
})
$notifyIcon.ContextMenuStrip = $menu

$script:window.Add_Closed({
    Write-Log "Window closed, cleaning up"
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
})

# ── Run event loop ─────────────────────────────────────────────────────────────
Write-Log "Starting event loop"
$script:window.Show()
Start-Sleep -Milliseconds 100  # Brief pause for window composition

# Use WinForms message loop — more stable than WPF Application.Run() in PowerShell
$script:running = $true
$script:window.Add_Closed({ $script:running = $false })
# ── Show startup notification ──────────────────────────────────────────────────
Show-Message "Archipelago Overlay ready - waiting for events" $OverlayColor
Write-Host ">> Startup overlay shown"
Write-Log "Startup overlay shown"

Write-Host "Overlay running! Monitoring: $(Split-Path $script:currentLogFile -Leaf)"
Write-Host "Waiting for game events... (this window stays open)"
Write-Host ""
Write-Log "Event loop running"
while ($script:running) {
    try {
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ }
        )
    } catch {
        Write-Log "Pump error (non-fatal): $($_.Exception.Message)"
    }
    Start-Sleep -Milliseconds 30
}

} catch {
    $errMsg = $_.Exception.Message
    $errStack = $_.ScriptStackTrace
    Write-Log "FATAL: $errMsg`n$errStack"
    [System.Windows.MessageBox]::Show(
        "Archipelago Overlay crashed:`n`n$errMsg`n`nSee log: $logFile",
        "Archipelago Overlay Error",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error) | Out-Null
}

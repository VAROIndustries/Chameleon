<#
.SYNOPSIS
    Chameleon (Tray) - a system-tray version of the Wi-Fi-on-dock switcher.

.DESCRIPTION
    Sits in the notification area with a coloured dot:
        green  = target device present  (on the "connected" network)
        grey   = target device absent   (on the "disconnected" network)
    Right-click for a menu: toggle auto-switching, switch manually, open the
    log, or exit. Balloon tips announce each switch.

    Detection is done by polling every $pollSeconds via Get-PnpDevice, which
    plays nicely with the WinForms message loop. Logs next to this script.

.NOTES
    - Wi-Fi profiles named below must already be saved on this machine.
    - Run Get-AttachedDevices.ps1 to find the device match string.
    - Launch silently (no console window) with Chameleon-Tray.vbs.
#>

# ---- CONFIGURE THESE (defaults; overridden by Chameleon.config.json if present) ----
$targetDeviceMatch    = "*Your Monitor Or Dock Name*"
$wifiWhenConnected    = "OfficeWiFi"
$wifiWhenDisconnected = "HomeWiFi"
$wifiInterface        = "Wi-Fi"
$pollSeconds          = 4
# --------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logFile   = Join-Path $scriptDir 'Chameleon-Tray.log'

# Single source of truth: share Chameleon.config.json with the other scripts if present.
$configPath = Join-Path $scriptDir 'Chameleon.config.json'
if (Test-Path $configPath) {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    if ($cfg.deviceMatch)          { $targetDeviceMatch    = $cfg.deviceMatch }
    if ($cfg.wifiWhenConnected)    { $wifiWhenConnected    = $cfg.wifiWhenConnected }
    if ($cfg.wifiWhenDisconnected) { $wifiWhenDisconnected = $cfg.wifiWhenDisconnected }
    if ($cfg.wifiInterface)        { $wifiInterface        = $cfg.wifiInterface }
}

# Shared state
$script:autoSwitch     = $true
$script:currentProfile = $null
$script:lastPresent    = $null

function Write-Log {
    param([string]$Message)
    Add-Content -Path $logFile -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
}

function Test-DevicePresent {
    [bool](Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like $targetDeviceMatch })
}

function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 12, 12)
    $g.DrawEllipse([System.Drawing.Pens]::Black, 2, 2, 11, 11)
    $g.Dispose(); $brush.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    return $icon
}

$iconOn  = New-DotIcon ([System.Drawing.Color]::LimeGreen)
$iconOff = New-DotIcon ([System.Drawing.Color]::Gray)

function Set-WifiNetwork {
    param([string]$ProfileName, [switch]$Announce)
    if ($script:currentProfile -eq $ProfileName) { return }
    $script:currentProfile = $ProfileName

    Write-Log "Switching Wi-Fi to '$ProfileName'"
    netsh wlan disconnect interface="$wifiInterface" | Out-Null
    Start-Sleep -Milliseconds 800
    netsh wlan connect name="$ProfileName" interface="$wifiInterface" | Out-Null

    if ($Announce) {
        $notify.ShowBalloonTip(3000, "Chameleon", "Switched to '$ProfileName'",
            [System.Windows.Forms.ToolTipIcon]::Info)
    }
}

# ---- Tray icon + menu ----
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon    = $iconOff
$notify.Text    = "Chameleon"
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$statusItem = New-Object System.Windows.Forms.ToolStripMenuItem "Starting..."
$statusItem.Enabled = $false
$menu.Items.Add($statusItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$autoItem = New-Object System.Windows.Forms.ToolStripMenuItem "Auto-switch"
$autoItem.CheckOnClick = $true
$autoItem.Checked = $script:autoSwitch
$autoItem.Add_Click({
    $script:autoSwitch = $autoItem.Checked
    Write-Log "Auto-switch set to $($script:autoSwitch)"
})
$menu.Items.Add($autoItem) | Out-Null

$connectItem = New-Object System.Windows.Forms.ToolStripMenuItem "Switch to '$wifiWhenConnected' now"
$connectItem.Add_Click({ Set-WifiNetwork -ProfileName $wifiWhenConnected -Announce })
$menu.Items.Add($connectItem) | Out-Null

$disconnectItem = New-Object System.Windows.Forms.ToolStripMenuItem "Switch to '$wifiWhenDisconnected' now"
$disconnectItem.Add_Click({ Set-WifiNetwork -ProfileName $wifiWhenDisconnected -Announce })
$menu.Items.Add($disconnectItem) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$logItem = New-Object System.Windows.Forms.ToolStripMenuItem "Open log"
$logItem.Add_Click({
    if (Test-Path $logFile) { Start-Process notepad.exe $logFile }
    else { [System.Windows.Forms.MessageBox]::Show("No log yet.", "Chameleon") | Out-Null }
})
$menu.Items.Add($logItem) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "Exit"
$exitItem.Add_Click({
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    Write-Log "Chameleon (Tray) exited."
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($exitItem) | Out-Null

$notify.ContextMenuStrip = $menu

# ---- Poll loop ----
function Update-State {
    param([switch]$Startup)
    $present = Test-DevicePresent

    if ($present) {
        $notify.Icon = $iconOn
        $statusItem.Text = "Dock detected -> $wifiWhenConnected"
        $notify.Text = "Chameleon - docked ($wifiWhenConnected)"
    } else {
        $notify.Icon = $iconOff
        $statusItem.Text = "No dock -> $wifiWhenDisconnected"
        $notify.Text = "Chameleon - undocked ($wifiWhenDisconnected)"
    }

    if ($present -ne $script:lastPresent) {
        if ($script:autoSwitch) {
            $target = if ($present) { $wifiWhenConnected } else { $wifiWhenDisconnected }
            # Announce only on genuine changes, not the initial startup sync.
            if ($Startup) { Set-WifiNetwork -ProfileName $target }
            else          { Set-WifiNetwork -ProfileName $target -Announce }
        }
        $script:lastPresent = $present
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]($pollSeconds * 1000)
$timer.Add_Tick({ Update-State })

Write-Log "Chameleon (Tray) started. Target device match: '$targetDeviceMatch'"
Update-State -Startup
$timer.Start()

$notify.ShowBalloonTip(2000, "Chameleon", "Watching for '$targetDeviceMatch'",
    [System.Windows.Forms.ToolTipIcon]::Info)

$appContext = New-Object System.Windows.Forms.ApplicationContext
[System.Windows.Forms.Application]::Run($appContext)

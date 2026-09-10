#Requires -Version 3
<#
    GCL Ping Monitor
    ----------------
    Simple Windows desktop ping monitor for the support desk.
      * Add / remove hosts from the GUI (saved automatically)
      * Every host is pinged on an interval; grid turns RED when a host is down
      * A loud alarm sounds while any un-acknowledged host is down
      * "Acknowledge" silences the current alarm; a NEW host going down re-arms it
      * All state changes are written to an event log

    Config + log location:  %APPDATA%\GCL-PingMonitor\

    Supported: Windows 10 / 11 and Windows Server 2012 R2 -> 2025.
      - Needs Windows PowerShell 4.0 or newer + .NET Framework 4.5 or newer.
      - Windows 10/11 and Server 2016+ already have PowerShell 5.1 (nothing to do).
      - Server 2012 / 2012 R2: install "Windows Management Framework 5.1" (free)
        if PowerShell is still 3.0/4.0 - or at least WMF 4.0.

    Run it with:  Start-PingMonitor.cmd   (or  powershell -STA -ExecutionPolicy Bypass -File GCL-PingMonitor.ps1)
#>

param(
    [int]$IntervalSeconds = 5,
    [int]$TimeoutMs       = 1000,
    [int]$FailThreshold   = 2,
    [switch]$NoUpdate                # skip the GitHub self-update check
)

# --- minimum-platform guard (friendly message instead of a cryptic failure) ---
if ($PSVersionTable.PSVersion.Major -lt 4) {
    $msg = "GCL Ping Monitor needs Windows PowerShell 4.0 or newer.`n`n" +
           "This machine has $($PSVersionTable.PSVersion).`n`n" +
           "Install 'Windows Management Framework 5.1' from Microsoft, then run it again."
    try { Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show($msg, 'GCL Ping Monitor', 'OK', 'Warning') | Out-Null }
    catch { [Console]::Error.WriteLine($msg) }
    exit 1
}

# ---------------------------------------------------------------------------
#  Self-update settings  (edit these if you fork the repo)
# ---------------------------------------------------------------------------
$script:Repo         = 'badshashorif/gcl-ping-monitor'
$script:Branch       = 'main'
$script:UpdateFiles  = @('GCL-PingMonitor.ps1', 'Start-PingMonitor.cmd', 'install.ps1', 'README.md', 'LICENSE')
$script:ScriptPath   = $MyInvocation.MyCommand.Path
$script:ScriptDir    = Split-Path -Parent $script:ScriptPath
$script:IsGitCheckout = Test-Path (Join-Path $script:ScriptDir '.git')

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

try {
    Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr hwnd, bool bInvert);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hwnd, int nCmdShow);
'@
} catch { }

# ---------------------------------------------------------------------------
#  Single instance only
# ---------------------------------------------------------------------------
#  Two copies running at once means acknowledging the alarm in one window
#  leaves the other one still sounding - which looks exactly like a broken
#  Acknowledge button. Only one instance is ever allowed.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\GCL-PingMonitor-SingleInstance')
$script:HaveMutex = $false
try { $script:HaveMutex = $script:Mutex.WaitOne(0, $false) } catch { $script:HaveMutex = $true }

# A named event is how a second launch asks the running one to show itself.
# Matching on MainWindowTitle does NOT work here: the console host is hidden,
# so Process.MainWindowTitle comes back empty and the second copy would just
# exit silently - which looks exactly like "the app won't open".
$script:ShowEvent = $null
try {
    $script:ShowEvent = New-Object System.Threading.EventWaitHandle($false,
        [System.Threading.EventResetMode]::AutoReset, 'Global\GCL-PingMonitor-Show')
} catch { }

if (-not $script:HaveMutex) {
    try { if ($script:ShowEvent) { [void]$script:ShowEvent.Set() } } catch { }
    exit
}

# ---------------------------------------------------------------------------
#  Paths / config
# ---------------------------------------------------------------------------
$script:AppDir     = Join-Path $env:APPDATA 'GCL-PingMonitor'
if (-not (Test-Path $script:AppDir)) { New-Item -ItemType Directory -Path $script:AppDir -Force | Out-Null }
$script:ConfigPath = Join-Path $script:AppDir 'config.json'
$script:LogPath    = Join-Path $script:AppDir 'events.log'

$script:Config = $null
if (Test-Path $script:ConfigPath) {
    try { $script:Config = Get-Content $script:ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $script:Config = $null }
}
if (-not $script:Config) {
    $script:Config = [pscustomobject]@{
        IntervalSeconds = $IntervalSeconds
        TimeoutMs       = $TimeoutMs
        FailThreshold   = $FailThreshold
        AlwaysOnTop     = $false
        AutoUpdate      = $true
        UpdateHours     = 6
        TextSize        = 12
        Hosts           = @()
    }
}
# A hashtable, not a switch: an overlapping/duplicated switch clause returns an
# ARRAY here and the default silently becomes garbage. See the note further down.
$script:Defaults = @{
    IntervalSeconds = $IntervalSeconds
    TimeoutMs       = $TimeoutMs
    FailThreshold   = $FailThreshold
    AlwaysOnTop     = $false
    AutoUpdate      = $true
    UpdateHours     = 6
    TextSize        = 12
    LossWindow      = 100
    SplitPercent    = 72
    Hosts           = @()
    AlarmSound      = 'siren'    # key from $script:SoundDefs, or 'custom'
    AlarmFile       = ''         # the .wav when AlarmSound = 'custom'
    AlarmRepeatMs   = 1400       # how often the alarm sound is re-started
    AlarmAutoStopMin = 5         # silence an un-acknowledged alarm after N min (0 = never)
    UpSoundEnabled  = $true      # a short sound when a host comes back
    UpSound         = 'chime'
    UpSoundFile     = ''
    WinW            = 1180       # window size / position are remembered so a
    WinH            = 780        # small "corner of the screen" window stays small
    WinX            = -32000     # -32000 = never positioned yet -> centre
    WinY            = -32000
    WinMax          = $false
}
foreach ($p in @($script:Defaults.Keys)) {
    if ($null -eq $script:Config.$p) {
        $script:Config | Add-Member -NotePropertyName $p -NotePropertyValue $script:Defaults[$p] -Force
    }
}

# ---- notification settings (email / telegram / sms) -------------------------
function Set-Default {
    param($Obj, [string]$Name, $Value)
    if ($null -eq $Obj.$Name) { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}
# Called at startup AND after an import: a backup written by an older version
# replaces the whole Notify object and can be missing a channel entirely.
function Initialize-NotifyDefaults {
if ($null -eq $script:Config.Notify) {
    $script:Config | Add-Member -NotePropertyName Notify -NotePropertyValue ([pscustomobject]@{}) -Force
}
$n = $script:Config.Notify
Set-Default $n 'OnDown'       $true
Set-Default $n 'OnRecover'    $true
Set-Default $n 'BatchSeconds' 20
Set-Default $n 'MaxPerHour'   20
# A single message can be slept through, and then the outage is unattended until
# morning. While a host is down AND un-acknowledged, re-send every N minutes.
# Acknowledging - from the desk, a browser or a phone - stops it. 0 = off.
Set-Default $n 'RepeatMin'    0
Set-Default $n 'Email'    ([pscustomobject]@{})
Set-Default $n 'Telegram' ([pscustomobject]@{})
Set-Default $n 'Sms'      ([pscustomobject]@{})
Set-Default $n.Email 'Enabled' $false; Set-Default $n.Email 'SmtpServer' ''; Set-Default $n.Email 'Port' 587
Set-Default $n.Email 'UseSsl'  $true;  Set-Default $n.Email 'User' '';       Set-Default $n.Email 'PassEnc' ''
Set-Default $n.Email 'From' '';        Set-Default $n.Email 'To' ''
# Auto = port 465 means implicit SSL, anything else means STARTTLS if UseSsl.
# The two are NOT interchangeable and .NET's SmtpClient can only do STARTTLS.
Set-Default $n.Email 'Security' 'Auto'
Set-Default $n.Telegram 'Enabled' $false; Set-Default $n.Telegram 'TokenEnc' ''; Set-Default $n.Telegram 'ChatId' ''
Set-Default $n.Sms 'Enabled' $false;   Set-Default $n.Sms 'Numbers' ''
Set-Default $n.Sms 'UrlTemplate' 'https://YOUR-SMS-GATEWAY/api/sendsms?api_key={apikey}&msisdn={phone}&message={message}'
Set-Default $n.Sms 'Method' 'GET';     Set-Default $n.Sms 'BodyTemplate' ''
Set-Default $n.Sms 'ContentType' 'application/x-www-form-urlencoded'
Set-Default $n.Sms 'ApiKeyEnc' ''
# The offline channel: run a local program (GSM modem / smssend / gammu / a .bat).
# Needs no internet, which is the whole point - when the link is down the HTTP
# SMS gateway is exactly what cannot be reached.
Set-Default $n 'Command' ([pscustomobject]@{})
Set-Default $n.Command 'Enabled'    $false
Set-Default $n.Command 'Path'       ''
Set-Default $n.Command 'Args'       '{phone} "{message}"'
Set-Default $n.Command 'Numbers'    ''
Set-Default $n.Command 'WorkDir'    ''
Set-Default $n.Command 'PerHost'    $false
Set-Default $n.Command 'TimeoutSec' 60
Set-Default $n.Command 'Modem'      ''     # modem name as shown by Windows -> {modem}
Set-Default $n.Command 'ModemPort'  ''     # its COM port                   -> {port}
# ntfy - the phone channel. Email and Telegram deliver a NOTIFICATION; ntfy is
# the only one that can deliver an ALARM: priority 5 ("urgent") makes the
# Android app ring through Do Not Disturb and vibrate continuously until it is
# swiped away. That is the whole reason it exists here, so the two priorities
# are separate settings - a recovery must never be as loud as an outage.
Set-Default $n 'Ntfy' ([pscustomobject]@{})
Set-Default $n.Ntfy 'Enabled'      $false
Set-Default $n.Ntfy 'Server'       'https://ntfy.sh'
Set-Default $n.Ntfy 'Topic'        ''
Set-Default $n.Ntfy 'TokenEnc'     ''      # optional; self-hosted with auth
Set-Default $n.Ntfy 'UserEnc'      ''      # optional; basic auth alternative
Set-Default $n.Ntfy 'DownPriority' 5       # urgent - bypasses Do Not Disturb
Set-Default $n.Ntfy 'UpPriority'   3       # default - a normal notification
Set-Default $n.Ntfy 'ClickUrl'     ''      # tapping the notification opens this
}
Initialize-NotifyDefaults

# ---- web dashboard ----------------------------------------------------------
# Serves the same view over HTTP so a browser or a phone on the LAN sees exactly
# what the desk sees. Off by default: turning it on opens a port.
function Initialize-WebDefaults {
if ($null -eq $script:Config.Web) {
    $script:Config | Add-Member -NotePropertyName Web -NotePropertyValue ([pscustomobject]@{}) -Force
}
$w = $script:Config.Web
Set-Default $w 'Enabled'  $false
Set-Default $w 'Port'     8080
# 'any' needs a one-off URL reservation (the Settings dialog offers to make it);
# 'local' is 127.0.0.1 only and always works without administrator.
Set-Default $w 'Bind'     'any'
Set-Default $w 'TokenEnc' ''
Set-Default $w 'AllowAck' $true
}
Initialize-WebDefaults

# Viewer mode: let the Linux server do the pinging and the alerting, and use
# this window as what it is actually good at - a loud screen on a desk.
#
# The point is that a monitor which only runs while somebody's PC is switched
# on is not a monitor. With this on, the PC can be rebooted, moved or turned
# off for the night and nothing stops being watched.
#
# The alarm still sounds HERE, because that is the part a server cannot do.
function Initialize-RemoteDefaults {
if ($null -eq $script:Config.Remote) {
    $script:Config | Add-Member -NotePropertyName Remote -NotePropertyValue ([pscustomobject]@{}) -Force
}
$r = $script:Config.Remote
Set-Default $r 'Enabled'  $false
# e.g. https://ping.monitor.grameencybernet.net  - no trailing slash, no token
Set-Default $r 'Url'      ''
# DPAPI-encrypted like every other secret here, so config.json never holds it
Set-Default $r 'TokenEnc' ''
}
Initialize-RemoteDefaults

function Test-RemoteMode {
    $r = $script:Config.Remote
    [bool]($r -and $r.Enabled -and [string]$r.Url)
}

# ---------------------------------------------------------------------------
#  Runtime state
# ---------------------------------------------------------------------------
$script:Hosts        = New-Object System.Collections.Generic.List[object]
# declared here, not down in the web section, so the startup lines written long
# before the server exists still reach the dashboard's log panel
$script:WebLogRing   = New-Object System.Collections.ArrayList
$script:CycleRunning = $false
$script:Paused       = $false
$script:LastCheck    = $null
$script:AlarmActive  = $false

function New-HostState {
    param($Label, $Target, $Enabled = $true, $AlarmEnabled = $true)
    [pscustomobject]@{
        Label      = $Label
        Target     = $Target
        Enabled    = [bool]$Enabled
        # Alarm off = still pinged, still shown, still logged - but it makes no
        # sound and sends no notification. Different from Enabled = $false,
        # which stops monitoring the host altogether.
        AlarmEnabled = [bool]$AlarmEnabled
        Sel        = $false      # the tick box in the first column (not saved)
        Status     = 'INIT'      # INIT | UP | WARN | DOWN | OFF
        Latency    = $null
        LastChange = $null
        DownSince  = $null
        Acked      = $false
        FailCount  = 0
        Task       = $null
        Ping       = $null
        SyncError  = $null
        StyleKey   = ''          # cached row style so we only restyle on change
        # In viewer mode the loss figure is the SERVER's, measured over its own
        # window. Recomputing it here from a history this PC never collected
        # would be a different number wearing the same label.
        RemoteLoss = $null
        Hist       = (New-Object System.Collections.Generic.Queue[bool])  # rolling ping results
        Lost       = 0           # failures currently inside Hist
        TotSent    = 0           # lifetime counters, for the tooltip
        TotLost    = 0
        LastRtts   = (New-Object System.Collections.Generic.Queue[int])   # for average latency
    }
}

# Rolling packet-loss window. Keeping a running "Lost" counter and adjusting it
# as samples fall out of the queue avoids rescanning the whole history 3x/sec.
function Add-PingSample {
    param($h, [bool]$Ok, $Rtt)
    $h.TotSent++
    if (-not $Ok) { $h.TotLost++ }
    $h.Hist.Enqueue($Ok)
    if (-not $Ok) { $h.Lost++ }
    $win = [int]$script:Config.LossWindow
    if ($win -lt 5) { $win = 5 }
    while ($h.Hist.Count -gt $win) {
        if (-not $h.Hist.Dequeue()) { $h.Lost-- }
    }
    if ($Ok -and $null -ne $Rtt) {
        $h.LastRtts.Enqueue([int]$Rtt)
        while ($h.LastRtts.Count -gt 20) { [void]$h.LastRtts.Dequeue() }
    }
}

function Get-LossPercent {
    param($h)
    if ($null -ne $h.RemoteLoss) { return [int]$h.RemoteLoss }
    if ($h.Hist.Count -eq 0) { return $null }
    [int][Math]::Round(($h.Lost * 100.0) / $h.Hist.Count)
}

function Reset-HostStats {
    param($h)
    $h.Hist.Clear(); $h.LastRtts.Clear()
    $h.Lost = 0; $h.TotSent = 0; $h.TotLost = 0
}

# Missing flags mean "on" - a config written by an older version has no Alarm
# property at all, and silently muting somebody's hosts on upgrade would be the
# worst possible default.
function Get-SavedFlag {
    param($Entry, [string]$Name)
    if ($null -eq $Entry.$Name) { return $true }
    [bool]$Entry.$Name
}

# Not in viewer mode: there the server's list is the list, and loading these
# first would show a screenful of hosts for a few seconds and then log every one
# of them being taken away again.
if (-not (Test-RemoteMode)) {
    foreach ($c in @($script:Config.Hosts)) {
        if ($c -and $c.Target) {
            $en = Get-SavedFlag $c 'Enabled'
            $h  = New-HostState -Label ([string]$c.Label) -Target ([string]$c.Target) -Enabled $en `
                                -AlarmEnabled (Get-SavedFlag $c 'Alarm')
            if (-not $en) { $h.Status = 'OFF' }
            $script:Hosts.Add($h)
        }
    }
}

function Format-Duration {
    param([TimeSpan]$ts)
    if ($ts.TotalSeconds -lt 60)    { return ('{0}s'  -f [int]$ts.TotalSeconds) }
    if ($ts.TotalMinutes -lt 60)    { return ('{0}m {1}s' -f [int]$ts.Minutes, [int]$ts.Seconds) }
    if ($ts.TotalHours -lt 24)      { return ('{0}h {1}m' -f [int]$ts.Hours, [int]$ts.Minutes) }
    return ('{0}d {1}h' -f [int]$ts.Days, [int]$ts.Hours)
}

function Write-Event {
    param([string]$Message)
    $line = ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    try { Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 } catch { }
    # the last few lines are mirrored to the web dashboard. A ring, not the file:
    # the page must not make the server read a 10 MB log once a second.
    if ($null -ne $script:WebLogRing) {
        [void]$script:WebLogRing.Add($line)
        while ($script:WebLogRing.Count -gt 60) { $script:WebLogRing.RemoveAt(0) }
    }
    if ($script:txtLog) {
        $script:txtLog.AppendText($line + [Environment]::NewLine)
        if ($script:txtLog.Lines.Count -gt 400) {
            $script:txtLog.Lines = $script:txtLog.Lines[-300..-1]
            $script:txtLog.SelectionStart = $script:txtLog.Text.Length
            $script:txtLog.ScrollToCaret()
        }
    }
}

# ---------------------------------------------------------------------------
#  Self-update  (pulls the latest files straight from GitHub - no git needed)
# ---------------------------------------------------------------------------
#  * Fetches each tracked file from raw.githubusercontent.com (branch tip) and
#    rewrites only the ones whose content differs. Any push to the repo is
#    picked up within a few minutes - nothing to version-bump.
#  * A downloaded .ps1 that fails to parse is rejected, so a broken push can
#    never replace a working install.
#  * A dev checkout (folder has a .git) is left alone so local edits survive.
#  * Startup: if files changed it relaunches once (guarded by a timestamp file
#    so it can't loop). While running: a background check downloads updates and
#    shows a "RESTART to apply" button - it never closes the window itself.

function Get-LocalScriptVersion {
    try { (Get-FileHash -Path $script:ScriptPath -Algorithm SHA1).Hash.Substring(0, 7).ToLower() }
    catch { 'local' }
}

function Invoke-SelfUpdate {
    param([switch]$Silent)
    if ($script:IsGitCheckout -or -not $script:ScriptDir) { return $false }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch { }

    $base    = "https://raw.githubusercontent.com/$($script:Repo)/$($script:Branch)/"
    $pending = @{}
    foreach ($name in $script:UpdateFiles) {
        try {
            $resp = Invoke-WebRequest -Uri ($base + $name) -UseBasicParsing -TimeoutSec 10 `
                        -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
        } catch {
            if (-not $Silent) { Write-Event ("UPDATE err : {0} ({1})" -f $name, $_.Exception.Message) }
            return $false                                  # network problem - try again later
        }
        if ($resp.StatusCode -ne 200) { return $false }
        $remote = [string]$resp.Content
        if ($name -like '*.ps1') {
            $perr = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($remote, [ref]$null, [ref]$perr)
            if ($perr -and $perr.Count) {
                if (-not $Silent) { Write-Event ("UPDATE err : {0} upstream has syntax errors - held back" -f $name) }
                return $false
            }
        }
        $dest  = Join-Path $script:ScriptDir $name
        $local = if (Test-Path $dest) { [System.IO.File]::ReadAllText($dest) } else { $null }
        if ($remote -ne $local) { $pending[$dest] = $remote }
    }

    if ($pending.Count -eq 0) { return $false }             # already up to date
    foreach ($dest in @($pending.Keys)) {
        try {
            [System.IO.File]::WriteAllText($dest, $pending[$dest], (New-Object System.Text.UTF8Encoding($false)))
            Write-Event ("UPDATE    : refreshed {0}" -f (Split-Path $dest -Leaf))
        } catch {
            if (-not $Silent) { Write-Event ("UPDATE err : cannot write {0} ({1})" -f (Split-Path $dest -Leaf), $_.Exception.Message) }
            return $false
        }
    }
    return $true
}

# ---- run the check once at startup, before the GUI is built ----
if (-not $NoUpdate -and -not $script:IsGitCheckout -and $script:Config.AutoUpdate) {
    try {
        if (Invoke-SelfUpdate -Silent) {
            $stamp   = Join-Path $script:AppDir '.last-relaunch'
            $justDid = $false
            if (Test-Path $stamp) {
                try { $justDid = ((Get-Date) - (Get-Item $stamp).LastWriteTime).TotalSeconds -lt 120 } catch { }
            }
            if ($justDid) {
                # updated again right after a relaunch (rapid pushes) - don't loop,
                # just let this session run and offer the button
                $script:UpdatePending = $true
            } else {
                Set-Content -Path $stamp -Value (Get-Date -Format 'o') -ErrorAction SilentlyContinue
                Start-Process powershell -WindowStyle Hidden -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $script:ScriptPath)
                )
                exit
            }
        }
    } catch { }
}

function Save-Config {
    try {
        # interval / timeout / threshold / loss window are written straight into
        # $script:Config by the settings dialog, so there is nothing to read back
        if ($script:MnuTop)        { $script:Config.AlwaysOnTop = [bool]$script:MnuTop.Checked }
        if ($script:MnuAutoUpdate) { $script:Config.AutoUpdate  = [bool]$script:MnuAutoUpdate.Checked }
        if ($script:TextSize)      { $script:Config.TextSize    = [int]$script:TextSize }
        if ($script:FormReady) {
            # RestoreBounds, not Bounds, so a maximised window still remembers the
            # size it had before it was maximised
            $b = if ($form.WindowState -eq 'Normal') { $form.Bounds } else { $form.RestoreBounds }
            if ($b.Width -ge 200 -and $b.Height -ge 150) {
                $script:Config.WinW = [int]$b.Width;  $script:Config.WinH = [int]$b.Height
                $script:Config.WinX = [int]$b.X;      $script:Config.WinY = [int]$b.Y
            }
            $script:Config.WinMax = ($form.WindowState -eq 'Maximized')
        }
        # In viewer mode the list on screen is the SERVER's, and it is not this
        # PC's to keep. Writing it here would quietly replace the local list,
        # and turning viewer mode off again would then come back to whatever the
        # server happened to be watching - with the PC's own hosts gone for good.
        if (-not (Test-RemoteMode)) {
            $script:Config.Hosts = @($script:Hosts | ForEach-Object {
                [pscustomobject]@{ Label = $_.Label; Target = $_.Target; Enabled = [bool]$_.Enabled; Alarm = [bool]$_.AlarmEnabled }
            })
        }
        $script:Config | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
#  Ping cycle (fully async - all hosts fire concurrently, UI never blocks)
# ---------------------------------------------------------------------------
function Start-CheckCycle {
    # In viewer mode this PC sends no ICMP at all - it asks the server what it
    # found. Note there is no $script:Paused test on this path: pausing is the
    # server's state now, and a viewer that stopped fetching could not see it
    # being un-paused from somebody else's phone.
    if (Test-RemoteMode) { Start-RemoteSync; return }
    if ($script:CycleRunning -or $script:Paused) { return }
    if ($script:Hosts.Count -eq 0) { return }
    $script:CycleRunning = $true
    $timeout = [int]$script:Config.TimeoutMs
    foreach ($h in $script:Hosts) {
        $h.SyncError = $null
        if (-not $h.Enabled) { $h.Task = $null; $h.Ping = $null; continue }
        try {
            $p = New-Object System.Net.NetworkInformation.Ping
            $h.Ping = $p
            $h.Task = $p.SendPingAsync($h.Target, $timeout)
        } catch {
            $h.Ping = $null
            $h.Task = $null
            $h.SyncError = $_.Exception.Message
        }
    }
}

function Process-Result {
    param($h, [bool]$ok, $rtt)
    $threshold = [int]$script:Config.FailThreshold
    if ($threshold -lt 1) { $threshold = 1 }

    Add-PingSample $h $ok $rtt

    if ($ok) {
        $h.Latency = $rtt
        if ($h.Status -in 'DOWN','INIT','WARN') {
            $prev = $h.Status
            $h.Status     = 'UP'
            $h.LastChange = Get-Date
            if ($prev -eq 'DOWN') {
                $dur = if ($h.DownSince) { Format-Duration ((Get-Date) - $h.DownSince) } else { '?' }
                Write-Event ("RECOVERED : {0} [{1}] - was down {2}" -f $h.Label, $h.Target, $dur)
                Add-Notification -Kind 'UP' -Host_ $h
                if ($h.AlarmEnabled) { Play-UpSound }
            } elseif ($prev -eq 'INIT') {
                Write-Event ("OK        : {0} [{1}] - reachable" -f $h.Label, $h.Target)
            }
            $h.DownSince = $null
            $h.Acked     = $false
        }
        $h.FailCount = 0
    }
    else {
        $h.Latency = $null
        $h.FailCount++
        if ($h.Status -ne 'DOWN') {
            if ($h.FailCount -ge $threshold) {
                $h.Status     = 'DOWN'
                $h.LastChange = Get-Date
                $h.DownSince  = Get-Date
                $h.Acked      = $false
                Write-Event ("DOWN      : {0} [{1}] - no reply" -f $h.Label, $h.Target)
                Add-Notification -Kind 'DOWN' -Host_ $h
            } else {
                $h.Status = 'WARN'
            }
        }
    }
}

function Poll-Results {
    if (Test-RemoteMode) { Poll-RemoteSync; return }
    if (-not $script:CycleRunning) { return }
    $pending = $false
    foreach ($h in $script:Hosts) {
        if (-not $h.Enabled) { continue }
        if ($null -ne $h.SyncError) {
            Process-Result $h $false $null
            $h.SyncError = $null
            continue
        }
        if ($null -eq $h.Task) { continue }
        if ($h.Task.IsCompleted) {
            $ok = $false; $rtt = $null
            if (-not $h.Task.IsFaulted) {
                try {
                    $r = $h.Task.Result
                    if ($r.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $ok = $true; $rtt = $r.RoundtripTime }
                } catch { $ok = $false }
            }
            Process-Result $h $ok $rtt
            $h.Task = $null
            if ($h.Ping) { try { $h.Ping.Dispose() } catch { }; $h.Ping = $null }
        } else {
            $pending = $true
        }
    }
    if (-not $pending) {
        $script:CycleRunning = $false
        $script:LastCheck    = Get-Date
    }
}

# ---------------------------------------------------------------------------
#  Viewer mode - the engine is the Linux server, this window is the screen
# ---------------------------------------------------------------------------
#  Nothing here pings anything. The server does that, and it also sends the
#  email / Telegram / ntfy alerts - which is why Add-Notification is switched
#  off below. Two engines watching the same hosts through the same channels is
#  two of every message for one outage.
#
#  The fetch is asynchronous for the same reason the pings are: a server that
#  has stopped answering must not freeze the window. That is exactly the moment
#  somebody is staring at it.

$script:RemoteTask    = $null
$script:RemoteClient  = $null
$script:RemoteFails   = 0
$script:RemoteError   = ''
$script:RemoteMonitor = ''
$script:RemoteLastOk  = $null

# How many failed fetches before the screen stops claiming to know anything.
# Two, not one: a single dropped request on a busy link is not an outage, and
# blanking the board every time one packet is lost teaches people to ignore it.
$script:RemoteFailLimit = 2

function Get-RemoteBase {
    ([string]$script:Config.Remote.Url).Trim().TrimEnd('/')
}

function Get-RemoteToken {
    Unprotect-Secret ([string]$script:Config.Remote.TokenEnc)
}

function New-RemoteClient {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch { }
    $wc = New-Object System.Net.WebClient
    $tok = Get-RemoteToken
    # the header, never the query string: a token in a URL ends up in proxy
    # logs and in anything that screenshots the address bar
    if ($tok) { $wc.Headers.Add('X-Token', $tok) }
    $wc.Headers.Add('Cache-Control', 'no-store')
    $wc
}

# The server sends "1m 35s" / "1h 2m" / "2d 4h" - the same vocabulary
# Format-Duration produces here. Turning it back into a start time keeps every
# downstream caller (the grid, the tooltip, the notification text) unchanged.
function ConvertFrom-DurationText {
    param([string]$Text)
    if (-not $Text) { return $null }
    $total = 0.0
    $found = $false
    foreach ($m in [regex]::Matches($Text, '(\d+(?:\.\d+)?)\s*([dhms])')) {
        $n = [double]$m.Groups[1].Value
        switch ($m.Groups[2].Value) {
            'd' { $total += $n * 86400 }
            'h' { $total += $n * 3600 }
            'm' { $total += $n * 60 }
            's' { $total += $n }
        }
        $found = $true
    }
    if (-not $found) { return $null }
    $total
}

# "17:29:10" -> a DateTime today. Just after midnight the server's timestamp can
# read as later than now, which would show a change "in the future"; assume it
# was yesterday rather than print something impossible.
function ConvertFrom-ClockText {
    param([string]$Text)
    if (-not $Text) { return $null }
    try {
        $t = [datetime]::ParseExact($Text, 'HH:mm:ss', $null)
        $d = (Get-Date).Date.Add($t.TimeOfDay)
        if ($d -gt (Get-Date).AddMinutes(1)) { $d = $d.AddDays(-1) }
        $d
    } catch { $null }
}

function Start-RemoteSync {
    if ($script:RemoteTask) { return }        # one in flight is enough
    $base = Get-RemoteBase
    if (-not $base) { return }
    try {
        $script:RemoteClient = New-RemoteClient
        $script:RemoteTask   = $script:RemoteClient.DownloadStringTaskAsync(($base + '/api/status'))
    } catch {
        $script:RemoteTask = $null
        Set-RemoteFailure $_.Exception.Message
    }
}

function Set-RemoteFailure {
    param([string]$Message)
    $script:RemoteFails++
    $script:RemoteError = $Message
    if ($script:RemoteFails -eq $script:RemoteFailLimit) {
        Write-Event ('REMOTE err: {0} - {1}' -f (Get-RemoteBase), $Message)
    }
    if ($script:RemoteFails -ge $script:RemoteFailLimit) {
        # Do NOT leave the last known good picture on screen looking current.
        # A board that still says ALL OK when nothing is being received is
        # worse than a board that says it has lost contact.
        foreach ($h in $script:Hosts) {
            if ($h.Status -ne 'INIT') { $h.Status = 'INIT'; $h.StyleKey = '' }
            $h.Latency = $null
        }
    }
}

function Poll-RemoteSync {
    if (-not $script:RemoteTask) { return }
    if (-not $script:RemoteTask.IsCompleted) { return }

    $json = $null
    if ($script:RemoteTask.IsFaulted) {
        $ex = $script:RemoteTask.Exception
        $msg = if ($ex -and $ex.GetBaseException()) { $ex.GetBaseException().Message } else { 'request failed' }
        Set-RemoteFailure $msg
    } else {
        try { $json = $script:RemoteTask.Result } catch { Set-RemoteFailure $_.Exception.Message }
    }

    $script:RemoteTask = $null
    if ($script:RemoteClient) { try { $script:RemoteClient.Dispose() } catch { }; $script:RemoteClient = $null }

    if ($null -eq $json) { $script:LastCheck = $script:RemoteLastOk; return }

    try {
        $snap = $json | ConvertFrom-Json
    } catch {
        Set-RemoteFailure 'the server sent something that is not JSON'
        return
    }
    Apply-RemoteSnapshot $snap
}

function Apply-RemoteSnapshot {
    param($Snap)
    if ($null -eq $Snap -or $null -eq $Snap.hosts) {
        Set-RemoteFailure 'the reply had no host list in it'
        return
    }
    if ($script:RemoteFails -ge $script:RemoteFailLimit) {
        Write-Event ('REMOTE    : back in contact with {0}' -f (Get-RemoteBase))
    }
    $script:RemoteFails  = 0
    $script:RemoteError  = ''
    $script:RemoteLastOk = Get-Date
    $script:LastCheck    = $script:RemoteLastOk
    $script:RemoteMonitor = [string]$Snap.monitor
    $script:Paused        = [bool]$Snap.paused

    $now  = Get-Date
    $seen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($r in @($Snap.hosts)) {
        $target = [string]$r.target
        if (-not $target) { continue }
        [void]$seen.Add($target.ToLowerInvariant())

        $h = $script:Hosts | Where-Object { $_.Target -eq $target } | Select-Object -First 1
        if ($null -eq $h) {
            $h = New-HostState -Label ([string]$r.label) -Target $target
            $script:Hosts.Add($h)
            Write-Event ('REMOTE    : added {0} [{1}] from the server' -f $r.label, $target)
        }

        $prev = $h.Status
        $h.Label        = [string]$r.label
        $h.Enabled      = [bool]$r.enabled
        $h.AlarmEnabled = [bool]$r.sound
        $h.Acked        = [bool]$r.acked
        $h.Latency      = if ($null -ne $r.rtt) { [int]$r.rtt } else { $null }
        $h.RemoteLoss   = if ($null -ne $r.loss) { [int]$r.loss } else { $null }
        # OFF is how the server reports a host it is not watching; this window
        # has always shown that as Enabled = false plus a greyed row
        $h.Status       = if ([string]$r.status -eq 'OFF') { 'INIT' } else { [string]$r.status }

        $lc = ConvertFrom-ClockText ([string]$r.since)
        if ($lc) { $h.LastChange = $lc }

        if ($h.Status -eq 'DOWN') {
            $secs = ConvertFrom-DurationText ([string]$r.downFor)
            $h.DownSince = if ($null -ne $secs) { $now.AddSeconds(-$secs) } else { $h.DownSince }
            if (-not $h.DownSince) { $h.DownSince = $now }
        } else {
            $h.DownSince = $null
        }

        # The noise is this window's whole job, so the transitions still have to
        # be noticed here - they just come from the server's opinion rather than
        # from a ping sent by this PC.
        if ($prev -ne $h.Status) {
            $h.StyleKey = ''
            if ($h.Status -eq 'DOWN' -and $prev -ne 'DOWN') {
                Write-Event ('DOWN      : {0} [{1}] - no reply' -f $h.Label, $h.Target)
            }
            elseif ($h.Status -eq 'UP' -and $prev -eq 'DOWN') {
                Write-Event ('RECOVERED : {0} [{1}]' -f $h.Label, $h.Target)
                if ($h.AlarmEnabled) { Play-UpSound }
            }
        }
    }

    # A host removed on the server has to disappear here too, or the desk goes
    # on showing a device nobody is watching any more.
    for ($i = $script:Hosts.Count - 1; $i -ge 0; $i--) {
        $h = $script:Hosts[$i]
        if (-not $seen.Contains($h.Target.ToLowerInvariant())) {
            Write-Event ('REMOTE    : {0} [{1}] is no longer on the server' -f $h.Label, $h.Target)
            $script:Hosts.RemoveAt($i)
        }
    }
    Rebuild-Grid
}

function Send-RemoteCommand {
    param([ValidateSet('ack','pause','resume')][string]$Command)
    $base = Get-RemoteBase
    if (-not $base) { return }
    try {
        $wc = New-RemoteClient
        # fire and forget: the next status fetch is what confirms it, and
        # waiting for a reply would freeze the window on the one click that is
        # always made in a hurry
        [void]$wc.UploadStringTaskAsync(($base + '/api/' + $Command), 'POST', '')
        Write-Event ('REMOTE    : {0} sent to the server' -f $Command)
    } catch {
        Write-Event ('REMOTE err: {0} - {1}' -f $Command, $_.Exception.Message)
    }
}

function Send-RemoteAck { Send-RemoteCommand 'ack' }

# ---------------------------------------------------------------------------
#  Alarm
# ---------------------------------------------------------------------------
#  We GENERATE our own .wav tones so the alarm never depends on the Windows
#  sound scheme - which on a lot of machines is set to "No Sounds", which is why
#  SystemSounds / MessageBeep can be silent.
#  The sound is (re)started on a short timer while the alarm is active, rather
#  than PlayLooping(), because a re-triggered Play() is self-healing.
#  Which sound is used is a setting: any built-in tone below, any Windows Media
#  .wav, or a custom .wav of your own (Monitoring > Alarm sound...).

$script:SoundDefs = @(
    [pscustomobject]@{ Key = 'siren'; Name = 'Two-tone siren  (default)'; Amp = 27000; Segments = @(
        @{ F = 880;  Ms = 260 }, @{ F = 0; Ms = 80 }, @{ F = 1245; Ms = 260 }, @{ F = 0; Ms = 240 }) }
    [pscustomobject]@{ Key = 'hilo'; Name = 'Ambulance hi-lo'; Amp = 27000; Segments = @(
        @{ F = 990; Ms = 400 }, @{ F = 700; Ms = 400 }, @{ F = 0; Ms = 200 }) }
    [pscustomobject]@{ Key = 'fastbeep'; Name = 'Fast triple beep'; Amp = 28000; Segments = @(
        @{ F = 1000; Ms = 110 }, @{ F = 0; Ms = 70 }, @{ F = 1000; Ms = 110 }, @{ F = 0; Ms = 70 },
        @{ F = 1000; Ms = 110 }, @{ F = 0; Ms = 400 }) }
    [pscustomobject]@{ Key = 'pulse'; Name = 'Rapid pulse  (most urgent)'; Amp = 29000; Segments = @(
        @{ F = 1300; Ms = 60 }, @{ F = 0; Ms = 55 }, @{ F = 1300; Ms = 60 }, @{ F = 0; Ms = 55 },
        @{ F = 1300; Ms = 60 }, @{ F = 0; Ms = 55 }, @{ F = 1300; Ms = 60 }, @{ F = 0; Ms = 55 },
        @{ F = 1300; Ms = 60 }, @{ F = 0; Ms = 300 }) }
    [pscustomobject]@{ Key = 'whoop'; Name = 'Rising whoop'; Amp = 27000; Segments = @(
        @{ F = 500; F2 = 1700; Ms = 480 }, @{ F = 0; Ms = 220 }) }
    [pscustomobject]@{ Key = 'klaxon'; Name = 'Low klaxon  (deep)'; Amp = 28000; Segments = @(
        @{ F = 440; Ms = 340 }, @{ F = 0; Ms = 60 }, @{ F = 330; Ms = 340 }, @{ F = 0; Ms = 260 }) }
    [pscustomobject]@{ Key = 'chime'; Name = 'Soft chime  (quiet office)'; Amp = 17000; Segments = @(
        @{ F = 1046; Ms = 220 }, @{ F = 1568; Ms = 380 }, @{ F = 0; Ms = 500 }) }
)

function New-ToneWav {
    # 16 kHz / 16-bit / mono PCM written by hand - no media library needed.
    # A segment is @{ F = <Hz>; Ms = <length> } and optionally F2 for a sweep.
    # F = 0 is silence. Phase is accumulated so a sweep has no clicks.
    param([string]$Path, $Segments, [int]$Amp = 27000)
    try {
        $sr  = 16000
        $mem = New-Object System.IO.MemoryStream
        foreach ($seg in $Segments) {
            $n    = [int]($sr * $seg.Ms / 1000)
            $fade = [int]($sr * 0.008)
            if ($fade -lt 1) { $fade = 1 }
            $f1 = [double]$seg.F
            $f2 = $f1
            if ($seg.ContainsKey('F2')) { $f2 = [double]$seg.F2 }
            $phase = 0.0
            for ($i = 0; $i -lt $n; $i++) {
                $val = 0
                if ($f1 -gt 0 -or $f2 -gt 0) {
                    $f = $f1 + ($f2 - $f1) * ($i / [double]$n)
                    $phase += 2 * [math]::PI * $f / $sr
                    $e = 1.0
                    if ($i -lt $fade) { $e = $i / $fade }
                    elseif ($i -gt ($n - $fade)) { $e = ($n - $i) / $fade }
                    if ($e -lt 0) { $e = 0 }
                    $val = [int][math]::Round([math]::Sin($phase) * $Amp * $e)
                }
                $mem.Write([System.BitConverter]::GetBytes([int16]$val), 0, 2)
            }
        }
        $pcm = $mem.ToArray()
        $fs  = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create)
        $bw  = New-Object System.IO.BinaryWriter($fs)
        $ascii = [System.Text.Encoding]::ASCII
        $bw.Write($ascii.GetBytes('RIFF')); $bw.Write([int](36 + $pcm.Length)); $bw.Write($ascii.GetBytes('WAVE'))
        $bw.Write($ascii.GetBytes('fmt ')); $bw.Write([int]16)
        $bw.Write([int16]1); $bw.Write([int16]1); $bw.Write([int]$sr)
        $bw.Write([int]($sr * 2)); $bw.Write([int16]2); $bw.Write([int16]16)
        $bw.Write($ascii.GetBytes('data')); $bw.Write([int]$pcm.Length); $bw.Write($pcm)
        $bw.Close(); $fs.Close()
        return (Test-Path $Path)
    } catch { return $false }
}

function Get-BuiltInSoundPath {
    # generated once into %APPDATA% and cached there
    param([string]$Key)
    $def = $script:SoundDefs | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if (-not $def) { $def = $script:SoundDefs[0] }
    $p = Join-Path $script:AppDir ('alarm-{0}.wav' -f $def.Key)
    if (-not (Test-Path $p)) { [void](New-ToneWav -Path $p -Segments $def.Segments -Amp $def.Amp) }
    $p
}

function Resolve-AlarmSound {
    # the .wav the alarm should use right now. A custom file that has gone
    # missing falls back to the default tone - the alarm must never go silent.
    $key = [string]$script:Config.AlarmSound
    if ($key -eq 'custom') {
        $f = [string]$script:Config.AlarmFile
        if ($f -and (Test-Path $f)) { return $f }
        return (Get-BuiltInSoundPath 'siren')
    }
    Get-BuiltInSoundPath $key
}

$script:Player = $null
function Set-AlarmPlayer {
    param([string]$Path)
    try { if ($script:Player) { $script:Player.Stop(); $script:Player.Dispose() } } catch { }
    $script:Player = $null
    $script:AlarmWavPath = $Path
    try {
        if ($Path -and (Test-Path $Path)) {
            $script:Player = New-Object System.Media.SoundPlayer $Path
            $script:Player.Load()
        }
    } catch { $script:Player = $null }
}

Set-AlarmPlayer (Resolve-AlarmSound)
if (-not $script:Player) {
    $fb = @(
        (Join-Path $env:WINDIR 'Media\Alarm01.wav'),
        (Join-Path $env:WINDIR 'Media\Ring06.wav'),
        (Join-Path $env:WINDIR 'Media\notify.wav')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($fb) { Set-AlarmPlayer $fb }
}

# ---- recovery sound ---------------------------------------------------------
# Its own player, so a recovery can be heard even while the down alarm is still
# sounding for some OTHER host - one SoundPlayer can only play one thing.
$script:UpPlayer   = $null
$script:UpWavPath  = ''
function Resolve-UpSound {
    $key = [string]$script:Config.UpSound
    if ($key -eq 'custom') {
        $f = [string]$script:Config.UpSoundFile
        if ($f -and (Test-Path $f)) { return $f }
        return (Get-BuiltInSoundPath 'chime')
    }
    Get-BuiltInSoundPath $key
}
function Set-UpPlayer {
    param([string]$Path)
    try { if ($script:UpPlayer) { $script:UpPlayer.Stop(); $script:UpPlayer.Dispose() } } catch { }
    $script:UpPlayer = $null
    $script:UpWavPath = $Path
    try {
        if ($Path -and (Test-Path $Path)) {
            $script:UpPlayer = New-Object System.Media.SoundPlayer $Path
            $script:UpPlayer.Load()
        }
    } catch { $script:UpPlayer = $null }
}
Set-UpPlayer (Resolve-UpSound)

function Play-UpSound {
    if (-not $script:Config.UpSoundEnabled) { return }
    try { if ($script:UpPlayer) { $script:UpPlayer.Play() } } catch { }
}

$script:AlarmActive = $false

# NOTE: do NOT wrap this filter in a function. Returning an array from a
# PowerShell function is a minefield: a 1-element result gets unrolled to a
# scalar (.Count -> $null, alarm never fires for a single down host), and the
# usual ",@(...)" workaround makes an EMPTY result come back as Count 1 once
# the caller re-wraps it (alarm fires when nothing is down). Assigning
# "@( ... | Where-Object ... )" inline is correct for 0, 1 and N.

# $script:AlarmLoud is set by Update-Alarm: true when at least one of the hosts
# currently down still has its Alarm box ticked. Gating here rather than at each
# call site means nothing can accidentally make a noise for a muted host.
# -Force is for the "Test alarm sound" button, which must always play.
$script:AlarmLoud = $false
function Play-Alarm {
    param([switch]$Force)
    if (-not $Force -and -not $script:AlarmLoud) { return }
    try { if ($script:Player) { $script:Player.Play(); return } } catch { }
    try { [System.Media.SystemSounds]::Hand.Play() } catch { }
}

# ---------------------------------------------------------------------------
#  Notifications - email / telegram / sms
# ---------------------------------------------------------------------------
#  * Secrets (SMTP password, bot token, SMS api key) are stored DPAPI-encrypted,
#    so config.json never holds a readable password. DPAPI is tied to this
#    Windows user on this machine - copying config.json elsewhere gives nothing.
#  * Events are batched for a few seconds and sent as ONE message, so a link
#    failure taking 30 hosts down does not fire 30 SMS.
#  * Sending happens in a background runspace; the UI never blocks on SMTP.

$script:NotifyQueue = New-Object System.Collections.ArrayList
$script:NotifySent  = New-Object System.Collections.ArrayList   # timestamps, for the hourly cap

function Protect-Secret {
    param([string]$Plain)
    if ([string]::IsNullOrEmpty($Plain)) { return '' }
    try { ConvertTo-SecureString $Plain -AsPlainText -Force | ConvertFrom-SecureString } catch { '' }
}

function Unprotect-Secret {
    param([string]$Enc)
    if ([string]::IsNullOrEmpty($Enc)) { return '' }
    try {
        $ss = ConvertTo-SecureString $Enc -ErrorAction Stop
        $b  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try   { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    } catch { '' }
}

function Test-NotifyEnabled {
    # null-safe on purpose: importing a backup written by an older version
    # replaces the whole Notify object, and it may not have every channel yet
    $n = $script:Config.Notify
    if (-not $n) { return $false }
    foreach ($ch in 'Email','Telegram','Sms','Command','Ntfy') {
        if ($n.$ch -and $n.$ch.Enabled) { return $true }
    }
    $false
}

function Add-Notification {
    param([ValidateSet('DOWN','UP')][string]$Kind, $Host_)
    # In viewer mode the server has already sent this. Sending it again from
    # here means two emails, two Telegram messages and two phone alarms for one
    # outage - and the second one arrives just as somebody has silenced the
    # first, which is how people learn to ignore alerts.
    if (Test-RemoteMode) { return }
    $n = $script:Config.Notify
    if (-not (Test-NotifyEnabled)) { return }
    # NOTE: a host with the alarm off still sends its message. "Alarm off"
    # silences the DESK - no sound, no red banner, no acknowledge - it does not
    # stop the tool telling anybody. Stopping everything is what Disable is for.
    if ($Kind -eq 'DOWN' -and -not $n.OnDown)    { return }
    if ($Kind -eq 'UP'   -and -not $n.OnRecover) { return }
    # DownSince is still set at this point - Process-Result clears it right after
    # this call - so the recovery message can carry the downtime
    $down = ''
    if ($Kind -eq 'UP' -and $Host_.DownSince) { $down = Format-Duration ((Get-Date) - $Host_.DownSince) }
    [void]$script:NotifyQueue.Add([pscustomobject]@{
        Kind = $Kind; Label = $Host_.Label; Target = $Host_.Target; Time = Get-Date; DownFor = $down
    })
}

# Which PC the alert came from. Resolved once - a DNS lookup per message would
# be a pointless stall, and this cannot change while the tool is running.
$script:MonitorName = $env:COMPUTERNAME
$script:MonitorIp   = ''
try {
    # Ask the routing table which interface would be used to leave the machine.
    # A UDP "connect" sends no packet, it only binds the local end - which is why
    # this picks the real NIC instead of a VirtualBox/Hyper-V/VPN adapter, as
    # Dns.GetHostAddresses() so often does.
    $sock = New-Object System.Net.Sockets.Socket(
        [System.Net.Sockets.AddressFamily]::InterNetwork,
        [System.Net.Sockets.SocketType]::Dgram,
        [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $sock.Connect('8.8.8.8', 65530)
        $script:MonitorIp = $sock.LocalEndPoint.Address.ToString()
    } finally { $sock.Close() }
} catch { }
if (-not $script:MonitorIp) {
    try {
        $addr = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' -and
                           -not $_.ToString().StartsWith('169.254') -and
                           -not $_.ToString().StartsWith('127.') })
        if ($addr.Count -gt 0) { $script:MonitorIp = $addr[0].ToString() }
    } catch { }
}

function Get-MonitorLabel {
    if ($script:MonitorIp) { '{0} ({1})' -f $script:MonitorName, $script:MonitorIp }
    else                   { [string]$script:MonitorName }
}

function Format-NotifyBody {
    # The message people actually read, one block per event:
    #
    #   [red][red] "niketon pop" Down
    #   Severity: Critical
    #   Timestamp: 2026-09-01 14:14:16
    #
    # The emoji are built from code points instead of being typed literally:
    # the installer writes these files as UTF-8 WITHOUT a BOM and Windows
    # PowerShell 5.1 then reads a plain .ps1 as ANSI, which would mangle any
    # literal emoji into mojibake before it ever reached Telegram.
    param($Items)
    $red   = [char]::ConvertFromUtf32(0x1F534)   # large red circle
    $green = [char]::ConvertFromUtf32(0x1F7E2)   # large green circle
    $nl    = [Environment]::NewLine
    $blocks = @()
    foreach ($e in $Items) {
        $isDown = ($e.Kind -eq 'DOWN')
        $icon   = $(if ($isDown) { $red + $red } else { $green + $green })
        $state  = $(if ($isDown) { 'Down' } else { 'Up' })
        $sev    = $(if ($isDown) { 'Critical' } else { 'Normal' })
        $b = '{0} "{1}" {2}{3}Severity: {4}{3}Timestamp: {5}' -f `
            $icon, $e.Label, $state, $nl, $sev, $e.Time.ToString('yyyy-MM-dd HH:mm:ss')
        if ($e.Target) { $b += ('{0}IP / Host: {1}' -f $nl, $e.Target) }
        # A DOWN event normally has no DownFor - it has only just happened. The
        # "still down" reminder does, and there it is the most useful line in
        # the message, so both kinds print it when it is set.
        if ($e.DownFor) {
            $b += ('{0}{1}: {2}' -f $nl, $(if ($isDown) { 'Down for' } else { 'Downtime' }), $e.DownFor)
        }
        $blocks += $b
    }
    # which desk PC raised this - once at the end, not on every block, so a
    # 30-host outage does not repeat it 30 times
    ($blocks -join ($nl + $nl)) + $nl + $nl + ('Monitored from: {0}' -f (Get-MonitorLabel))
}

function Expand-CmdTemplate {
    # placeholder substitution for the command channel. Kept out of the runspace
    # so both the sender and the "what will run" preview use the same rules.
    param([string]$Template, [hashtable]$Values)
    $out = [string]$Template
    foreach ($k in $Values.Keys) { $out = $out.Replace(('{' + $k + '}'), [string]$Values[$k]) }
    $out
}

$script:NotifySender = {
    param($LogPath, $Subject, $BodyLong, $BodyShort, $Cfg, $Events)
    function Log($m) {
        for ($i = 0; $i -lt 5; $i++) {
            try { Add-Content -Path $LogPath -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8; return }
            catch { Start-Sleep -Milliseconds 120 }
        }
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch { }

    # SmtpClient only speaks STARTTLS. On port 465 (implicit SSL, which is what
    # most cPanel hosts hand out) it connects, waits for a plaintext greeting
    # that never comes and dies on "The operation has timed out." So 465 gets a
    # hand-rolled SMTP conversation over an SslStream instead.
    function Send-SmtpImplicitSsl {
        param($Server, $Port, $User, $Pass, $From, $Recipients, $Subject_, $Body_, $TimeoutMs = 25000)
        $client = $null; $ssl = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            if (-not $client.ConnectAsync($Server, [int]$Port).Wait($TimeoutMs)) { throw "connect to ${Server}:${Port} timed out" }
            $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
            $ssl.ReadTimeout = $TimeoutMs; $ssl.WriteTimeout = $TimeoutMs
            $proto = [System.Security.Authentication.SslProtocols]::Tls12 -bor
                     [System.Security.Authentication.SslProtocols]::Tls11 -bor
                     [System.Security.Authentication.SslProtocols]::Tls
            $ssl.AuthenticateAsClient($Server, $null, $proto, $false)
            $rd = New-Object System.IO.StreamReader($ssl, [System.Text.Encoding]::UTF8)
            $wr = New-Object System.IO.StreamWriter($ssl, (New-Object System.Text.UTF8Encoding($false)))
            $wr.NewLine = "`r`n"; $wr.AutoFlush = $true

            function Read-Reply {
                # SMTP replies can be multi-line: "250-CAP" ... "250 CAP" ends it
                $last = ''
                while ($true) {
                    $line = $rd.ReadLine()
                    if ($null -eq $line) { break }
                    $last = $line
                    if ($line -match '^\d{3} ') { break }
                }
                $last
            }
            function Say { param($cmd, $expect)
                if ($cmd -ne $null) { $wr.WriteLine($cmd) }
                $r = Read-Reply
                if ($r -notmatch ('^' + $expect)) { throw ("SMTP said: " + $r) }
                $r
            }
            $b64 = { param($t) [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$t)) }

            [void](Say $null '220')
            [void](Say ('EHLO {0}' -f $env:COMPUTERNAME) '250')
            if ($User) {
                [void](Say 'AUTH LOGIN' '334')
                [void](Say (& $b64 $User) '334')
                [void](Say (& $b64 $Pass) '235')
            }
            [void](Say ('MAIL FROM:<{0}>' -f $From) '250')
            foreach ($rcpt in $Recipients) { [void](Say ('RCPT TO:<{0}>' -f $rcpt) '25') }
            [void](Say 'DATA' '354')
            $wr.WriteLine('From: {0}' -f $From)
            $wr.WriteLine('To: {0}' -f ($Recipients -join ', '))
            $wr.WriteLine('Subject: {0}' -f $Subject_)
            $wr.WriteLine('MIME-Version: 1.0')
            $wr.WriteLine('Content-Type: text/plain; charset=utf-8')
            $wr.WriteLine('Content-Transfer-Encoding: base64')
            $wr.WriteLine('Date: {0}' -f (Get-Date).ToString('r'))
            $wr.WriteLine('')
            # base64 so the emoji survive and no body line can ever look like the
            # "." that ends DATA
            $b = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Body_))
            for ($i = 0; $i -lt $b.Length; $i += 76) {
                $wr.WriteLine($b.Substring($i, [Math]::Min(76, $b.Length - $i)))
            }
            [void](Say '.' '250')
            try { $wr.WriteLine('QUIT') } catch { }
        } finally {
            if ($ssl)    { try { $ssl.Dispose() }    catch { } }
            if ($client) { try { $client.Close() }   catch { } }
        }
    }

    if ($Cfg.EmailEnabled) {
        try {
            $rcpts = @()
            foreach ($to in ($Cfg.EmailTo -split '[;,]')) { if ($to.Trim()) { $rcpts += $to.Trim() } }
            if ($rcpts.Count -eq 0) { throw 'no recipient address' }

            $mode = [string]$Cfg.EmailSecurity
            if (-not $mode -or $mode -eq 'Auto') {
                $mode = if ([int]$Cfg.EmailPort -eq 465) { 'SSL' }
                        elseif ([bool]$Cfg.EmailSsl)     { 'STARTTLS' }
                        else                             { 'None' }
            }

            if ($mode -eq 'SSL') {
                Send-SmtpImplicitSsl -Server $Cfg.EmailServer -Port $Cfg.EmailPort `
                    -User $Cfg.EmailUser -Pass $Cfg.EmailPass -From $Cfg.EmailFrom `
                    -Recipients $rcpts -Subject_ $Subject -Body_ $BodyLong
            } else {
                $msg = New-Object System.Net.Mail.MailMessage
                $msg.From = New-Object System.Net.Mail.MailAddress($Cfg.EmailFrom)
                foreach ($r in $rcpts) { $msg.To.Add($r) }
                $msg.Subject         = $Subject
                $msg.Body            = $BodyLong
                $msg.SubjectEncoding = [System.Text.Encoding]::UTF8
                $msg.BodyEncoding    = [System.Text.Encoding]::UTF8
                $cli = New-Object System.Net.Mail.SmtpClient($Cfg.EmailServer, [int]$Cfg.EmailPort)
                $cli.EnableSsl = ($mode -eq 'STARTTLS')
                $cli.Timeout   = 25000
                if ($Cfg.EmailUser) {
                    $cli.UseDefaultCredentials = $false
                    # NOTE: "Credentials", plural. SmtpClient has no "Credential"
                    # property - setting it throws, which is why email silently
                    # never worked until 1 Sep 2026.
                    $cli.Credentials = New-Object System.Net.NetworkCredential($Cfg.EmailUser, $Cfg.EmailPass)
                }
                $cli.Send($msg)
                $msg.Dispose(); $cli.Dispose()
            }
            Log ('NOTIFY    : email sent to {0} ({1}:{2} {3})' -f ($rcpts -join ','), $Cfg.EmailServer, $Cfg.EmailPort, $mode)
        } catch { Log ('NOTIFY err: email - {0}' -f $_.Exception.Message) }
    }

    if ($Cfg.TgEnabled) {
        try {
            $uri = 'https://api.telegram.org/bot{0}/sendMessage' -f $Cfg.TgToken
            # percent-encode the form body ourselves: EscapeDataString is UTF-8,
            # so the status emoji survive whatever the console code page is
            $body = 'chat_id={0}&disable_web_page_preview=true&text={1}' -f `
                [Uri]::EscapeDataString([string]$Cfg.TgChat), [Uri]::EscapeDataString([string]$BodyLong)
            $null = Invoke-WebRequest -Uri $uri -Method Post -Body $body -UseBasicParsing -TimeoutSec 25 `
                -ContentType 'application/x-www-form-urlencoded; charset=utf-8'
            Log ('NOTIFY    : telegram sent to chat {0}' -f $Cfg.TgChat)
        } catch {
            $detail = $_.Exception.Message
            try {
                $rs = $_.Exception.Response.GetResponseStream()
                $sr = New-Object System.IO.StreamReader($rs)
                $txt = $sr.ReadToEnd()
                if ($txt) { $detail = $detail + ' | ' + (($txt -replace '\s+', ' ').Trim()) }
            } catch { }
            Log ('NOTIFY err: telegram - {0}' -f $detail)
        }
    }

    # ---- ntfy: the phone alarm ------------------------------------------------
    # Everything that makes this ring rather than merely appear is a HEADER, and
    # every one of them has to be ASCII. ntfy reads its headers as latin-1, so a
    # Bengali or emoji character in Title comes out as mojibake on the phone -
    # the body is UTF-8 and safe, the headers are not. Hence Title is built from
    # the ASCII subject and the emoji live in the body only.
    if ($Cfg.NtfyEnabled -and $Cfg.NtfyTopic) {
        try {
            $base = ([string]$Cfg.NtfyServer).TrimEnd('/')
            if (-not $base) { $base = 'https://ntfy.sh' }
            $uri  = '{0}/{1}' -f $base, ([string]$Cfg.NtfyTopic).Trim('/')

            $isDown = ([string]$Subject).StartsWith('[CRITICAL]')
            $pri    = if ($isDown) { [int]$Cfg.NtfyDownPri } else { [int]$Cfg.NtfyUpPri }
            if ($pri -lt 1 -or $pri -gt 5) { $pri = if ($isDown) { 5 } else { 3 } }

            # Tags are what the Android app turns into the icon and, for
            # "rotating_light", what most users bind a custom alarm sound to.
            $tags = if ($isDown) { 'rotating_light,warning' } else { 'white_check_mark' }

            # Strip the "[CRITICAL] " / "[OK] " marker: priority already carries
            # it and the phone only shows about 40 characters of the title.
            $title = [regex]::Replace([string]$Subject, '^\[(CRITICAL|OK)\]\s*', '')
            $title = [regex]::Replace($title, '[^\x20-\x7E]', '?')
            if ($title.Length -gt 90) { $title = $title.Substring(0, 87) + '...' }

            $hdr = @{
                'Title'    = $title
                'Priority' = [string]$pri
                'Tags'     = $tags
            }
            if ($Cfg.NtfyClick) { $hdr['Click'] = [string]$Cfg.NtfyClick }
            if ($Cfg.NtfyToken) {
                $hdr['Authorization'] = 'Bearer ' + [string]$Cfg.NtfyToken
            } elseif ($Cfg.NtfyUser) {
                # ntfy basic auth wants "user:pass" base64'd, and the app stores
                # the pair as one string so that is how it is kept here too
                $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Cfg.NtfyUser))
                $hdr['Authorization'] = 'Basic ' + $b64
            }

            # POST the body as raw UTF-8 bytes. Handing Invoke-WebRequest a
            # string lets it re-encode with the default code page, which is what
            # turns the emoji in Format-NotifyBody into "?" on the phone.
            $bytes = [Text.Encoding]::UTF8.GetBytes([string]$BodyLong)
            $null = Invoke-WebRequest -Uri $uri -Method Post -Body $bytes -Headers $hdr `
                        -ContentType 'text/plain; charset=utf-8' -UseBasicParsing -TimeoutSec 25
            Log ('NOTIFY    : ntfy sent to {0} (priority {1})' -f $uri, $pri)
        } catch {
            $detail = $_.Exception.Message
            try {
                $rs = $_.Exception.Response.GetResponseStream()
                $sr = New-Object System.IO.StreamReader($rs)
                $txt = $sr.ReadToEnd()
                if ($txt) { $detail = $detail + ' | ' + (($txt -replace '\s+', ' ').Trim()) }
            } catch { }
            Log ('NOTIFY err: ntfy - {0}' -f $detail)
        }
    }

    if ($Cfg.SmsEnabled) {
        foreach ($raw in ($Cfg.SmsNumbers -split '[;,]')) {
            $num = $raw.Trim()
            if (-not $num) { continue }
            try {
                $url = $Cfg.SmsUrl.Replace('{apikey}',  [Uri]::EscapeDataString([string]$Cfg.SmsKey)).
                                   Replace('{phone}',   [Uri]::EscapeDataString($num)).
                                   Replace('{message}', [Uri]::EscapeDataString($BodyShort))
                if ($Cfg.SmsMethod -eq 'POST') {
                    $b = $Cfg.SmsBody.Replace('{apikey}', [string]$Cfg.SmsKey).Replace('{phone}', $num).Replace('{message}', $BodyShort)
                    $null = Invoke-WebRequest -Uri $url -Method Post -Body $b -ContentType $Cfg.SmsContentType -UseBasicParsing -TimeoutSec 25
                } else {
                    $null = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 25
                }
                Log ('NOTIFY    : sms sent to {0}' -f $num)
            } catch { Log ('NOTIFY err: sms {0} - {1}' -f $num, $_.Exception.Message) }
        }
    }

    # ---- offline channel: run a local command (GSM modem, smssend, a .bat) ----
    # Deliberately last and completely independent of the three above: when the
    # internet is down they all fail and this is the one that still delivers.
    if ($Cfg.CmdEnabled -and $Cfg.CmdPath) {
        # one run per event when PerHost is on (so {host}/{status} mean something),
        # otherwise a single run for the whole batch
        $runs = New-Object System.Collections.ArrayList
        if ($Cfg.CmdPerHost -and $Events -and $Events.Count -gt 0) {
            foreach ($e in $Events) {
                $st = if ($e.Kind -eq 'DOWN') { 'DOWN' } else { 'UP' }
                [void]$runs.Add(@{
                    message = ('{0} [{1}] is now {2}' -f $e.Label, $e.Target, $st)
                    host    = [string]$e.Label
                    target  = [string]$e.Target
                    status  = $st
                })
            }
        } else {
            [void]$runs.Add(@{ message = $BodyShort; host = ''; target = ''; status = '' })
        }

        $numbers = @()
        foreach ($raw in ($Cfg.CmdNumbers -split '[;,]')) { if ($raw.Trim()) { $numbers += $raw.Trim() } }
        if ($numbers.Count -eq 0) { $numbers = @('') }   # no numbers: run once, {phone} empty

        $timeout = [int]$Cfg.CmdTimeout
        if ($timeout -lt 5) { $timeout = 5 }

        foreach ($r in $runs) {
            foreach ($num in $numbers) {
                try {
                    $map = @{
                        message = $r.message
                        host    = $r.host
                        target  = $r.target
                        status  = $r.status
                        phone   = $num
                        subject = $Subject
                        time    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                        pc      = $env:COMPUTERNAME
                        modem   = [string]$Cfg.CmdModem
                        port    = [string]$Cfg.CmdModemPort
                    }
                    $argLine = [string]$Cfg.CmdArgs
                    foreach ($k in $map.Keys) { $argLine = $argLine.Replace(('{' + $k + '}'), [string]$map[$k]) }

                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName        = $Cfg.CmdPath
                    $psi.Arguments       = $argLine
                    $psi.UseShellExecute = $false
                    $psi.CreateNoWindow  = $true
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError  = $true
                    if ($Cfg.CmdWorkDir) { $psi.WorkingDirectory = $Cfg.CmdWorkDir }

                    $proc = [System.Diagnostics.Process]::Start($psi)
                    # Drain the pipes ASYNCHRONOUSLY. A child that fills a 4KB pipe
                    # buffer blocks forever if nobody reads it, but a blocking
                    # ReadToEnd() would also sit there until the child exits and so
                    # defeat the timeout below - a hung modem tool would hang here.
                    $soT = $proc.StandardOutput.ReadToEndAsync()
                    $seT = $proc.StandardError.ReadToEndAsync()
                    if (-not $proc.WaitForExit($timeout * 1000)) {
                        try { $proc.Kill() } catch { }
                        Log ('NOTIFY err: command timed out after {0}s - {1}' -f $timeout, $Cfg.CmdPath)
                        continue
                    }
                    $so = ''; $se = ''
                    try { if ($soT.Wait(2000)) { $so = [string]$soT.Result } } catch { }
                    try { if ($seT.Wait(2000)) { $se = [string]$seT.Result } } catch { }
                    $code = $proc.ExitCode
                    $tail = (($so + ' ' + $se) -replace '\s+', ' ').Trim()
                    if ($tail.Length -gt 160) { $tail = $tail.Substring(0, 157) + '...' }
                    if ($code -eq 0) {
                        Log ('NOTIFY    : command ok{0}{1}' -f `
                            $(if ($num) { " -> $num" } else { '' }), $(if ($tail) { " - $tail" } else { '' }))
                    } else {
                        Log ('NOTIFY err: command exit {0}{1}' -f $code, $(if ($tail) { " - $tail" } else { '' }))
                    }
                } catch { Log ('NOTIFY err: command - {0}' -f $_.Exception.Message) }
            }
        }
    }
}

function Send-Notification {
    param([string]$Subject, [string]$BodyLong, [string]$BodyShort, $Events = @())
    $n = $script:Config.Notify
    $cfg = @{
        EmailEnabled = [bool]$n.Email.Enabled
        EmailServer  = [string]$n.Email.SmtpServer
        EmailPort    = [int]$n.Email.Port
        EmailSsl     = [bool]$n.Email.UseSsl
        EmailSecurity = [string]$n.Email.Security
        EmailUser    = [string]$n.Email.User
        EmailPass    = (Unprotect-Secret ([string]$n.Email.PassEnc))
        EmailFrom    = [string]$n.Email.From
        EmailTo      = [string]$n.Email.To
        TgEnabled    = [bool]$n.Telegram.Enabled
        TgToken      = (Unprotect-Secret ([string]$n.Telegram.TokenEnc))
        TgChat       = [string]$n.Telegram.ChatId
        SmsEnabled   = [bool]$n.Sms.Enabled
        SmsNumbers   = [string]$n.Sms.Numbers
        SmsUrl       = [string]$n.Sms.UrlTemplate
        SmsMethod    = [string]$n.Sms.Method
        SmsBody      = [string]$n.Sms.BodyTemplate
        SmsContentType = [string]$n.Sms.ContentType
        SmsKey       = (Unprotect-Secret ([string]$n.Sms.ApiKeyEnc))
        CmdEnabled   = [bool]$n.Command.Enabled
        CmdPath      = [string]$n.Command.Path
        CmdArgs      = [string]$n.Command.Args
        CmdNumbers   = [string]$n.Command.Numbers
        CmdWorkDir   = [string]$n.Command.WorkDir
        CmdPerHost   = [bool]$n.Command.PerHost
        CmdTimeout   = [int]$n.Command.TimeoutSec
        CmdModem     = [string]$n.Command.Modem
        CmdModemPort = [string]$n.Command.ModemPort
        NtfyEnabled  = [bool]$n.Ntfy.Enabled
        NtfyServer   = [string]$n.Ntfy.Server
        NtfyTopic    = [string]$n.Ntfy.Topic
        NtfyToken    = (Unprotect-Secret ([string]$n.Ntfy.TokenEnc))
        NtfyUser     = (Unprotect-Secret ([string]$n.Ntfy.UserEnc))
        NtfyDownPri  = [int]$n.Ntfy.DownPriority
        NtfyUpPri    = [int]$n.Ntfy.UpPriority
        NtfyClick    = [string]$n.Ntfy.ClickUrl
    }
    try {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:NotifySender)
        [void]$ps.AddArgument($script:LogPath)
        [void]$ps.AddArgument($Subject)
        [void]$ps.AddArgument($BodyLong)
        [void]$ps.AddArgument($BodyShort)
        [void]$ps.AddArgument($cfg)
        [void]$ps.AddArgument($Events)
        [void]$ps.BeginInvoke()
    } catch {
        Write-Event ("NOTIFY err: could not start sender - {0}" -f $_.Exception.Message)
    }
}

# Fires one ntfy message and nothing else, from the values typed in the dialog
# rather than from the saved config - so "test" tests what is on screen. Reuses
# the real sender with every other channel switched off, because a test that
# goes down a different code path proves nothing about the real one.
function Send-NtfyTest {
    param([string]$Server, [string]$Topic, [string]$Token, [int]$Priority = 5)
    if (-not $Topic) {
        Show-Info 'Type a topic first - that is the name your phone subscribes to.' 'ntfy test'
        return
    }
    if (-not $Server) { $Server = 'https://ntfy.sh' }
    $cfg = @{
        EmailEnabled = $false; TgEnabled = $false; SmsEnabled = $false; CmdEnabled = $false
        NtfyEnabled  = $true
        NtfyServer   = $Server
        NtfyTopic    = $Topic
        NtfyToken    = $Token
        NtfyUser     = ''
        NtfyDownPri  = $Priority
        NtfyUpPri    = $Priority
        NtfyClick    = ''
    }
    $body = ('GCL Ping Monitor test from {0}' -f (Get-MonitorLabel)) + [Environment]::NewLine +
            ('Sent {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) + [Environment]::NewLine +
            'If this arrived silently: Android sets the sound on the notification CHANNEL,' +
            [Environment]::NewLine +
            'not the topic - Settings > Apps > ntfy > Notifications > Max/Urgent.' +
            [Environment]::NewLine +
            'If it arrived late, turn on Instant delivery for the subscription.'
    try {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:NotifySender)
        [void]$ps.AddArgument($script:LogPath)
        [void]$ps.AddArgument(('[CRITICAL] Ping Monitor test - {0}' -f $script:MonitorName))
        [void]$ps.AddArgument($body)
        [void]$ps.AddArgument($body)
        [void]$ps.AddArgument($cfg)
        [void]$ps.AddArgument(@())
        [void]$ps.BeginInvoke()
        Write-Event ('NTFY      : test queued to {0}/{1} (priority {2})' -f $Server.TrimEnd('/'), $Topic, $Priority)
        Show-Info ("Test sent to {0}/{1}`r`n`r`nWatch the log panel for 'NOTIFY : ntfy sent' or an error." -f $Server.TrimEnd('/'), $Topic) 'ntfy test'
    } catch {
        Write-Event ('NTFY  err : {0}' -f $_.Exception.Message)
    }
}

function Send-QueuedNotifications {
    if ($script:NotifyQueue.Count -eq 0) { return }
    $items = @($script:NotifyQueue.ToArray())
    $script:NotifyQueue.Clear()
    if (-not (Test-NotifyEnabled)) { return }

    # hourly cap so an outage storm can't burn the SMS balance
    $cut = (Get-Date).AddHours(-1)
    $keep = @($script:NotifySent | Where-Object { $_ -gt $cut })
    $script:NotifySent.Clear()
    foreach ($t in $keep) { [void]$script:NotifySent.Add($t) }
    if ($script:NotifySent.Count -ge [int]$script:Config.Notify.MaxPerHour) {
        Write-Event ('NOTIFY err: hourly limit ({0}) reached - message suppressed' -f $script:Config.Notify.MaxPerHour)
        return
    }
    [void]$script:NotifySent.Add((Get-Date))

    $downs = @($items | Where-Object { $_.Kind -eq 'DOWN' })
    $ups   = @($items | Where-Object { $_.Kind -eq 'UP' })
    $where = $env:COMPUTERNAME
    # one event is the normal case, so the subject names the host rather than
    # counting it. The monitoring PC goes on the end so the inbox list alone
    # says which desk raised it.
    $subject = if ($items.Count -eq 1) {
        '{0} "{1}" {2}' -f $(if ($downs.Count) { '[CRITICAL]' } else { '[OK]' }), $items[0].Label,
                            $(if ($downs.Count) { 'Down' } else { 'Up' })
    } elseif ($downs.Count -gt 0 -and $ups.Count -gt 0) {
        '[CRITICAL] {0} Down, {1} Up' -f $downs.Count, $ups.Count
    } elseif ($downs.Count -gt 0) {
        '[CRITICAL] {0} host(s) Down' -f $downs.Count
    } else {
        '[OK] {0} host(s) Up' -f $ups.Count
    }
    $subject = '{0} - {1}' -f $subject, $script:MonitorName

    $long = Format-NotifyBody $items

    # SMS / modem text: plain ASCII on purpose - emoji force a phone into UCS-2
    # and halve the characters that fit in one SMS
    $parts = @()
    foreach ($e in $items) {
        $p = '"{0}" {1}' -f $e.Label, $(if ($e.Kind -eq 'DOWN') { 'Down' } else { 'Up' })
        if ($e.Kind -eq 'UP' -and $e.DownFor) { $p += (' (was down {0})' -f $e.DownFor) }
        $parts += $p
    }
    $short = ('[{0}] {1} - {2}' -f $where, ($parts -join '; '), (Get-Date -Format 'HH:mm:ss'))
    if ($short.Length -gt 300) { $short = $short.Substring(0, 297) + '...' }

    Write-Event ('NOTIFY    : sending ({0} down, {1} up)' -f $downs.Count, $ups.Count)
    # the reminder clock restarts from any real message, so a fresh outage is
    # never followed a few seconds later by a "still down" for the same thing
    $script:LastNotifySent = Get-Date
    # the raw events go along too - the command channel can run once per host
    $evts = @($items | ForEach-Object { @{ Kind = $_.Kind; Label = $_.Label; Target = $_.Target } })
    Send-Notification -Subject $subject -BodyLong $long -BodyShort $short -Events $evts
}

# While something is still down and nobody has acknowledged it, say so again.
# This is what separates an alarm from a notification: one message at 3am that
# nobody hears leaves the outage unattended until morning.
$script:LastNotifySent = $null

function Send-DownReminder {
    # This one calls Send-Notification directly rather than going through
    # Add-Notification, so it needs its own viewer-mode gate - the server is
    # already repeating these, and two reminders about one outage are worse
    # than none.
    if (Test-RemoteMode) { return }
    $every = [int]$script:Config.Notify.RepeatMin
    if ($every -le 0) { return }
    if (-not (Test-NotifyEnabled)) { return }
    if (-not $script:Config.Notify.OnDown) { return }

    # Acknowledging is the off switch, deliberately - it is reachable from the
    # desk, the browser and the phone, and it already means "I have seen this".
    $down = @($script:Hosts | Where-Object { $_.Enabled -and $_.Status -eq 'DOWN' -and -not $_.Acked })
    if ($down.Count -eq 0) { $script:LastNotifySent = $null; return }

    if ($null -eq $script:LastNotifySent) { $script:LastNotifySent = Get-Date; return }
    if (((Get-Date) - $script:LastNotifySent).TotalMinutes -lt $every) { return }
    $script:LastNotifySent = Get-Date

    # goes through the same cap as everything else, so a flapping link cannot
    # turn this into an unbounded sender
    $cut  = (Get-Date).AddHours(-1)
    $keep = @($script:NotifySent | Where-Object { $_ -gt $cut })
    $script:NotifySent.Clear()
    foreach ($t in $keep) { [void]$script:NotifySent.Add($t) }
    if ($script:NotifySent.Count -ge [int]$script:Config.Notify.MaxPerHour) {
        Write-Event ('NOTIFY err: hourly limit ({0}) reached - reminder suppressed' -f $script:Config.Notify.MaxPerHour)
        return
    }
    [void]$script:NotifySent.Add((Get-Date))

    $items = @($down | ForEach-Object {
        [pscustomobject]@{
            Kind = 'DOWN'; Label = $_.Label; Target = $_.Target
            Time = Get-Date
            DownFor = $(if ($_.DownSince) { Format-Duration ((Get-Date) - $_.DownSince) } else { '' })
        }
    })
    $subject = if ($items.Count -eq 1) {
        '[CRITICAL] "{0}" STILL DOWN - {1}' -f $items[0].Label, $script:MonitorName
    } else {
        '[CRITICAL] {0} host(s) STILL DOWN - {1}' -f $items.Count, $script:MonitorName
    }
    $parts = @($items | ForEach-Object {
        '"{0}" still down{1}' -f $_.Label, $(if ($_.DownFor) { ' ' + $_.DownFor } else { '' })
    })
    $short = ('[{0}] {1} - {2}' -f $env:COMPUTERNAME, ($parts -join '; '), (Get-Date -Format 'HH:mm:ss'))
    if ($short.Length -gt 300) { $short = $short.Substring(0, 297) + '...' }

    $long = (Format-NotifyBody $items) + [Environment]::NewLine + [Environment]::NewLine +
            ('Still not acknowledged. This repeats every {0} minute(s) until someone acknowledges it.' -f $every)

    Write-Event ('NOTIFY    : reminder - {0} still down, un-acknowledged' -f $items.Count)
    Send-Notification -Subject $subject -BodyLong $long -BodyShort $short `
        -Events @($items | ForEach-Object { @{ Kind = 'DOWN'; Label = $_.Label; Target = $_.Target } })
}

function Stop-Alarm {
    # MUST be called when the alarm turns off. Play() is asynchronous - without
    # an explicit Stop() the last-started sound keeps going after Acknowledge.
    try { if ($script:Player) { $script:Player.Stop() } } catch { }
}

#  Auto-silence: after N minutes an un-acknowledged alarm stops MAKING NOISE but
#  stays an alarm - the banner is still red, the row is still red, the button is
#  still lit. It is deliberately NOT an auto-acknowledge: nobody has seen it, and
#  the screen must not claim otherwise. A host going down AFTER that re-arms the
#  sound, so a new fault is never swallowed by an older one.
$script:AlarmOnSince = $null
$script:AlarmMuted   = $false
$script:AlarmSet     = @()          # targets currently down and un-acknowledged

function Update-Alarm {
    # A host with the alarm off is STILL an alarm - red banner, red row, it has
    # to be acknowledged, and it is still reported. The only thing its switch
    # controls is the noise. So the alarm set is every down host, and a second,
    # smaller set decides whether anything is audible.
    $down   = @($script:Hosts | Where-Object { $_.Enabled -and $_.Status -eq 'DOWN' -and -not $_.Acked })
    $active = $down.Count -gt 0
    $loud   = @($down | Where-Object { $_.AlarmEnabled })
    $script:AlarmLoud = $loud.Count -gt 0

    # a down host that was not there last time re-arms the sound - but only a
    # host that is allowed to make one, otherwise nothing to re-arm
    $now = @($loud | ForEach-Object { $_.Target })
    $fresh = @($now | Where-Object { $script:AlarmSet -notcontains $_ })
    $script:AlarmSet = $now
    if ($fresh.Count -gt 0 -and $script:AlarmActive) {
        # a new fault restarts the auto-silence clock even if the alarm is
        # already sounding for something else
        $script:AlarmOnSince = Get-Date
        if ($script:AlarmMuted) {
            $script:AlarmMuted = $false
            Write-Event ('ALARM     : re-armed - {0} newly down' -f ($fresh -join ', '))
        }
        Play-Alarm
    }

    if ($script:btnAck) {
        $script:btnAck.Enabled = $active
        # the button itself goes red while it has something to acknowledge
        if ($active) {
            $script:btnAck.BackColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
            $script:btnAck.ForeColor = [System.Drawing.Color]::White
        } else {
            $script:btnAck.BackColor = [System.Drawing.Color]::Transparent
            $script:btnAck.ForeColor = [System.Drawing.SystemColors]::ControlText
        }
    }
    if ($active -eq $script:AlarmActive) { return }
    $script:AlarmActive = $active
    if ($active) {
        $src = if (-not $script:AlarmLoud) { 'off - Sound unticked for these host(s)' }
               elseif ($script:Player) { Split-Path $script:AlarmWavPath -Leaf }
               else { 'system sound' }
        $script:AlarmOnSince = Get-Date
        $script:AlarmMuted   = $false
        Write-Event ("ALARM     : ON  ({0} host(s) down, sound={1})" -f $down.Count, $src)
        Play-Alarm
    } else {
        Stop-Alarm
        $script:AlarmOnSince = $null
        $script:AlarmMuted   = $false
        Write-Event 'ALARM     : off'
    }
}

function Update-AlarmAutoStop {
    # called from the alarm timer, once a second-ish
    if (-not $script:AlarmActive -or $script:AlarmMuted) { return }
    if (-not $script:AlarmLoud) { return }            # nothing is sounding to silence
    $mins = [double]$script:Config.AlarmAutoStopMin
    if ($mins -le 0) { return }                       # 0 = keep sounding forever
    if (-not $script:AlarmOnSince) { return }
    if (((Get-Date) - $script:AlarmOnSince).TotalMinutes -lt $mins) { return }
    Stop-Alarm
    $script:AlarmMuted = $true
    Write-Event ('ALARM     : auto-silenced after {0} min - STILL DOWN and not acknowledged' -f $mins)
}

# ---------------------------------------------------------------------------
#  UI
# ---------------------------------------------------------------------------
$script:TextSize = [int][Math]::Min([Math]::Max([int]$script:Config.TextSize, 9), 22)
function UiFont  { param([double]$Scale = 1.0, [switch]$Bold)
    New-Object System.Drawing.Font('Segoe UI', [single]($script:TextSize * $Scale),
        $(if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }))
}

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'GCL Ping Monitor'
$form.Size          = New-Object System.Drawing.Size(1180, 780)
# The real minimum is computed from the text size in Apply-TextSize; this is
# only a floor so the window can be dragged genuinely small (a corner of the
# screen), with Update-Responsive dropping columns to keep it readable.
$form.MinimumSize   = New-Object System.Drawing.Size(300, 200)
$form.StartPosition = 'CenterScreen'
$form.Font          = UiFont
$form.TopMost       = [bool]$script:Config.AlwaysOnTop
$form.BackColor     = [System.Drawing.Color]::FromArgb(245, 246, 248)

# ---- restore the last window size / position -------------------------------
# Whatever size he leaves it at is the size it comes back at - otherwise a small
# corner window would have to be re-shrunk after every restart or update.
try {
    $cw = [int]$script:Config.WinW; $ch = [int]$script:Config.WinH
    if ($cw -ge 300 -and $ch -ge 200) { $form.Size = New-Object System.Drawing.Size($cw, $ch) }
    $cx = [int]$script:Config.WinX; $cy = [int]$script:Config.WinY
    if ($cx -gt -32000 -and $cy -gt -32000) {
        # only if that spot is still on a screen - a monitor may have been unplugged
        $pt = New-Object System.Drawing.Point(($cx + 40), ($cy + 20))
        $onScreen = $false
        foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) {
            if ($sc.WorkingArea.Contains($pt)) { $onScreen = $true; break }
        }
        if ($onScreen) {
            $form.StartPosition = 'Manual'
            $form.Location = New-Object System.Drawing.Point($cx, $cy)
        }
    }
    if ([bool]$script:Config.WinMax) { $form.WindowState = 'Maximized' }
} catch { }

$script:SizeMap = @(9, 12, 15, 18, 22)
$script:SizeNames = @('Small', 'Normal', 'Large', 'Extra large', 'TV')

# ---- Banner: the thing you read from across the room ----
$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Dock      = 'Top'
$lblBanner.TextAlign = 'MiddleCenter'
$lblBanner.AutoEllipsis = $true          # a long "3 HOSTS DOWN - a, b, c" must not clip mid-letter
$lblBanner.ForeColor = [System.Drawing.Color]::White
$lblBanner.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$lblBanner.Text      = 'Starting...'

# ---- Menu bar ---------------------------------------------------------------
# Everything that is set once and forgotten lives here, so the toolbar only
# carries what the support desk touches during a shift. That is what keeps the
# toolbar on one line instead of wrapping into a scrollbar at small text sizes.
$menu = New-Object System.Windows.Forms.MenuStrip
$menu.Dock      = 'Top'
$menu.BackColor = [System.Drawing.Color]::FromArgb(52, 58, 70)
$menu.ForeColor = [System.Drawing.Color]::White
$menu.Padding   = New-Object System.Windows.Forms.Padding(6, 2, 6, 2)
$menu.RenderMode = 'Professional'
$menu.CanOverflow = $true          # so the menu bar survives a very narrow window too

function New-Mnu {
    param([string]$Text, [switch]$Checkable, [switch]$Checked)
    $i = New-Object System.Windows.Forms.ToolStripMenuItem
    $i.Text = $Text
    $i.ForeColor = [System.Drawing.Color]::FromArgb(30, 33, 38)
    if ($Checkable) { $i.CheckOnClick = $true; $i.Checked = [bool]$Checked }
    $i
}
function New-Sep { New-Object System.Windows.Forms.ToolStripSeparator }

$mFile   = New-Mnu '&Hosts'
$mView   = New-Mnu '&View'
$mMon    = New-Mnu '&Monitoring'
$mSet    = New-Mnu '&Settings'
$mHelp   = New-Mnu 'Hel&p'
foreach ($t in @($mFile, $mView, $mMon, $mSet, $mHelp)) { $t.ForeColor = [System.Drawing.Color]::White }

$miAdd     = New-Mnu '&Add host'
$miAddMany = New-Mnu 'Add &many hosts...  (paste a list)'
$miEdit    = New-Mnu '&Edit selected...'
$miTickAll = New-Mnu 'Tick &all shown'
$miTickNon = New-Mnu 'Untick a&ll'
$miTickInv = New-Mnu '&Invert ticks'
$miEnable  = New-Mnu 'E&nable ticked'
$miDisable = New-Mnu '&Disable ticked'
$miAlarmOn = New-Mnu 'Sound &ON for ticked'
$miAlarmOf = New-Mnu 'Sound O&FF for ticked  (silent)'
$miAckSel  = New-Mnu 'Ac&knowledge ticked'
$miResetSt = New-Mnu 'Reset &statistics for ticked'
$miCopySel = New-Mnu '&Copy ticked to clipboard'
$miRemove  = New-Mnu '&Remove ticked'
$miExit    = New-Mnu 'E&xit'
[void]$mFile.DropDownItems.AddRange(@(
    $miAdd, $miAddMany, $miEdit, (New-Sep),
    $miTickAll, $miTickNon, $miTickInv, (New-Sep),
    $miEnable, $miDisable, (New-Sep),
    $miAlarmOn, $miAlarmOf, $miAckSel, (New-Sep),
    $miResetSt, $miCopySel, (New-Sep),
    $miRemove, (New-Sep), $miExit))

$miSize    = New-Mnu '&Text size'
$script:SizeItems = @()
for ($i = 0; $i -lt $script:SizeNames.Count; $i++) {
    $it = New-Mnu $script:SizeNames[$i]
    $it.Tag = $script:SizeMap[$i]
    [void]$miSize.DropDownItems.Add($it)
    $script:SizeItems += $it
}
$miTop     = New-Mnu '&Always on top' -Checkable -Checked:([bool]$script:Config.AlwaysOnTop)
$miShowLog = New-Mnu 'Show event &log' -Checkable -Checked
$miCompact = New-Mnu '&Compact window  (smallest size)'
$miNormalW = New-Mnu '&Normal window size'
[void]$mView.DropDownItems.AddRange(@($miSize, (New-Sep), $miTop, $miShowLog, (New-Sep), $miCompact, $miNormalW))

$miPause   = New-Mnu '&Pause monitoring'
$miTest    = New-Mnu '&Test alarm sound'
$miSound   = New-Mnu 'Alarm &sound...'
$miMonSet  = New-Mnu '&Monitoring settings...'
[void]$mMon.DropDownItems.AddRange(@($miPause, (New-Sep), $miTest, $miSound, (New-Sep), $miMonSet))

$miNotify  = New-Mnu '&Notifications...'
$miWeb     = New-Mnu '&Web dashboard  (browser / phone)...'
$miRemote  = New-Mnu '&Monitor server  (viewer mode)...'
$miExport  = New-Mnu '&Export hosts + settings...'
$miImport  = New-Mnu '&Import hosts + settings...'
$miAuto    = New-Mnu 'Auto-&update' -Checkable -Checked:([bool]$script:Config.AutoUpdate)
$miUpdate  = New-Mnu '&Check for updates now'
[void]$mSet.DropDownItems.AddRange(@($miNotify, $miWeb, $miRemote, (New-Sep), $miExport, $miImport, (New-Sep), $miAuto, $miUpdate))

$miAbout   = New-Mnu '&About'
$miFolder  = New-Mnu 'Open &data folder'
$miRepo    = New-Mnu 'Open &project page'
[void]$mHelp.DropDownItems.AddRange(@($miAbout, (New-Sep), $miFolder, $miRepo))

[void]$menu.Items.AddRange(@($mFile, $mView, $mMon, $mSet, $mHelp))
$form.MainMenuStrip = $menu

if ($script:IsGitCheckout) {
    $miAuto.Enabled = $false; $miUpdate.Enabled = $false
    $miAuto.Text = 'Auto-update (dev checkout - off)'
}

# ---- Toolbar: only what gets used during a shift -----------------------------
# A ToolStrip (not a panel of buttons) because it has real overflow built in:
# whatever does not fit the window width moves into a ">>" dropdown instead of
# wrapping onto a second line or growing a scrollbar. That is the responsive bit.
$panelTop = New-Object System.Windows.Forms.ToolStrip
$panelTop.Dock        = 'Top'
$panelTop.GripStyle   = 'Hidden'
$panelTop.CanOverflow = $true
$panelTop.LayoutStyle = 'HorizontalStackWithOverflow'
$panelTop.Padding     = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
$panelTop.BackColor   = [System.Drawing.Color]::FromArgb(238, 240, 244)
$panelTop.RenderMode  = 'System'

$script:UiLabels = New-Object System.Collections.Generic.List[object]
function New-Lbl($text) {
    $l = New-Object System.Windows.Forms.ToolStripLabel
    $l.Text = $text
    $l.Margin = New-Object System.Windows.Forms.Padding(8, 1, 2, 1)
    $script:UiLabels.Add($l)
    $l
}
$script:UiButtons = New-Object System.Collections.Generic.List[object]
function New-Btn($text, [switch]$Strong) {
    $b = New-Object System.Windows.Forms.ToolStripButton
    $b.Text = $text
    $b.DisplayStyle = 'Text'
    $b.AutoSize = $true
    $b.Margin = New-Object System.Windows.Forms.Padding(3, 1, 6, 1)
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3)
    if ($Strong) { $b.Font = UiFont -Bold }
    $script:UiButtons.Add($b)
    $b
}
function New-Txt($chars) {
    $t = New-Object System.Windows.Forms.ToolStripTextBox
    $t.Margin = New-Object System.Windows.Forms.Padding(2, 1, 6, 1)
    $t.BorderStyle = 'FixedSingle'
    $t.Tag = $chars                       # width in characters, resized by text size
    $t
}
function New-TSep {
    $s = New-Object System.Windows.Forms.ToolStripSeparator
    $s.Margin = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
    $s
}

$btnAdd    = New-Btn 'Add host'
$btnAdd.ToolTipText = 'Add a single host.  Hosts menu -> Add many hosts... takes a whole pasted list'

$txtSearch      = New-Txt 13
$btnClearSearch = New-Btn 'x'

$btnAck  = New-Btn 'ACKNOWLEDGE' -Strong
$btnAck.Enabled = $false
$btnAck.ToolTipText = 'Silence the alarm (a NEW host going down re-arms it)'

$btnPause = New-Btn 'Pause'

# The tick box column is discoverable only if something on screen names it, so
# the bulk actions get their own toolbar button rather than hiding in a menu.
$btnBulk = New-Object System.Windows.Forms.ToolStripDropDownButton
$btnBulk.Text = 'Bulk select'
$btnBulk.DisplayStyle = 'Text'
$btnBulk.AutoSize = $true
$btnBulk.Margin  = New-Object System.Windows.Forms.Padding(3, 1, 6, 1)
$btnBulk.Padding = New-Object System.Windows.Forms.Padding(8, 3, 4, 3)
$btnBulk.ToolTipText = 'Tick hosts in the first column, then act on all of them at once'
$script:UiButtons.Add($btnBulk)

$tbTickAll = New-Mnu 'Tick &all shown'
$tbTickNon = New-Mnu 'Untick a&ll'
$tbTickInv = New-Mnu '&Invert ticks'
$tbEnable  = New-Mnu 'E&nable ticked'
$tbDisable = New-Mnu '&Disable ticked'
$tbAlarmOn = New-Mnu 'Sound &ON for ticked'
$tbAlarmOf = New-Mnu 'Sound O&FF for ticked  (silent)'
$tbAck     = New-Mnu 'Ac&knowledge ticked'
$tbReset   = New-Mnu 'Reset &statistics for ticked'
$tbCopy    = New-Mnu '&Copy ticked to clipboard'
$tbRemove  = New-Mnu '&Remove ticked'
[void]$btnBulk.DropDownItems.AddRange(@(
    $tbTickAll, $tbTickNon, $tbTickInv, (New-Sep),
    $tbEnable, $tbDisable, (New-Sep),
    $tbAlarmOn, $tbAlarmOf, $tbAck, (New-Sep),
    $tbReset, $tbCopy, (New-Sep), $tbRemove))

# becomes visible only after a newer version has been downloaded in the background
$btnRestartNow = New-Btn 'RESTART to apply update' -Strong
$btnRestartNow.Visible   = $false
$btnRestartNow.BackColor = [System.Drawing.Color]::Gold

# these must never disappear into the ">>" overflow, however narrow the window:
# acknowledging an alarm you cannot see the button for is the whole problem
$btnAck.Overflow        = 'Never'
$btnPause.Overflow      = 'Never'
$btnRestartNow.Overflow = 'Never'
# Bulk select is pinned too: it is the only thing on screen that names the tick
# box column, and a feature nobody can find is a feature nobody has. Its label
# shortens to "Bulk" in a narrow window so all three still fit.
$btnBulk.Overflow       = 'Never'

[void]$panelTop.Items.AddRange(@(
    $btnAdd,
    (New-TSep),
    (New-Lbl 'Search:'), $txtSearch, $btnClearSearch,
    (New-TSep),
    $btnAck, $btnPause, $btnBulk, $btnRestartNow
))

# Edit / Disable / Remove live on the right-click menu and the Hosts menu -
# keeping them off the toolbar is what lets it stay on a single line.
$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$ctx.Font = UiFont
$cmEdit    = New-Mnu '&Edit host...'
$cmToggle  = New-Mnu '&Disable / Enable'
$cmAlarm   = New-Mnu 'Sound on / o&ff'
$cmRemove  = New-Mnu '&Remove'
$cmTick    = New-Mnu '&Tick / untick this host'
$cmTickAll = New-Mnu 'Tick &all shown'
$cmTickNon = New-Mnu '&Untick all'
$cmReset   = New-Mnu 'Reset &statistics'
$cmCopy    = New-Mnu '&Copy to clipboard'
$cmAck     = New-Mnu '&Acknowledge alarm'
[void]$ctx.Items.AddRange(@(
    $cmEdit, $cmToggle, $cmAlarm, $cmRemove, (New-Sep),
    $cmTick, $cmTickAll, $cmTickNon, (New-Sep),
    $cmReset, $cmCopy, (New-Sep), $cmAck))

# ---- Split: grid on top, log on bottom ----
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
# kept small on purpose: a 200px-tall window still has to be able to place the
# splitter, otherwise SplitterDistance silently refuses to move
$split.Panel1MinSize = 46
$split.Panel2MinSize = 34

# A fixed SplitterDistance set before the control is laid out ends up wrong once
# the form has its real size - that is how the log panel got squashed to one
# line. Drive it from a saved percentage instead.
function Apply-SplitPercent {
    try {
        $pct = [double]$script:Config.SplitPercent
        if ($pct -lt 25) { $pct = 25 }; if ($pct -gt 90) { $pct = 90 }
        $h = $split.Height
        if ($h -gt ($split.Panel1MinSize + $split.Panel2MinSize + 20)) {
            $split.SplitterDistance = [int]($h * $pct / 100.0)
        }
    } catch { }
}

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.AutoSizeColumnsMode = 'Fill'
# Fill mode already divides the width up; a horizontal scrollbar would only ever
# mean a column has been pushed off the right edge, so forbid one outright
$grid.ScrollBars = 'Vertical'
$grid.EnableHeadersVisualStyles = $false
$grid.AllowUserToOrderColumns = $true
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.GridColor = [System.Drawing.Color]::FromArgb(210, 214, 220)
$grid.BorderStyle = 'None'
$grid.CellBorderStyle = 'SingleHorizontal'
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(52, 58, 70)
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(52, 58, 70)
$grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 4, 4, 4)
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 2, 4, 2)
$grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
$grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
# The tick box for bulk actions, and the per-host alarm switch. Both are
# read-only checkbox columns toggled by hand in CellContentClick: making them
# editable would mean taking the whole grid out of read-only mode, and then a
# stray keypress could start editing a host's name.
function New-ChkCol($name, $header, $tip) {
    $c = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $c.Name = $name; $c.HeaderText = $header
    $c.SortMode = 'NotSortable'
    $c.ToolTipText = $tip
    $c.FlatStyle = 'Standard'
    $c.DefaultCellStyle.Alignment = 'MiddleCenter'
    $c
}
$null = $grid.Columns.Add((New-ChkCol 'cSel' '' 'BULK SELECT - tick hosts here, then use the Bulk select button (or the Hosts / right-click menu) to enable, disable, mute, acknowledge or remove all of them at once.  Click this header to tick or untick every host shown.'))
$null = $grid.Columns.Add('cLabel',  'Name')
$null = $grid.Columns.Add('cTarget', 'IP / Host')
$null = $grid.Columns.Add('cStatus', 'Status')
$null = $grid.Columns.Add((New-ChkCol 'cAlarm' 'Sound' 'Sound on / off for this host.  OFF = this host makes no noise - the row and the banner still go red, it still has to be acknowledged, and email / Telegram / SMS still go out.  (To stop everything, disable the host.)  Click to toggle.'))
$null = $grid.Columns.Add('cLat',    'Latency')
$null = $grid.Columns.Add('cLoss',   'Loss %')
$null = $grid.Columns.Add('cSince',  'Since')
$null = $grid.Columns.Add('cDown',   'Down for')
# Fill mode refuses to shrink a column below its MinimumWidth, and the default is
# wide enough to push the last column off the right edge in a small window
foreach ($c in $grid.Columns) { $c.MinimumWidth = 22 }
# No column sorts. The list re-sorts itself every cycle (down hosts to the top),
# so a user sort would be undone within half a second - and an Automatic sort
# mode silently reserves room for a sort arrow in every header, which is what
# was clipping "Status" to "Statu" in a narrow window.
foreach ($c in $grid.Columns) { $c.SortMode = 'NotSortable' }
# the two check boxes keep a fixed width instead of a share of it - a tick box
# that grows with the window would look like a mistake
$grid.Columns['cSel'].AutoSizeMode   = 'None'
$grid.Columns['cAlarm'].AutoSizeMode = 'None'
$grid.Columns['cSel'].Resizable      = 'False'
$grid.Columns['cLabel'].FillWeight  = 130
$grid.Columns['cTarget'].FillWeight = 120
$grid.Columns['cStatus'].FillWeight = 80
$grid.Columns['cLat'].FillWeight    = 62
$grid.Columns['cLoss'].FillWeight   = 62
$grid.Columns['cSince'].FillWeight  = 90
$grid.Columns['cDown'].FillWeight   = 70
$grid.ContextMenuStrip = $ctx
$split.Panel1.Controls.Add($grid)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Dock = 'Fill'
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(28, 30, 34)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(215, 225, 235)
$txtLog.BorderStyle = 'None'
$script:txtLog = $txtLog
$split.Panel2.Controls.Add($txtLog)

# ---------------------------------------------------------------------------
#  Text size - one place that resizes everything for big / far-away monitors
# ---------------------------------------------------------------------------
function Apply-TextSize {
    param([int]$Size)
    $script:TextSize = [int][Math]::Min([Math]::Max($Size, 9), 22)
    $s = $script:TextSize

    $form.SuspendLayout()
    $form.Font        = UiFont
    $menu.Font        = UiFont
    $panelTop.Font    = UiFont

    # the smallest the window may get is derived from the text size, not fixed -
    # at Small it can be a little corner box, at TV it still has to fit the
    # ACKNOWLEDGE button
    $minW = [int][Math]::Max(320, $s * 24)
    $minH = [int][Math]::Max(210, $s * 16)
    try { $form.MinimumSize = New-Object System.Drawing.Size($minW, $minH) } catch { }

    foreach ($t in @($txtSearch)) {
        $t.Font = UiFont
        $t.Size = New-Object System.Drawing.Size([int]($s * [double]$t.Tag), [int]($s * 2.0))
    }
    $btnAck.Font        = UiFont -Bold
    $btnRestartNow.Font = UiFont -Bold
    $panelTop.PerformLayout()

    $grid.ColumnHeadersDefaultCellStyle.Font = UiFont 1.0 -Bold
    $grid.ColumnHeadersHeight = [int]($s * 2.8)
    $grid.DefaultCellStyle.Font = UiFont
    $grid.RowTemplate.Height    = [int]($s * 2.5)
    # fixed-width check box columns still have to follow the text size
    try {
        $grid.Columns['cSel'].Width   = [int]($s * 2.8)
        # wide enough for the bold "Alarm" header, which is what sets the size -
        # a clipped header ("Alarr") is worse than a slightly wide column. In a
        # narrow window the header is already the short "Alm", so ask the tier.
        $grid.Columns['cAlarm'].Width = [int]($s * $(if ($script:RespTier -ge 1) { 4.0 } else { 5.6 }))
    } catch { }
    foreach ($r in $grid.Rows) { $r.Height = [int]($s * 2.5) }

    $txtLog.Font = New-Object System.Drawing.Font('Consolas', [single][Math]::Max($s - 2, 8))
    $status.Font = UiFont
    $form.ResumeLayout()
    foreach ($it in $script:SizeItems) { $it.Checked = ([int]$it.Tag -eq $s) }
    $script:RespTier = -1                 # force the responsive pass to re-apply
    Update-Responsive
    Refresh-Grid
}

# ---------------------------------------------------------------------------
#  Responsive layout
# ---------------------------------------------------------------------------
#  Everything below is measured in TEXT UNITS (multiples of the font size), not
#  pixels, so the same rules hold at Small and at TV size. As the window gets
#  narrower the least important columns drop out rather than every column
#  becoming an unreadable sliver; as it gets shorter the log panel and then the
#  banner give up their space so the host list always stays usable.
$script:RespTier    = -1
$script:LogAutoHidden = $false

function Update-Responsive {
    if (-not $form -or -not $form.IsHandleCreated) { return }
    try {
        $u = [double]$script:TextSize
        $w = $form.ClientSize.Width
        $h = $form.ClientSize.Height

        # --- width tiers: which columns still earn their space ---
        # dropped in order of how little they are worth in a glance: the two
        # timestamps first, then the IP (the Name identifies the host), and only
        # in the smallest box the latency. Name / Status / Loss % always stay.
        $tier = 0
        if     ($w -lt $u * 27) { $tier = 4 }
        elseif ($w -lt $u * 34) { $tier = 3 }
        elseif ($w -lt $u * 44) { $tier = 2 }
        elseif ($w -lt $u * 56) { $tier = 1 }

        if ($tier -ne $script:RespTier) {
            $script:RespTier = $tier
            $hide = @()
            if ($tier -ge 1) { $hide += 'cSince'  }
            if ($tier -ge 2) { $hide += 'cDown'   }
            if ($tier -ge 3) { $hide += 'cTarget' }
            if ($tier -ge 4) { $hide += 'cLat'; $hide += 'cAlarm' }
            foreach ($c in $grid.Columns) { $c.Visible = ($hide -notcontains $c.Name) }

            # Short headers + a different share of the width once space is tight.
            # This kicks in from tier 1, not tier 2: the two fixed-width check
            # box columns take ~9 text units that the fill columns used to
            # share, so "Latency" and "Down for" were clipping to "Later" and
            # "Dowr" one tier earlier than they used to.
            if ($tier -ge 1) {
                $grid.Columns['cTarget'].HeaderText = 'IP'
                $grid.Columns['cLat'].HeaderText    = 'ms'
                $grid.Columns['cLoss'].HeaderText   = 'Loss'
                $grid.Columns['cAlarm'].HeaderText  = 'Snd'
                $grid.Columns['cDown'].HeaderText   = 'Down'
                $grid.Columns['cAlarm'].Width       = [int]($u * 4.0)
                $grid.Columns['cLabel'].FillWeight  = 132
                $grid.Columns['cTarget'].FillWeight = 96
                $grid.Columns['cStatus'].FillWeight = 64
                $grid.Columns['cLat'].FillWeight    = 60
                $grid.Columns['cLoss'].FillWeight   = 58
                $grid.Columns['cDown'].FillWeight   = 62
            } else {
                $grid.Columns['cTarget'].HeaderText = 'IP / Host'
                $grid.Columns['cLat'].HeaderText    = 'Latency'
                $grid.Columns['cLoss'].HeaderText   = 'Loss %'
                $grid.Columns['cAlarm'].HeaderText  = 'Sound'
                $grid.Columns['cDown'].HeaderText   = 'Down for'
                $grid.Columns['cAlarm'].Width       = [int]($u * 5.6)
                $grid.Columns['cLabel'].FillWeight  = 130
                $grid.Columns['cTarget'].FillWeight = 120
                $grid.Columns['cStatus'].FillWeight = 80
                $grid.Columns['cLat'].FillWeight    = 62
                $grid.Columns['cLoss'].FillWeight   = 62
                $grid.Columns['cDown'].FillWeight   = 70
            }

            # the banner is the biggest text on screen - it shrinks first
            if ($tier -ge 2) {
                $lblBanner.Font   = UiFont 1.15 -Bold
                $lblBanner.Height = [int]($u * 2.2)
            } else {
                $lblBanner.Font   = UiFont 1.75 -Bold
                $lblBanner.Height = [int]($u * 3.4)
            }
            # the clock is the first thing to go in the status bar - the counts
            # (UP / DOWN / disabled) are the part that matters
            if ($lblClock) { $lblClock.Visible = ($tier -lt 2) }
            # Three pinned buttons do not fit a corner-sized window, and
            # ACKNOWLEDGE is the one that must never be squeezed out. Bulk
            # select gives up its place first - it is still in the Hosts menu.
            if ($script:btnBulk) { $script:btnBulk.Visible = ($tier -lt 3) }
            Update-BulkButton
        }

        # --- height: hand the log panel's space back when there is none ---
        $needLog = $miShowLog -and $miShowLog.Checked
        $tooShort = $h -lt ($u * 24)
        if ($needLog -and $tooShort -and -not $split.Panel2Collapsed) {
            $split.Panel2Collapsed = $true
            $script:LogAutoHidden = $true
        } elseif ($needLog -and -not $tooShort -and $script:LogAutoHidden) {
            $split.Panel2Collapsed = $false
            $script:LogAutoHidden = $false
            Apply-SplitPercent
        }
    } catch { }
}

# ---- Status bar ----
$status = New-Object System.Windows.Forms.StatusStrip
$lblCounts = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblCounts.Spring = $true
$lblCounts.TextAlign = 'MiddleLeft'
$lblClock = New-Object System.Windows.Forms.ToolStripStatusLabel
$status.Items.AddRange(@($lblCounts, $lblClock))

# ---- Dock order matters -----------------------------------------------------
# Docking is applied from the HIGHEST z-index (last added) to the lowest, and
# the lowest-index control gets whatever space is left. So add the Fill control
# FIRST and the outermost edges LAST:  menu | toolbar | banner | grid | status
$form.Controls.Add($split)      # Fill  - added first, gets the remainder
$form.Controls.Add($lblBanner)  # Top
$form.Controls.Add($panelTop)   # Top   - above the banner
$form.Controls.Add($menu)       # Top   - very top
$form.Controls.Add($status)     # Bottom

# ---------------------------------------------------------------------------
#  Grid refresh
# ---------------------------------------------------------------------------
# Row palette - DOWN is deliberately loud so it reads from across the room
$colDownBg   = [System.Drawing.Color]::FromArgb(211, 47, 47)      # solid red
$colDownFg   = [System.Drawing.Color]::White
$colAckBg    = [System.Drawing.Color]::FromArgb(255, 214, 214)    # acknowledged - calmer
$colAckFg    = [System.Drawing.Color]::FromArgb(140, 20, 20)
$colWarnBg   = [System.Drawing.Color]::FromArgb(255, 224, 130)
$colWarnFg   = [System.Drawing.Color]::FromArgb(110, 70, 0)
$colUpBg     = [System.Drawing.Color]::FromArgb(232, 245, 233)
$colUpFg     = [System.Drawing.Color]::FromArgb(27, 94, 32)
$colOffBg    = [System.Drawing.Color]::FromArgb(228, 230, 234)
$colOffFg    = [System.Drawing.Color]::FromArgb(130, 134, 140)
$colInitBg   = [System.Drawing.Color]::FromArgb(245, 246, 248)
$colInitFg   = [System.Drawing.Color]::FromArgb(90, 94, 100)

# Display order: un-acknowledged DOWN first, then acknowledged DOWN, then the
# ones going bad, then unknown, then healthy, then disabled. So whatever needs
# attention is always at the top of the screen without anyone scrolling.
function Get-HostRank {
    param($h)
    if (-not $h.Enabled) { return 5 }
    switch ($h.Status) {
        'DOWN' { if ($h.Acked) { 1 } else { 0 } }
        'WARN' { 2 }
        'INIT' { 3 }
        'UP'   { 4 }
        default { 3 }
    }
}

# Fills $script:Visible instead of returning an array. Returning arrays from a
# PowerShell function is unreliable (0 elements and 1 element both misbehave),
# so the visible list is published through a script variable.
$script:Visible = @()

function Update-VisibleHosts {
    $q = ''
    if ($script:txtSearch) { $q = $script:txtSearch.Text.Trim() }
    if ($q) {
        $filtered = @($script:Hosts | Where-Object { $_.Label -like "*$q*" -or $_.Target -like "*$q*" })
    } else {
        $filtered = @($script:Hosts | Where-Object { $true })
    }
    # stable bucket sort - no Sort-Object, so ties keep their entry order
    $out = New-Object System.Collections.ArrayList
    foreach ($rank in 0..5) {
        foreach ($h in $filtered) { if ((Get-HostRank $h) -eq $rank) { [void]$out.Add($h) } }
    }
    $script:Visible = [object[]]$out.ToArray()
}

function Rebuild-Grid {
    $selected = @($grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
    $scroll   = $grid.FirstDisplayedScrollingRowIndex
    Update-VisibleHosts
    $grid.SuspendLayout()
    $grid.Rows.Clear()
    foreach ($h in $script:Visible) {
        # added empty and filled by name - with check box columns in the middle a
        # positional value array is one reordering away from silent nonsense
        $i = $grid.Rows.Add()
        $grid.Rows[$i].Tag = $h
        $h.StyleKey = ''                       # force a restyle on the new row
    }
    $grid.ClearSelection()
    foreach ($row in $grid.Rows) {
        if ($selected -contains $row.Tag) { $row.Selected = $true }
    }
    if ($scroll -ge 0 -and $scroll -lt $grid.Rows.Count) { $grid.FirstDisplayedScrollingRowIndex = $scroll }
    $grid.ResumeLayout()
    Refresh-Grid
}

function Refresh-Grid {
    # re-sort / re-filter only when the visible sequence actually changed,
    # otherwise the grid would flicker and lose selection every 400 ms
    Update-VisibleHosts
    $want = $script:Visible
    $have = @($grid.Rows | ForEach-Object { $_.Tag })
    $same = $want.Count -eq $have.Count
    if ($same) {
        for ($i = 0; $i -lt $want.Count; $i++) {
            if (-not [object]::ReferenceEquals($want[$i], $have[$i])) { $same = $false; break }
        }
    }
    if (-not $same) { Rebuild-Grid; return }

    foreach ($row in $grid.Rows) {
        $h = $row.Tag
        if (-not $h) { continue }
        $row.Cells['cLabel'].Value  = $h.Label
        $row.Cells['cTarget'].Value = $h.Target
        $row.Cells['cSel'].Value    = [bool]$h.Sel
        $row.Cells['cAlarm'].Value  = [bool]$h.AlarmEnabled

        if (-not $h.Enabled) {
            $statusText = 'DISABLED'
            $bg = $colOffBg; $fg = $colOffFg; $bold = $false
        } else {
            switch ($h.Status) {
                'UP'   { $statusText = 'UP';           $bg = $colUpBg;   $fg = $colUpFg;   $bold = $false }
                'WARN' { $statusText = 'checking...';  $bg = $colWarnBg; $fg = $colWarnFg; $bold = $false }
                'DOWN' {
                    # a muted host is just as red - only the noise is off. The
                    # cell says which, because the Alarm column is dropped in a
                    # small window
                    if ($h.Acked) { $statusText = 'DOWN (ack)'; $bg = $colAckBg; $fg = $colAckFg; $bold = $true }
                    elseif (-not $h.AlarmEnabled) {
                        # the Sound column sits right next to Status and already
                        # shows an empty box, so the word stays plain "DOWN" -
                        # "DOWN (no sound)" does not fit the column and truncates
                        # to "DOWN (n...". Only in the smallest window, where the
                        # Sound column is dropped, does a bare * have to carry it.
                        $statusText = if ($script:RespTier -ge 4) { 'DOWN *' } else { 'DOWN' }
                        $bg = $colDownBg; $fg = $colDownFg; $bold = $true
                    }
                    else          { $statusText = 'DOWN';       $bg = $colDownBg; $fg = $colDownFg; $bold = $true }
                }
                default { $statusText = '-';           $bg = $colInitBg; $fg = $colInitFg; $bold = $false }
            }
        }

        $row.Cells['cStatus'].Value = $statusText
        # in a narrow window the header already says "ms" - the suffix would only
        # push a 3-digit latency out of the column
        $row.Cells['cLat'].Value    = if ($h.Enabled -and $h.Status -eq 'UP' -and $null -ne $h.Latency) {
            if ($script:RespTier -ge 1) { "$($h.Latency)" } else { "$($h.Latency) ms" }
        } else { '' }
        # today needs no date - that is what keeps this column readable at TV size
        $row.Cells['cSince'].Value  = if ($h.LastChange) {
            if ($h.LastChange.Date -eq [DateTime]::Today) { $h.LastChange.ToString('HH:mm:ss') }
            else { $h.LastChange.ToString('MM-dd HH:mm') }
        } else { '' }
        $row.Cells['cDown'].Value   = if ($h.Enabled -and $h.Status -eq 'DOWN' -and $h.DownSince) { Format-Duration ((Get-Date) - $h.DownSince) } else { '' }

        $loss = Get-LossPercent $h
        if ($null -eq $loss) {
            $row.Cells['cLoss'].Value = ''
            $lossBucket = 'na'
        } else {
            $row.Cells['cLoss'].Value = "$loss %"
            $lossBucket = if ($loss -eq 0) { 'ok' } elseif ($loss -lt 10) { 'low' } elseif ($loss -lt 50) { 'mid' } else { 'high' }
            $avg = if ($h.LastRtts.Count -gt 0) { [int]((@($h.LastRtts.ToArray()) | Measure-Object -Average).Average) } else { $null }
            $row.Cells['cLoss'].ToolTipText = ("{0} lost of last {1} pings   (lifetime {2}/{3}){4}" -f `
                $h.Lost, $h.Hist.Count, $h.TotLost, $h.TotSent,
                $(if ($null -ne $avg) { "`r`navg latency {0} ms (last {1})" -f $avg, $h.LastRtts.Count } else { '' }))
        }

        $key = "$statusText|$lossBucket|$($script:TextSize)"
        if ($h.StyleKey -ne $key) {
            $h.StyleKey = $key
            $row.DefaultCellStyle.BackColor = $bg
            $row.DefaultCellStyle.ForeColor = $fg
            $row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
            $row.DefaultCellStyle.Font = if ($bold) { UiFont 1.0 -Bold } else { UiFont }
            $row.Height = [int]($script:TextSize * 2.5)

            # loss cell gets its own emphasis on a healthy-looking (green) row,
            # so partial loss on a host that is still "UP" cannot be missed
            $lc = $row.Cells['cLoss']
            if ($statusText -eq 'UP') {
                switch ($lossBucket) {
                    'ok'   { $lc.Style.ForeColor = $fg;                                        $lc.Style.Font = UiFont }
                    'low'  { $lc.Style.ForeColor = [System.Drawing.Color]::FromArgb(150,90,0);  $lc.Style.Font = UiFont 1.0 -Bold }
                    'mid'  { $lc.Style.BackColor = $colWarnBg
                             $lc.Style.ForeColor = [System.Drawing.Color]::FromArgb(120,60,0);  $lc.Style.Font = UiFont 1.0 -Bold }
                    'high' { $lc.Style.BackColor = [System.Drawing.Color]::FromArgb(255,170,170)
                             $lc.Style.ForeColor = [System.Drawing.Color]::FromArgb(150,20,20); $lc.Style.Font = UiFont 1.0 -Bold }
                    default { $lc.Style.ForeColor = $fg;                                       $lc.Style.Font = UiFont }
                }
                if ($lossBucket -in 'ok','low','na') { $lc.Style.BackColor = $bg }
            } else {
                $lc.Style.BackColor = $bg
                $lc.Style.ForeColor = $fg
                $lc.Style.Font = if ($bold) { UiFont 1.0 -Bold } else { UiFont }
            }
        }
    }
}

function Refresh-Banner {
    # Losing contact with the server is not "all quiet". Whatever was on screen
    # is now a photograph of the past, and a green ALL UP banner over stale data
    # is the most dangerous thing this window can display.
    if ((Test-RemoteMode) -and $script:RemoteFails -ge $script:RemoteFailLimit) {
        $ago = if ($script:RemoteLastOk) { Format-Duration ((Get-Date) - $script:RemoteLastOk) } else { 'ever' }
        $lblBanner.Text = ('NO CONTACT WITH THE MONITOR SERVER   -   last reply {0} ago' -f $ago)
        $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(184, 118, 0)
        return
    }
    $active  = @($script:Hosts | Where-Object { $_.Enabled })
    $down    = @($active | Where-Object { $_.Status -eq 'DOWN' })
    # a muted host still turns the banner red - its switch controls the sound,
    # nothing else
    $unacked = @($down   | Where-Object { -not $_.Acked })
    if ($down.Count -gt 0) {
        $names = ($down | Select-Object -First 6 | ForEach-Object { $_.Label }) -join ',  '
        if ($down.Count -gt 6) { $names += '  ...' }
        $lblBanner.Text = ('{0} HOST{1} DOWN   -   {2}' -f $down.Count, $(if ($down.Count -eq 1) { '' } else { 'S' }), $names)
        $lblBanner.BackColor = if ($unacked.Count -gt 0) { [System.Drawing.Color]::FromArgb(200, 30, 30) } else { [System.Drawing.Color]::FromArgb(184, 118, 0) }
    }
    elseif ($active.Count -eq 0) {
        $lblBanner.Text = if ($script:Hosts.Count -eq 0) { 'No hosts yet - add an IP or hostname above' } else { 'All hosts are disabled' }
        $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    }
    elseif ($script:Paused) {
        $lblBanner.Text = 'PAUSED'
        $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    }
    else {
        $lblBanner.Text = ('ALL {0} HOST{1} UP' -f $active.Count, $(if ($active.Count -eq 1) { '' } else { 'S' }))
        $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(40, 140, 60)
    }
}

# The toolbar button carries the tick count, so the selection is visible without
# hunting for it - and shortens to "Bulk" once the window is narrow.
function Update-BulkButton {
    if (-not $script:btnBulk) { return }
    $t = Get-TickCount
    $base = if ($script:RespTier -ge 2) { 'Bulk' } else { 'Bulk select' }
    $want = if ($t -gt 0) { '{0} ({1})' -f $base, $t } else { $base }
    if ($script:btnBulk.Text -ne $want) { $script:btnBulk.Text = $want }
}

function Refresh-Status {
    $active = @($script:Hosts | Where-Object { $_.Enabled })
    $up   = @($active | Where-Object { $_.Status -eq 'UP' }).Count
    $down = @($active | Where-Object { $_.Status -eq 'DOWN' }).Count
    $oth  = $active.Count - $up - $down
    $off  = $script:Hosts.Count - $active.Count
    $shown = $grid.Rows.Count
    $filter = if ($shown -ne $script:Hosts.Count) { ("    |    showing {0} of {1}" -f $shown, $script:Hosts.Count) } else { '' }
    # a live tick count, because a tick made three screens up is invisible and
    # still decides what the next bulk action does
    $ticked = Get-TickCount
    $muted  = @($script:Hosts | Where-Object { $_.Enabled -and -not $_.AlarmEnabled }).Count
    Update-BulkButton
    if ($muted -gt 0)  { $filter += ("    |    {0} muted" -f $muted) }
    if ($ticked -gt 0) { $filter += ("    |    {0} ticked" -f $ticked) }
    if ($script:RespTier -ge 2) {
        # a narrow window gets the short form - a clipped status bar tells nobody anything
        $lblCounts.Text = ('UP {0}  DOWN {1}  off {2}{3}{4}' -f `
            $up, $down, $off, $(if ($ticked -gt 0) { "  tick $ticked" } else { '' }),
            $(if ($script:Paused) { '  [PAUSED]' } else { '' }))
    } else {
        $lblCounts.Text = ('UP: {0}    DOWN: {1}    other: {2}    disabled: {3}    |    every {4}s{5}{6}' -f `
            $up, $down, $oth, $off, [int]$script:Config.IntervalSeconds, $(if ($script:Paused) { '   [PAUSED]' } else { '' }), $filter)
    }
    $upd = if ($script:UpdatePending) { '  |  update ready - restart' }
           elseif ($script:LastUpdateCheck) { '  |  upd chk ' + $script:LastUpdateCheck.ToString('HH:mm') }
           else { '' }
    # Say whose numbers these are. Somebody looking at this screen has to be
    # able to tell whether it is watching the network or watching a server that
    # is watching the network - they fail in completely different ways.
    $src = if (Test-RemoteMode) { '  |  viewer: ' + $(if ($script:RemoteMonitor) { $script:RemoteMonitor } else { Get-RemoteBase }) } else { '' }
    $lblClock.Text = $(if ($script:LastCheck) { 'last check ' + $script:LastCheck.ToString('HH:mm:ss') } else { 'no check yet' }) + $src + $upd
}

# ---------------------------------------------------------------------------
#  Handlers
# ---------------------------------------------------------------------------
# Adding used to be two text boxes sitting on the toolbar. They cost more than
# half its width - for the least frequent action there is - which is what
# pushed Search into the ">>" overflow once ACKNOWLEDGE, Pause and Bulk select
# were all pinned. It uses the same dialog as Edit instead; the fields are
# bigger, properly labelled, and Enter / Esc work.
function Add-Host {
    if (Block-IfRemote "The host list") { return }
    $r = Show-HostDialog -Name '' -Target '' -Title 'Add host'
    if (-not $r) { return }
    $target = $r.Target
    if (-not $target) { return }
    $label = $r.Label
    if (-not $label) { $label = $target }
    if (@($script:Hosts | Where-Object { $_.Target -eq $target }).Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show("'$target' is already in the list.", 'Duplicate', 'OK', 'Warning') | Out-Null
        return
    }
    $script:Hosts.Add((New-HostState -Label $label -Target $target))
    Write-Event ("ADDED     : {0} [{1}]" -f $label, $target)
    Save-Config
    Rebuild-Grid
    Refresh-Banner
    Refresh-Status
    $script:CycleRunning = $false
    Start-CheckCycle
}

$btnAdd.Add_Click({ Add-Host })

# ---- Edit / modify a host ----------------------------------------------------
function Show-HostDialog {
    param([string]$Name, [string]$Target, [string]$Title = 'Edit host')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $s = $script:TextSize
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 34), [int]($s * 11))

    $l1 = New-Object System.Windows.Forms.Label
    $l1.Text = 'Name'; $l1.AutoSize = $true
    $l1.Location = New-Object System.Drawing.Point([int]($s*1.2), [int]($s*1.2))
    $t1 = New-Object System.Windows.Forms.TextBox
    $t1.Text = $Name
    $t1.Location = New-Object System.Drawing.Point([int]($s*8), [int]($s*1.0))
    $t1.Width = [int]($s * 24)

    $l2 = New-Object System.Windows.Forms.Label
    $l2.Text = 'IP / host'; $l2.AutoSize = $true
    $l2.Location = New-Object System.Drawing.Point([int]($s*1.2), [int]($s*4.2))
    $t2 = New-Object System.Windows.Forms.TextBox
    $t2.Text = $Target
    $t2.Location = New-Object System.Drawing.Point([int]($s*8), [int]($s*4.0))
    $t2.Width = [int]($s * 24)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = $(if ($Title -like 'Add*') { '&Add' } else { '&Save' }); $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point([int]($s*17), [int]($s*7.4))
    $ok.Size = New-Object System.Drawing.Size([int]($s*7), [int]($s*2.6))

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point([int]($s*25), [int]($s*7.4))
    $cancel.Size = New-Object System.Drawing.Size([int]($s*7), [int]($s*2.6))

    $dlg.Controls.AddRange(@($l1, $t1, $l2, $t2, $ok, $cancel))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel
    if ($dlg.ShowDialog($form) -ne 'OK') { $dlg.Dispose(); return $null }
    $res = [pscustomobject]@{ Label = $t1.Text.Trim(); Target = $t2.Text.Trim() }
    $dlg.Dispose()
    $res
}

function Edit-SelectedHost {
    if (Block-IfRemote "The host list") { return }
    $sel = @($grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
    if ($sel.Count -ne 1) {
        [System.Windows.Forms.MessageBox]::Show('Select exactly one host to edit.', 'Edit host', 'OK', 'Information') | Out-Null
        return
    }
    $h = $sel[0]
    $r = Show-HostDialog -Name $h.Label -Target $h.Target
    if (-not $r) { return }
    if (-not $r.Target) {
        [System.Windows.Forms.MessageBox]::Show('IP / host cannot be empty.', 'Edit host', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $r.Label) { $r.Label = $r.Target }
    $clash = @($script:Hosts | Where-Object { $_.Target -eq $r.Target -and -not [object]::ReferenceEquals($_, $h) })
    if ($clash.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show("'$($r.Target)' is already in the list.", 'Duplicate', 'OK', 'Warning') | Out-Null
        return
    }
    $oldLabel = $h.Label; $oldTarget = $h.Target
    $targetChanged = ($h.Target -ne $r.Target)
    $h.Label  = $r.Label
    $h.Target = $r.Target
    if ($targetChanged) {
        # different address - the old up/down history no longer applies
        $h.Status = if ($h.Enabled) { 'INIT' } else { 'OFF' }
        $h.Latency = $null; $h.DownSince = $null; $h.LastChange = $null
        $h.Acked = $false; $h.FailCount = 0; $h.Task = $null; $h.Ping = $null
        Reset-HostStats $h
    }
    $h.StyleKey = ''
    Write-Event ("EDITED    : {0} [{1}]  ->  {2} [{3}]" -f $oldLabel, $oldTarget, $h.Label, $h.Target)
    Save-Config
    Rebuild-Grid
    Update-Alarm
    Refresh-Banner
    $script:CycleRunning = $false
    Start-CheckCycle
}

function Get-SelectedHosts {
    @($grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
}

# ---- Bulk selection ---------------------------------------------------------
# What a bulk action works on: every TICKED host if anything is ticked, and only
# then the highlighted rows. A tick survives sorting, searching and the 400 ms
# refresh; a highlight does not - which is why the tick wins when both exist.
function Get-BulkHosts {
    $ticked = @($script:Hosts | Where-Object { $_.Sel })
    if ($ticked.Count -gt 0) { return $ticked }
    @($grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
}

# A one-line wrapper, so a headless test can stub the message box - a static
# .NET call cannot be replaced, and an unattended MessageBox just hangs forever.
function Show-Info {
    param([string]$Text, [string]$Title)
    [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Information') | Out-Null
}

# In viewer mode the host list belongs to the server. Editing it here would
# look like it worked and then vanish on the next fetch a few seconds later,
# which is a worse answer than saying no.
function Block-IfRemote {
    param([string]$What = 'This')
    if (-not (Test-RemoteMode)) { return $false }
    Show-Info ("$What is decided by the monitor server while viewer mode is on." + [Environment]::NewLine + [Environment]::NewLine +
               'Edit the host list in a browser at:' + [Environment]::NewLine +
               ('    {0}/hosts' -f (Get-RemoteBase)) + [Environment]::NewLine + [Environment]::NewLine +
               'Changes there appear here within a few seconds.') 'Viewer mode'
    $true
}

function Show-NothingPicked {
    param([string]$Title)
    [System.Windows.Forms.MessageBox]::Show(
        "Nothing picked.`r`n`r`nTick the boxes in the first column (or highlight rows) first.`r`nClick the tick-box column header to select every host at once.",
        $Title, 'OK', 'Information') | Out-Null
}

# The header check box draws itself from the current ticks, so it has to be
# repainted whenever they change - the cell values alone do not invalidate it.
function Update-SelHeader {
    try { $grid.InvalidateCell($grid.Columns['cSel'].Index, -1) } catch { }
}

function Set-AllTicks {
    param([bool]$On)
    # only what the search box is currently showing - ticking hosts you cannot
    # see and then disabling them is exactly the accident to avoid
    foreach ($h in $script:Visible) { $h.Sel = $On }
    if (-not $On) { foreach ($h in $script:Hosts) { $h.Sel = $false } }
    Refresh-Grid
    Update-SelHeader
    Refresh-Status
}

function Invert-Ticks {
    foreach ($h in $script:Visible) { $h.Sel = -not $h.Sel }
    Refresh-Grid; Update-SelHeader; Refresh-Status
}

function Get-TickCount { @($script:Hosts | Where-Object { $_.Sel }).Count }

# ---- Enable / disable -------------------------------------------------------
function Apply-HostEnabled {
    param($h, [bool]$On)
    $h.Enabled   = $On
    $h.StyleKey  = ''
    $h.FailCount = 0; $h.Acked = $false
    $h.DownSince = $null; $h.Latency = $null; $h.LastChange = Get-Date
    if ($On) {
        $h.Status = 'INIT'
        Reset-HostStats $h                # loss % from before the outage is meaningless
    } else {
        $h.Status = 'OFF'
        $h.Task = $null; $h.Ping = $null
    }
}

# One log line per host up to 5, a summary beyond that - a 60-host bulk action
# must not push everything else out of the event log.
function Write-BulkEvent {
    param([string]$Tag, $Hosts_, [string]$Suffix = '')
    if ($Hosts_.Count -le 5) {
        foreach ($h in $Hosts_) { Write-Event ("{0}: {1} [{2}]{3}" -f $Tag.PadRight(10), $h.Label, $h.Target, $Suffix) }
    } else {
        Write-Event ("{0}: {1} hosts{2}" -f $Tag.PadRight(10), $Hosts_.Count, $Suffix)
    }
}

function Set-HostsEnabled {
    param([bool]$On)
    if (Block-IfRemote "Which hosts are watched") { return }
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Enable / disable'; return }
    $changed = @($sel | Where-Object { [bool]$_.Enabled -ne $On })
    if ($changed.Count -eq 0) {
        Write-Event ("HOSTS     : {0} host(s) already {1}" -f $sel.Count, $(if ($On) { 'enabled' } else { 'disabled' }))
        return
    }
    foreach ($h in $changed) { Apply-HostEnabled $h $On }
    if ($On) { Write-BulkEvent 'ENABLED' $changed }
    else     { Write-BulkEvent 'DISABLED' $changed ' - not monitored, no alarm' }
    Save-Config; Rebuild-Grid; Update-Alarm; Refresh-Banner; Refresh-Status
    $script:CycleRunning = $false
    Start-CheckCycle
}

function Toggle-SelectedHosts {
    # a mixed bunch is not flipped one by one - that would leave the list in the
    # same mixed state and tell nobody what happened. All on unless all were on.
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Enable / disable'; return }
    $allOn = @($sel | Where-Object { -not $_.Enabled }).Count -eq 0
    Set-HostsEnabled (-not $allOn)
}

# ---- Alarm on / off (per host) ----------------------------------------------
function Set-HostsAlarm {
    param([bool]$On)
    if (Block-IfRemote "The per-host sound switch") { return }
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Alarm on / off'; return }
    $changed = @($sel | Where-Object { [bool]$_.AlarmEnabled -ne $On })
    if ($changed.Count -eq 0) {
        Write-Event ("HOSTS     : alarm already {0} for {1} host(s)" -f $(if ($On) { 'on' } else { 'off' }), $sel.Count)
        return
    }
    foreach ($h in $changed) {
        $h.AlarmEnabled = $On
        $h.StyleKey = ''
        if ($On) { $h.Acked = $false }    # un-muting a host that is down must ring
    }
    if ($On) { Write-BulkEvent 'SOUND ON' $changed }
    else     { Write-BulkEvent 'SOUND OFF' $changed ' - silent; banner, acknowledge and notifications unchanged' }
    Save-Config; Refresh-Grid; Update-Alarm; Refresh-Banner
}

function Toggle-HostsAlarm {
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Alarm on / off'; return }
    $allOn = @($sel | Where-Object { -not $_.AlarmEnabled }).Count -eq 0
    Set-HostsAlarm (-not $allOn)
}

# Clicking the box in the row itself - one host, no menu needed
function Toggle-HostAlarmRow {
    param($h)
    if (Block-IfRemote "The per-host sound switch") { return }
    if (-not $h) { return }
    $h.AlarmEnabled = -not $h.AlarmEnabled
    $h.StyleKey = ''
    if ($h.AlarmEnabled) {
        $h.Acked = $false
        Write-Event ("SOUND ON  : {0} [{1}]" -f $h.Label, $h.Target)
    } else {
        Write-Event ("SOUND OFF : {0} [{1}] - silent; banner, acknowledge and notifications unchanged" -f $h.Label, $h.Target)
    }
    Save-Config; Refresh-Grid; Update-Alarm; Refresh-Banner
}

function Remove-SelectedHosts {
    if (Block-IfRemote "The host list") { return }
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Remove hosts'; return }
    if ($sel.Count -eq 1) {
        $msg = "Remove '{0}'  [{1}] ?" -f $sel[0].Label, $sel[0].Target
    } else {
        # a bulk delete names what it is about to delete - "Remove 40 hosts?" is
        # not something anybody can say yes to safely
        $names = ($sel | Select-Object -First 12 | ForEach-Object { '   - {0}   [{1}]' -f $_.Label, $_.Target }) -join "`r`n"
        if ($sel.Count -gt 12) { $names += ("`r`n   ... and {0} more" -f ($sel.Count - 12)) }
        $msg = "Remove these {0} hosts?`r`n`r`n{1}`r`n`r`nThis cannot be undone." -f $sel.Count, $names
    }
    # default button is No: a stray Enter on a 40-host delete is unforgiving
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, 'Confirm removal',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning,
        [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($ans -ne 'Yes') { return }
    foreach ($h in $sel) { $script:Hosts.Remove($h) | Out-Null }
    Write-BulkEvent 'REMOVED' $sel
    Save-Config; Rebuild-Grid; Update-Alarm; Refresh-Banner; Refresh-Status
}

# ---- Acknowledge / reset / copy, for the picked hosts only -------------------
function Confirm-AlarmSelected {
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Acknowledge'; return }
    $down = @($sel | Where-Object { $_.Enabled -and $_.Status -eq 'DOWN' -and -not $_.Acked })
    if ($down.Count -eq 0) {
        Write-Event ("ACK       : nothing to acknowledge among the {0} picked host(s)" -f $sel.Count)
        return
    }
    foreach ($h in $down) { $h.Acked = $true; $h.StyleKey = '' }
    Write-BulkEvent 'ACK' $down ' - acknowledged'
    # The server acknowledges everything at once - it has no per-host ack - so
    # in viewer mode a partial acknowledgement cannot be expressed. Say so,
    # rather than let the next fetch quietly undo the selection somebody made.
    if (Test-RemoteMode) {
        Write-Event 'ACK       : the server acknowledges all down hosts, not a selection'
        Send-RemoteAck
    }
    Update-Alarm; Refresh-Grid; Refresh-Banner
}

function Reset-SelectedStats {
    if (Block-IfRemote "Ping statistics") { return }
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Reset statistics'; return }
    foreach ($h in $sel) { Reset-HostStats $h; $h.StyleKey = '' }
    Write-BulkEvent 'RESET' $sel ' - loss / latency history cleared'
    Refresh-Grid; Refresh-Status
}

function Copy-SelectedHosts {
    $sel = @(Get-BulkHosts)
    if ($sel.Count -eq 0) { Show-NothingPicked 'Copy to clipboard'; return }
    $lines = @($sel | ForEach-Object {
        '{0},{1},{2},{3},{4}' -f $_.Label, $_.Target,
            $(if ($_.Enabled) { 'monitored' } else { 'disabled' }),
            $(if ($_.AlarmEnabled) { 'alarm' } else { 'muted' }),
            $(if ($_.Enabled) { $_.Status } else { 'OFF' })
    })
    $text = (@('Name,Target,Monitoring,Alarm,Status') + $lines) -join "`r`n"
    try {
        [System.Windows.Forms.Clipboard]::SetText($text)
        Write-Event ("COPIED    : {0} host(s) to the clipboard as CSV" -f $sel.Count)
    } catch {
        Write-Event ("COPY FAIL : {0}" -f $_.Exception.Message)
    }
}

# ---- Bulk add ---------------------------------------------------------------
# One host per line. "label,target", "label;target", "label<tab>target" or a
# bare target. A last-octet range - 10.0.0.1-30 or 10.0.0.1-10.0.0.30 - expands
# into one host per address, which is how a whole POP gets added in one paste.
function Parse-HostLines {
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $parts = @($line -split '\s*[,;\t]\s*' | Where-Object { $_ -ne '' })
        if ($parts.Count -ge 2) { $label = $parts[0]; $target = $parts[1] }
        else                    { $label = '';        $target = $parts[0] }

        $m = [regex]::Match($target, '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.)(\d{1,3})\s*-\s*(?:\1)?(\d{1,3})$')
        if ($m.Success) {
            $a = [int]$m.Groups[2].Value; $b = [int]$m.Groups[3].Value
            if ($a -le $b -and $b -le 255 -and ($b - $a) -lt 256) {
                for ($i = $a; $i -le $b; $i++) {
                    $t = $m.Groups[1].Value + $i
                    [void]$out.Add([pscustomobject]@{
                        Label = $(if ($label) { '{0}{1}' -f $label, $i } else { $t }); Target = $t })
                }
                continue
            }
        }
        if (-not $label) { $label = $target }
        [void]$out.Add([pscustomobject]@{ Label = $label; Target = $target })
    }
    # no leading comma here: every caller already wraps the result in @(), and
    # ",$array" on top of that hands back an array holding one array
    $out.ToArray()
}

function Show-BulkAddDialog {
    if (Block-IfRemote "The host list") { return }
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Add many hosts'
    $dlg.FormBorderStyle = 'Sizable'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 40), [int]($s * 26))
    $dlg.MinimumSize = New-Object System.Drawing.Size([int]($s * 30), [int]($s * 20))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.AutoSize = $false
    $lbl.Text = "One host per line:`r`n    name,10.0.0.1        name and address`r`n    10.0.0.1             address only (the name becomes the address)`r`n    POP-RTR,10.0.0.1-30  a whole range, one host per address"
    $lbl.Location = New-Object System.Drawing.Point([int]($s*1.2), [int]($s*0.8))
    $lbl.Size = New-Object System.Drawing.Size([int]($s*38), [int]($s*6.2))

    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ScrollBars = 'Vertical'; $box.WordWrap = $false
    $box.Font = New-Object System.Drawing.Font('Consolas', [single]$s, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $box.Location = New-Object System.Drawing.Point([int]($s*1.2), [int]($s*7.2))
    $box.Size = New-Object System.Drawing.Size([int]($s*37.6), [int]($s*15))
    $box.Anchor = 'Top,Left,Right,Bottom'

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '&Add'; $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point([int]($s*23), [int]($s*23))
    $ok.Size = New-Object System.Drawing.Size([int]($s*7), [int]($s*2.6))
    $ok.Anchor = 'Bottom,Right'

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point([int]($s*31), [int]($s*23))
    $cancel.Size = New-Object System.Drawing.Size([int]($s*7), [int]($s*2.6))
    $cancel.Anchor = 'Bottom,Right'

    $dlg.Controls.AddRange(@($lbl, $box, $ok, $cancel))
    # NOT AcceptButton: Enter has to make a new line in a multi-line box
    $dlg.CancelButton = $cancel
    $r = $dlg.ShowDialog($form)
    $text = $box.Text
    $dlg.Dispose()
    if ($r -ne 'OK') { return $null }
    $text
}

function Add-ManyHosts {
    $text = Show-BulkAddDialog
    if ($null -eq $text) { return }
    $wanted = @(Parse-HostLines $text)
    if ($wanted.Count -eq 0) {
        Show-Info 'Nothing to add - no usable lines.' 'Add many hosts'
        return
    }
    $added = 0; $dupes = 0
    foreach ($w in $wanted) {
        if (@($script:Hosts | Where-Object { $_.Target -eq $w.Target }).Count -gt 0) { $dupes++; continue }
        $script:Hosts.Add((New-HostState -Label $w.Label -Target $w.Target)) | Out-Null
        $added++
    }
    Write-Event ("ADDED     : {0} host(s) from a pasted list{1}" -f $added,
        $(if ($dupes -gt 0) { " ($dupes already in the list, skipped)" } else { '' }))
    if ($added -eq 0) {
        Show-Info ("Nothing added - all {0} were already in the list." -f $dupes) 'Add many hosts'
        return
    }
    Save-Config; Rebuild-Grid; Update-Alarm; Refresh-Banner; Refresh-Status
    $script:CycleRunning = $false
    Start-CheckCycle
    Show-Info ("Added {0} host(s).{1}" -f $added,
        $(if ($dupes -gt 0) { "`r`n$dupes were already in the list and were skipped." } else { '' })) 'Add many hosts'
}

function Confirm-Alarm {
    $down = @($script:Hosts | Where-Object { $_.Enabled -and $_.Status -eq 'DOWN' -and -not $_.Acked })
    if ($down.Count -eq 0) { return }
    foreach ($h in $down) { $h.Acked = $true; $h.StyleKey = '' }
    Write-Event ("ACK       : alarm acknowledged ({0} host(s) still down)" -f $down.Count)
    # Acknowledging here has to reach the server, or the phones go on being
    # reminded about something the desk has already picked up - and the next
    # fetch would overwrite this window's own acknowledgement anyway.
    if (Test-RemoteMode) { Send-RemoteAck }
    Update-Alarm; Refresh-Grid; Refresh-Banner
}

function Toggle-Pause {
    $script:Paused = -not $script:Paused
    # Pausing is the server's state in viewer mode - the next fetch overwrites
    # whatever is set here, so it has to be told, or the button appears to do
    # nothing for four seconds and then springs back.
    if (Test-RemoteMode) { Send-RemoteCommand $(if ($script:Paused) { 'pause' } else { 'resume' }) }
    $btnPause.Text = if ($script:Paused) { 'Resume' } else { 'Pause' }
    $miPause.Text  = if ($script:Paused) { '&Resume monitoring' } else { '&Pause monitoring' }
    Write-Event ('MONITOR   : {0}' -f $(if ($script:Paused) { 'paused' } else { 'resumed' }))
    if (-not $script:Paused) { Start-CheckCycle }
    Refresh-Banner; Refresh-Status
}

$cmEdit.Add_Click({ Edit-SelectedHost })
$cmToggle.Add_Click({ Toggle-SelectedHosts })
$cmAlarm.Add_Click({ Toggle-HostsAlarm })
$cmRemove.Add_Click({ Remove-SelectedHosts })
$cmTick.Add_Click({
    $sel = @(Get-SelectedHosts)
    if ($sel.Count -eq 0) { return }
    $allOn = @($sel | Where-Object { -not $_.Sel }).Count -eq 0
    foreach ($h in $sel) { $h.Sel = -not $allOn }
    Refresh-Grid; Update-SelHeader; Refresh-Status
})
$cmTickAll.Add_Click({ Set-AllTicks $true })
$cmTickNon.Add_Click({ Set-AllTicks $false })
$cmReset.Add_Click({ Reset-SelectedStats })
$cmCopy.Add_Click({ Copy-SelectedHosts })
$cmAck.Add_Click({ Confirm-Alarm })

# The right-click menu says what it is about to do, for the rows it is about to
# do it to: with a tick set live, "Disable" meaning something different from the
# row under the cursor has to be visible before the click, not after.
$ctx.Add_Opening({
    $t = Get-TickCount
    $n = if ($t -gt 0) { $t } else { @(Get-SelectedHosts).Count }
    $what = if ($t -gt 0) { "$t ticked" } else { "$n selected" }
    $cmToggle.Text = "&Disable / Enable  ($what)"
    $cmAlarm.Text  = "Sound on / o&ff  ($what)"
    $cmRemove.Text = "&Remove  ($what)"
    $cmReset.Text  = "Reset &statistics  ($what)"
    $cmCopy.Text   = "&Copy to clipboard  ($what)"
    $cmEdit.Enabled = (@(Get-SelectedHosts).Count -eq 1)
})

# ---- Notification settings dialog -------------------------------------------
$miNotify.Add_Click({
    $n = $script:Config.Notify
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Notifications - email / Telegram / phone / SMS / command'
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    # tall enough for the Command tab, which is the longest one
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 52), [int]($s * 42))

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(10, 10)
    $tabs.Size = New-Object System.Drawing.Size([int]($s * 52 - 20), [int]($s * 38))
    $dlg.Controls.Add($tabs)

    $rowY = 0
    function NRow { param($page, $label, $ctrl, $w = 30)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $label; $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($script:rowY + $s*0.4))
        $ctrl.Location = New-Object System.Drawing.Point([int]($s*13), [int]$script:rowY)
        $ctrl.Width = [int]($s * $w)
        $page.Controls.AddRange(@($l, $ctrl))
        $script:rowY += [int]($s * 2.9)
    }
    function NChk { param($page, $text, $checked)
        $c = New-Object System.Windows.Forms.CheckBox
        $c.Text = $text; $c.AutoSize = $true; $c.Checked = [bool]$checked
        $c.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$script:rowY)
        $page.Controls.Add($c)
        $script:rowY += [int]($s * 2.9)
        $c
    }
    function NTxt { param($val, [switch]$Pass)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Text = [string]$val
        if ($Pass) { $t.UseSystemPasswordChar = $true }
        $t
    }

    # ---------- General ----------
    $pGen = New-Object System.Windows.Forms.TabPage; $pGen.Text = 'General'; $pGen.BackColor = 'White'
    $script:rowY = [int]($s * 1.2)
    $gDown  = NChk $pGen 'Notify when a host goes DOWN'      $n.OnDown
    $gUp    = NChk $pGen 'Notify when a host RECOVERS'       $n.OnRecover
    $gBatch = New-Object System.Windows.Forms.NumericUpDown; $gBatch.Minimum=5; $gBatch.Maximum=300; $gBatch.Value=[Math]::Min([Math]::Max([int]$n.BatchSeconds,5),300)
    NRow $pGen 'Batch (sec)' $gBatch 8
    $gMax = New-Object System.Windows.Forms.NumericUpDown; $gMax.Minimum=1; $gMax.Maximum=500; $gMax.Value=[Math]::Min([Math]::Max([int]$n.MaxPerHour,1),500)
    NRow $pGen 'Max msgs/hour' $gMax 8
    $gRep = New-Object System.Windows.Forms.NumericUpDown; $gRep.Minimum=0; $gRep.Maximum=240
    $gRep.Value = [Math]::Min([Math]::Max([int]$n.RepeatMin, 0), 240)
    NRow $pGen 'Repeat every (min)' $gRep 8
    $gInfo = New-Object System.Windows.Forms.Label
    $gInfo.Text = "Events inside the batch window are combined into ONE message," + [Environment]::NewLine +
                  "so a link failure taking many hosts down does not fire many SMS." + [Environment]::NewLine + [Environment]::NewLine +
                  "Repeat every: while a host is STILL down and nobody has" + [Environment]::NewLine +
                  "acknowledged it, send again this often. 0 = send once only." + [Environment]::NewLine +
                  "Acknowledging - on the PC, in a browser or on a phone - stops it." + [Environment]::NewLine +
                  "Use it so a message missed at 3am does not leave an outage" + [Environment]::NewLine +
                  "unattended until morning. Recoveries are never repeated." + [Environment]::NewLine + [Environment]::NewLine +
                  "Passwords, bot tokens and API keys are stored encrypted (DPAPI)" + [Environment]::NewLine +
                  "and can only be read back by this Windows user on this machine."
    $gInfo.AutoSize = $true
    $gInfo.ForeColor = [System.Drawing.Color]::FromArgb(90,94,100)
    $gInfo.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($script:rowY + $s))
    $pGen.Controls.Add($gInfo)
    $tabs.TabPages.Add($pGen)

    # ---------- Email ----------
    $pMail = New-Object System.Windows.Forms.TabPage; $pMail.Text = 'Email'; $pMail.BackColor = 'White'
    $script:rowY = [int]($s * 1.2)
    $mEn   = NChk $pMail 'Send email notifications' $n.Email.Enabled
    $mSrv  = NTxt $n.Email.SmtpServer;        NRow $pMail 'SMTP server' $mSrv
    $mPort = New-Object System.Windows.Forms.NumericUpDown; $mPort.Minimum=1; $mPort.Maximum=65535; $mPort.Value=[Math]::Min([Math]::Max([int]$n.Email.Port,1),65535)
    NRow $pMail 'Port' $mPort 8
    # SSL/TLS on 465 and STARTTLS on 587 are NOT the same protocol - picking the
    # wrong one just times out, so it is a choice, not a checkbox
    $mSec = New-Object System.Windows.Forms.ComboBox; $mSec.DropDownStyle = 'DropDownList'
    [void]$mSec.Items.AddRange(@(
        'Auto  (465 = SSL, else STARTTLS)',
        'STARTTLS  (587 / 25)',
        'SSL / TLS  (465)',
        'None'))
    $mSecKeys = @('Auto','STARTTLS','SSL','None')
    $ix = [Array]::IndexOf($mSecKeys, [string]$n.Email.Security)
    if ($ix -lt 0) { $ix = 0 }
    $mSec.SelectedIndex = $ix
    NRow $pMail 'Security' $mSec 24
    $mUser = NTxt $n.Email.User;              NRow $pMail 'Username' $mUser
    $mPass = NTxt '' -Pass;                   NRow $pMail 'Password' $mPass
    if ($n.Email.PassEnc) { $mPass.Text = '********' }
    $mFrom = NTxt $n.Email.From;              NRow $pMail 'From' $mFrom
    $mTo   = NTxt $n.Email.To;                NRow $pMail 'To (comma sep)' $mTo
    $tabs.TabPages.Add($pMail)

    # ---------- Telegram ----------
    $pTg = New-Object System.Windows.Forms.TabPage; $pTg.Text = 'Telegram'; $pTg.BackColor = 'White'
    $script:rowY = [int]($s * 1.2)
    $tEn   = NChk $pTg 'Send Telegram notifications' $n.Telegram.Enabled
    $tTok  = NTxt '' -Pass;                   NRow $pTg 'Bot token' $tTok
    if ($n.Telegram.TokenEnc) { $tTok.Text = '********' }
    $tChat = NTxt $n.Telegram.ChatId;         NRow $pTg 'Chat ID' $tChat
    $tInfo = New-Object System.Windows.Forms.Label
    $tInfo.Text = "1. Talk to @BotFather in Telegram, /newbot, copy the token." + [Environment]::NewLine +
                  "2. Add the bot to your group (or message it directly)." + [Environment]::NewLine +
                  "3. Open  https://api.telegram.org/bot<TOKEN>/getUpdates" + [Environment]::NewLine +
                  "   and copy the chat id (group ids start with -100)."
    $tInfo.AutoSize = $true
    $tInfo.ForeColor = [System.Drawing.Color]::FromArgb(90,94,100)
    $tInfo.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($script:rowY + $s))
    $pTg.Controls.Add($tInfo)
    $tabs.TabPages.Add($pTg)

    # ---------- ntfy (phone alarm) ----------
    # The only channel that can wake a locked phone with a real alarm. Priority
    # 5 in the Android app bypasses Do Not Disturb and vibrates continuously.
    $pNt = New-Object System.Windows.Forms.TabPage; $pNt.Text = 'Phone (ntfy)'; $pNt.BackColor = 'White'
    $script:rowY = [int]($s * 1.2)
    $nEn   = NChk $pNt 'Send phone alarms via ntfy' $n.Ntfy.Enabled
    $nSrv  = NTxt $n.Ntfy.Server;   NRow $pNt 'Server' $nSrv 30
    $nTop  = NTxt $n.Ntfy.Topic;    NRow $pNt 'Topic' $nTop 30
    $nTok  = NTxt '' -Pass;         NRow $pNt 'Token (optional)' $nTok
    if ($n.Ntfy.TokenEnc) { $nTok.Text = '********' }
    $nDp = New-Object System.Windows.Forms.ComboBox; $nDp.DropDownStyle = 'DropDownList'
    $nUp = New-Object System.Windows.Forms.ComboBox; $nUp.DropDownStyle = 'DropDownList'
    $priText = @('1 - min (silent)','2 - low','3 - default','4 - high','5 - urgent (ignores Do Not Disturb)')
    [void]$nDp.Items.AddRange($priText); [void]$nUp.Items.AddRange($priText)
    $nDp.SelectedIndex = [Math]::Min([Math]::Max([int]$n.Ntfy.DownPriority, 1), 5) - 1
    $nUp.SelectedIndex = [Math]::Min([Math]::Max([int]$n.Ntfy.UpPriority,   1), 5) - 1
    NRow $pNt 'DOWN priority' $nDp 30
    NRow $pNt 'RECOVER priority' $nUp 30

    $nTest = New-Object System.Windows.Forms.Button
    $nTest.Text = 'Send a test to my phone'
    $nTest.AutoSize = $true
    $nTest.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$script:rowY)
    $pNt.Controls.Add($nTest)
    $script:rowY += [int]($s * 3.0)
    # Tests what is TYPED IN THE BOX, not what is saved - otherwise the first
    # test after typing a topic silently checks the previous one.
    $nTest.Add_Click({
        $tok = if ($nTok.Text -eq '********') { Unprotect-Secret ([string]$n.Ntfy.TokenEnc) } else { $nTok.Text.Trim() }
        Send-NtfyTest -Server $nSrv.Text.Trim() -Topic $nTop.Text.Trim() -Token $tok `
                      -Priority ($nDp.SelectedIndex + 1)
    })

    $nInfo = New-Object System.Windows.Forms.Label
    $nInfo.Text = "The channel that rings a LOCKED phone. Three steps on the phone," + [Environment]::NewLine +
                  "and skipping any one of them makes it arrive late or silent:" + [Environment]::NewLine +
                  "1. Install ""ntfy"", subscribe to the SAME server + topic above." + [Environment]::NewLine +
                  "2. In the subscription: turn ON 'Instant delivery'. Without it" + [Environment]::NewLine +
                  "   ntfy uses Firebase and alerts can be MINUTES OR HOURS late." + [Environment]::NewLine +
                  "3. Android Settings > Apps > ntfy > Notifications > the MAX /" + [Environment]::NewLine +
                  "   URGENT channel: set a loud sound and 'Override Do Not Disturb'." + [Environment]::NewLine +
                  "   (Android sets sound per PRIORITY CHANNEL, not per topic.)" + [Environment]::NewLine +
                  "Also exclude ntfy from battery optimisation, or Android will" + [Environment]::NewLine +
                  "eventually kill it." + [Environment]::NewLine +
                  "Treat the topic name as a password - anyone who knows it can read" + [Environment]::NewLine +
                  "your alerts on a public server. Use your own server for real use."
    $nInfo.AutoSize = $true
    $nInfo.ForeColor = [System.Drawing.Color]::FromArgb(90,94,100)
    $nInfo.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($script:rowY))
    $pNt.Controls.Add($nInfo)
    $tabs.TabPages.Add($pNt)

    # ---------- SMS ----------
    $pSms = New-Object System.Windows.Forms.TabPage; $pSms.Text = 'SMS'; $pSms.BackColor = 'White'
    $script:rowY = [int]($s * 1.2)
    $sEn  = NChk $pSms 'Send SMS notifications' $n.Sms.Enabled
    $sNum = NTxt $n.Sms.Numbers;               NRow $pSms 'Numbers (comma)' $sNum
    $sUrl = NTxt $n.Sms.UrlTemplate;           NRow $pSms 'Gateway URL' $sUrl 34
    $sKey = NTxt '' -Pass;                     NRow $pSms 'API key' $sKey
    if ($n.Sms.ApiKeyEnc) { $sKey.Text = '********' }
    $sMet = New-Object System.Windows.Forms.ComboBox; $sMet.DropDownStyle='DropDownList'
    [void]$sMet.Items.AddRange(@('GET','POST'))
    $sMet.SelectedIndex = $(if ("$($n.Sms.Method)".ToUpper() -eq 'POST') { 1 } else { 0 })
    NRow $pSms 'Method' $sMet 10
    $sBody = NTxt $n.Sms.BodyTemplate;         NRow $pSms 'POST body' $sBody 34
    $sInfo = New-Object System.Windows.Forms.Label
    $sInfo.Text = "Works with any HTTP SMS gateway. Placeholders you can use in the" + [Environment]::NewLine +
                  "URL and POST body:   {apikey}   {phone}   {message}" + [Environment]::NewLine + [Environment]::NewLine +
                  "Example (GET):" + [Environment]::NewLine +
                  "  https://api.example.com/send?api_key={apikey}&to={phone}&msg={message}"
    $sInfo.AutoSize = $true
    $sInfo.ForeColor = [System.Drawing.Color]::FromArgb(90,94,100)
    $sInfo.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($script:rowY + $s))
    $pSms.Controls.Add($sInfo)
    $tabs.TabPages.Add($pSms)

    # ---------- Command (offline / GSM modem) ----------
    # The one channel that does not need the internet. Runs any local program:
    # a modem CLI, gammu, smssend, a .bat - whatever the desk already has.
    $pCmd = New-Object System.Windows.Forms.TabPage; $pCmd.Text = 'Command (offline)'; $pCmd.BackColor = 'White'
    $script:rowY = [int]($s * 1.2)
    $cEn   = NChk $pCmd 'Run a command when a host goes down / recovers' $n.Command.Enabled
    $cPath = NTxt $n.Command.Path;    NRow $pCmd 'Program / script' $cPath 30
    $cBrowse = New-Object System.Windows.Forms.Button
    $cBrowse.Text = '...'
    $cBrowse.Size = New-Object System.Drawing.Size([int]($s*2.6), [int]($s*1.9))
    $cBrowse.Location = New-Object System.Drawing.Point([int]($s*43.4), [int]($script:rowY - $s*2.9))
    $pCmd.Controls.Add($cBrowse)
    $cArgs = NTxt $n.Command.Args;    NRow $pCmd 'Arguments' $cArgs 34
    $cNum  = NTxt $n.Command.Numbers; NRow $pCmd 'Numbers (comma)' $cNum 22

    # Modem: filled from what Windows actually has attached, but editable so a
    # name the modem tool expects can just be typed in
    $cMdm = New-Object System.Windows.Forms.ComboBox
    $cMdm.DropDownStyle = 'DropDown'
    $cMdm.AutoCompleteMode = 'SuggestAppend'
    $cMdm.AutoCompleteSource = 'ListItems'
    try {
        Get-WmiObject Win32_POTSModem -ErrorAction Stop | ForEach-Object {
            $p = [string]$_.AttachedTo
            [void]$cMdm.Items.Add($(if ($p) { '{0}  ({1})' -f $_.Name, $p } else { [string]$_.Name }))
        }
    } catch { }
    try {
        foreach ($p in [System.IO.Ports.SerialPort]::GetPortNames()) {
            $seen = $false
            foreach ($it in $cMdm.Items) { if ([string]$it -like "*$p*") { $seen = $true; break } }
            if (-not $seen) { [void]$cMdm.Items.Add($p) }
        }
    } catch { }
    $cMdm.Text = [string]$n.Command.Modem
    NRow $pCmd 'Modem' $cMdm 30

    $cDir  = NTxt $n.Command.WorkDir; NRow $pCmd 'Start in (opt.)' $cDir 30
    $cTmo  = New-Object System.Windows.Forms.NumericUpDown; $cTmo.Minimum=5; $cTmo.Maximum=600
    $cTmo.Value = [Math]::Min([Math]::Max([int]$n.Command.TimeoutSec, 5), 600)
    NRow $pCmd 'Timeout (sec)' $cTmo 8
    $cPer  = NChk $pCmd 'Run once per host instead of once per batch' $n.Command.PerHost
    $cInfo = New-Object System.Windows.Forms.Label
    $cInfo.Text = "Needs no internet - use a GSM / USB modem so alerts still go out" + [Environment]::NewLine +
                  "when the link itself is what failed. Several numbers = one run each." + [Environment]::NewLine +
                  "{phone} {message} {host} {target} {status} {time} {pc} {modem} {port}" + [Environment]::NewLine +
                  "Example:  C:\gammu\gammu.exe   sendsms TEXT {phone} -text ""{message}"""
    $cInfo.AutoSize = $true
    $cInfo.ForeColor = [System.Drawing.Color]::FromArgb(90,94,100)
    $cInfo.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($script:rowY + $s*0.6))
    $pCmd.Controls.Add($cInfo)
    $tabs.TabPages.Add($pCmd)

    $script:CmdPathBox = $cPath
    $cBrowse.Add_Click({
        $of = New-Object System.Windows.Forms.OpenFileDialog
        $of.Title  = 'Choose the program to run'
        $of.Filter = 'Programs and scripts (*.exe;*.bat;*.cmd;*.ps1)|*.exe;*.bat;*.cmd;*.ps1|All files (*.*)|*.*'
        if ($of.ShowDialog($script:CmdPathBox.FindForm()) -eq 'OK') { $script:CmdPathBox.Text = $of.FileName }
    })

    # ---------- buttons ----------
    $bTest = New-Object System.Windows.Forms.Button
    $bTest.Text = 'Send &test'
    $bTest.Location = New-Object System.Drawing.Point(10, [int]($s * 38.6))
    $bTest.Size = New-Object System.Drawing.Size([int]($s*9), [int]($s*2.6))
    $bOk = New-Object System.Windows.Forms.Button
    $bOk.Text = 'Save'; $bOk.DialogResult = 'OK'
    $bOk.Location = New-Object System.Drawing.Point([int]($s*35), [int]($s * 38.6))
    $bOk.Size = New-Object System.Drawing.Size([int]($s*7.5), [int]($s*2.6))
    $bCancel = New-Object System.Windows.Forms.Button
    $bCancel.Text = 'Cancel'; $bCancel.DialogResult = 'Cancel'
    $bCancel.Location = New-Object System.Drawing.Point([int]($s*43), [int]($s * 38.6))
    $bCancel.Size = New-Object System.Drawing.Size([int]($s*7.5), [int]($s*2.6))
    $dlg.Controls.AddRange(@($bTest, $bOk, $bCancel))
    $dlg.AcceptButton = $bOk
    $dlg.CancelButton = $bCancel

    # writes the dialog back into $script:Config.Notify
    $apply = {
        $n.OnDown       = [bool]$gDown.Checked
        $n.OnRecover    = [bool]$gUp.Checked
        $n.BatchSeconds = [int]$gBatch.Value
        $n.MaxPerHour   = [int]$gMax.Value
        $n.RepeatMin    = [int]$gRep.Value

        $n.Email.Enabled    = [bool]$mEn.Checked
        $n.Email.SmtpServer = $mSrv.Text.Trim()
        $n.Email.Port       = [int]$mPort.Value
        $n.Email.Security   = $mSecKeys[$mSec.SelectedIndex]
        $n.Email.UseSsl     = ($n.Email.Security -ne 'None')   # kept for older builds
        $n.Email.User       = $mUser.Text.Trim()
        if ($mPass.Text -ne '********') { $n.Email.PassEnc = Protect-Secret $mPass.Text }
        $n.Email.From       = $mFrom.Text.Trim()
        $n.Email.To         = $mTo.Text.Trim()

        $n.Telegram.Enabled = [bool]$tEn.Checked
        if ($tTok.Text -ne '********') { $n.Telegram.TokenEnc = Protect-Secret $tTok.Text.Trim() }
        $n.Telegram.ChatId  = $tChat.Text.Trim()

        $n.Sms.Enabled      = [bool]$sEn.Checked
        $n.Sms.Numbers      = $sNum.Text.Trim()
        $n.Sms.UrlTemplate  = $sUrl.Text.Trim()
        if ($sKey.Text -ne '********') { $n.Sms.ApiKeyEnc = Protect-Secret $sKey.Text.Trim() }
        $n.Sms.Method       = [string]$sMet.SelectedItem
        $n.Sms.BodyTemplate = $sBody.Text

        $n.Command.Enabled    = [bool]$cEn.Checked
        $n.Command.Path       = $cPath.Text.Trim()
        $n.Command.Args       = $cArgs.Text
        $n.Command.Numbers    = $cNum.Text.Trim()
        $n.Command.WorkDir    = $cDir.Text.Trim()
        $n.Command.TimeoutSec = [int]$cTmo.Value
        $n.Command.PerHost    = [bool]$cPer.Checked
        # the picker shows "HUAWEI Mobile Connect  (COM7)" - keep the name for
        # {modem} and pull the port out of it for {port}
        $mdm = $cMdm.Text.Trim()
        $n.Command.Modem = $mdm
        $mm = [regex]::Match($mdm, '(?i)\bCOM\d+\b')
        $n.Command.ModemPort = $(if ($mm.Success) { $mm.Value.ToUpper() } else { '' })

        $n.Ntfy.Enabled = [bool]$nEn.Checked
        $n.Ntfy.Server  = $nSrv.Text.Trim()
        $n.Ntfy.Topic   = $nTop.Text.Trim().Trim('/')
        if ($nTok.Text -ne '********') { $n.Ntfy.TokenEnc = Protect-Secret $nTok.Text.Trim() }
        $n.Ntfy.DownPriority = $nDp.SelectedIndex + 1
        $n.Ntfy.UpPriority   = $nUp.SelectedIndex + 1
    }

    $bTest.Add_Click({
        & $apply
        if (-not (Test-NotifyEnabled)) {
            [System.Windows.Forms.MessageBox]::Show('Enable at least one channel first.', 'Send test', 'OK', 'Information') | Out-Null
            return
        }
        # a fake event, so the test looks exactly like a real alert - including
        # the emoji, which is the bit worth proving on a new machine
        $fake = @([pscustomobject]@{
            Kind = 'DOWN'; Label = 'TEST-HOST'; Target = '0.0.0.0'; Time = Get-Date; DownFor = ''
        })
        Send-Notification -Subject ('[TEST] GCL Ping Monitor - {0}' -f $script:MonitorName) `
            -BodyLong  (Format-NotifyBody $fake) `
            -BodyShort ('[{0}] GCL Ping Monitor test message' -f $env:COMPUTERNAME) `
            -Events @(@{ Kind = 'DOWN'; Label = 'TEST-HOST'; Target = '0.0.0.0' })
        Write-Event 'NOTIFY    : test message queued'
        [System.Windows.Forms.MessageBox]::Show("Test sent. Watch the log panel for 'NOTIFY : ... sent' or an error.", 'Send test', 'OK', 'Information') | Out-Null
    })

    if ($dlg.ShowDialog($form) -eq 'OK') {
        & $apply
        Save-Config
        $script:notifyTimer.Interval = [Math]::Max([int]$n.BatchSeconds, 5) * 1000
        $on = @()
        if ($n.Email.Enabled)    { $on += 'email' }
        if ($n.Telegram.Enabled) { $on += 'telegram' }
        if ($n.Sms.Enabled)      { $on += 'sms' }
        if ($n.Command.Enabled)  { $on += 'command' }
        if ($n.Ntfy.Enabled)     { $on += 'ntfy' }
        Write-Event ('NOTIFY    : settings saved - channels: {0}' -f $(if ($on.Count) { $on -join ', ' } else { 'none' }))
    }
    $dlg.Dispose()
})

# ---- Monitor server (viewer mode) -------------------------------------------
#  Hand the pinging and the alerting to the Linux server, and keep this window
#  for the thing a server in a rack cannot do: make a noise in the office.
$miRemote.Add_Click({
    $r = $script:Config.Remote
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Monitor server - let a server do the watching'
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 56), [int]($s * 33))

    $y = [int]($s * 1.2)

    $lblWhy = New-Object System.Windows.Forms.Label
    $lblWhy.Text = ('A monitor that only runs while this PC is on is not a monitor.' + [Environment]::NewLine +
                    'With this on, the server does the pinging and sends the alerts.' + [Environment]::NewLine +
                    'This window becomes the screen and the alarm - which is the part' + [Environment]::NewLine +
                    'a server in a rack cannot do.')
    $lblWhy.AutoSize = $true
    $lblWhy.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
    $lblWhy.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($lblWhy)
    $y += [int]($s * 6.4)

    $chkOn = New-Object System.Windows.Forms.CheckBox
    $chkOn.Text = 'Viewer mode - show the server instead of pinging from here'
    $chkOn.AutoSize = $true
    $chkOn.Checked = [bool]$r.Enabled
    $chkOn.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($chkOn)
    $y += [int]($s * 3.0)

    $lblU = New-Object System.Windows.Forms.Label
    $lblU.Text = 'Server'; $lblU.AutoSize = $true
    $lblU.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($y + $s*0.4))
    $txtU = New-Object System.Windows.Forms.TextBox
    $txtU.Text = [string]$r.Url
    $txtU.Width = [int]($s * 42)
    $txtU.Location = New-Object System.Drawing.Point([int]($s*8), [int]$y)
    $dlg.Controls.AddRange(@($lblU, $txtU))
    $y += [int]($s * 2.9)

    $lblT = New-Object System.Windows.Forms.Label
    $lblT.Text = 'Token'; $lblT.AutoSize = $true
    $lblT.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($y + $s*0.4))
    $txtT = New-Object System.Windows.Forms.TextBox
    $txtT.UseSystemPasswordChar = $true
    $txtT.Text = Get-RemoteToken
    $txtT.Width = [int]($s * 42)
    $txtT.Location = New-Object System.Drawing.Point([int]($s*8), [int]$y)
    $dlg.Controls.AddRange(@($lblT, $txtT))
    $y += [int]($s * 2.5)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = 'The t=... value from the dashboard link. Stored encrypted, like every other secret here.'
    $lblHint.AutoSize = $true
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(120,120,120)
    $lblHint.Location = New-Object System.Drawing.Point([int]($s*8), [int]$y)
    $dlg.Controls.Add($lblHint)
    $y += [int]($s * 3.0)

    $lblRes = New-Object System.Windows.Forms.Label
    $lblRes.AutoSize = $true
    $lblRes.MaximumSize = New-Object System.Drawing.Size([int]($s*52), 0)
    $lblRes.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($lblRes)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = 'Test'
    $btnTest.Width = [int]($s * 7)
    $btnTest.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($dlg.ClientSize.Height - $s*3.2))
    # A synchronous call is right HERE and nowhere else: the person just pressed
    # Test and is waiting for an answer, and the timeout is short.
    $btnTest.Add_Click({
        $lblRes.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
        $lblRes.Text = 'Asking...'
        $dlg.Refresh()
        $u = ([string]$txtU.Text).Trim().TrimEnd('/')
        if (-not $u) { $lblRes.Text = 'Fill in the server address first.'; return }
        try {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch { }
            $resp = Invoke-RestMethod -Uri ($u + '/api/status') -Headers @{ 'X-Token' = [string]$txtT.Text } -TimeoutSec 8
            $n = @($resp.hosts).Count
            $lblRes.ForeColor = [System.Drawing.Color]::FromArgb(20,120,50)
            $lblRes.Text = ('OK - {0}, {1} host(s), {2} down' -f $resp.monitor, $n, $resp.counts.down)
        } catch {
            $lblRes.ForeColor = [System.Drawing.Color]::FromArgb(180,30,30)
            $m = $_.Exception.Message
            # 401 is by far the most common one and the message alone does not
            # say which of the two fields is wrong
            if ($m -match '401|Unauthorized') { $m = 'The server refused the token (401). Check the Token field.' }
            $lblRes.Text = $m
        }
    })
    $dlg.Controls.Add($btnTest)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = 'Save'; $btnOk.DialogResult = 'OK'
    $btnOk.Width = [int]($s * 7)
    $btnOk.Location = New-Object System.Drawing.Point([int]($dlg.ClientSize.Width - $s*15.5), [int]($dlg.ClientSize.Height - $s*3.2))
    $btnNo = New-Object System.Windows.Forms.Button
    $btnNo.Text = 'Cancel'; $btnNo.DialogResult = 'Cancel'
    $btnNo.Width = [int]($s * 7)
    $btnNo.Location = New-Object System.Drawing.Point([int]($dlg.ClientSize.Width - $s*8), [int]($dlg.ClientSize.Height - $s*3.2))
    $dlg.Controls.AddRange(@($btnOk, $btnNo))
    $dlg.AcceptButton = $btnOk; $dlg.CancelButton = $btnNo

    if ($dlg.ShowDialog($form) -ne 'OK') { $dlg.Dispose(); return }

    $was = Test-RemoteMode
    $r.Url      = ([string]$txtU.Text).Trim().TrimEnd('/')
    $r.TokenEnc = Protect-Secret ([string]$txtT.Text)
    $r.Enabled  = [bool]$chkOn.Checked
    $dlg.Dispose()
    Save-Config
    $now = Test-RemoteMode

    if ($was -ne $now) {
        # a mode change means the host list on screen belongs to somebody else
        # now, so start from the right source rather than blending the two
        $script:RemoteFails = 0
        $script:RemoteTask  = $null
        $script:Hosts.Clear()
        if (-not $now) {
            foreach ($c in @($script:Config.Hosts)) {
                if ($c -and $c.Target) {
                    $en = Get-SavedFlag $c 'Enabled'
                    $h  = New-HostState -Label ([string]$c.Label) -Target ([string]$c.Target) -Enabled $en `
                                        -AlarmEnabled (Get-SavedFlag $c 'Alarm')
                    if (-not $en) { $h.Status = 'OFF' }
                    $script:Hosts.Add($h)
                }
            }
            Write-Event 'REMOTE    : viewer mode off - pinging from this PC again'
        } else {
            Write-Event ('REMOTE    : viewer mode on - watching {0}' -f $r.Url)
            Write-Event 'REMOTE    : this PC stops pinging and stops sending alerts; the server does both'
        }
        Rebuild-Grid; Update-Alarm; Refresh-Banner; Refresh-Status
        Start-CheckCycle
    }
})

# ---- Web dashboard settings -------------------------------------------------
$miWeb.Add_Click({
    $w = $script:Config.Web
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Web dashboard - see the monitor in a browser or on your phone'
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 54), [int]($s * 40))

    $y = [int]($s * 1.2)

    $chkOn = New-Object System.Windows.Forms.CheckBox
    $chkOn.Text = 'Serve the dashboard over HTTP'; $chkOn.AutoSize = $true
    $chkOn.Checked = [bool]$w.Enabled
    $chkOn.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($chkOn)
    $y += [int]($s * 2.9)

    $lblP = New-Object System.Windows.Forms.Label
    $lblP.Text = 'Port'; $lblP.AutoSize = $true
    $lblP.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($y + $s*0.4))
    $numP = New-Object System.Windows.Forms.NumericUpDown
    $numP.Minimum = 1; $numP.Maximum = 65535
    $numP.Value = [Math]::Min([Math]::Max([int]$w.Port, 1), 65535)
    $numP.Width = [int]($s * 8)
    $numP.Location = New-Object System.Drawing.Point([int]($s*13), [int]$y)
    $dlg.Controls.AddRange(@($lblP, $numP))
    $y += [int]($s * 2.9)

    $lblB = New-Object System.Windows.Forms.Label
    $lblB.Text = 'Reachable from'; $lblB.AutoSize = $true
    $lblB.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]($y + $s*0.4))
    $cboB = New-Object System.Windows.Forms.ComboBox
    $cboB.DropDownStyle = 'DropDownList'
    [void]$cboB.Items.AddRange(@(
        'Any PC or phone on the network',
        'This PC only  (localhost)'))
    $cboB.SelectedIndex = $(if ([string]$w.Bind -eq 'local') { 1 } else { 0 })
    $cboB.Width = [int]($s * 30)
    $cboB.Location = New-Object System.Drawing.Point([int]($s*13), [int]$y)
    $dlg.Controls.AddRange(@($lblB, $cboB))
    $y += [int]($s * 2.9)

    $chkAck = New-Object System.Windows.Forms.CheckBox
    $chkAck.Text = 'Allow Acknowledge from the browser'; $chkAck.AutoSize = $true
    $chkAck.Checked = [bool]$w.AllowAck
    $chkAck.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($chkAck)
    $y += [int]($s * 3.0)

    # The URL, ready to be copied into a bookmark or sent to a phone. Selectable
    # rather than a Label on purpose - the token is 20 characters nobody wants to
    # retype off a screen.
    $lblU = New-Object System.Windows.Forms.Label
    $lblU.Text = 'Open this on the other device:'; $lblU.AutoSize = $true
    $lblU.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($lblU)
    $y += [int]($s * 1.9)

    $txtU = New-Object System.Windows.Forms.TextBox
    $txtU.Multiline = $true; $txtU.ReadOnly = $true; $txtU.ScrollBars = 'Vertical'
    $txtU.Width = [int]($s * 50); $txtU.Height = [int]($s * 5.5)
    $txtU.BackColor = [System.Drawing.Color]::FromArgb(246,247,249)
    $refreshUrls = {
        # show what the CURRENT boxes would produce, not what is saved
        $port = [int]$numP.Value
        $tok  = Get-WebToken
        $u = @()
        if ($cboB.SelectedIndex -eq 1) {
            $u += ('http://localhost:{0}/?t={1}' -f $port, $tok)
        } else {
            if ($script:MonitorIp) { $u += ('http://{0}:{1}/?t={2}' -f $script:MonitorIp, $port, $tok) }
            $u += ('http://{0}:{1}/?t={2}' -f $script:MonitorName.ToLower(), $port, $tok)
        }
        $txtU.Text = ($u -join [Environment]::NewLine)
    }
    & $refreshUrls
    $numP.Add_ValueChanged($refreshUrls)
    $cboB.Add_SelectedIndexChanged($refreshUrls)
    $txtU.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($txtU)
    $y += [int]($s * 6.4)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = 'Copy link'; $btnCopy.AutoSize = $true
    $btnCopy.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $btnCopy.Add_Click({
        try {
            $first = @($txtU.Lines | Where-Object { $_ })[0]
            [System.Windows.Forms.Clipboard]::SetText([string]$first)
            Write-Event 'WEB       : dashboard link copied to the clipboard'
        } catch { }
    })
    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = 'Open in browser'; $btnOpen.AutoSize = $true
    $btnOpen.Location = New-Object System.Drawing.Point([int]($s*10), [int]$y)
    $btnOpen.Add_Click({
        $first = @($txtU.Lines | Where-Object { $_ })[0]
        if ($first) { try { Start-Process $first } catch { } }
    })
    $btnAcl = New-Object System.Windows.Forms.Button
    $btnAcl.Text = 'Allow access from other PCs...'; $btnAcl.AutoSize = $true
    $btnAcl.Location = New-Object System.Drawing.Point([int]($s*24), [int]$y)
    $btnAcl.Add_Click({
        if (-not (Add-WebUrlAcl)) {
            Show-Info "Nothing was changed - the administrator prompt was refused, or netsh failed.`r`n`r`nThe dashboard still works on this PC (localhost)." 'Web dashboard'
            return
        }
        # Rebind immediately. This used to say "turn it off and on again", which
        # is three more clicks to do something the tool can obviously do itself.
        if ($chkOn.Checked) {
            $script:Config.Web.Port = [int]$numP.Value
            $script:Config.Web.Bind = 'any'
            $cboB.SelectedIndex = 0
            Stop-WebServer
            Start-WebServer
            & $refreshUrls
        }
        if ($script:Web.Running -and -not $script:Web.LocalOnly) {
            Show-Info ("Done - the dashboard is now reachable from other devices at:`r`n`r`n{0}" -f (@(Get-WebUrls)[0])) 'Web dashboard'
        } else {
            Show-Info "Permission granted. Tick 'Serve the dashboard over HTTP' and Save to start it." 'Web dashboard'
        }
    })
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = 'New token'; $btnNew.AutoSize = $true
    $btnNew.Location = New-Object System.Drawing.Point([int]($s*44), [int]$y)
    $btnNew.Add_Click({
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Generate a new access token?`r`n`r`nEvery bookmark and every phone using the old link will stop working and has to be given the new one.",
            'New token', 'YesNo', 'Warning', 'Button2')
        if ($ans -eq 'Yes') { [void](Reset-WebToken); & $refreshUrls }
    })
    $dlg.Controls.AddRange(@($btnCopy, $btnOpen, $btnAcl, $btnNew))
    $y += [int]($s * 3.2)

    $info = New-Object System.Windows.Forms.Label
    $info.Text =
        "The page shows the same hosts, the same red banner and the same" + [Environment]::NewLine +
        "Acknowledge button. On a phone: open the link, then browser menu ->" + [Environment]::NewLine +
        """Add to Home screen"" to get an app icon." + [Environment]::NewLine + [Environment]::NewLine +
        "The browser can only make a sound while the page is OPEN - tap the" + [Environment]::NewLine +
        "Sound button once to allow it. For an alarm that wakes a locked phone," + [Environment]::NewLine +
        "use Settings -> Notifications -> Phone (ntfy)." + [Environment]::NewLine + [Environment]::NewLine +
        "Anyone with the link can read your monitoring. Keep it inside the" + [Environment]::NewLine +
        "office network - do not forward this port to the internet."
    $info.AutoSize = $true
    $info.ForeColor = [System.Drawing.Color]::FromArgb(90,94,100)
    $info.Location = New-Object System.Drawing.Point([int]($s*1.0), [int]$y)
    $dlg.Controls.Add($info)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '&Save'; $ok.DialogResult = 'OK'; $ok.AutoSize = $true
    $ok.Location = New-Object System.Drawing.Point([int]($s*38), [int]($s*36.5))
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.DialogResult = 'Cancel'; $cancel.AutoSize = $true
    $cancel.Location = New-Object System.Drawing.Point([int]($s*45), [int]($s*36.5))
    $dlg.Controls.AddRange(@($ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $w.Enabled  = [bool]$chkOn.Checked
        $w.Port     = [int]$numP.Value
        $w.Bind     = $(if ($cboB.SelectedIndex -eq 1) { 'local' } else { 'any' })
        $w.AllowAck = [bool]$chkAck.Checked
        Save-Config
        # restart rather than reconfigure: the port and the binding are fixed at
        # Start() and there is no way to change them on a live HttpListener
        Stop-WebServer
        if ($w.Enabled) { Start-WebServer } else { Write-Event 'WEB       : dashboard turned off' }
    }
    $dlg.Dispose()
})
$mFile.Add_DropDownOpening({
    $t = Get-TickCount
    $n = if ($t -gt 0) { $t } else { @(Get-SelectedHosts).Count }
    $what = if ($t -gt 0) { "$t ticked" } else { "$n selected" }
    $miEnable.Text  = "E&nable  ($what)"
    $miDisable.Text = "&Disable  ($what)"
    $miAlarmOn.Text = "Sound &ON  ($what)"
    $miAlarmOf.Text = "Sound O&FF - silent  ($what)"
    $miAckSel.Text  = "Ac&knowledge  ($what)"
    $miResetSt.Text = "Reset &statistics  ($what)"
    $miCopySel.Text = "&Copy to clipboard  ($what)"
    $miRemove.Text  = "&Remove  ($what)"
    $miTickNon.Enabled = ($t -gt 0)
    $miTickInv.Enabled = ($script:Hosts.Count -gt 0)
})

# ---- Tick box + alarm box in the grid ----------------------------------------
# The grid is read-only, so the check boxes are drawn but not interactive - the
# click is handled here instead. CellMouseUp with an explicit left-button test:
# CellClick would also fire on the right-click that opens the context menu, and
# CellContentClick only counts a hit on the ~13px box itself, which is a mean
# target. Anywhere in the cell works.
$grid.Add_CellMouseUp({
    if ($_.RowIndex -lt 0 -or $_.ColumnIndex -lt 0) { return }
    if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    $col = $grid.Columns[$_.ColumnIndex].Name
    if ($col -ne 'cSel' -and $col -ne 'cAlarm') { return }
    $h = $grid.Rows[$_.RowIndex].Tag
    if (-not $h) { return }
    if ($col -eq 'cSel') {
        $h.Sel = -not $h.Sel
        $grid.Rows[$_.RowIndex].Cells['cSel'].Value = [bool]$h.Sel
        Update-SelHeader
        Refresh-Status
    } else {
        Toggle-HostAlarmRow $h
    }
})

# An empty header over a column of tick boxes tells nobody what it is for, so
# the header gets a check box of its own - the one control everybody already
# knows means "all of them". It shows the current state: ticked when everything
# on screen is ticked. A text label would not fit the column width.
$grid.Add_CellPainting({
    if ($_.RowIndex -ne -1 -or $_.ColumnIndex -lt 0) { return }
    if ($grid.Columns[$_.ColumnIndex].Name -ne 'cSel') { return }
    $_.PaintBackground($_.CellBounds, $false)
    $shown = @($script:Visible)
    $all   = ($shown.Count -gt 0) -and (@($shown | Where-Object { -not $_.Sel }).Count -eq 0)
    $side  = [int][Math]::Max(13, $script:TextSize * 1.1)
    $x = $_.CellBounds.X + [int](($_.CellBounds.Width  - $side) / 2)
    $y = $_.CellBounds.Y + [int](($_.CellBounds.Height - $side) / 2)
    try {
        # themed first, classic if visual styles are off (Server Core-ish boxes)
        $st = if ($all) { [System.Windows.Forms.VisualStyles.CheckBoxState]::CheckedNormal }
              else      { [System.Windows.Forms.VisualStyles.CheckBoxState]::UncheckedNormal }
        [System.Windows.Forms.CheckBoxRenderer]::DrawCheckBox($_.Graphics,
            (New-Object System.Drawing.Point($x, $y)), $st)
    } catch {
        $bs = if ($all) { [System.Windows.Forms.ButtonState]::Checked } else { [System.Windows.Forms.ButtonState]::Normal }
        [System.Windows.Forms.ControlPaint]::DrawCheckBox($_.Graphics, $x, $y, $side, $side, $bs)
    }
    $_.Handled = $true
})

# Header of the tick column = tick / untick everything that is showing
$grid.Add_ColumnHeaderMouseClick({
    if ($_.ColumnIndex -lt 0) { return }
    if ($_.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    if ($grid.Columns[$_.ColumnIndex].Name -ne 'cSel') { return }
    $shown = @($script:Visible)
    $allOn = ($shown.Count -gt 0) -and (@($shown | Where-Object { -not $_.Sel }).Count -eq 0)
    Set-AllTicks (-not $allOn)
})

$grid.Add_CellDoubleClick({
    if ($_.RowIndex -lt 0) { return }
    # a double click on a check box is two toggles, not a request to edit
    if ($_.ColumnIndex -ge 0 -and $grid.Columns[$_.ColumnIndex].Name -in 'cSel','cAlarm') { return }
    Edit-SelectedHost
})

# ---- Search ------------------------------------------------------------------
$txtSearch.Add_TextChanged({ Refresh-Grid; Refresh-Status })
$txtSearch.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $_.SuppressKeyPress = $true; $txtSearch.Clear() } })
$btnClearSearch.Add_Click({ $txtSearch.Clear(); $txtSearch.Focus() })

$btnAck.Add_Click({ Confirm-Alarm })
$btnPause.Add_Click({ Toggle-Pause })

# ---- Bulk select toolbar button ----------------------------------------------
$tbTickAll.Add_Click({ Set-AllTicks $true })
$tbTickNon.Add_Click({ Set-AllTicks $false })
$tbTickInv.Add_Click({ Invert-Ticks })
$tbEnable.Add_Click({ Set-HostsEnabled $true })
$tbDisable.Add_Click({ Set-HostsEnabled $false })
$tbAlarmOn.Add_Click({ Set-HostsAlarm $true })
$tbAlarmOf.Add_Click({ Set-HostsAlarm $false })
$tbAck.Add_Click({ Confirm-AlarmSelected })
$tbReset.Add_Click({ Reset-SelectedStats })
$tbCopy.Add_Click({ Copy-SelectedHosts })
$tbRemove.Add_Click({ Remove-SelectedHosts })

$btnBulk.Add_DropDownOpening({
    $t = Get-TickCount
    $n = if ($t -gt 0) { $t } else { @(Get-SelectedHosts).Count }
    $what = if ($t -gt 0) { "$t ticked" } else { "$n selected" }
    $tbEnable.Text  = "E&nable  ($what)"
    $tbDisable.Text = "&Disable  ($what)"
    $tbAlarmOn.Text = "Sound &ON  ($what)"
    $tbAlarmOf.Text = "Sound O&FF - silent  ($what)"
    $tbAck.Text     = "Ac&knowledge  ($what)"
    $tbReset.Text   = "Reset &statistics  ($what)"
    $tbCopy.Text    = "&Copy to clipboard  ($what)"
    $tbRemove.Text  = "&Remove  ($what)"
    $tbTickNon.Enabled = ($t -gt 0)
})

function Test-AlarmSound {
    Play-Alarm -Force
    $src = if ($script:Player) { Split-Path $script:AlarmWavPath -Leaf } else { 'system sound (Windows sounds may be off!)' }
    Write-Event ("TEST      : played alarm - source: {0}" -f $src)
}

# ---- Alarm sound picker ------------------------------------------------------
# The preview helpers live at SCRIPT scope, not nested inside the dialog
# function: a function defined inside another function is not reliably
# resolvable from a WinForms event handler, which fires from the message loop.
$script:PreviewPlayer = $null
$script:SndItems      = $null
$script:SndList       = $null

function Stop-SoundPreview {
    try { if ($script:PreviewPlayer) { $script:PreviewPlayer.Stop(); $script:PreviewPlayer.Dispose() } } catch { }
    $script:PreviewPlayer = $null
}

function Play-SoundPreview {
    if (-not $script:SndList -or $script:SndList.SelectedIndex -lt 0) { return }
    $sel  = $script:SndItems[$script:SndList.SelectedIndex]
    $path = if ($sel.Key -eq 'custom') { $sel.File } else { Get-BuiltInSoundPath $sel.Key }
    Stop-SoundPreview
    try {
        if ($path -and (Test-Path $path)) {
            $script:PreviewPlayer = New-Object System.Media.SoundPlayer $path
            $script:PreviewPlayer.Load()
            $script:PreviewPlayer.Play()
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            ("That file could not be played:`r`n{0}`r`n`r`nIt must be an uncompressed .wav (PCM) - mp3 will not work." -f $_.Exception.Message),
            'Alarm sound', 'OK', 'Warning') | Out-Null
    }
}

function Sync-SoundList {
    $script:SndList.Items.Clear()
    foreach ($it in $script:SndItems) { [void]$script:SndList.Items.Add($it.Text) }
}

# ---- recovery-sound picker (same script-scope rule as above) ----
$script:SndUpCombo = $null
$script:SndUpFile  = ''
function Get-UpPickPath {
    # the last combo entry is "Use my own .wav..."
    if (-not $script:SndUpCombo) { return '' }
    $i = $script:SndUpCombo.SelectedIndex
    if ($i -lt 0) { return '' }
    if ($i -ge $script:SoundDefs.Count) { return [string]$script:SndUpFile }
    Get-BuiltInSoundPath $script:SoundDefs[$i].Key
}
function Play-UpPreview {
    $p = Get-UpPickPath
    Stop-SoundPreview
    try {
        if ($p -and (Test-Path $p)) {
            $script:PreviewPlayer = New-Object System.Media.SoundPlayer $p
            $script:PreviewPlayer.Load()
            $script:PreviewPlayer.Play()
        }
    } catch { }
}

function Show-AlarmSoundDialog {
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Alarm sound'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 38), [int]($s * 38))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Sound played while a host is DOWN:'
    $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 0.9))
    $dlg.Controls.Add($lbl)

    # one flat list: built-in tones, then whatever Windows ships in \Media, then
    # any custom .wav already chosen. Tag-free - a parallel array holds the data.
    $items = New-Object System.Collections.ArrayList
    foreach ($d in $script:SoundDefs) {
        [void]$items.Add([pscustomobject]@{ Text = $d.Name; Key = $d.Key; File = '' })
    }
    try {
        Get-ChildItem (Join-Path $env:WINDIR 'Media') -Filter '*.wav' -ErrorAction Stop |
            Sort-Object Name | ForEach-Object {
                [void]$items.Add([pscustomobject]@{
                    Text = ('Windows:  {0}' -f $_.BaseName); Key = 'custom'; File = $_.FullName })
            }
    } catch { }

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 2.6))
    $list.Size = New-Object System.Drawing.Size([int]($s * 35.6), [int]($s * 14))
    $list.IntegralHeight = $false
    $dlg.Controls.Add($list)

    # a custom file that is not one of the Windows ones gets its own row
    $cf = [string]$script:Config.AlarmFile
    if ([string]$script:Config.AlarmSound -eq 'custom' -and $cf) {
        $known = @($items | Where-Object { $_.File -eq $cf })
        if ($known.Count -eq 0) {
            [void]$items.Add([pscustomobject]@{ Text = ('My file:  {0}' -f (Split-Path $cf -Leaf)); Key = 'custom'; File = $cf })
        }
    }

    $script:SndItems = $items
    $script:SndList  = $list
    Sync-SoundList

    # select whatever is configured right now
    $curKey  = [string]$script:Config.AlarmSound
    $curFile = [string]$script:Config.AlarmFile
    $list.SelectedIndex = 0
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($curKey -eq 'custom') {
            if ($items[$i].Key -eq 'custom' -and $items[$i].File -eq $curFile) { $list.SelectedIndex = $i; break }
        } elseif ($items[$i].Key -eq $curKey) { $list.SelectedIndex = $i; break }
    }

    $btnPlay = New-Object System.Windows.Forms.Button
    $btnPlay.Text = 'Play'
    $btnPlay.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 17.2))
    $btnPlay.Size = New-Object System.Drawing.Size([int]($s * 6.5), [int]($s * 2.6))
    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = 'Stop'
    $btnStop.Location = New-Object System.Drawing.Point([int]($s * 8.2), [int]($s * 17.2))
    $btnStop.Size = New-Object System.Drawing.Size([int]($s * 6.5), [int]($s * 2.6))
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Use my own .wav...'
    $btnBrowse.Location = New-Object System.Drawing.Point([int]($s * 15.2), [int]($s * 17.2))
    $btnBrowse.Size = New-Object System.Drawing.Size([int]($s * 21.6), [int]($s * 2.6))
    $dlg.Controls.AddRange(@($btnPlay, $btnStop, $btnBrowse))

    $lblRep = New-Object System.Windows.Forms.Label
    $lblRep.Text = 'Repeat every'
    $lblRep.AutoSize = $true
    $lblRep.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 20.9))
    $nRep = New-Object System.Windows.Forms.NumericUpDown
    $nRep.DecimalPlaces = 1; $nRep.Increment = 0.5
    $nRep.Minimum = 0.5; $nRep.Maximum = 60
    $nRep.Location = New-Object System.Drawing.Point([int]($s * 12), [int]($s * 20.5))
    $nRep.Width = [int]($s * 5)
    $repSec = [Math]::Round(([double][int]$script:Config.AlarmRepeatMs) / 1000.0, 1)
    if ($repSec -lt 0.5) { $repSec = 1.4 }; if ($repSec -gt 60) { $repSec = 60 }
    $nRep.Value = [decimal]$repSec
    $lblRep2 = New-Object System.Windows.Forms.Label
    $lblRep2.Text = 'seconds'
    $lblRep2.AutoSize = $true
    $lblRep2.ForeColor = [System.Drawing.Color]::FromArgb(110, 114, 120)
    $lblRep2.Location = New-Object System.Drawing.Point([int]($s * 17.6), [int]($s * 20.9))
    $dlg.Controls.AddRange(@($lblRep, $nRep, $lblRep2))

    # auto-silence
    $lblStop = New-Object System.Windows.Forms.Label
    $lblStop.Text = 'Stop sound after'
    $lblStop.AutoSize = $true
    $lblStop.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 23.7))
    $nStop = New-Object System.Windows.Forms.NumericUpDown
    $nStop.Minimum = 0; $nStop.Maximum = 240
    $nStop.Location = New-Object System.Drawing.Point([int]($s * 12), [int]($s * 23.3))
    $nStop.Width = [int]($s * 5)
    $nStop.Value = [Math]::Min([Math]::Max([int]$script:Config.AlarmAutoStopMin, 0), 240)
    $lblStop2 = New-Object System.Windows.Forms.Label
    $lblStop2.Text = "minutes if nobody acknowledges" + [Environment]::NewLine +
                     "(0 = never stop.  Row stays red)"
    $lblStop2.AutoSize = $true
    $lblStop2.ForeColor = [System.Drawing.Color]::FromArgb(110, 114, 120)
    $lblStop2.Location = New-Object System.Drawing.Point([int]($s * 17.6), [int]($s * 23.4))
    $dlg.Controls.AddRange(@($lblStop, $nStop, $lblStop2))

    # ---- recovery sound ----
    $lblUp = New-Object System.Windows.Forms.Label
    $lblUp.Text = 'When a host comes back UP:'
    $lblUp.AutoSize = $true
    $lblUp.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 27.2))
    $dlg.Controls.Add($lblUp)

    $chkUp = New-Object System.Windows.Forms.CheckBox
    $chkUp.Text = 'Play a recovery sound'
    $chkUp.AutoSize = $true
    $chkUp.Checked = [bool]$script:Config.UpSoundEnabled
    $chkUp.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 29.2))
    $dlg.Controls.Add($chkUp)

    $cboUp = New-Object System.Windows.Forms.ComboBox
    $cboUp.DropDownStyle = 'DropDownList'
    $cboUp.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 31.4))
    $cboUp.Width = [int]($s * 21)
    foreach ($d in $script:SoundDefs) { [void]$cboUp.Items.Add($d.Name) }
    [void]$cboUp.Items.Add('Use my own .wav...')
    $upIx = 0
    for ($i = 0; $i -lt $script:SoundDefs.Count; $i++) {
        if ($script:SoundDefs[$i].Key -eq [string]$script:Config.UpSound) { $upIx = $i; break }
    }
    if ([string]$script:Config.UpSound -eq 'custom') { $upIx = $cboUp.Items.Count - 1 }
    $cboUp.SelectedIndex = $upIx
    $dlg.Controls.Add($cboUp)

    $btnUpPlay = New-Object System.Windows.Forms.Button
    $btnUpPlay.Text = 'Play'
    $btnUpPlay.Location = New-Object System.Drawing.Point([int]($s * 23), [int]($s * 31.2))
    $btnUpPlay.Size = New-Object System.Drawing.Size([int]($s * 6.5), [int]($s * 2.4))
    $dlg.Controls.Add($btnUpPlay)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '&Save'; $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point([int]($s * 21.2), [int]($s * 34.6))
    $ok.Size = New-Object System.Drawing.Size([int]($s * 7.5), [int]($s * 2.6))
    $cn = New-Object System.Windows.Forms.Button
    $cn.Text = 'Cancel'; $cn.DialogResult = 'Cancel'
    $cn.Location = New-Object System.Drawing.Point([int]($s * 29.2), [int]($s * 34.6))
    $cn.Size = New-Object System.Drawing.Size([int]($s * 7.5), [int]($s * 2.6))
    $dlg.Controls.AddRange(@($ok, $cn))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cn

    $script:SndUpCombo = $cboUp
    $script:SndUpFile  = [string]$script:Config.UpSoundFile
    $btnUpPlay.Add_Click({ Play-UpPreview })
    $cboUp.Add_SelectedIndexChanged({
        if ($script:SndUpCombo.SelectedIndex -lt $script:SoundDefs.Count) { return }
        $of = New-Object System.Windows.Forms.OpenFileDialog
        $of.Title  = 'Choose the recovery sound'
        $of.Filter = 'Wave sound (*.wav)|*.wav|All files (*.*)|*.*'
        $of.InitialDirectory = (Join-Path $env:WINDIR 'Media')
        if ($of.ShowDialog($script:SndUpCombo.FindForm()) -eq 'OK') {
            $script:SndUpFile = $of.FileName
            Play-UpPreview
        } elseif (-not $script:SndUpFile) {
            $script:SndUpCombo.SelectedIndex = 0     # nothing picked - fall back
        }
    })

    $btnPlay.Add_Click({ Play-SoundPreview })
    $btnStop.Add_Click({ Stop-SoundPreview })
    $list.Add_DoubleClick({ Play-SoundPreview })
    # everything this handler touches is script-scope on purpose - see the note
    # above Stop-SoundPreview
    $btnBrowse.Add_Click({
        $of = New-Object System.Windows.Forms.OpenFileDialog
        $of.Title  = 'Choose an alarm sound'
        $of.Filter = 'Wave sound (*.wav)|*.wav|All files (*.*)|*.*'
        $of.InitialDirectory = (Join-Path $env:WINDIR 'Media')
        if ($of.ShowDialog($script:SndList.FindForm()) -ne 'OK') { return }
        $f = $of.FileName
        $hit = -1
        for ($i = 0; $i -lt $script:SndItems.Count; $i++) {
            if ($script:SndItems[$i].File -eq $f) { $hit = $i; break }
        }
        if ($hit -lt 0) {
            [void]$script:SndItems.Add([pscustomobject]@{
                Text = ('My file:  {0}' -f (Split-Path $f -Leaf)); Key = 'custom'; File = $f })
            Sync-SoundList
            $hit = $script:SndItems.Count - 1
        }
        $script:SndList.SelectedIndex = $hit
        Play-SoundPreview
    })

    $res = $dlg.ShowDialog($form)
    Stop-SoundPreview
    $items = $script:SndItems          # the Browse button may have added a row
    if ($res -eq 'OK' -and $list.SelectedIndex -ge 0) {
        $sel = $items[$list.SelectedIndex]
        $script:Config.AlarmSound     = $sel.Key
        $script:Config.AlarmFile      = [string]$sel.File
        $script:Config.AlarmRepeatMs  = [int]([double]$nRep.Value * 1000)
        $script:Config.AlarmAutoStopMin = [int]$nStop.Value

        $upIdx = $cboUp.SelectedIndex
        $script:Config.UpSoundEnabled = [bool]$chkUp.Checked
        if ($upIdx -ge $script:SoundDefs.Count) {
            $script:Config.UpSound     = 'custom'
            $script:Config.UpSoundFile = [string]$script:SndUpFile
        } else {
            $script:Config.UpSound     = $script:SoundDefs[$upIdx].Key
            $script:Config.UpSoundFile = ''
        }
        Set-UpPlayer (Resolve-UpSound)

        # a live alarm must not be left playing the old sound
        $wasOn = $script:AlarmActive -and -not $script:AlarmMuted
        Stop-Alarm
        Set-AlarmPlayer (Resolve-AlarmSound)
        $script:AlarmTimer.Interval = [Math]::Max([int]$script:Config.AlarmRepeatMs, 500)
        if ($wasOn) { Play-Alarm }
        Save-Config
        Write-Event ('ALARM     : sound "{0}", repeat {1}s, auto-stop {2}, recovery sound {3}' -f `
            $sel.Text, $nRep.Value,
            $(if ([int]$nStop.Value -gt 0) { "$($nStop.Value)m" } else { 'off' }),
            $(if ($chkUp.Checked) { Split-Path $script:UpWavPath -Leaf } else { 'off' }))
    }
    $dlg.Dispose()
}

$split.Add_SplitterMoved({
    if ($split.Height -gt 0 -and $split.Panel2Collapsed -eq $false) {
        $script:Config.SplitPercent = [int](100.0 * $split.SplitterDistance / $split.Height)
        Save-Config
    }
})

# ---- Monitoring settings dialog ---------------------------------------------
function Show-MonitoringSettings {
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Monitoring settings'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 40), [int]($s * 21))

    $y = [int]($s * 1.2)
    function Row { param($text, $ctrl, $hint)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.AutoSize = $true
        $l.Location = New-Object System.Drawing.Point([int]($script:TextSize*1.2), [int]($script:dY + $script:TextSize*0.4))
        $ctrl.Location = New-Object System.Drawing.Point([int]($script:TextSize*14), [int]$script:dY)
        $ctrl.Width = [int]($script:TextSize * 8)
        $h = New-Object System.Windows.Forms.Label
        $h.Text = $hint; $h.AutoSize = $true
        $h.ForeColor = [System.Drawing.Color]::FromArgb(110,114,120)
        $h.Location = New-Object System.Drawing.Point([int]($script:TextSize*23), [int]($script:dY + $script:TextSize*0.4))
        $dlg.Controls.AddRange(@($l, $ctrl, $h))
        $script:dY += [int]($script:TextSize * 3.2)
    }
    $script:dY = $y

    $nI = New-Object System.Windows.Forms.NumericUpDown; $nI.Minimum=2; $nI.Maximum=3600
    $nI.Value = [Math]::Min([Math]::Max([int]$script:Config.IntervalSeconds,2),3600)
    Row 'Interval (sec)' $nI 'how often every host is pinged'

    $nT = New-Object System.Windows.Forms.NumericUpDown; $nT.Minimum=200; $nT.Maximum=10000; $nT.Increment=100
    $nT.Value = [Math]::Min([Math]::Max([int]$script:Config.TimeoutMs,200),10000)
    Row 'Timeout (ms)' $nT 'how long to wait for a reply'

    $nF = New-Object System.Windows.Forms.NumericUpDown; $nF.Minimum=1; $nF.Maximum=10
    $nF.Value = [Math]::Min([Math]::Max([int]$script:Config.FailThreshold,1),10)
    Row 'Fails -> DOWN' $nF 'flap guard before raising the alarm'

    $nL = New-Object System.Windows.Forms.NumericUpDown; $nL.Minimum=5; $nL.Maximum=5000; $nL.Increment=10
    $nL.Value = [Math]::Min([Math]::Max([int]$script:Config.LossWindow,5),5000)
    Row 'Loss over (pings)' $nL 'window the Loss % is measured across'

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Save'; $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point([int]($s*23), [int]($s*17.2))
    $ok.Size = New-Object System.Drawing.Size([int]($s*7.5), [int]($s*2.6))
    $cn = New-Object System.Windows.Forms.Button
    $cn.Text = 'Cancel'; $cn.DialogResult = 'Cancel'
    $cn.Location = New-Object System.Drawing.Point([int]($s*31), [int]($s*17.2))
    $cn.Size = New-Object System.Drawing.Size([int]($s*7.5), [int]($s*2.6))
    $dlg.Controls.AddRange(@($ok, $cn))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cn

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $script:Config.IntervalSeconds = [int]$nI.Value
        $script:Config.TimeoutMs       = [int]$nT.Value
        $script:Config.FailThreshold   = [int]$nF.Value
        $script:Config.LossWindow      = [int]$nL.Value
        $script:checkTimer.Interval    = [int]$nI.Value * 1000
        foreach ($h in $script:Hosts) { $h.StyleKey = '' }
        Save-Config
        Refresh-Status
        Write-Event ('MONITOR   : settings - every {0}s, timeout {1}ms, {2} fails to DOWN, loss over {3}' -f `
            $nI.Value, $nT.Value, $nF.Value, $nL.Value)
    }
    $dlg.Dispose()
}

# ---- Export / import (backup & recovery) ------------------------------------
function Export-Settings {
    Save-Config
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title    = 'Export hosts and settings'
    $dlg.Filter   = 'GCL Ping Monitor backup (*.json)|*.json|All files (*.*)|*.*'
    $dlg.FileName = 'gcl-ping-monitor-backup-{0}-{1}.json' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm')
    if ($dlg.ShowDialog($form) -ne 'OK') { return }
    try {
        $payload = [pscustomobject]@{
            _app        = 'GCL Ping Monitor'
            _exportedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            _exportedOn = $env:COMPUTERNAME
            _exportedBy = $env:USERNAME
            _note       = 'Notification passwords/tokens are DPAPI-encrypted. They restore only on the SAME Windows user and machine; on any other PC re-enter them in Notifications.'
            config      = $script:Config
        }
        $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $dlg.FileName -Encoding UTF8
        Write-Event ('BACKUP    : exported {0} host(s) to {1}' -f $script:Hosts.Count, $dlg.FileName)
        [System.Windows.Forms.MessageBox]::Show(
            ("Exported {0} host(s) and all settings to:`r`n`r`n{1}" -f $script:Hosts.Count, $dlg.FileName),
            'Export complete', 'OK', 'Information') | Out-Null
    } catch {
        Write-Event ('BACKUP err: export - {0}' -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show(("Export failed:`r`n{0}" -f $_.Exception.Message), 'Export', 'OK', 'Error') | Out-Null
    }
}

function Import-Settings {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = 'Import hosts and settings'
    $dlg.Filter = 'GCL Ping Monitor backup (*.json)|*.json|All files (*.*)|*.*'
    if ($dlg.ShowDialog($form) -ne 'OK') { return }

    try { $raw = Get-Content $dlg.FileName -Raw -ErrorAction Stop | ConvertFrom-Json }
    catch {
        [System.Windows.Forms.MessageBox]::Show(("That file is not valid JSON:`r`n{0}" -f $_.Exception.Message), 'Import', 'OK', 'Error') | Out-Null
        return
    }

    # accept both a full backup file and a bare config.json
    $cfg = if ($raw.config) { $raw.config } else { $raw }
    $incoming = @($cfg.Hosts | Where-Object { $_ -and $_.Target })
    if ($incoming.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No hosts found in that file.', 'Import', 'OK', 'Warning') | Out-Null
        return
    }

    $ans = [System.Windows.Forms.MessageBox]::Show(
        ("Found {0} host(s) in the file.`r`n`r`nYES  - replace everything (hosts AND settings)`r`nNO   - only add hosts that are not already in the list`r`nCANCEL - do nothing" -f $incoming.Count),
        'Import', 'YesNoCancel', 'Question')
    if ($ans -eq 'Cancel') { return }

    if ($ans -eq 'Yes') {
        # window size/position are deliberately NOT imported - a backup from
        # another PC would drop the window on a monitor that may not exist here
        foreach ($p in 'IntervalSeconds','TimeoutMs','FailThreshold','AlwaysOnTop','AutoUpdate','UpdateHours','TextSize','LossWindow','SplitPercent','AlarmSound','AlarmFile','AlarmRepeatMs','AlarmAutoStopMin','UpSoundEnabled','UpSound','UpSoundFile') {
            if ($null -ne $cfg.$p) { $script:Config.$p = $cfg.$p }
        }
        if ($cfg.Notify) { $script:Config.Notify = $cfg.Notify; Initialize-NotifyDefaults }
        # The web port travels, the access token deliberately does not: it is
        # DPAPI-sealed to the machine that wrote it, so importing one would leave
        # the dashboard with a token nobody here can read. A fresh one is made
        # the first time the server starts.
        if ($cfg.Web) {
            $script:Config.Web = $cfg.Web
            Initialize-WebDefaults
            $script:Config.Web.TokenEnc = ''
        }
        $script:Hosts.Clear()
        foreach ($c in $incoming) {
            $en = Get-SavedFlag $c 'Enabled'
            $h  = New-HostState -Label ([string]$c.Label) -Target ([string]$c.Target) -Enabled $en `
                                -AlarmEnabled (Get-SavedFlag $c 'Alarm')
            if (-not $en) { $h.Status = 'OFF' }
            $script:Hosts.Add($h)
        }
        $added = $incoming.Count
        $script:MnuTop.Checked        = [bool]$script:Config.AlwaysOnTop
        $script:MnuAutoUpdate.Checked = [bool]$script:Config.AutoUpdate
        $form.TopMost = [bool]$script:Config.AlwaysOnTop
        $script:checkTimer.Interval = [Math]::Max([int]$script:Config.IntervalSeconds, 2) * 1000
        $script:notifyTimer.Interval = [Math]::Max([int]$script:Config.Notify.BatchSeconds, 5) * 1000
        Stop-Alarm
        Set-AlarmPlayer (Resolve-AlarmSound)
        Set-UpPlayer (Resolve-UpSound)
        $script:AlarmTimer.Interval = [Math]::Min([Math]::Max([int]$script:Config.AlarmRepeatMs, 500), 60000)
        Apply-TextSize ([int]$script:Config.TextSize)
        Write-Event ('BACKUP    : imported {0} host(s) + settings (replaced) from {1}' -f $added, $dlg.FileName)
    }
    else {
        $added = 0
        foreach ($c in $incoming) {
            $t = [string]$c.Target
            if (@($script:Hosts | Where-Object { $_.Target -eq $t }).Count -gt 0) { continue }
            $en = Get-SavedFlag $c 'Enabled'
            $h  = New-HostState -Label ([string]$c.Label) -Target $t -Enabled $en `
                                -AlarmEnabled (Get-SavedFlag $c 'Alarm')
            if (-not $en) { $h.Status = 'OFF' }
            $script:Hosts.Add($h)
            $added++
        }
        Write-Event ('BACKUP    : imported {0} new host(s) from {1} ({2} already present)' -f $added, $dlg.FileName, ($incoming.Count - $added))
    }

    Save-Config; Rebuild-Grid; Update-Alarm; Refresh-Banner; Refresh-Status
    $script:CycleRunning = $false
    Start-CheckCycle
    [System.Windows.Forms.MessageBox]::Show(("Imported {0} host(s)." -f $added), 'Import complete', 'OK', 'Information') | Out-Null
}

# ---- About -------------------------------------------------------------------
function Show-About {
    $s = $script:TextSize
    $ver = $script:Version
    $chan = if ($script:IsGitCheckout) { 'dev checkout (auto-update off)' } else { 'auto-update from GitHub' }
    $msg = @"
GCL Ping Monitor
version  $ver

A ping monitor with an audible alarm for the support desk.

Installed  : $($script:ScriptDir)
Data       : $($script:AppDir)
Updates    : $chan
Project    : https://github.com/$($script:Repo)

PowerShell $($PSVersionTable.PSVersion)  on  $([Environment]::OSVersion.VersionString)

Built for Grameen Cybernet / WeTechi. MIT licensed.
"@
    [System.Windows.Forms.MessageBox]::Show($msg, 'About GCL Ping Monitor', 'OK', 'Information') | Out-Null
}

function Invoke-UpdateCheck {
    $miUpdate.Enabled = $false
    try {
        $r = Invoke-SelfUpdate
        $script:LastUpdateCheck = Get-Date
        if ($r) {
            $script:UpdatePending = $true
            $btnRestartNow.Visible = $true
            Write-Event 'UPDATE    : new version downloaded (manual check) - restart to apply'
            [System.Windows.Forms.MessageBox]::Show('A new version was downloaded. Click "RESTART to apply update" when ready.', 'Update ready', 'OK', 'Information') | Out-Null
        } else {
            Write-Event 'UPDATE    : already up to date'
            [System.Windows.Forms.MessageBox]::Show('Already running the latest version.', 'Up to date', 'OK', 'Information') | Out-Null
        }
    } finally { $miUpdate.Enabled = $true }
}

# ---- Menu wiring -------------------------------------------------------------
$miAdd.Add_Click({ Add-Host })
$miAddMany.Add_Click({ Add-ManyHosts })
$miEdit.Add_Click({ Edit-SelectedHost })
$miAckSel.Add_Click({ Confirm-AlarmSelected })
$miResetSt.Add_Click({ Reset-SelectedStats })
$miCopySel.Add_Click({ Copy-SelectedHosts })
$miTickAll.Add_Click({ Set-AllTicks $true })
$miTickNon.Add_Click({ Set-AllTicks $false })
$miTickInv.Add_Click({ Invert-Ticks })
$miEnable.Add_Click({ Set-HostsEnabled $true })
$miDisable.Add_Click({ Set-HostsEnabled $false })
$miAlarmOn.Add_Click({ Set-HostsAlarm $true })
$miAlarmOf.Add_Click({ Set-HostsAlarm $false })
$miRemove.Add_Click({ Remove-SelectedHosts })
$miExit.Add_Click({ $form.Close() })

foreach ($it in $script:SizeItems) {
    $it.Add_Click({
        Apply-TextSize ([int]$this.Tag)
        Save-Config; Refresh-Banner; Refresh-Status
    })
}
$miTop.Add_Click({ $form.TopMost = $miTop.Checked; Save-Config })
$miShowLog.Add_Click({
    $split.Panel2Collapsed = -not $miShowLog.Checked
    $script:LogAutoHidden = $false
    if ($miShowLog.Checked) { Apply-SplitPercent; Update-Responsive }
})
$miCompact.Add_Click({
    # snap straight to the smallest useful size for this text size
    $form.WindowState = 'Normal'
    $form.Size = New-Object System.Drawing.Size($form.MinimumSize.Width, $form.MinimumSize.Height)
    Update-Responsive; Save-Config
})
$miNormalW.Add_Click({
    $form.WindowState = 'Normal'
    $w = [int][Math]::Max($form.MinimumSize.Width,  $script:TextSize * 82)
    $h = [int][Math]::Max($form.MinimumSize.Height, $script:TextSize * 56)
    $form.Size = New-Object System.Drawing.Size($w, $h)
    Update-Responsive; Save-Config
})

$miPause.Add_Click({ Toggle-Pause })
$miTest.Add_Click({ Test-AlarmSound })
$miSound.Add_Click({ Show-AlarmSoundDialog })
$miMonSet.Add_Click({ Show-MonitoringSettings })

$miAuto.Add_Click({ Save-Config })
$miUpdate.Add_Click({ Invoke-UpdateCheck })
$miExport.Add_Click({ Export-Settings })
$miImport.Add_Click({ Import-Settings })

$miAbout.Add_Click({ Show-About })
$miFolder.Add_Click({ try { Start-Process explorer.exe $script:AppDir } catch { } })
$miRepo.Add_Click({ try { Start-Process ("https://github.com/{0}" -f $script:Repo) } catch { } })

function Restart-Self {
    try { Save-Config } catch { }
    # clear the relaunch guard so the fresh instance starts cleanly
    try { Remove-Item (Join-Path $script:AppDir '.last-relaunch') -ErrorAction SilentlyContinue } catch { }
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $script:ScriptPath)
    ) | Out-Null
    $form.Close()
}

$btnRestartNow.Add_Click({ Restart-Self })


# The page. One file, no CDN, no framework: it has to load on a phone sitting on
# an isolated management VLAN with no route to the internet, which is exactly
# when it is needed most.
$script:WebPage = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#0f1115">
<title>GCL Ping Monitor</title>
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<style>
:root{
  --bg:#0f1115; --card:#171a21; --line:#252a34; --fg:#e6e9ef; --dim:#8b93a3;
  --up:#22c55e; --down:#ef4444; --warn:#f59e0b; --off:#4b5563; --accent:#3b82f6;
}
*{box-sizing:border-box}
html,body{margin:0;padding:0}
body{
  background:var(--bg); color:var(--fg);
  font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,system-ui,sans-serif;
  padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
  -webkit-text-size-adjust:100%;
}
.wrap{max-width:1100px;margin:0 auto;padding:10px}

/* the banner is the whole point - it has to be readable across a room */
#banner{
  border-radius:12px; padding:16px 18px; margin-bottom:10px;
  font-weight:700; letter-spacing:.4px; text-align:center;
  font-size:clamp(17px,4.6vw,30px); line-height:1.25;
  background:var(--card); border:1px solid var(--line);
  transition:background .15s;
}
#banner.ok{background:#10331d;border-color:#1c5c33;color:#7ef0a6}
#banner.down{background:var(--down);border-color:#b91c1c;color:#fff}
#banner.down.flash{background:#7f1d1d}
#banner.lost{background:#3a2a08;border-color:#a16207;color:#fbbf24}
#banner small{display:block;font-size:.52em;font-weight:500;opacity:.85;margin-top:4px;letter-spacing:0}

.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-bottom:10px}
button{
  font:inherit;font-weight:600;color:var(--fg);background:var(--card);
  border:1px solid var(--line);border-radius:9px;padding:10px 14px;cursor:pointer;
  -webkit-tap-highlight-color:transparent;
}
button:active{transform:translateY(1px)}
button[disabled]{opacity:.4;cursor:default}
button.primary{background:var(--accent);border-color:var(--accent);color:#fff}
button.danger{background:var(--down);border-color:var(--down);color:#fff}
button.on{background:#14532d;border-color:#166534;color:#86efac}
/* A browser will not make a noise until the page has been tapped once, so a
   phone can sit there showing a red banner in total silence and look broken.
   While that is the situation, the button stops being a quiet toggle and
   starts demanding the tap. */
button.needsound{background:var(--warn);border-color:var(--warn);color:#111;
                 animation:beg 1s ease-in-out infinite}
@keyframes beg{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.72;transform:scale(1.045)}}
@media (prefers-reduced-motion:reduce){button.needsound{animation:none}}
.spacer{flex:1}
.pill{font-size:12px;color:var(--dim);white-space:nowrap}

input[type=search],select{
  font:inherit;color:var(--fg);background:var(--card);
  border:1px solid var(--line);border-radius:9px;padding:9px 12px;
}
input[type=search]{flex:1 1 180px;min-width:150px;max-width:300px}
input[type=search]::placeholder{color:var(--dim)}
input[type=search]:focus,select:focus{outline:2px solid var(--accent);outline-offset:-1px}
select{font-weight:600;padding:9px 8px}
/* On a phone the column headers are hidden, so sorting needs its own control.
   On a desktop the headers themselves are the control and these would be
   two ways to do one thing. */
.sortctl{display:none}

/* A filter that hides a DOWN host is the one way this page can lie, so it
   says so - and loudly when what it is hiding is an outage. */
#fwarn{border-radius:10px;padding:8px 12px;margin-bottom:10px;font-size:13px;
       font-weight:600;display:flex;gap:10px;align-items:center;flex-wrap:wrap;
       background:#3a2a08;border:1px solid #a16207;color:#fbbf24}
#fwarn.bad{background:var(--down);border-color:#b91c1c;color:#fff}
#fwarn button{padding:4px 10px;font-size:12px}
/* an id beats [hidden]'s display:none, so the strip would never go away */
#fwarn[hidden]{display:none}

table{width:100%;border-collapse:collapse;background:var(--card);border-radius:12px;overflow:hidden}
th,td{padding:9px 10px;text-align:left;border-bottom:1px solid var(--line);white-space:nowrap}
th{font-size:11px;text-transform:uppercase;letter-spacing:.6px;color:var(--dim);font-weight:600}
th.sortable{cursor:pointer;user-select:none;-webkit-user-select:none}
th.sortable:hover{color:var(--fg)}
th.sorted{color:var(--fg)}
th .car{font-size:9px;margin-left:3px;vertical-align:1px}
tr:last-child td{border-bottom:none}
td.name{white-space:normal;font-weight:600;word-break:break-word}
td.ip{color:var(--dim);font-family:ui-monospace,Consolas,monospace;font-size:13px}
td.num{text-align:right;font-variant-numeric:tabular-nums}
.badge{display:inline-block;padding:2px 9px;border-radius:99px;font-size:12px;font-weight:700}
.s-UP{background:#0d3320;color:#4ade80}
.s-DOWN{background:var(--down);color:#fff}
.s-WARN{background:#3a2a08;color:#fbbf24}
.s-OFF{background:#20242c;color:var(--off)}
.s-INIT{background:#20242c;color:var(--dim)}
tr.down td{background:#2a1212}
tr.down.acked td{background:#2a2412}
.mute{color:var(--dim);font-size:12px}

/* ---- group headings ----
   The whole strip is the tap target, and the colour down its left edge is
   the group's worst host - so the layer that is in trouble is findable
   without reading a single row. */
tr.ghead td{padding:0;background:#12151c}
.gh{display:flex;align-items:center;gap:9px;padding:11px 12px;cursor:pointer;
    border-left:3px solid var(--off);-webkit-tap-highlight-color:transparent}
tr.ghead.ok .gh{border-left-color:#1c5c33}
tr.ghead.warn .gh{border-left-color:var(--warn)}
tr.ghead.bad .gh{border-left-color:var(--down);background:#1f1416}
.gcar{color:var(--dim);font-size:10px;width:9px;flex:none}
.gname{font-weight:700;font-size:12px;letter-spacing:.7px;text-transform:uppercase}
.gp{font-size:11px;font-weight:700;padding:2px 8px;border-radius:99px;
    background:#20242c;color:var(--dim);white-space:nowrap}
.gp.down{background:var(--down);color:#fff}
.gp.warn{background:#3a2a08;color:#fbbf24}
.gp.up{background:#0d3320;color:#4ade80}
/* members sit under their heading, so the hierarchy is visible and not just
   implied by the order */
tbody.grouped td.name{padding-left:24px}

/* On a phone the table becomes one card per host - a 9-column grid squeezed
   into 380px is unreadable, and unreadable is the same as broken here. */
@media (max-width:640px){
  thead{display:none}
  .sortctl{display:inline-block}
  input[type=search]{max-width:none}
  table,tbody,tr,td{display:block;width:100%}
  table{background:none}
  tr{background:var(--card);border:1px solid var(--line);border-radius:12px;margin-bottom:8px;padding:10px 12px}
  td{border:none;padding:2px 0;white-space:normal}
  td.num{text-align:left}
  td[data-k]:before{content:attr(data-k) " ";color:var(--dim);font-size:12px}
  /* a healthy host has no "down for" value, and a card listing an empty
     labelled row for every field it does not have is mostly noise */
  td:empty{display:none}
  td.name{font-size:17px}
  td.name:before{content:none}
  tr.down td,tr.down.acked td{background:none}
  tr.down{border-color:var(--down);background:#2a1212}
  tr.down.acked{background:#2a2412;border-color:#a16207}
  /* the heading is a strip between cards, not another card */
  tr.ghead{background:none;border:none;border-radius:0;padding:0;margin:10px 0 6px}
  tr.ghead td{display:block;background:#12151c;border-radius:10px}
  tbody.grouped td.name{padding-left:0}
}
#log{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 12px;margin-top:10px;
     font:12px/1.5 ui-monospace,Consolas,monospace;color:var(--dim);max-height:230px;overflow:auto;white-space:pre-wrap}
footer{color:var(--dim);font-size:12px;margin:12px 2px 24px;display:flex;flex-wrap:wrap;gap:10px}
</style>
</head>
<body>
<div class="wrap">
  <div id="banner">connecting&hellip;</div>

  <div id="fwarn" hidden></div>

  <div class="bar">
    <button id="ack" class="danger" hidden>ACKNOWLEDGE</button>
    <button id="snd">&#128263; Sound off</button>
    <button id="wake" title="Stop the phone screen turning off">&#9728; Keep awake</button>
    <input id="q" type="search" placeholder="Search name, IP or status"
           autocomplete="off" autocorrect="off" spellcheck="false"
           aria-label="Filter the host list">
    <button id="grp" title="Group the list by network layer">Grouped</button>
    <button id="focus" title="Collapse the layers that are healthy">Focus</button>
    <select id="sortsel" class="sortctl" aria-label="Sort by">
      <option value="">Priority (down first)</option>
      <option value="config">Config order</option>
      <option value="name">Name</option>
      <option value="target">IP / Host</option>
      <option value="status">Status</option>
      <option value="rtt">ms</option>
      <option value="loss">Loss</option>
      <option value="since">Since</option>
      <option value="downFor">Down for</option>
    </select>
    <button id="sortdir" class="sortctl" title="Reverse the sort">&#9650;</button>
    <span class="spacer"></span>
    <span class="pill" id="counts"></span>
  </div>

  <table id="tbl">
    <thead><tr>
      <th class="sortable" data-s="name" data-t="Name">Name</th>
      <th class="sortable" data-s="target" data-t="IP / Host">IP / Host</th>
      <th class="sortable" data-s="status" data-t="Status">Status</th>
      <th class="sortable" data-s="rtt" data-t="ms" style="text-align:right">ms</th>
      <th class="sortable" data-s="loss" data-t="Loss" style="text-align:right">Loss</th>
      <th class="sortable" data-s="since" data-t="Since">Since</th>
      <th class="sortable" data-s="downFor" data-t="Down for">Down for</th>
    </tr></thead>
    <tbody id="rows"></tbody>
  </table>

  <div id="log"></div>
  <footer>
    <span id="fmon"></span><span id="fver"></span><span id="fchk"></span>
  </footer>
</div>

<script>
"use strict";
var S = null, fails = 0, flash = false;

/* ---- the access token ---------------------------------------------------
   The server also sets a cookie, but the page must not DEPEND on one: an
   installed home-screen app, a browser told to drop site data, or the page
   opened inside a frame will not send it, and the symptom is a dashboard stuck
   on "connecting" with no clue why. So the token is taken from the ?t= in the
   link, kept locally, and sent as a header on every request thereafter.       */
var tok = "";
try {
  var m = /[?&]t=([^&]+)/.exec(location.search);
  if (m) { tok = decodeURIComponent(m[1]); localStorage.setItem("tok", tok); }
  else { tok = localStorage.getItem("tok") || ""; }
} catch (e) { if (m) { tok = decodeURIComponent(m[1]); } }

function api(path, opts) {
  opts = opts || {};
  opts.cache = "no-store";
  if (tok) { opts.headers = { "X-Token": tok }; }
  return fetch(path, opts);
}

/* ---- alarm -------------------------------------------------------------
   A browser will not make a noise until the user has interacted with the page,
   so the sound button is not a preference, it is the unlock. The tone is
   generated rather than fetched for the same reason the desktop tool generates
   its .wav: no file to be missing, and nothing to load over a dead link.      */
var ac = null, soundOn = false, beeping = false, stopAt = 0;
try { soundOn = localStorage.getItem("snd") === "1"; } catch (e) {}

function ensureAudio() {
  if (!ac) {
    var C = window.AudioContext || window.webkitAudioContext;
    if (!C) return false;
    ac = new C();
  }
  if (ac.state === "suspended") { ac.resume(); }
  return true;
}

/* two-tone siren, one burst; called repeatedly while the alarm is up */
function burst() {
  if (!ac) return;
  var t0 = ac.currentTime;
  var g = ac.createGain();
  g.connect(ac.destination);
  g.gain.setValueAtTime(0.0001, t0);
  g.gain.exponentialRampToValueAtTime(0.30, t0 + 0.02);
  g.gain.setValueAtTime(0.30, t0 + 0.55);
  g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.62);
  var o = ac.createOscillator();
  o.type = "square";
  o.frequency.setValueAtTime(760, t0);
  o.frequency.setValueAtTime(560, t0 + 0.3);
  o.connect(g);
  o.start(t0);
  o.stop(t0 + 0.65);
}

function alarmTick() {
  var want = soundOn && S && S.alarm && S.alarm.active && S.alarm.loud && !S.alarm.muted;
  if (want && ac) burst();
  if (want && navigator.vibrate) { try { navigator.vibrate([250, 120, 250]); } catch (e) {} }
}
setInterval(alarmTick, 1400);

var bSnd = document.getElementById("snd");
function paintSnd() {
  /* Bell and muted-speaker emoji, written as \u escapes on purpose: the whole
     .ps1 is kept pure ASCII because it ships without a BOM and Windows
     PowerShell 5.1 reads such a file as ANSI - a literal emoji in the source
     would reach the browser as mojibake. Same reason Format-NotifyBody builds
     its emoji with ConvertFromUtf32 instead of typing them. */
  /* Three states, not two. The third is the one that matters: something is
     down, and this page is silent only because nobody has tapped it yet. */
  var begging = !soundOn && S && S.alarm && S.alarm.active && S.alarm.loud;
  if (begging) {
    bSnd.textContent = "\uD83D\uDD07 TAP FOR SOUND";
    bSnd.className = "needsound";
  } else {
    bSnd.textContent = soundOn ? "\uD83D\uDD14 Sound on" : "\uD83D\uDD07 Sound off";
    bSnd.className = soundOn ? "on" : "";
  }
}
bSnd.onclick = function () {
  soundOn = !soundOn;
  try { localStorage.setItem("snd", soundOn ? "1" : "0"); } catch (e) {}
  if (soundOn) { if (ensureAudio()) burst(); }
  paintSnd();
};
paintSnd();

/* ---- keep the screen on (phone on a desk showing the dashboard) ---- */
var wl = null, wantWake = false, bWake = document.getElementById("wake");
if (!("wakeLock" in navigator)) bWake.hidden = true;

/* Android drops the lock whenever the tab is hidden and does NOT give it back,
   so the wanted state and the held lock are tracked separately and re-acquired
   on every return to the foreground. */
function acquireWake() {
  if (wl || !wantWake || !("wakeLock" in navigator)) return;
  navigator.wakeLock.request("screen").then(function (s) {
    wl = s;
    s.addEventListener("release", function () { wl = null; });
  }).catch(function () {});
}
bWake.onclick = function () {
  wantWake = !wantWake;
  bWake.className = wantWake ? "on" : "";
  if (wantWake) { acquireWake(); }
  else if (wl) { wl.release(); wl = null; }
};
document.addEventListener("visibilitychange", function () {
  if (document.visibilityState === "visible") { acquireWake(); poll(); }
});

/* ---- acknowledge ---- */
document.getElementById("ack").onclick = function () {
  var b = this; b.disabled = true;
  api("/api/ack", { method: "POST" })
    .then(function () { setTimeout(poll, 250); })
    .catch(function () {})
    .then(function () { b.disabled = false; });
};

/* ---- render ---- */
function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
    return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
  });
}

/* ---- search and sort ---------------------------------------------------
   Both are view-only. The banner, the counts and the alarm are always
   computed from the WHOLE list, never from what happens to be on screen: a
   filter that could turn the banner green would be the one way this page is
   able to lie, and lying is the failure it exists to prevent. When a filter
   IS hiding something down, the strip above the table says so.

   The sort is remembered across a reload. The search deliberately is not -
   walking up to a wall display and not noticing that half the estate has
   been filtered out is exactly the same trap.                               */
var q = "", sortKey = "", sortDir = 1, grouped = true, focusMode = true;
try {
  sortKey = localStorage.getItem("sk") || "";
  sortDir = localStorage.getItem("sd") === "-1" ? -1 : 1;
  grouped = localStorage.getItem("gv") !== "0";
  focusMode = localStorage.getItem("fm") !== "0";
} catch (e) {}

/* Worst first, so ascending on Status is the order a NOC actually wants. */
var SEV = { DOWN: 0, WARN: 1, INIT: 2, UP: 3, OFF: 4 };
var UNGROUPED = "Ungrouped";

/* The default ordering, and the reason the list is worth looking at: whatever
   is broken is at the top of its layer. An acknowledged outage drops below an
   unacknowledged one - somebody is already on that one. */
function sevOf(h) {
  var s = SEV[h.status];
  if (s === undefined) s = 9;
  return (h.status === "DOWN" && h.acked) ? s + 0.5 : s;
}

function troubled(list) {
  for (var i = 0; i < list.length; i++) {
    if (list[i].status === "DOWN" || list[i].status === "WARN") return true;
  }
  return false;
}

/* 172.30.100.9 must sort before 172.30.100.10, which it does not as text. */
function ipKey(s) {
  var m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(s || "");
  if (!m) return null;
  var n = 0;
  for (var i = 1; i <= 4; i++) {
    if (+m[i] > 255) return null;
    n = n * 256 + (+m[i]);
  }
  return n;
}

/* the four shapes fmt_duration emits: "1d 2h", "3h 4m", "5m 6s", "7s" */
function durSecs(s) {
  var t = 0, mul = { d: 86400, h: 3600, m: 60, s: 1 }, re = /(\d+)\s*([dhms])/g, m;
  while ((m = re.exec(s || ""))) { t += (+m[1]) * mul[m[2]]; }
  return t;
}

/* "HH:MM:SS" -> seconds. A stamp ahead of the monitor's own clock can only be
   yesterday, so it sorts before midnight instead of jumping to the far end. */
function clockSecs(s, nowS) {
  var m = /^(\d\d):(\d\d):(\d\d)$/.exec(s || "");
  if (!m) return 0;
  var t = (+m[1]) * 3600 + (+m[2]) * 60 + (+m[3]);
  return (nowS && t > nowS + 60) ? t - 86400 : t;
}

function sortVal(h, nowS) {
  switch (sortKey) {
    case "name":    return String(h.label || h.target || "").toLowerCase();
    /* one comparable string for both kinds of target: IPs zero-padded and
       grouped ahead of names, so the two never interleave */
    case "target":  var n = ipKey(h.target);
                    return n === null ? "1 " + String(h.target || "").toLowerCase()
                                      : "0 " + ("0000000000" + n).slice(-10);
    case "status":  return SEV[h.status] === undefined ? 9 : SEV[h.status];
    case "rtt":     return h.rtt == null ? 0 : h.rtt;
    case "loss":    return h.loss || 0;
    case "since":   return clockSecs(h.since, nowS);
    case "downFor": return durSecs(h.downFor);
  }
  return 0;
}

/* "-" is not a small number. A host with no reading sits at the bottom
   whichever way the column is pointing, rather than winning the sort. */
function isBlank(h) {
  if (sortKey === "rtt") return h.rtt == null;
  if (sortKey === "since") return !h.since;
  if (sortKey === "downFor") return !h.downFor;
  return false;
}

function arrange(list, nowS) {
  if (sortKey === "config") return list;      /* the raw file order, on demand */
  var pri = !sortKey;                         /* the default: worst first */
  var dir = pri ? 1 : sortDir;
  var k = list.map(function (h, i) {
    return { h: h, i: i,
             v: pri ? sevOf(h) : sortVal(h, nowS),
             b: pri ? false : isBlank(h) };
  });
  k.sort(function (x, y) {
    if (x.b !== y.b) return x.b ? 1 : -1;
    var c = (x.v < y.v ? -1 : x.v > y.v ? 1 : 0) * dir;
    return c || (x.i - y.i);          /* ties keep the order config lists them */
  });
  return k.map(function (e) { return e.h; });
}

/* ---- the layers --------------------------------------------------------
   Order comes from config, not from the data: `groups:` in config.yml IS the
   hierarchy, upstream first. A layer with something wrong is lifted above the
   healthy ones, so an incident walks up the page towards you instead of
   waiting to be scrolled to.

   Counts on a heading are always the WHOLE layer, never the filtered subset -
   same rule as the banner. A heading that quietly recounted itself to match a
   search would be the page lying in a smaller font.                          */
var collapsed = {};      /* name -> bool. Session only, on purpose: a reload
                            must not restore a fold that hides a device. */

function layers(all, keep) {
  var order = [], bucket = {}, out = [];
  var declared = S.groups || [];
  for (var i = 0; i < declared.length; i++) {
    order.push(declared[i].name);
    bucket[declared[i].name] = [];
  }
  for (var j = 0; j < all.length; j++) {
    var name = all[j].group || UNGROUPED;
    if (!bucket[name]) { bucket[name] = []; order.push(name); }
    bucket[name].push(all[j]);
  }
  for (var k = 0; k < order.length; k++) {
    var members = bucket[order[k]];
    if (!members.length) continue;            /* an empty layer is just noise */
    var rows = members.filter(keep);
    if (!rows.length) continue;               /* nothing of it survived the search */
    out.push({ name: order[k], all: members, rows: rows, bad: troubled(members) });
  }
  var hurt = [], well = [];
  for (var m = 0; m < out.length; m++) { (out[m].bad ? hurt : well).push(out[m]); }
  return hurt.concat(well);
}

function tally(members) {
  var t = { up: 0, down: 0, warn: 0, off: 0 };
  for (var i = 0; i < members.length; i++) {
    var s = members[i].status;
    if (s === "OFF") t.off++;
    else if (s === "DOWN") t.down++;
    else if (s === "WARN") t.warn++;
    else if (s === "UP") t.up++;
  }
  return t;
}

function matches(h) {
  if (!q) return true;
  return (String(h.label || "") + " " + String(h.target || "") + " " +
          String(h.status || "")).toLowerCase().indexOf(q) >= 0;
}

var inQ = document.getElementById("q");
var selSort = document.getElementById("sortsel");
var bDir = document.getElementById("sortdir");

function setSort(key, dir) {
  sortKey = dir ? key : "";
  sortDir = dir || 1;
  try {
    localStorage.setItem("sk", sortKey);
    localStorage.setItem("sd", String(sortDir));
  } catch (e) {}
  paintSort();
  if (S) render();
}

function paintSort() {
  selSort.value = sortKey;
  bDir.innerHTML = sortDir > 0 ? "&#9650;" : "&#9660;";
  bDir.disabled = !sortKey;
  var ths = document.querySelectorAll("th.sortable");
  for (var i = 0; i < ths.length; i++) {
    var on = ths[i].getAttribute("data-s") === sortKey;
    ths[i].className = on ? "sortable sorted" : "sortable";
    ths[i].innerHTML = esc(ths[i].getAttribute("data-t")) +
      (on ? '<span class="car">' + (sortDir > 0 ? "&#9650;" : "&#9660;") + "</span>" : "");
  }
}

(function () {
  var ths = document.querySelectorAll("th.sortable");
  for (var i = 0; i < ths.length; i++) {
    /* asc, then desc, then back to the order config lists them in */
    ths[i].onclick = function () {
      var k = this.getAttribute("data-s");
      if (k !== sortKey) setSort(k, 1);
      else if (sortDir > 0) setSort(k, -1);
      else setSort("", 0);
    };
  }
})();

selSort.onchange = function () { setSort(this.value, this.value ? sortDir : 0); };
bDir.onclick = function () { if (sortKey) setSort(sortKey, -sortDir); };

var bGrp = document.getElementById("grp"), bFocus = document.getElementById("focus");
function paintView() {
  bGrp.className = grouped ? "on" : "";
  bGrp.textContent = grouped ? "Grouped" : "Flat";
  bFocus.className = focusMode ? "on" : "";
  bFocus.disabled = !grouped;
}
function toggle(which) {
  return function () {
    if (which === "gv") { grouped = !grouped; } else { focusMode = !focusMode; }
    try {
      localStorage.setItem(which, (which === "gv" ? grouped : focusMode) ? "1" : "0");
    } catch (e) {}
    paintView();
    if (S) render();
  };
}
bGrp.onclick = toggle("gv");
bFocus.onclick = toggle("fm");
paintView();

/* Folding a layer is one tap anywhere along its strip. */
document.getElementById("rows").addEventListener("click", function (e) {
  var tr = e.target.closest ? e.target.closest("tr.ghead") : null;
  if (!tr) return;
  collapsed[tr.getAttribute("data-g")] = tr.getAttribute("data-c") !== "1";
  if (S) render();
});

function clearQ() { inQ.value = ""; q = ""; if (S) render(); }
inQ.oninput = function () {
  q = this.value.trim().toLowerCase();
  if (S) render();
};
inQ.onkeydown = function (e) {
  if (e.key === "Escape" || e.keyCode === 27) { clearQ(); }
};
paintSort();

function rowHtml(h) {
  var cls = (h.status === "DOWN" ? "down" : "") + (h.acked ? " acked" : "");
  return '<tr class="' + cls + '">' +
    '<td class="name">' + esc(h.label || h.target) +
      (h.sound ? "" : ' <span class="mute" title="sound off for this host">&#128263;</span>') + "</td>" +
    '<td class="ip" data-k="">' + esc(h.target) + "</td>" +
    '<td data-k=""><span class="badge s-' + esc(h.status) + '">' + esc(h.status) +
      (h.acked ? " ack" : "") + "</span></td>" +
    '<td class="num" data-k="ms">' + (h.rtt == null ? "-" : h.rtt) + "</td>" +
    '<td class="num" data-k="loss">' + h.loss + "%</td>" +
    '<td data-k="since">' + esc(h.since) + "</td>" +
    '<td data-k="down for">' + esc(h.downFor) + "</td></tr>";
}

/* `tick` is only true when a poll brought new data, so holding a key down in
   the search box cannot speed up the banner's flash. */
function render(tick) {
  var b = document.getElementById("banner");
  var downs = S.hosts.filter(function (h) { return h.status === "DOWN"; });
  var unacked = downs.filter(function (h) { return !h.acked; });

  b.className = downs.length ? "down" : "ok";
  if (downs.length) {
    if (tick) flash = !flash;
    if (flash && unacked.length) b.className = "down flash";
    var names = downs.slice(0, 4).map(function (h) { return h.label || h.target; }).join(", ");
    if (downs.length > 4) names += " +" + (downs.length - 4) + " more";
    b.innerHTML = esc(downs.length + (downs.length === 1 ? " HOST DOWN" : " HOSTS DOWN")) +
                  "<small>" + esc(names) + "</small>";
  } else {
    b.innerHTML = "ALL OK<small>" + esc(S.counts.up + " up" +
      (S.counts.off ? ", " + S.counts.off + " disabled" : "") +
      (S.paused ? " - PAUSED" : "")) + "</small>";
  }

  var ack = document.getElementById("ack");
  ack.hidden = !(S.canAck && unacked.length);

  /* repainted every poll, not just on click: whether the button has to beg for
     a tap depends on the alarm, which changes underneath it */
  paintSnd();

  /* the view: filtered and sorted, and used for NOTHING but the table */
  var nm = /^(\d\d):(\d\d):(\d\d)$/.exec(S.time || "");
  var nowS = nm ? (+nm[1]) * 3600 + (+nm[2]) * 60 + (+nm[3]) : 0;
  var shown = arrange(S.hosts.filter(matches), nowS);

  var hidden = S.hosts.length - shown.length;
  var hiddenDown = 0;
  for (var d = 0; d < downs.length; d++) { if (!matches(downs[d])) hiddenDown++; }

  var fw = document.getElementById("fwarn");
  fw.hidden = !hidden;
  if (hidden) {
    fw.className = hiddenDown ? "bad" : "";
    fw.innerHTML = (hiddenDown
        ? esc(hiddenDown + (hiddenDown === 1 ? " DOWN host is" : " DOWN hosts are") +
              " hidden by the search")
        : esc(hidden + (hidden === 1 ? " host" : " hosts") + " hidden by the search")) +
      ' <span class="spacer"></span><button type="button" id="fclr">Show all</button>';
    document.getElementById("fclr").onclick = clearQ;
  }

  document.getElementById("counts").textContent =
    (q ? "showing " + shown.length + " of " + S.hosts.length + "   " : "") +
    "UP " + S.counts.up + "   DOWN " + S.counts.down + "   off " + S.counts.off;

  var body = document.getElementById("rows");
  var out = "";

  /* No group on any host means the engine answering does not send them - the
     Windows tool does not - so the page quietly stays flat rather than piling
     the whole estate under one "Ungrouped" heading. */
  var anyGroup = false;
  for (var g = 0; g < S.hosts.length; g++) {
    if (S.hosts[g].group) { anyGroup = true; break; }
  }

  if (grouped && anyGroup) {
    body.className = "grouped";
    var incident = troubled(S.hosts);
    var ls = layers(S.hosts, matches);
    for (var a = 0; a < ls.length; a++) {
      var L = ls[a], t = tally(L.all);
      /* An explicit fold wins. Otherwise Focus collapses the layers with
         nothing wrong, but only once something IS wrong somewhere: on a quiet
         day the whole estate stays open, which is the view a wall wants. */
      var shut = Object.prototype.hasOwnProperty.call(collapsed, L.name)
        ? collapsed[L.name]
        : (focusMode && incident && !L.bad);
      var pills = "";
      if (t.down) { pills += '<span class="gp down">' + t.down + " down</span>"; }
      if (t.warn) { pills += '<span class="gp warn">' + t.warn + " warn</span>"; }
      if (t.up) { pills += '<span class="gp up">' + t.up + " up</span>"; }
      if (t.off) { pills += '<span class="gp">' + t.off + " off</span>"; }
      out += '<tr class="ghead ' + (t.down ? "bad" : t.warn ? "warn" : "ok") +
        '" data-g="' + esc(L.name) + '" data-c="' + (shut ? "1" : "0") + '">' +
        '<td colspan="7"><div class="gh"><span class="gcar">' +
        (shut ? "&#9654;" : "&#9660;") + '</span><span class="gname">' +
        esc(L.name) + '</span><span class="spacer"></span>' + pills +
        "</div></td></tr>";
      if (!shut) {
        var mem = arrange(L.rows, nowS);
        for (var b = 0; b < mem.length; b++) { out += rowHtml(mem[b]); }
      }
    }
  } else {
    body.className = "";
    for (var i = 0; i < shown.length; i++) { out += rowHtml(shown[i]); }
  }

  if (!shown.length) {
    out = '<tr><td class="mute" colspan="7">nothing matches ' + esc(q) + "</td></tr>";
  }
  body.innerHTML = out;

  var lg = document.getElementById("log");
  lg.textContent = (S.log || []).join("\n");

  document.getElementById("fmon").textContent = S.monitor;
  document.getElementById("fver").textContent = "v:" + S.version;
  document.getElementById("fchk").textContent = S.checked ? "last check " + S.checked : "";
  document.title = (downs.length ? "(" + downs.length + " DOWN) " : "") + "GCL Ping Monitor";
}

/* ---- poll --------------------------------------------------------------
   A monitoring page that quietly stops updating is worse than one that is
   plainly broken, so a failed poll is shown as loudly as an outage.          */
function poll() {
  api("/api/status")
    .then(function (r) {
      if (r.status === 401) { throw new Error("401"); }
      if (!r.ok) throw new Error(r.status);
      return r.json();
    })
    .then(function (j) {
      fails = 0;
      if (!j.ready) return;
      S = j;
      render(true);
    })
    .catch(function (e) {
      fails++;
      if (fails < 2) return;
      var b = document.getElementById("banner");
      b.className = "lost";
      /* A rejected token and a dead PC look identical if both just say
         "no connection" - and on a monitoring screen that is the difference
         between "fix your link" and "go and look at the rack". */
      if (String(e && e.message) === "401") {
        b.innerHTML = "LINK NO LONGER VALID<small>the access token was changed - open the current link from Settings &rarr; Web dashboard</small>";
        document.title = "(link expired) GCL Ping Monitor";
      } else {
        b.innerHTML = "NO CONNECTION TO THE MONITOR<small>the PC or the network may be down - this page is not updating</small>";
        document.title = "(offline) GCL Ping Monitor";
      }
    });
}
poll();
setInterval(poll, 2000);

if ("serviceWorker" in navigator) {
  try { navigator.serviceWorker.register("/sw.js"); } catch (e) {}
}
</script>
</body>
</html>
'@
# ---------------------------------------------------------------------------
#  Web dashboard  (browser on the LAN, and a phone)
# ---------------------------------------------------------------------------
#  HttpListener blocks, and this is a single-threaded WinForms app, so the
#  server lives in its own runspace. The two sides share exactly one object - a
#  synchronized hashtable - and they only ever exchange STRINGS through it:
#
#      UI  -> web :  $script:Web.Status     a JSON snapshot, rebuilt each second
#      web -> UI  :  $script:Web.Commands   'ack' / 'pause' / 'resume', drained
#                                           by the UI timer on the UI thread
#
#  Nothing in the web runspace ever touches a host object or a control, which is
#  the only reason this is safe. Keep it that way: the moment the handler starts
#  reading $script:Hosts directly it is reading a List<T> from two threads.
#
#  The JSON shape is deliberately a small, versioned contract ("v": 1) rather
#  than a dump of the internal state, because the plan is to move the polling
#  engine off Windows later - when that happens this page must not have to change.
# ---------------------------------------------------------------------------

$script:Web = [hashtable]::Synchronized(@{
    Running   = $false
    Listener  = $null
    PS        = $null
    Runspace  = $null
    Status    = '{"v":1,"ready":false}'
    Commands  = (New-Object System.Collections.ArrayList)
    Messages  = (New-Object System.Collections.ArrayList)   # log lines back from the runspace
    Token     = ''
    AllowAck  = $true
    Prefix    = ''
    LocalOnly = $false
    Stop      = $false
    Hits      = 0
})
$script:WebLastPush = [datetime]::MinValue

function Get-WebPort {
    $p = [int]$script:Config.Web.Port
    if ($p -lt 1 -or $p -gt 65535) { $p = 8080 }
    $p
}

# The token is what stops the rest of the office reading the dashboard. It is
# generated once, DPAPI-sealed like every other secret, and shown in the
# Settings dialog so it can be copied into a bookmark.
function Get-WebToken {
    $t = Unprotect-Secret ([string]$script:Config.Web.TokenEnc)
    if ($t) { return $t }
    # one random byte PER CHARACTER. An earlier version drew 16 bytes for 20
    # characters and wrapped the index, which made the last four characters a
    # literal repeat of the first four - visible in every token it produced.
    $bytes = New-Object byte[] 20
    ([System.Security.Cryptography.RNGCryptoServiceProvider]::Create()).GetBytes($bytes)
    # base32-ish: no look-alike characters, because this gets typed on a phone
    $abc = '23456789abcdefghjkmnpqrstuvwxyz'
    $t = -join (0..19 | ForEach-Object { $abc[$bytes[$_] % $abc.Length] })
    $script:Config.Web.TokenEnc = Protect-Secret $t
    Save-Config
    $t
}

function Reset-WebToken {
    $script:Config.Web.TokenEnc = ''
    $new = Get-WebToken
    $script:Web.Token = $new
    Write-Event 'WEB       : access token replaced - old bookmarks stop working'
    $new
}

function Get-WebUrls {
    $port = Get-WebPort
    $tok  = Get-WebToken
    $urls = @()
    # what it is ACTUALLY bound to, not what was asked for - after a fallback
    # the two differ, and handing out a network URL that refuses connections is
    # the most confusing thing this dialog could do
    $isLocal = if ($script:Web.Running) { [bool]$script:Web.LocalOnly }
               else { [string]$script:Config.Web.Bind -eq 'local' }
    if ($isLocal) {
        $urls += ('http://localhost:{0}/?t={1}' -f $port, $tok)
    } else {
        if ($script:MonitorIp) { $urls += ('http://{0}:{1}/?t={2}' -f $script:MonitorIp, $port, $tok) }
        $urls += ('http://{0}:{1}/?t={2}' -f $script:MonitorName.ToLower(), $port, $tok)
        $urls += ('http://localhost:{0}/?t={1}' -f $port, $tok)
    }
    $urls
}

# One JSON snapshot of everything the page shows. Built on the UI thread, handed
# over as an immutable string - see the note at the top of this section.
function Update-WebStatus {
    if (-not $script:Web.Running) { return }
    $now = Get-Date
    if (($now - $script:WebLastPush).TotalMilliseconds -lt 900) { return }
    $script:WebLastPush = $now

    $rows = @()
    foreach ($h in $script:Hosts) {
        $rows += [pscustomobject]@{
            label   = [string]$h.Label
            target  = [string]$h.Target
            status  = [string]$(if (-not $h.Enabled) { 'OFF' } else { $h.Status })
            enabled = [bool]$h.Enabled
            sound   = [bool]$h.AlarmEnabled
            acked   = [bool]$h.Acked
            rtt     = $(if ($null -ne $h.Latency) { [int]$h.Latency } else { $null })
            loss    = [int](Get-LossPercent $h)
            since   = $(if ($h.LastChange) { $h.LastChange.ToString('HH:mm:ss') } else { '' })
            downFor = $(if ($h.Status -eq 'DOWN' -and $h.DownSince) { Format-Duration ($now - $h.DownSince) } else { '' })
        }
    }
    $active = @($script:Hosts | Where-Object { $_.Enabled })
    $obj = [pscustomobject]@{
        v       = 1
        ready   = $true
        monitor = Get-MonitorLabel
        version = [string]$script:Version
        time    = $now.ToString('HH:mm:ss')
        checked = $(if ($script:LastCheck) { $script:LastCheck.ToString('HH:mm:ss') } else { '' })
        paused  = [bool]$script:Paused
        canAck  = [bool]$script:Web.AllowAck
        alarm   = [pscustomobject]@{
            active = [bool]$script:AlarmActive
            loud   = [bool]$script:AlarmLoud
            muted  = [bool]$script:AlarmMuted
        }
        counts  = [pscustomobject]@{
            total = $script:Hosts.Count
            up    = @($active | Where-Object { $_.Status -eq 'UP' }).Count
            down  = @($active | Where-Object { $_.Status -eq 'DOWN' }).Count
            off   = $script:Hosts.Count - $active.Count
        }
        hosts   = $rows
        log     = @($script:WebLogRing)
    }
    try {
        # -Compress matters: this string is rebuilt every second and pretty JSON
        # for 60 hosts is several times the size for no reader benefit
        $script:Web.Status = ($obj | ConvertTo-Json -Depth 5 -Compress)
    } catch { }
}

# Anything the browser asked for, applied on the UI thread where it is safe.
function Invoke-WebCommands {
    if ($script:Web.Messages.Count -gt 0) {
        $msgs = @($script:Web.Messages.ToArray()); $script:Web.Messages.Clear()
        foreach ($m in $msgs) { Write-Event $m }
    }
    if ($script:Web.Commands.Count -eq 0) { return }
    $cmds = @($script:Web.Commands.ToArray()); $script:Web.Commands.Clear()
    foreach ($c in $cmds) {
        switch ([string]$c) {
            'ack'    { Confirm-Alarm;                       Write-Event 'WEB       : acknowledged from a browser' }
            'pause'  { if (-not $script:Paused) { Toggle-Pause; Write-Event 'WEB       : paused from a browser' } }
            'resume' { if ($script:Paused)      { Toggle-Pause; Write-Event 'WEB       : resumed from a browser' } }
        }
    }
}

function Add-WebUrlAcl {
    # Binding anything other than 127.0.0.1 needs a one-off HTTP.SYS reservation,
    # which needs administrator. Rather than demanding the whole app run
    # elevated - a monitoring tool that sits on a desk all day should not - this
    # elevates a single netsh call and comes straight back.
    $port = Get-WebPort
    $me   = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    # The firewall rule is scoped to private/office ranges, NOT left open.
    # A monitoring PC can easily have a public address (GCL's desks do), and an
    # unscoped rule would publish the whole dashboard - hosts, IPs and all - to
    # the internet on a plain HTTP port with one guessable token in front of it.
    $from = 'LocalSubnet,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'
    $cmd  = 'netsh http add urlacl url=http://+:{0}/ user="{1}" ; ' -f $port, $me
    $cmd += 'netsh advfirewall firewall delete rule name="GCL Ping Monitor web" ; '
    $cmd += 'netsh advfirewall firewall add rule name="GCL Ping Monitor web" dir=in action=allow protocol=TCP localport={0} profile=any remoteip={1}' -f $port, $from
    try {
        $p = Start-Process powershell -Verb RunAs -Wait -PassThru -WindowStyle Hidden `
                -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command', $cmd
        if ($p.ExitCode -eq 0) {
            Write-Event ('WEB       : URL reservation + firewall rule created for port {0}' -f $port)
            return $true
        }
        Write-Event ('WEB   err : netsh returned {0}' -f $p.ExitCode)
    } catch {
        # the user clicking "No" on the UAC prompt lands here - not an error
        Write-Event ('WEB   err : could not elevate - {0}' -f $_.Exception.Message)
    }
    $false
}

function Stop-WebServer {
    if (-not $script:Web.Running -and -not $script:Web.Listener) { return }
    $script:Web.Stop = $true
    # Close(), not Stop(): Stop() lets the blocked GetContext() sit there until
    # the next request arrives, so the runspace would outlive the window.
    try { if ($script:Web.Listener) { $script:Web.Listener.Close() } } catch { }
    try { if ($script:Web.PS) { $script:Web.PS.Dispose() } } catch { }
    try { if ($script:Web.Runspace) { $script:Web.Runspace.Close(); $script:Web.Runspace.Dispose() } } catch { }
    $script:Web.Listener = $null; $script:Web.PS = $null; $script:Web.Runspace = $null
    if ($script:Web.Running) { Write-Event 'WEB       : dashboard stopped' }
    $script:Web.Running = $false
}

function Start-WebServer {
    param([switch]$Quiet, [switch]$ForceLocal)
    Stop-WebServer
    $port = Get-WebPort
    $script:Web.Stop     = $false
    $script:Web.Token    = Get-WebToken
    $script:Web.AllowAck = [bool]$script:Config.Web.AllowAck
    # $ForceLocal is the RUNTIME fallback and is deliberately not written to the
    # config: what the user asked for is "any", and a missing URL reservation is
    # a temporary condition. Persisting it meant one failed start silently
    # rewrote the setting to localhost, so granting the permission afterwards
    # appeared to do nothing.
    $local = $ForceLocal -or ([string]$script:Config.Web.Bind -eq 'local')

    $listener = New-Object System.Net.HttpListener
    $prefix = if ($local) { 'http://localhost:{0}/' -f $port } else { 'http://+:{0}/' -f $port }
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    } catch [System.Net.HttpListenerException] {
        $code = $_.Exception.ErrorCode
        try { $listener.Close() } catch { }
        if ($code -eq 5 -and -not $local) {
            # ERROR_ACCESS_DENIED - no URL reservation. Fall back to loopback so
            # the tool still works, and say exactly what to click to fix it.
            Write-Event ('WEB   err : port {0} needs a one-off permission (Settings -> Web dashboard -> Allow access from other PCs). Listening on localhost only for now.' -f $port)
            Start-WebServer -Quiet:$Quiet -ForceLocal
            return
        }
        if ($code -eq 32 -or $code -eq 183) {
            Write-Event ('WEB   err : port {0} is already in use by another program - pick a different port.' -f $port)
        } else {
            Write-Event ('WEB   err : could not listen on {0} - {1}' -f $prefix, $_.Exception.Message)
        }
        $script:Web.Running = $false
        return
    } catch {
        try { $listener.Close() } catch { }
        Write-Event ('WEB   err : could not listen on {0} - {1}' -f $prefix, $_.Exception.Message)
        $script:Web.Running = $false
        return
    }

    $script:Web.Listener  = $listener
    $script:Web.Prefix    = $prefix
    $script:Web.LocalOnly = $local
    $script:Web.Running   = $true

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Web',  $script:Web)
    $rs.SessionStateProxy.SetVariable('Page', $script:WebPage)
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:WebWorker)
    [void]$ps.BeginInvoke()
    $script:Web.PS = $ps; $script:Web.Runspace = $rs

    Update-WebStatus
    if (-not $Quiet) {
        Write-Event ('WEB       : dashboard on {0}  (token required)' -f (@(Get-WebUrls)[0]))
    }
}

# The request loop. Runs in its own runspace with NOTHING from the main script
# in scope except $Web and $Page - if it needs anything else, pass it in.
$script:WebWorker = {
    $listener = $Web.Listener
    function Reply {
        param($ctx, [int]$code, [string]$type, $body, $extraHeaders)
        try {
            $res = $ctx.Response
            $res.StatusCode  = $code
            $res.ContentType = $type
            # every response is generated here and never cached: a stale
            # dashboard is worse than no dashboard
            $res.Headers['Cache-Control'] = 'no-store'
            $res.Headers['X-Content-Type-Options'] = 'nosniff'
            if ($extraHeaders) { foreach ($k in $extraHeaders.Keys) { $res.Headers[$k] = [string]$extraHeaders[$k] } }
            $bytes = if ($body -is [byte[]]) { $body } else { [Text.Encoding]::UTF8.GetBytes([string]$body) }
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.OutputStream.Close()
        } catch { }
    }

    while (-not $Web.Stop) {
        $ctx = $null
        try { $ctx = $listener.GetContext() }
        catch { break }          # Close() from the UI thread lands here - that is the exit
        if (-not $ctx) { continue }
        try {
            $req  = $ctx.Request
            $path = $req.Url.AbsolutePath.TrimEnd('/')
            if (-not $path) { $path = '/' }

            # ---- authentication ----
            # The token may arrive three ways: in the query string (the link he
            # bookmarks), in a cookie (set from that link, so the URL can then be
            # clean), or in a header (for anything scripted against the API).
            $want = [string]$Web.Token
            $got  = ''
            try { if ($req.QueryString['t']) { $got = [string]$req.QueryString['t'] } } catch { }
            if (-not $got) { try { $c = $req.Cookies['gclpm']; if ($c) { $got = [string]$c.Value } } catch { } }
            if (-not $got) { try { $got = [string]$req.Headers['X-Token'] } catch { } }
            $ok = ($want -eq '') -or ($got -eq $want)

            if (-not $ok) {
                Reply $ctx 401 'text/html; charset=utf-8' '<!doctype html><meta name=viewport content="width=device-width,initial-scale=1"><body style="font:16px system-ui;background:#111;color:#ddd;padding:2em"><h2>GCL Ping Monitor</h2><p>Access token required.</p><p style="color:#888">Open the link from Settings &rarr; Web dashboard.</p></body>'
                continue
            }

            switch -Regex ($path) {
                '^/api/status$' {
                    Reply $ctx 200 'application/json; charset=utf-8' $Web.Status
                    break
                }
                '^/api/(ack|pause|resume)$' {
                    $what = $Matches[1]
                    if ($what -eq 'ack' -and -not $Web.AllowAck) {
                        Reply $ctx 403 'application/json' '{"ok":false,"error":"read-only"}'
                        break
                    }
                    if ($req.HttpMethod -ne 'POST') {
                        Reply $ctx 405 'application/json' '{"ok":false,"error":"POST only"}'
                        break
                    }
                    [void]$Web.Commands.Add($what)
                    Reply $ctx 200 'application/json' '{"ok":true}'
                    break
                }
                '^/manifest\.webmanifest$' {
                    # start_url carries the token so the installed icon opens
                    # straight into the dashboard without a login step
                    $tok = [string]$Web.Token
                    $m = '{"name":"GCL Ping Monitor","short_name":"Ping Mon","start_url":"/?t=' + $tok +
                         '","scope":"/","display":"standalone","background_color":"#0f1115","theme_color":"#0f1115",' +
                         '"icons":[{"src":"/icon.svg","sizes":"any","type":"image/svg+xml","purpose":"any maskable"}]}'
                    Reply $ctx 200 'application/manifest+json; charset=utf-8' $m
                    break
                }
                '^/icon\.svg$' {
                    $svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><rect width="192" height="192" rx="34" fill="#0f1115"/><circle cx="96" cy="96" r="52" fill="none" stroke="#22c55e" stroke-width="12"/><circle cx="96" cy="96" r="20" fill="#22c55e"/></svg>'
                    Reply $ctx 200 'image/svg+xml; charset=utf-8' $svg
                    break
                }
                '^/sw\.js$' {
                    # Deliberately a no-op service worker. It exists only so
                    # Android offers "Install app"; caching a monitoring page
                    # would be actively harmful.
                    Reply $ctx 200 'application/javascript; charset=utf-8' "self.addEventListener('fetch',function(){});"
                    break
                }
                '^/favicon\.ico$' { Reply $ctx 404 'text/plain' 'no'; break }
                default {
                    if ($path -ne '/') { Reply $ctx 404 'text/plain; charset=utf-8' 'Not found'; break }
                    $extra = @{}
                    # Move the token out of the URL into a cookie on first visit,
                    # so a screenshot or a shoulder-surfer does not hand it over.
                    try {
                        if ($req.QueryString['t']) {
                            $extra['Set-Cookie'] = 'gclpm={0}; Path=/; Max-Age=31536000; SameSite=Lax; HttpOnly' -f $Web.Token
                        }
                    } catch { }
                    $Web.Hits = [int]$Web.Hits + 1
                    Reply $ctx 200 'text/html; charset=utf-8' $Page $extra
                    break
                }
            }
        } catch {
            try { [void]$Web.Messages.Add('WEB   err : ' + $_.Exception.Message) } catch { }
            try { $ctx.Response.Abort() } catch { }
        }
    }
}

# ---------------------------------------------------------------------------
#  Timers
# ---------------------------------------------------------------------------
$script:checkTimer = New-Object System.Windows.Forms.Timer
$script:checkTimer.Interval = [Math]::Max([int]$script:Config.IntervalSeconds,2) * 1000
$script:checkTimer.Add_Tick({ try { Start-CheckCycle } catch { Write-Event "ERR check: $($_.Exception.Message)" } })

$script:uiTimer = New-Object System.Windows.Forms.Timer
$script:uiTimer.Interval = 400
$script:uiTimer.Add_Tick({
    try {
        # someone double-clicked the shortcut again - show this window instead
        if ($script:ShowEvent -and $script:ShowEvent.WaitOne(0, $false)) { Show-MainWindow }
        Poll-Results
        Refresh-Grid
        Update-Alarm
        Refresh-Banner
        Refresh-Status
        # the browser side rides on this tick: commands first (so an
        # acknowledge made on a phone is applied before the snapshot is taken
        # and the phone does not see its own click bounce back)
        Invoke-WebCommands
        Update-WebStatus
    } catch { Write-Event "ERR ui: $($_.Exception.Message)" }
})

$script:AlarmTimer = New-Object System.Windows.Forms.Timer
$script:AlarmTimer.Interval = [Math]::Min([Math]::Max([int]$script:Config.AlarmRepeatMs, 500), 60000)
$script:AlarmTimer.Add_Tick({
    Update-AlarmAutoStop
    if ($script:AlarmActive -and -not $script:AlarmMuted) {
        Play-Alarm
    }
    if ($script:AlarmActive) {
        # the taskbar keeps flashing even once the sound has been auto-silenced -
        # the fault has not gone away, only the noise has
        try {
            if (-not $form.ContainsFocus) { [Win32.Native]::FlashWindow($form.Handle, $true) }
        } catch { }
    }
})

$script:notifyTimer = New-Object System.Windows.Forms.Timer
$script:notifyTimer.Interval = [Math]::Max([int]$script:Config.Notify.BatchSeconds, 5) * 1000
$script:notifyTimer.Add_Tick({
    try { Send-QueuedNotifications } catch { Write-Event "ERR notify: $($_.Exception.Message)" }
    try { Send-DownReminder }        catch { Write-Event "ERR notify: $($_.Exception.Message)" }
})

# background self-update check while the app is running
$script:updateTimer = New-Object System.Windows.Forms.Timer
$script:UpdateHoursMs = [int]([Math]::Min([Math]::Max([double]$script:Config.UpdateHours, 0.5), 168) * 3600 * 1000)
$script:updateTimer.Interval = $script:UpdateHoursMs
$script:updateTimer.Add_Tick({
    try {
        if ($script:IsGitCheckout) { return }
        if (-not $script:MnuAutoUpdate.Checked) { return }
        if ($script:UpdatePending) { return }
        $script:LastUpdateCheck = Get-Date
        if (Invoke-SelfUpdate -Silent) {
            $script:UpdatePending = $true
            $script:btnRestartNow.Visible = $true
            Write-Event 'UPDATE    : new version downloaded - click "RESTART to apply update"'
        }
    } catch { Write-Event "ERR update: $($_.Exception.Message)" }
})

# ---------------------------------------------------------------------------
#  Wire up / start
# ---------------------------------------------------------------------------
$script:btnAck        = $btnAck
$script:MnuTop        = $miTop
$script:MnuAutoUpdate = $miAuto
$script:btnRestartNow = $btnRestartNow
$script:txtSearch     = $txtSearch
$script:Version       = Get-LocalScriptVersion
$form.Text = "GCL Ping Monitor  -  v:$($script:Version)"

function Show-MainWindow {
    # Launched with "-WindowStyle Hidden" (so no black console box appears) the
    # process start info carries SW_HIDE, and WinForms applies it to the FIRST
    # top-level window - the form comes up invisible while everything else runs
    # normally. Force it visible explicitly.
    try {
        $form.WindowState   = [System.Windows.Forms.FormWindowState]::Normal
        $form.ShowInTaskbar = $true
        $form.Visible       = $true
        [void][Win32.Native]::ShowWindowAsync($form.Handle, 5)   # SW_SHOW
        $form.BringToFront()
        $form.Activate()
        [void][Win32.Native]::SetForegroundWindow($form.Handle)
    } catch { }
}

$form.Add_Resize({ Update-Responsive })
$form.Add_ResizeEnd({ Update-Responsive; Save-Config })

$form.Add_Shown({
    $script:FormReady = $true
    Show-MainWindow
    Apply-TextSize $script:TextSize
    Apply-SplitPercent
    Update-Responsive
    Rebuild-Grid
    Refresh-Banner
    Refresh-Status
    Write-Event ("MONITOR   : started - v:{0} - {1} host(s) loaded" -f $script:Version, $script:Hosts.Count)
    $script:checkTimer.Start()
    $script:uiTimer.Start()
    $script:AlarmTimer.Start()
    $script:notifyTimer.Start()
    if (-not $script:IsGitCheckout) { $script:updateTimer.Start() }
    if ([bool]$script:Config.Web.Enabled) { Start-WebServer }
    Start-CheckCycle
})

$form.Add_FormClosing({
    try {
        $script:checkTimer.Stop(); $script:uiTimer.Stop(); $script:AlarmTimer.Stop()
        $script:updateTimer.Stop(); $script:notifyTimer.Stop()
        try { Stop-WebServer } catch { }
        try { Send-QueuedNotifications } catch { }
        Stop-Alarm
        Save-Config
        Write-Event 'MONITOR   : stopped'
    } catch { }
    try { if ($script:ShowEvent) { $script:ShowEvent.Close() } } catch { }
    try { if ($script:HaveMutex -and $script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
})

[void][System.Windows.Forms.Application]::Run($form)

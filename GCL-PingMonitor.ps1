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
if ($null -eq $script:Config.Notify) {
    $script:Config | Add-Member -NotePropertyName Notify -NotePropertyValue ([pscustomobject]@{}) -Force
}
$n = $script:Config.Notify
Set-Default $n 'OnDown'       $true
Set-Default $n 'OnRecover'    $true
Set-Default $n 'BatchSeconds' 20
Set-Default $n 'MaxPerHour'   20
Set-Default $n 'Email'    ([pscustomobject]@{})
Set-Default $n 'Telegram' ([pscustomobject]@{})
Set-Default $n 'Sms'      ([pscustomobject]@{})
Set-Default $n.Email 'Enabled' $false; Set-Default $n.Email 'SmtpServer' ''; Set-Default $n.Email 'Port' 587
Set-Default $n.Email 'UseSsl'  $true;  Set-Default $n.Email 'User' '';       Set-Default $n.Email 'PassEnc' ''
Set-Default $n.Email 'From' '';        Set-Default $n.Email 'To' ''
Set-Default $n.Telegram 'Enabled' $false; Set-Default $n.Telegram 'TokenEnc' ''; Set-Default $n.Telegram 'ChatId' ''
Set-Default $n.Sms 'Enabled' $false;   Set-Default $n.Sms 'Numbers' ''
Set-Default $n.Sms 'UrlTemplate' 'https://YOUR-SMS-GATEWAY/api/sendsms?api_key={apikey}&msisdn={phone}&message={message}'
Set-Default $n.Sms 'Method' 'GET';     Set-Default $n.Sms 'BodyTemplate' ''
Set-Default $n.Sms 'ContentType' 'application/x-www-form-urlencoded'
Set-Default $n.Sms 'ApiKeyEnc' ''

# ---------------------------------------------------------------------------
#  Runtime state
# ---------------------------------------------------------------------------
$script:Hosts        = New-Object System.Collections.Generic.List[object]
$script:CycleRunning = $false
$script:Paused       = $false
$script:LastCheck    = $null
$script:AlarmActive  = $false

function New-HostState {
    param($Label, $Target, $Enabled = $true)
    [pscustomobject]@{
        Label      = $Label
        Target     = $Target
        Enabled    = [bool]$Enabled
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
    if ($h.Hist.Count -eq 0) { return $null }
    [int][Math]::Round(($h.Lost * 100.0) / $h.Hist.Count)
}

function Reset-HostStats {
    param($h)
    $h.Hist.Clear(); $h.LastRtts.Clear()
    $h.Lost = 0; $h.TotSent = 0; $h.TotLost = 0
}

foreach ($c in @($script:Config.Hosts)) {
    if ($c -and $c.Target) {
        $en = if ($null -eq $c.Enabled) { $true } else { [bool]$c.Enabled }
        $h  = New-HostState -Label ([string]$c.Label) -Target ([string]$c.Target) -Enabled $en
        if (-not $en) { $h.Status = 'OFF' }
        $script:Hosts.Add($h)
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
        $script:Config.Hosts = @($script:Hosts | ForEach-Object {
            [pscustomobject]@{ Label = $_.Label; Target = $_.Target; Enabled = [bool]$_.Enabled }
        })
        $script:Config | ConvertTo-Json -Depth 5 | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
#  Ping cycle (fully async - all hosts fire concurrently, UI never blocks)
# ---------------------------------------------------------------------------
function Start-CheckCycle {
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

$script:AlarmActive = $false

# NOTE: do NOT wrap this filter in a function. Returning an array from a
# PowerShell function is a minefield: a 1-element result gets unrolled to a
# scalar (.Count -> $null, alarm never fires for a single down host), and the
# usual ",@(...)" workaround makes an EMPTY result come back as Count 1 once
# the caller re-wraps it (alarm fires when nothing is down). Assigning
# "@( ... | Where-Object ... )" inline is correct for 0, 1 and N.

function Play-Alarm {
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
    $n = $script:Config.Notify
    ($n.Email.Enabled -or $n.Telegram.Enabled -or $n.Sms.Enabled)
}

function Add-Notification {
    param([ValidateSet('DOWN','UP')][string]$Kind, $Host_)
    $n = $script:Config.Notify
    if (-not (Test-NotifyEnabled)) { return }
    if ($Kind -eq 'DOWN' -and -not $n.OnDown)    { return }
    if ($Kind -eq 'UP'   -and -not $n.OnRecover) { return }
    [void]$script:NotifyQueue.Add([pscustomobject]@{
        Kind = $Kind; Label = $Host_.Label; Target = $Host_.Target; Time = Get-Date
    })
}

$script:NotifySender = {
    param($LogPath, $Subject, $BodyLong, $BodyShort, $Cfg)
    function Log($m) {
        for ($i = 0; $i -lt 5; $i++) {
            try { Add-Content -Path $LogPath -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8; return }
            catch { Start-Sleep -Milliseconds 120 }
        }
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch { }

    if ($Cfg.EmailEnabled) {
        try {
            $msg = New-Object System.Net.Mail.MailMessage
            $msg.From = New-Object System.Net.Mail.MailAddress($Cfg.EmailFrom)
            $any = $false
            foreach ($to in ($Cfg.EmailTo -split '[;,]')) { if ($to.Trim()) { $msg.To.Add($to.Trim()); $any = $true } }
            if (-not $any) { throw 'no recipient address' }
            $msg.Subject = $Subject
            $msg.Body    = $BodyLong
            $cli = New-Object System.Net.Mail.SmtpClient($Cfg.EmailServer, [int]$Cfg.EmailPort)
            $cli.EnableSsl = [bool]$Cfg.EmailSsl
            $cli.Timeout   = 25000
            if ($Cfg.EmailUser) {
                $cli.UseDefaultCredentials = $false
                $cli.Credential = New-Object System.Net.NetworkCredential($Cfg.EmailUser, $Cfg.EmailPass)
            }
            $cli.Send($msg)
            $msg.Dispose(); $cli.Dispose()
            Log ('NOTIFY    : email sent to {0}' -f $Cfg.EmailTo)
        } catch { Log ('NOTIFY err: email - {0}' -f $_.Exception.Message) }
    }

    if ($Cfg.TgEnabled) {
        try {
            $uri  = 'https://api.telegram.org/bot{0}/sendMessage' -f $Cfg.TgToken
            $body = @{ chat_id = $Cfg.TgChat; text = $BodyLong; disable_web_page_preview = 'true' }
            $null = Invoke-WebRequest -Uri $uri -Method Post -Body $body -UseBasicParsing -TimeoutSec 25
            Log ('NOTIFY    : telegram sent to chat {0}' -f $Cfg.TgChat)
        } catch { Log ('NOTIFY err: telegram - {0}' -f $_.Exception.Message) }
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
}

function Send-Notification {
    param([string]$Subject, [string]$BodyLong, [string]$BodyShort)
    $n = $script:Config.Notify
    $cfg = @{
        EmailEnabled = [bool]$n.Email.Enabled
        EmailServer  = [string]$n.Email.SmtpServer
        EmailPort    = [int]$n.Email.Port
        EmailSsl     = [bool]$n.Email.UseSsl
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
    }
    try {
        $ps = [PowerShell]::Create()
        [void]$ps.AddScript($script:NotifySender)
        [void]$ps.AddArgument($script:LogPath)
        [void]$ps.AddArgument($Subject)
        [void]$ps.AddArgument($BodyLong)
        [void]$ps.AddArgument($BodyShort)
        [void]$ps.AddArgument($cfg)
        [void]$ps.BeginInvoke()
    } catch {
        Write-Event ("NOTIFY err: could not start sender - {0}" -f $_.Exception.Message)
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
    $subject = if ($downs.Count -gt 0) { 'GCL Ping Monitor: {0} DOWN' -f $downs.Count }
               else                    { 'GCL Ping Monitor: {0} recovered' -f $ups.Count }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('GCL Ping Monitor  ({0})' -f $where))
    [void]$sb.AppendLine((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    if ($downs.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('DOWN ({0}):' -f $downs.Count))
        foreach ($d in $downs) { [void]$sb.AppendLine(('  {0}  [{1}]' -f $d.Label, $d.Target)) }
    }
    if ($ups.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine(('RECOVERED ({0}):' -f $ups.Count))
        foreach ($u in $ups) { [void]$sb.AppendLine(('  {0}  [{1}]' -f $u.Label, $u.Target)) }
    }
    $long = $sb.ToString()

    $parts = @()
    if ($downs.Count -gt 0) { $parts += ('DOWN: ' + (($downs | ForEach-Object { $_.Label }) -join ', ')) }
    if ($ups.Count   -gt 0) { $parts += ('UP: '   + (($ups   | ForEach-Object { $_.Label }) -join ', ')) }
    $short = ('[{0}] ' -f $where) + ($parts -join ' | ')
    if ($short.Length -gt 300) { $short = $short.Substring(0, 297) + '...' }

    Write-Event ('NOTIFY    : sending ({0} down, {1} up)' -f $downs.Count, $ups.Count)
    Send-Notification -Subject $subject -BodyLong $long -BodyShort $short
}

function Stop-Alarm {
    # MUST be called when the alarm turns off. Play() is asynchronous - without
    # an explicit Stop() the last-started sound keeps going after Acknowledge.
    try { if ($script:Player) { $script:Player.Stop() } } catch { }
}

function Update-Alarm {
    $down   = @($script:Hosts | Where-Object { $_.Enabled -and $_.Status -eq 'DOWN' -and -not $_.Acked })
    $active = $down.Count -gt 0
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
        $src = if ($script:Player) { Split-Path $script:AlarmWavPath -Leaf } else { 'system sound' }
        Write-Event ("ALARM     : ON  ({0} host(s) down, sound={1})" -f $down.Count, $src)
        Play-Alarm
    } else {
        Stop-Alarm
        Write-Event 'ALARM     : off'
    }
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
$miEdit    = New-Mnu '&Edit selected...'
$miToggle  = New-Mnu '&Disable / Enable selected'
$miRemove  = New-Mnu '&Remove selected'
$miExit    = New-Mnu 'E&xit'
[void]$mFile.DropDownItems.AddRange(@($miAdd, $miEdit, $miToggle, $miRemove, (New-Sep), $miExit))

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
$miExport  = New-Mnu '&Export hosts + settings...'
$miImport  = New-Mnu '&Import hosts + settings...'
$miAuto    = New-Mnu 'Auto-&update' -Checkable -Checked:([bool]$script:Config.AutoUpdate)
$miUpdate  = New-Mnu '&Check for updates now'
[void]$mSet.DropDownItems.AddRange(@($miNotify, (New-Sep), $miExport, $miImport, (New-Sep), $miAuto, $miUpdate))

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

$txtLabel  = New-Txt 13
$txtTarget = New-Txt 14
$btnAdd    = New-Btn 'Add'

$txtSearch      = New-Txt 14
$btnClearSearch = New-Btn 'x'

$btnAck  = New-Btn 'ACKNOWLEDGE' -Strong
$btnAck.Enabled = $false
$btnAck.ToolTipText = 'Silence the alarm (a NEW host going down re-arms it)'

$btnPause = New-Btn 'Pause'

# becomes visible only after a newer version has been downloaded in the background
$btnRestartNow = New-Btn 'RESTART to apply update' -Strong
$btnRestartNow.Visible   = $false
$btnRestartNow.BackColor = [System.Drawing.Color]::Gold

# these must never disappear into the ">>" overflow, however narrow the window:
# acknowledging an alarm you cannot see the button for is the whole problem
$btnAck.Overflow        = 'Never'
$btnPause.Overflow      = 'Never'
$btnRestartNow.Overflow = 'Never'

[void]$panelTop.Items.AddRange(@(
    (New-Lbl 'Name:'), $txtLabel,
    (New-Lbl 'IP / host:'), $txtTarget, $btnAdd,
    (New-TSep),
    (New-Lbl 'Search:'), $txtSearch, $btnClearSearch,
    (New-TSep),
    $btnAck, $btnPause, $btnRestartNow
))

# Edit / Disable / Remove live on the right-click menu and the Hosts menu -
# keeping them off the toolbar is what lets it stay on a single line.
$ctx = New-Object System.Windows.Forms.ContextMenuStrip
$ctx.Font = UiFont
$cmEdit   = New-Mnu '&Edit host...'
$cmToggle = New-Mnu '&Disable / Enable'
$cmRemove = New-Mnu '&Remove'
$cmAck    = New-Mnu '&Acknowledge alarm'
[void]$ctx.Items.AddRange(@($cmEdit, $cmToggle, $cmRemove, (New-Sep), $cmAck))

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
$null = $grid.Columns.Add('cLabel',  'Name')
$null = $grid.Columns.Add('cTarget', 'IP / Host')
$null = $grid.Columns.Add('cStatus', 'Status')
$null = $grid.Columns.Add('cLat',    'Latency')
$null = $grid.Columns.Add('cLoss',   'Loss %')
$null = $grid.Columns.Add('cSince',  'Since')
$null = $grid.Columns.Add('cDown',   'Down for')
# Fill mode refuses to shrink a column below its MinimumWidth, and the default is
# wide enough to push the last column off the right edge in a small window
foreach ($c in $grid.Columns) { $c.MinimumWidth = 26 }
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

    foreach ($t in @($txtLabel, $txtTarget, $txtSearch)) {
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
            if ($tier -ge 4) { $hide += 'cLat'    }
            foreach ($c in $grid.Columns) { $c.Visible = ($hide -notcontains $c.Name) }

            # short headers + a different share of the width once space is tight:
            # "Latency" as a header is wider than any value it ever shows
            if ($tier -ge 2) {
                $grid.Columns['cTarget'].HeaderText = 'IP'
                $grid.Columns['cLat'].HeaderText    = 'ms'
                $grid.Columns['cLoss'].HeaderText   = 'Loss'
                $grid.Columns['cLabel'].FillWeight  = 132
                $grid.Columns['cTarget'].FillWeight = 96
                $grid.Columns['cStatus'].FillWeight = 64
                $grid.Columns['cLat'].FillWeight    = 60
                $grid.Columns['cLoss'].FillWeight   = 58
            } else {
                $grid.Columns['cTarget'].HeaderText = 'IP / Host'
                $grid.Columns['cLat'].HeaderText    = 'Latency'
                $grid.Columns['cLoss'].HeaderText   = 'Loss %'
                $grid.Columns['cLabel'].FillWeight  = 130
                $grid.Columns['cTarget'].FillWeight = 120
                $grid.Columns['cStatus'].FillWeight = 80
                $grid.Columns['cLat'].FillWeight    = 62
                $grid.Columns['cLoss'].FillWeight   = 62
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
        $i = $grid.Rows.Add(@($h.Label, $h.Target, '', '', '', '', ''))
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

        if (-not $h.Enabled) {
            $statusText = 'DISABLED'
            $bg = $colOffBg; $fg = $colOffFg; $bold = $false
        } else {
            switch ($h.Status) {
                'UP'   { $statusText = 'UP';           $bg = $colUpBg;   $fg = $colUpFg;   $bold = $false }
                'WARN' { $statusText = 'checking...';  $bg = $colWarnBg; $fg = $colWarnFg; $bold = $false }
                'DOWN' {
                    if ($h.Acked) { $statusText = 'DOWN (ack)'; $bg = $colAckBg;  $fg = $colAckFg;  $bold = $true }
                    else          { $statusText = 'DOWN';       $bg = $colDownBg; $fg = $colDownFg; $bold = $true }
                }
                default { $statusText = '-';           $bg = $colInitBg; $fg = $colInitFg; $bold = $false }
            }
        }

        $row.Cells['cStatus'].Value = $statusText
        # in a narrow window the header already says "ms" - the suffix would only
        # push a 3-digit latency out of the column
        $row.Cells['cLat'].Value    = if ($h.Enabled -and $h.Status -eq 'UP' -and $null -ne $h.Latency) {
            if ($script:RespTier -ge 2) { "$($h.Latency)" } else { "$($h.Latency) ms" }
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
    $active  = @($script:Hosts | Where-Object { $_.Enabled })
    $down    = @($active | Where-Object { $_.Status -eq 'DOWN' })
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

function Refresh-Status {
    $active = @($script:Hosts | Where-Object { $_.Enabled })
    $up   = @($active | Where-Object { $_.Status -eq 'UP' }).Count
    $down = @($active | Where-Object { $_.Status -eq 'DOWN' }).Count
    $oth  = $active.Count - $up - $down
    $off  = $script:Hosts.Count - $active.Count
    $shown = $grid.Rows.Count
    $filter = if ($shown -ne $script:Hosts.Count) { ("    |    showing {0} of {1}" -f $shown, $script:Hosts.Count) } else { '' }
    if ($script:RespTier -ge 2) {
        # a narrow window gets the short form - a clipped status bar tells nobody anything
        $lblCounts.Text = ('UP {0}  DOWN {1}  off {2}{3}' -f `
            $up, $down, $off, $(if ($script:Paused) { '  [PAUSED]' } else { '' }))
    } else {
        $lblCounts.Text = ('UP: {0}    DOWN: {1}    other: {2}    disabled: {3}    |    every {4}s{5}{6}' -f `
            $up, $down, $oth, $off, [int]$script:Config.IntervalSeconds, $(if ($script:Paused) { '   [PAUSED]' } else { '' }), $filter)
    }
    $upd = if ($script:UpdatePending) { '  |  update ready - restart' }
           elseif ($script:LastUpdateCheck) { '  |  upd chk ' + $script:LastUpdateCheck.ToString('HH:mm') }
           else { '' }
    $lblClock.Text = $(if ($script:LastCheck) { 'last check ' + $script:LastCheck.ToString('HH:mm:ss') } else { 'no check yet' }) + $upd
}

# ---------------------------------------------------------------------------
#  Handlers
# ---------------------------------------------------------------------------
function Add-Host {
    $target = $txtTarget.Text.Trim()
    if (-not $target) { return }
    $label = $txtLabel.Text.Trim()
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
    $txtLabel.Clear(); $txtTarget.Clear(); $txtTarget.Focus()
    $script:CycleRunning = $false
    Start-CheckCycle
}

$btnAdd.Add_Click({ Add-Host })
$txtTarget.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Add-Host } })
$txtLabel.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; $txtTarget.Focus() } })

# ---- Edit / modify a host ----------------------------------------------------
function Show-HostDialog {
    param([string]$Name, [string]$Target)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Edit host'
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
    $ok.Text = 'Save'; $ok.DialogResult = 'OK'
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

function Toggle-SelectedHosts {
    $sel = Get-SelectedHosts
    if ($sel.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Select one or more hosts first.', 'Enable / disable', 'OK', 'Information') | Out-Null
        return
    }
    foreach ($h in $sel) {
        $h.Enabled = -not $h.Enabled
        $h.StyleKey = ''
        $h.FailCount = 0; $h.Acked = $false
        $h.DownSince = $null; $h.Latency = $null; $h.LastChange = Get-Date
        if ($h.Enabled) {
            $h.Status = 'INIT'
            Reset-HostStats $h            # loss % from before the outage is meaningless
            Write-Event ("ENABLED   : {0} [{1}]" -f $h.Label, $h.Target)
        } else {
            $h.Status = 'OFF'
            $h.Task = $null; $h.Ping = $null
            Write-Event ("DISABLED  : {0} [{1}] - not monitored, no alarm" -f $h.Label, $h.Target)
        }
    }
    Save-Config; Rebuild-Grid; Update-Alarm; Refresh-Banner
    $script:CycleRunning = $false
    Start-CheckCycle
}

function Remove-SelectedHosts {
    $sel = Get-SelectedHosts
    if ($sel.Count -eq 0) { return }
    $msg = if ($sel.Count -eq 1) { "Remove '$($sel[0].Label)'?" } else { "Remove $($sel.Count) hosts?" }
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Confirm', 'YesNo', 'Question') -ne 'Yes') { return }
    foreach ($h in $sel) {
        $script:Hosts.Remove($h) | Out-Null
        Write-Event ("REMOVED   : {0} [{1}]" -f $h.Label, $h.Target)
    }
    Save-Config; Rebuild-Grid; Update-Alarm; Refresh-Banner
}

function Confirm-Alarm {
    $down = @($script:Hosts | Where-Object { $_.Enabled -and $_.Status -eq 'DOWN' -and -not $_.Acked })
    if ($down.Count -eq 0) { return }
    foreach ($h in $down) { $h.Acked = $true; $h.StyleKey = '' }
    Write-Event ("ACK       : alarm acknowledged ({0} host(s) still down)" -f $down.Count)
    Update-Alarm; Refresh-Grid; Refresh-Banner
}

function Toggle-Pause {
    $script:Paused = -not $script:Paused
    $btnPause.Text = if ($script:Paused) { 'Resume' } else { 'Pause' }
    $miPause.Text  = if ($script:Paused) { '&Resume monitoring' } else { '&Pause monitoring' }
    Write-Event ('MONITOR   : {0}' -f $(if ($script:Paused) { 'paused' } else { 'resumed' }))
    if (-not $script:Paused) { Start-CheckCycle }
    Refresh-Banner; Refresh-Status
}

$cmEdit.Add_Click({ Edit-SelectedHost })
$cmToggle.Add_Click({ Toggle-SelectedHosts })
$cmRemove.Add_Click({ Remove-SelectedHosts })
$cmAck.Add_Click({ Confirm-Alarm })

# ---- Notification settings dialog -------------------------------------------
$miNotify.Add_Click({
    $n = $script:Config.Notify
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Notifications - email / Telegram / SMS'
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 52), [int]($s * 40))

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(10, 10)
    $tabs.Size = New-Object System.Drawing.Size([int]($s * 52 - 20), [int]($s * 36))
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
    $gInfo = New-Object System.Windows.Forms.Label
    $gInfo.Text = "Events inside the batch window are combined into ONE message," + [Environment]::NewLine +
                  "so a link failure taking many hosts down does not fire many SMS." + [Environment]::NewLine + [Environment]::NewLine +
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
    $mSsl  = NChk $pMail 'Use SSL / TLS' $n.Email.UseSsl
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

    # ---------- buttons ----------
    $bTest = New-Object System.Windows.Forms.Button
    $bTest.Text = 'Send test'
    $bTest.Location = New-Object System.Drawing.Point(10, [int]($s * 36.6))
    $bTest.Size = New-Object System.Drawing.Size([int]($s*9), [int]($s*2.6))
    $bOk = New-Object System.Windows.Forms.Button
    $bOk.Text = 'Save'; $bOk.DialogResult = 'OK'
    $bOk.Location = New-Object System.Drawing.Point([int]($s*35), [int]($s * 36.6))
    $bOk.Size = New-Object System.Drawing.Size([int]($s*7.5), [int]($s*2.6))
    $bCancel = New-Object System.Windows.Forms.Button
    $bCancel.Text = 'Cancel'; $bCancel.DialogResult = 'Cancel'
    $bCancel.Location = New-Object System.Drawing.Point([int]($s*43), [int]($s * 36.6))
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

        $n.Email.Enabled    = [bool]$mEn.Checked
        $n.Email.SmtpServer = $mSrv.Text.Trim()
        $n.Email.Port       = [int]$mPort.Value
        $n.Email.UseSsl     = [bool]$mSsl.Checked
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
    }

    $bTest.Add_Click({
        & $apply
        if (-not (Test-NotifyEnabled)) {
            [System.Windows.Forms.MessageBox]::Show('Enable at least one channel first.', 'Send test', 'OK', 'Information') | Out-Null
            return
        }
        Send-Notification -Subject 'GCL Ping Monitor - test' `
            -BodyLong  ("This is a test from GCL Ping Monitor on {0}.`r`n{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) `
            -BodyShort ("[{0}] GCL Ping Monitor test message" -f $env:COMPUTERNAME)
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
        Write-Event ('NOTIFY    : settings saved - channels: {0}' -f $(if ($on.Count) { $on -join ', ' } else { 'none' }))
    }
    $dlg.Dispose()
})
$grid.Add_CellDoubleClick({ if ($_.RowIndex -ge 0) { Edit-SelectedHost } })

# ---- Search ------------------------------------------------------------------
$txtSearch.Add_TextChanged({ Refresh-Grid; Refresh-Status })
$txtSearch.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $_.SuppressKeyPress = $true; $txtSearch.Clear() } })
$btnClearSearch.Add_Click({ $txtSearch.Clear(); $txtSearch.Focus() })

$btnAck.Add_Click({ Confirm-Alarm })
$btnPause.Add_Click({ Toggle-Pause })

function Test-AlarmSound {
    Play-Alarm
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

function Show-AlarmSoundDialog {
    $s = $script:TextSize
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Alarm sound'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition = 'CenterParent'
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = UiFont
    $dlg.ClientSize = New-Object System.Drawing.Size([int]($s * 38), [int]($s * 30))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = 'Sound played while a host is down:'
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
    $list.Size = New-Object System.Drawing.Size([int]($s * 35.6), [int]($s * 18))
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
    $btnPlay.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 21.2))
    $btnPlay.Size = New-Object System.Drawing.Size([int]($s * 6.5), [int]($s * 2.6))
    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = 'Stop'
    $btnStop.Location = New-Object System.Drawing.Point([int]($s * 8.2), [int]($s * 21.2))
    $btnStop.Size = New-Object System.Drawing.Size([int]($s * 6.5), [int]($s * 2.6))
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Use my own .wav...'
    $btnBrowse.Location = New-Object System.Drawing.Point([int]($s * 15.2), [int]($s * 21.2))
    $btnBrowse.Size = New-Object System.Drawing.Size([int]($s * 21.6), [int]($s * 2.6))
    $dlg.Controls.AddRange(@($btnPlay, $btnStop, $btnBrowse))

    $lblRep = New-Object System.Windows.Forms.Label
    $lblRep.Text = 'Repeat every'
    $lblRep.AutoSize = $true
    $lblRep.Location = New-Object System.Drawing.Point([int]($s * 1.2), [int]($s * 24.9))
    $nRep = New-Object System.Windows.Forms.NumericUpDown
    $nRep.DecimalPlaces = 1; $nRep.Increment = 0.5
    $nRep.Minimum = 0.5; $nRep.Maximum = 60
    $nRep.Location = New-Object System.Drawing.Point([int]($s * 10), [int]($s * 24.5))
    $nRep.Width = [int]($s * 5)
    $repSec = [Math]::Round(([double][int]$script:Config.AlarmRepeatMs) / 1000.0, 1)
    if ($repSec -lt 0.5) { $repSec = 1.4 }; if ($repSec -gt 60) { $repSec = 60 }
    $nRep.Value = [decimal]$repSec
    $lblRep2 = New-Object System.Windows.Forms.Label
    $lblRep2.Text = 'seconds between repeats'
    $lblRep2.AutoSize = $true
    $lblRep2.ForeColor = [System.Drawing.Color]::FromArgb(110, 114, 120)
    $lblRep2.Location = New-Object System.Drawing.Point([int]($s * 15.6), [int]($s * 24.9))
    $dlg.Controls.AddRange(@($lblRep, $nRep, $lblRep2))

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Save'; $ok.DialogResult = 'OK'
    $ok.Location = New-Object System.Drawing.Point([int]($s * 21.2), [int]($s * 27))
    $ok.Size = New-Object System.Drawing.Size([int]($s * 7.5), [int]($s * 2.6))
    $cn = New-Object System.Windows.Forms.Button
    $cn.Text = 'Cancel'; $cn.DialogResult = 'Cancel'
    $cn.Location = New-Object System.Drawing.Point([int]($s * 29.2), [int]($s * 27))
    $cn.Size = New-Object System.Drawing.Size([int]($s * 7.5), [int]($s * 2.6))
    $dlg.Controls.AddRange(@($ok, $cn))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cn

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
        $script:Config.AlarmSound    = $sel.Key
        $script:Config.AlarmFile     = [string]$sel.File
        $script:Config.AlarmRepeatMs = [int]([double]$nRep.Value * 1000)

        # a live alarm must not be left playing the old sound
        $wasOn = $script:AlarmActive
        Stop-Alarm
        Set-AlarmPlayer (Resolve-AlarmSound)
        $script:AlarmTimer.Interval = [Math]::Max([int]$script:Config.AlarmRepeatMs, 500)
        if ($wasOn) { Play-Alarm }
        Save-Config
        Write-Event ('ALARM     : sound set to "{0}" ({1}), repeat every {2}s' -f `
            $sel.Text, (Split-Path $script:AlarmWavPath -Leaf), $nRep.Value)
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
        foreach ($p in 'IntervalSeconds','TimeoutMs','FailThreshold','AlwaysOnTop','AutoUpdate','UpdateHours','TextSize','LossWindow','SplitPercent','AlarmSound','AlarmFile','AlarmRepeatMs') {
            if ($null -ne $cfg.$p) { $script:Config.$p = $cfg.$p }
        }
        if ($cfg.Notify) { $script:Config.Notify = $cfg.Notify }
        $script:Hosts.Clear()
        foreach ($c in $incoming) {
            $en = if ($null -eq $c.Enabled) { $true } else { [bool]$c.Enabled }
            $h  = New-HostState -Label ([string]$c.Label) -Target ([string]$c.Target) -Enabled $en
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
        $script:AlarmTimer.Interval = [Math]::Min([Math]::Max([int]$script:Config.AlarmRepeatMs, 500), 60000)
        Apply-TextSize ([int]$script:Config.TextSize)
        Write-Event ('BACKUP    : imported {0} host(s) + settings (replaced) from {1}' -f $added, $dlg.FileName)
    }
    else {
        $added = 0
        foreach ($c in $incoming) {
            $t = [string]$c.Target
            if (@($script:Hosts | Where-Object { $_.Target -eq $t }).Count -gt 0) { continue }
            $en = if ($null -eq $c.Enabled) { $true } else { [bool]$c.Enabled }
            $h  = New-HostState -Label ([string]$c.Label) -Target $t -Enabled $en
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
$miAdd.Add_Click({ $txtLabel.Focus() })
$miEdit.Add_Click({ Edit-SelectedHost })
$miToggle.Add_Click({ Toggle-SelectedHosts })
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
    } catch { Write-Event "ERR ui: $($_.Exception.Message)" }
})

$script:AlarmTimer = New-Object System.Windows.Forms.Timer
$script:AlarmTimer.Interval = [Math]::Min([Math]::Max([int]$script:Config.AlarmRepeatMs, 500), 60000)
$script:AlarmTimer.Add_Tick({
    if ($script:AlarmActive) {
        Play-Alarm
        try {
            if (-not $form.ContainsFocus) { [Win32.Native]::FlashWindow($form.Handle, $true) }
        } catch { }
    }
})

$script:notifyTimer = New-Object System.Windows.Forms.Timer
$script:notifyTimer.Interval = [Math]::Max([int]$script:Config.Notify.BatchSeconds, 5) * 1000
$script:notifyTimer.Add_Tick({
    try { Send-QueuedNotifications } catch { Write-Event "ERR notify: $($_.Exception.Message)" }
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
    Start-CheckCycle
    if ($script:Hosts.Count -eq 0) { $txtTarget.Focus() }
})

$form.Add_FormClosing({
    try {
        $script:checkTimer.Stop(); $script:uiTimer.Stop(); $script:AlarmTimer.Stop()
        $script:updateTimer.Stop(); $script:notifyTimer.Stop()
        try { Send-QueuedNotifications } catch { }
        Stop-Alarm
        Save-Config
        Write-Event 'MONITOR   : stopped'
    } catch { }
    try { if ($script:ShowEvent) { $script:ShowEvent.Close() } } catch { }
    try { if ($script:HaveMutex -and $script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
})

[void][System.Windows.Forms.Application]::Run($form)

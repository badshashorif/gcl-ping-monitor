#Requires -Version 5.1
<#
    GCL Ping Monitor
    ----------------
    Simple Windows desktop ping monitor for the support desk.
      * Add / remove hosts from the GUI (saved automatically)
      * Every host is pinged on an interval; grid turns RED when a host is down
      * A looping alarm sounds while any un-acknowledged host is down
      * "Acknowledge" silences the current alarm; a NEW host going down re-arms it
      * All state changes are written to an event log

    Config + log location:  %APPDATA%\GCL-PingMonitor\

    Run it with:  Start-PingMonitor.cmd   (or  powershell -STA -ExecutionPolicy Bypass -File GCL-PingMonitor.ps1)
#>

param(
    [int]$IntervalSeconds = 5,
    [int]$TimeoutMs       = 1000,
    [int]$FailThreshold   = 2,
    [switch]$NoUpdate                # skip the GitHub self-update check
)

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
    Add-Type -Namespace Win32 -Name Flash -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool FlashWindow(IntPtr hwnd, bool bInvert);
'@
} catch { }

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
        Hosts           = @()
    }
}
foreach ($p in 'IntervalSeconds','TimeoutMs','FailThreshold','AlwaysOnTop','AutoUpdate','UpdateHours','Hosts') {
    if ($null -eq $script:Config.$p) {
        $def = switch ($p) { 'IntervalSeconds' {$IntervalSeconds} 'TimeoutMs' {$TimeoutMs} 'FailThreshold' {$FailThreshold} 'AlwaysOnTop' {$false} 'AutoUpdate' {$true} 'UpdateHours' {6} 'Hosts' {@()} }
        $script:Config | Add-Member -NotePropertyName $p -NotePropertyValue $def -Force
    }
}

# ---------------------------------------------------------------------------
#  Runtime state
# ---------------------------------------------------------------------------
$script:Hosts        = New-Object System.Collections.Generic.List[object]
$script:CycleRunning = $false
$script:Paused       = $false
$script:LastCheck    = $null
$script:AlarmActive  = $false

function New-HostState {
    param($Label, $Target)
    [pscustomobject]@{
        Label      = $Label
        Target     = $Target
        Status     = 'INIT'      # INIT | UP | WARN | DOWN
        Latency    = $null
        LastChange = $null
        DownSince  = $null
        Acked      = $false
        FailCount  = 0
        Task       = $null
        Ping       = $null
        SyncError  = $null
    }
}

foreach ($c in @($script:Config.Hosts)) {
    if ($c -and $c.Target) { $script:Hosts.Add((New-HostState -Label ([string]$c.Label) -Target ([string]$c.Target))) }
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
#  * Compares each tracked file against raw.githubusercontent.com and rewrites
#    only the ones that differ. Any push to the repo is picked up automatically
#    (nothing to version-bump).
#  * A dev checkout (folder has a .git) is left alone so local edits survive.
#  * Startup: if files changed, the script relaunches itself so new code runs
#    immediately. While running: a background check downloads updates and shows
#    a "restart to apply" bar instead of yanking the window away mid-incident.

function Get-LocalScriptVersion {
    try { (Get-FileHash -Path $script:ScriptPath -Algorithm SHA1).Hash.Substring(0, 7).ToLower() } catch { '???????' }
}

function Invoke-SelfUpdate {
    param([switch]$Silent)
    if ($script:IsGitCheckout) { return $false }
    if (-not $script:ScriptDir) { return $false }
    $base = "https://raw.githubusercontent.com/$($script:Repo)/$($script:Branch)/"
    $changed = $false
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch { }
    foreach ($name in $script:UpdateFiles) {
        try {
            $resp = Invoke-WebRequest -Uri ($base + $name + '?_=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) `
                        -UseBasicParsing -TimeoutSec 8 -Headers @{ 'Cache-Control' = 'no-cache'; 'Pragma' = 'no-cache' }
        } catch {
            # network problem / offline / rate-limited - abort cleanly, retry later
            if (-not $Silent) { Write-Event ("UPDATE err : {0} ({1})" -f $name, $_.Exception.Message) }
            return $false
        }
        if ($resp.StatusCode -ne 200) { return $false }
        $remote = [string]$resp.Content
        $dest   = Join-Path $script:ScriptDir $name
        $local  = if (Test-Path $dest) { [System.IO.File]::ReadAllText($dest) } else { $null }
        if ($remote -ne $local) {
            try {
                [System.IO.File]::WriteAllText($dest, $remote, (New-Object System.Text.UTF8Encoding($false)))
                $changed = $true
                Write-Event ("UPDATE    : refreshed {0}" -f $name)
            } catch {
                if (-not $Silent) { Write-Event ("UPDATE err : cannot write {0} ({1})" -f $name, $_.Exception.Message) }
            }
        }
    }
    return $changed
}

# ---- run the check once at startup, before the GUI is built ----
if (-not $NoUpdate -and -not $script:IsGitCheckout -and $env:GCLPM_CHILD -ne '1' -and $script:Config.AutoUpdate) {
    try {
        if (Invoke-SelfUpdate -Silent) {
            $env:GCLPM_CHILD = '1'
            $child = Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $script:ScriptPath)
            )
            Start-Sleep -Milliseconds 1800
            if ($child -and -not $child.HasExited) {
                exit                                  # new version is up - hand over
            }
            # the freshly-pulled version failed to start - keep running the code
            # already loaded in this process so monitoring is not interrupted
            $env:GCLPM_CHILD = $null
            Write-Event 'UPDATE err : new version did not start - keeping the running version'
        }
    } catch { }
}

function Save-Config {
    try {
        $script:Config.IntervalSeconds = [int]$script:numInterval.Value
        $script:Config.TimeoutMs       = [int]$script:numTimeout.Value
        $script:Config.FailThreshold   = [int]$script:numThreshold.Value
        $script:Config.AlwaysOnTop     = [bool]$script:chkTop.Checked
        if ($script:chkAutoUpdate) { $script:Config.AutoUpdate = [bool]$script:chkAutoUpdate.Checked }
        $script:Config.Hosts = @($script:Hosts | ForEach-Object { [pscustomobject]@{ Label = $_.Label; Target = $_.Target } })
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

    if ($ok) {
        $h.Latency = $rtt
        if ($h.Status -in 'DOWN','INIT','WARN') {
            $prev = $h.Status
            $h.Status     = 'UP'
            $h.LastChange = Get-Date
            if ($prev -eq 'DOWN') {
                $dur = if ($h.DownSince) { Format-Duration ((Get-Date) - $h.DownSince) } else { '?' }
                Write-Event ("RECOVERED : {0} [{1}] - was down {2}" -f $h.Label, $h.Target, $dur)
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
#  We generate our OWN alarm.wav (a loud two-tone siren) so the alarm never
#  depends on the Windows sound scheme - which on a lot of machines is set to
#  "No Sounds", which is why SystemSounds / MessageBeep can be silent.
#  The sound is (re)started on a short timer while the alarm is active, rather
#  than PlayLooping(), because a re-triggered Play() is self-healing.

function New-AlarmWav {
    param([string]$Path)
    try {
        $sr = 16000
        $segments = @(
            @{ F = 880;  Ms = 260 },
            @{ F = 0;    Ms = 80  },
            @{ F = 1245; Ms = 260 },
            @{ F = 0;    Ms = 240 }
        )
        $mem = New-Object System.IO.MemoryStream
        foreach ($seg in $segments) {
            $n = [int]($sr * $seg.Ms / 1000)
            $fade = [int]($sr * 0.008)
            for ($i = 0; $i -lt $n; $i++) {
                $amp = 0
                if ($seg.F -gt 0) {
                    $e = 1.0
                    if ($i -lt $fade) { $e = $i / $fade }
                    elseif ($i -gt ($n - $fade)) { $e = ($n - $i) / $fade }
                    $amp = [int][math]::Round([math]::Sin(2 * [math]::PI * $seg.F * $i / $sr) * 27000 * $e)
                }
                $bytes = [System.BitConverter]::GetBytes([int16]$amp)
                $mem.Write($bytes, 0, 2)
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

$script:AlarmWavPath = Join-Path $script:AppDir 'alarm.wav'
if (-not (Test-Path $script:AlarmWavPath)) { [void](New-AlarmWav -Path $script:AlarmWavPath) }
if (-not (Test-Path $script:AlarmWavPath)) {
    $script:AlarmWavPath = @(
        (Join-Path $env:WINDIR 'Media\Alarm01.wav'),
        (Join-Path $env:WINDIR 'Media\Ring06.wav'),
        (Join-Path $env:WINDIR 'Media\notify.wav')
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

$script:Player = $null
try {
    if ($script:AlarmWavPath -and (Test-Path $script:AlarmWavPath)) {
        $script:Player = New-Object System.Media.SoundPlayer $script:AlarmWavPath
        $script:Player.Load()
    }
} catch { $script:Player = $null }

$script:AlarmActive = $false

function Get-AlarmHosts {
    @($script:Hosts | Where-Object { $_.Status -eq 'DOWN' -and -not $_.Acked })
}

function Play-Alarm {
    try { if ($script:Player) { $script:Player.Play(); return } } catch { }
    try { [System.Media.SystemSounds]::Hand.Play() } catch { }
}

function Update-Alarm {
    $active = (Get-AlarmHosts).Count -gt 0
    if ($script:btnAck) { $script:btnAck.Enabled = $active }
    if ($active -eq $script:AlarmActive) { return }
    $script:AlarmActive = $active
    if ($active) {
        $src = if ($script:Player) { Split-Path $script:AlarmWavPath -Leaf } else { 'system sound' }
        Write-Event ("ALARM     : ON  ({0} down, sound={1})" -f (Get-AlarmHosts).Count, $src)
        Play-Alarm
    } else {
        Write-Event 'ALARM     : off'
    }
}

# ---------------------------------------------------------------------------
#  UI
# ---------------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'GCL Ping Monitor'
$form.Size          = New-Object System.Drawing.Size(940, 640)
$form.MinimumSize   = New-Object System.Drawing.Size(760, 480)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
$form.TopMost       = [bool]$script:Config.AlwaysOnTop

# ---- Banner ----
$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Dock      = 'Top'
$lblBanner.Height    = 44
$lblBanner.TextAlign = 'MiddleCenter'
$lblBanner.Font      = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblBanner.ForeColor = [System.Drawing.Color]::White
$lblBanner.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$lblBanner.Text      = 'Starting...'
$form.Controls.Add($lblBanner)

# ---- Toolbar ----
$panelTop = New-Object System.Windows.Forms.FlowLayoutPanel
$panelTop.Dock          = 'Top'
$panelTop.Height        = 78
$panelTop.Padding       = New-Object System.Windows.Forms.Padding(8, 6, 8, 4)
$panelTop.WrapContents   = $true
$panelTop.AutoScroll     = $true
$form.Controls.Add($panelTop)

function New-Lbl($text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(6, 8, 2, 0)
    $l
}

$txtLabel = New-Object System.Windows.Forms.TextBox
$txtLabel.Width = 130
$txtLabel.Margin = New-Object System.Windows.Forms.Padding(2, 5, 4, 0)
# placeholder-ish
$txtLabel.Text = ''

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Width = 150
$txtTarget.Margin = New-Object System.Windows.Forms.Padding(2, 5, 4, 0)

$btnAdd = New-Object System.Windows.Forms.Button
$btnAdd.Text = 'Add host'
$btnAdd.Width = 78
$btnAdd.Margin = New-Object System.Windows.Forms.Padding(2, 4, 10, 0)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = 'Remove selected'
$btnRemove.Width = 120
$btnRemove.Margin = New-Object System.Windows.Forms.Padding(2, 4, 10, 0)

$btnAck = New-Object System.Windows.Forms.Button
$btnAck.Text = 'Acknowledge alarm'
$btnAck.Width = 140
$btnAck.Height = 30
$btnAck.Enabled = $false
$btnAck.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnAck.Margin = New-Object System.Windows.Forms.Padding(2, 3, 10, 0)

$btnPause = New-Object System.Windows.Forms.Button
$btnPause.Text = 'Pause'
$btnPause.Width = 70
$btnPause.Margin = New-Object System.Windows.Forms.Padding(2, 4, 10, 0)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = 'Test sound'
$btnTest.Width = 80
$btnTest.Margin = New-Object System.Windows.Forms.Padding(2, 4, 10, 0)

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Minimum = 2; $numInterval.Maximum = 3600; $numInterval.Width = 55
$numInterval.Value = [Math]::Min([Math]::Max([int]$script:Config.IntervalSeconds,2),3600)
$numInterval.Margin = New-Object System.Windows.Forms.Padding(2, 5, 4, 0)

$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Minimum = 200; $numTimeout.Maximum = 10000; $numTimeout.Increment = 100; $numTimeout.Width = 65
$numTimeout.Value = [Math]::Min([Math]::Max([int]$script:Config.TimeoutMs,200),10000)
$numTimeout.Margin = New-Object System.Windows.Forms.Padding(2, 5, 4, 0)

$numThreshold = New-Object System.Windows.Forms.NumericUpDown
$numThreshold.Minimum = 1; $numThreshold.Maximum = 10; $numThreshold.Width = 45
$numThreshold.Value = [Math]::Min([Math]::Max([int]$script:Config.FailThreshold,1),10)
$numThreshold.Margin = New-Object System.Windows.Forms.Padding(2, 5, 4, 0)

$chkTop = New-Object System.Windows.Forms.CheckBox
$chkTop.Text = 'Always on top'
$chkTop.AutoSize = $true
$chkTop.Checked = [bool]$script:Config.AlwaysOnTop
$chkTop.Margin = New-Object System.Windows.Forms.Padding(6, 7, 4, 0)

$chkAutoUpdate = New-Object System.Windows.Forms.CheckBox
$chkAutoUpdate.Text = 'Auto-update'
$chkAutoUpdate.AutoSize = $true
$chkAutoUpdate.Checked = [bool]$script:Config.AutoUpdate
$chkAutoUpdate.Margin = New-Object System.Windows.Forms.Padding(6, 7, 4, 0)

$btnUpdate = New-Object System.Windows.Forms.Button
$btnUpdate.Text = 'Check for updates'
$btnUpdate.Width = 120
$btnUpdate.Margin = New-Object System.Windows.Forms.Padding(2, 4, 10, 0)

# becomes visible only after a newer version has been downloaded in the background
$btnRestartNow = New-Object System.Windows.Forms.Button
$btnRestartNow.Text = 'RESTART to apply update'
$btnRestartNow.Width = 170
$btnRestartNow.Height = 30
$btnRestartNow.Visible = $false
$btnRestartNow.BackColor = [System.Drawing.Color]::Gold
$btnRestartNow.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnRestartNow.Margin = New-Object System.Windows.Forms.Padding(2, 3, 10, 0)

if ($script:IsGitCheckout) { $chkAutoUpdate.Enabled = $false; $btnUpdate.Enabled = $false; $chkAutoUpdate.Text = 'Auto-update (dev checkout - off)' }

$panelTop.Controls.AddRange(@(
    (New-Lbl 'Name:'), $txtLabel,
    (New-Lbl 'IP / host:'), $txtTarget, $btnAdd, $btnRemove,
    $btnAck, $btnPause, $btnTest,
    (New-Lbl 'Interval s:'), $numInterval,
    (New-Lbl 'Timeout ms:'), $numTimeout,
    (New-Lbl 'Fails->down:'), $numThreshold,
    $chkTop, $chkAutoUpdate, $btnUpdate, $btnRestartNow
))

# ---- Split: grid on top, log on bottom ----
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
$split.SplitterDistance = 340
$form.Controls.Add($split)
$split.BringToFront()

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
$grid.EnableHeadersVisualStyles = $false
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$grid.AllowUserToOrderColumns = $true
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.RowTemplate.Height = 26
$null = $grid.Columns.Add('cLabel',  'Name')
$null = $grid.Columns.Add('cTarget', 'IP / Host')
$null = $grid.Columns.Add('cStatus', 'Status')
$null = $grid.Columns.Add('cLat',    'Latency')
$null = $grid.Columns.Add('cSince',  'Since')
$null = $grid.Columns.Add('cDown',   'Down for')
$grid.Columns['cStatus'].FillWeight = 70
$grid.Columns['cLat'].FillWeight    = 60
$grid.Columns['cSince'].FillWeight  = 90
$grid.Columns['cDown'].FillWeight   = 70
$split.Panel1.Controls.Add($grid)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Dock = 'Fill'
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:txtLog = $txtLog
$split.Panel2.Controls.Add($txtLog)

# ---- Status bar ----
$status = New-Object System.Windows.Forms.StatusStrip
$lblCounts = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblCounts.Spring = $true
$lblCounts.TextAlign = 'MiddleLeft'
$lblClock = New-Object System.Windows.Forms.ToolStripStatusLabel
$status.Items.AddRange(@($lblCounts, $lblClock))
$form.Controls.Add($status)

# ---------------------------------------------------------------------------
#  Grid refresh
# ---------------------------------------------------------------------------
function Rebuild-Grid {
    $grid.Rows.Clear()
    foreach ($h in $script:Hosts) {
        $i = $grid.Rows.Add(@($h.Label, $h.Target, $h.Status, '', '', ''))
        $grid.Rows[$i].Tag = $h
    }
    Refresh-Grid
}

$colDown  = [System.Drawing.Color]::FromArgb(255, 200, 200)
$colUp    = [System.Drawing.Color]::FromArgb(210, 240, 210)
$colWarn  = [System.Drawing.Color]::FromArgb(255, 235, 170)
$colInit  = [System.Drawing.Color]::FromArgb(238, 238, 238)

function Refresh-Grid {
    foreach ($row in $grid.Rows) {
        $h = $row.Tag
        if (-not $h) { continue }
        $row.Cells['cLabel'].Value  = $h.Label
        $row.Cells['cTarget'].Value = $h.Target
        $statusText = switch ($h.Status) {
            'UP'   { 'UP' }
            'DOWN' { if ($h.Acked) { 'DOWN (ack)' } else { 'DOWN' } }
            'WARN' { 'checking...' }
            default { '-' }
        }
        $row.Cells['cStatus'].Value = $statusText
        $row.Cells['cLat'].Value    = if ($h.Status -eq 'UP' -and $null -ne $h.Latency) { "$($h.Latency) ms" } else { '' }
        $row.Cells['cSince'].Value  = if ($h.LastChange) { $h.LastChange.ToString('MM-dd HH:mm:ss') } else { '' }
        $row.Cells['cDown'].Value   = if ($h.Status -eq 'DOWN' -and $h.DownSince) { Format-Duration ((Get-Date) - $h.DownSince) } else { '' }
        $c = switch ($h.Status) { 'DOWN' { $colDown } 'UP' { $colUp } 'WARN' { $colWarn } default { $colInit } }
        if ($row.DefaultCellStyle.BackColor -ne $c) { $row.DefaultCellStyle.BackColor = $c }
    }
}

function Refresh-Banner {
    $down = @($script:Hosts | Where-Object { $_.Status -eq 'DOWN' })
    $unacked = @($down | Where-Object { -not $_.Acked })
    if ($down.Count -gt 0) {
        $names = ($down | Select-Object -First 6 | ForEach-Object { $_.Label }) -join ', '
        if ($down.Count -gt 6) { $names += ' ...' }
        $lblBanner.Text = ('{0} HOST(S) DOWN  -  {1}' -f $down.Count, $names)
        $lblBanner.BackColor = if ($unacked.Count -gt 0) { [System.Drawing.Color]::FromArgb(200, 30, 30) } else { [System.Drawing.Color]::FromArgb(180, 120, 0) }
    }
    elseif ($script:Hosts.Count -eq 0) {
        $lblBanner.Text = 'No hosts yet - add an IP or hostname above'
        $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    }
    elseif ($script:Paused) {
        $lblBanner.Text = 'PAUSED'
        $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    }
    else {
        $lblBanner.Text = ('All {0} host(s) UP' -f $script:Hosts.Count)
        $lblBanner.BackColor = [System.Drawing.Color]::FromArgb(40, 140, 60)
    }
}

function Refresh-Status {
    $up   = @($script:Hosts | Where-Object { $_.Status -eq 'UP' }).Count
    $down = @($script:Hosts | Where-Object { $_.Status -eq 'DOWN' }).Count
    $oth  = $script:Hosts.Count - $up - $down
    $lblCounts.Text = ('UP: {0}    DOWN: {1}    other: {2}    |    checking every {3}s{4}' -f `
        $up, $down, $oth, [int]$script:numInterval.Value, $(if ($script:Paused) { '   [PAUSED]' } else { '' }))
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

$btnRemove.Add_Click({
    $sel = @($grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
    if ($sel.Count -eq 0) { return }
    $msg = if ($sel.Count -eq 1) { "Remove '$($sel[0].Label)'?" } else { "Remove $($sel.Count) hosts?" }
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Confirm', 'YesNo', 'Question') -ne 'Yes') { return }
    foreach ($h in $sel) {
        $script:Hosts.Remove($h) | Out-Null
        Write-Event ("REMOVED   : {0} [{1}]" -f $h.Label, $h.Target)
    }
    Save-Config
    Rebuild-Grid
    Update-Alarm
    Refresh-Banner
})

$btnAck.Add_Click({
    $down = Get-AlarmHosts
    if ($down.Count -eq 0) { return }
    foreach ($h in $down) { $h.Acked = $true }
    Write-Event ("ACK       : alarm acknowledged ({0} host(s) still down)" -f $down.Count)
    Update-Alarm
    Refresh-Grid
    Refresh-Banner
})

$btnPause.Add_Click({
    $script:Paused = -not $script:Paused
    $btnPause.Text = if ($script:Paused) { 'Resume' } else { 'Pause' }
    Write-Event ('MONITOR   : {0}' -f $(if ($script:Paused) { 'paused' } else { 'resumed' }))
    if (-not $script:Paused) { Start-CheckCycle }
    Refresh-Banner
    Refresh-Status
})

$btnTest.Add_Click({
    Play-Alarm
    $src = if ($script:Player) { Split-Path $script:AlarmWavPath -Leaf } else { 'system sound (Windows sounds may be off!)' }
    Write-Event ("TEST      : played alarm - source: {0}" -f $src)
})

$numInterval.Add_ValueChanged({ $script:checkTimer.Interval = [int]$numInterval.Value * 1000; Save-Config; Refresh-Status })
$numTimeout.Add_ValueChanged({ Save-Config })
$numThreshold.Add_ValueChanged({ Save-Config })
$chkTop.Add_CheckedChanged({ $form.TopMost = $chkTop.Checked; Save-Config })
$chkAutoUpdate.Add_CheckedChanged({ Save-Config })

function Restart-Self {
    try { Save-Config } catch { }
    [Environment]::SetEnvironmentVariable('GCLPM_CHILD', $null)   # let the fresh instance re-check
    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $script:ScriptPath)
    ) | Out-Null
    $script:AllowClose = $true
    $form.Close()
}

$btnRestartNow.Add_Click({ Restart-Self })

$btnUpdate.Add_Click({
    $btnUpdate.Enabled = $false
    $old = $btnUpdate.Text
    $btnUpdate.Text = 'Checking...'
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
    } finally {
        $btnUpdate.Text = $old
        $btnUpdate.Enabled = $true
    }
})

# ---------------------------------------------------------------------------
#  Timers
# ---------------------------------------------------------------------------
$script:checkTimer = New-Object System.Windows.Forms.Timer
$script:checkTimer.Interval = [Math]::Max([int]$numInterval.Value,2) * 1000
$script:checkTimer.Add_Tick({ try { Start-CheckCycle } catch { Write-Event "ERR check: $($_.Exception.Message)" } })

$script:uiTimer = New-Object System.Windows.Forms.Timer
$script:uiTimer.Interval = 400
$script:uiTimer.Add_Tick({
    try {
        Poll-Results
        Refresh-Grid
        Update-Alarm
        Refresh-Banner
        Refresh-Status
    } catch { Write-Event "ERR ui: $($_.Exception.Message)" }
})

$script:AlarmTimer = New-Object System.Windows.Forms.Timer
$script:AlarmTimer.Interval = 1400
$script:AlarmTimer.Add_Tick({
    if ($script:AlarmActive) {
        Play-Alarm
        try {
            if (-not $form.ContainsFocus) { [Win32.Flash]::FlashWindow($form.Handle, $true) }
        } catch { }
    }
})

# background self-update check while the app is running
$script:updateTimer = New-Object System.Windows.Forms.Timer
$script:UpdateHoursMs = [int]([Math]::Min([Math]::Max([double]$script:Config.UpdateHours, 0.5), 168) * 3600 * 1000)
$script:updateTimer.Interval = $script:UpdateHoursMs
$script:updateTimer.Add_Tick({
    try {
        if ($script:IsGitCheckout) { return }
        if (-not $script:chkAutoUpdate.Checked) { return }
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
$script:numInterval   = $numInterval
$script:numTimeout    = $numTimeout
$script:numThreshold  = $numThreshold
$script:chkTop        = $chkTop
$script:btnAck        = $btnAck
$script:chkAutoUpdate = $chkAutoUpdate
$script:btnRestartNow = $btnRestartNow
$script:Version       = Get-LocalScriptVersion
$form.Text = "GCL Ping Monitor  -  v:$($script:Version)"

$form.Add_Shown({
    Rebuild-Grid
    Refresh-Banner
    Refresh-Status
    Write-Event ("MONITOR   : started - v:{0} - {1} host(s) loaded" -f $script:Version, $script:Hosts.Count)
    $script:checkTimer.Start()
    $script:uiTimer.Start()
    $script:AlarmTimer.Start()
    if (-not $script:IsGitCheckout) { $script:updateTimer.Start() }
    Start-CheckCycle
    if ($script:Hosts.Count -eq 0) { $txtTarget.Focus() }
})

$form.Add_FormClosing({
    try {
        $script:checkTimer.Stop(); $script:uiTimer.Stop(); $script:AlarmTimer.Stop(); $script:updateTimer.Stop()
        if ($script:Player) { try { $script:Player.Stop() } catch { } }
        Save-Config
        Write-Event 'MONITOR   : stopped'
    } catch { }
})

[void][System.Windows.Forms.Application]::Run($form)

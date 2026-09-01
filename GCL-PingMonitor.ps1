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
if (-not $script:HaveMutex) {
    # bring the window that is already running to the front, then quit quietly
    try {
        $other = Get-Process -Name 'powershell' -ErrorAction SilentlyContinue |
                 Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -like 'GCL Ping Monitor*' } |
                 Select-Object -First 1
        if ($other) {
            [void][Win32.Native]::ShowWindowAsync($other.MainWindowHandle, 9)   # SW_RESTORE
            [void][Win32.Native]::SetForegroundWindow($other.MainWindowHandle)
        }
    } catch { }
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
foreach ($p in 'IntervalSeconds','TimeoutMs','FailThreshold','AlwaysOnTop','AutoUpdate','UpdateHours','TextSize','Hosts') {
    if ($null -eq $script:Config.$p) {
        $def = switch ($p) { 'IntervalSeconds' {$IntervalSeconds} 'TimeoutMs' {$TimeoutMs} 'FailThreshold' {$FailThreshold} 'AlwaysOnTop' {$false} 'AutoUpdate' {$true} 'UpdateHours' {6} 'TextSize' {12} 'Hosts' {@()} }
        $script:Config | Add-Member -NotePropertyName $p -NotePropertyValue $def -Force
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
    }
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
        $script:Config.IntervalSeconds = [int]$script:numInterval.Value
        $script:Config.TimeoutMs       = [int]$script:numTimeout.Value
        $script:Config.FailThreshold   = [int]$script:numThreshold.Value
        $script:Config.AlwaysOnTop     = [bool]$script:chkTop.Checked
        if ($script:chkAutoUpdate) { $script:Config.AutoUpdate = [bool]$script:chkAutoUpdate.Checked }
        if ($script:TextSize)      { $script:Config.TextSize   = [int]$script:TextSize }
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
    if ($script:btnAck) { $script:btnAck.Enabled = $active }
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
$form.MinimumSize   = New-Object System.Drawing.Size(820, 520)
$form.StartPosition = 'CenterScreen'
$form.Font          = UiFont
$form.TopMost       = [bool]$script:Config.AlwaysOnTop
$form.BackColor     = [System.Drawing.Color]::FromArgb(245, 246, 248)

# ---- Banner: the thing you read from across the room ----
$lblBanner = New-Object System.Windows.Forms.Label
$lblBanner.Dock      = 'Top'
$lblBanner.TextAlign = 'MiddleCenter'
$lblBanner.ForeColor = [System.Drawing.Color]::White
$lblBanner.BackColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$lblBanner.Text      = 'Starting...'
$form.Controls.Add($lblBanner)

# ---- Toolbar ----
$panelTop = New-Object System.Windows.Forms.FlowLayoutPanel
$panelTop.Dock         = 'Top'
$panelTop.Padding      = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
$panelTop.WrapContents = $true
$panelTop.AutoScroll   = $true
$panelTop.BackColor    = [System.Drawing.Color]::FromArgb(238, 240, 244)
$form.Controls.Add($panelTop)

$script:UiLabels = New-Object System.Collections.Generic.List[object]
function New-Lbl($text) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(8, 9, 2, 0)
    $script:UiLabels.Add($l)
    $l
}
function New-Btn($text, $w, [switch]$Strong) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.AutoSize = $false
    $b.Width  = $w
    $b.Margin = New-Object System.Windows.Forms.Padding(3, 3, 8, 3)
    $b.FlatStyle = 'System'
    if ($Strong) { $b.Font = UiFont -Bold }
    $b
}

$txtLabel  = New-Object System.Windows.Forms.TextBox
$txtLabel.Margin = New-Object System.Windows.Forms.Padding(2, 5, 6, 0)

$txtTarget = New-Object System.Windows.Forms.TextBox
$txtTarget.Margin = New-Object System.Windows.Forms.Padding(2, 5, 6, 0)

$btnAdd    = New-Btn 'Add'              70
$btnEdit   = New-Btn 'Edit'             70
$btnToggle = New-Btn 'Disable / Enable' 150
$btnRemove = New-Btn 'Remove'           90

$txtSearch = New-Object System.Windows.Forms.TextBox
$txtSearch.Margin = New-Object System.Windows.Forms.Padding(2, 5, 6, 0)

$btnClearSearch = New-Btn 'x' 34

$btnAck  = New-Btn 'ACKNOWLEDGE ALARM' 210 -Strong
$btnAck.Enabled = $false

$btnPause = New-Btn 'Pause'      90
$btnTest  = New-Btn 'Test sound' 110

$numInterval = New-Object System.Windows.Forms.NumericUpDown
$numInterval.Minimum = 2; $numInterval.Maximum = 3600
$numInterval.Value = [Math]::Min([Math]::Max([int]$script:Config.IntervalSeconds,2),3600)
$numInterval.Margin = New-Object System.Windows.Forms.Padding(2, 5, 6, 0)

$numTimeout = New-Object System.Windows.Forms.NumericUpDown
$numTimeout.Minimum = 200; $numTimeout.Maximum = 10000; $numTimeout.Increment = 100
$numTimeout.Value = [Math]::Min([Math]::Max([int]$script:Config.TimeoutMs,200),10000)
$numTimeout.Margin = New-Object System.Windows.Forms.Padding(2, 5, 6, 0)

$numThreshold = New-Object System.Windows.Forms.NumericUpDown
$numThreshold.Minimum = 1; $numThreshold.Maximum = 10
$numThreshold.Value = [Math]::Min([Math]::Max([int]$script:Config.FailThreshold,1),10)
$numThreshold.Margin = New-Object System.Windows.Forms.Padding(2, 5, 6, 0)

$cboSize = New-Object System.Windows.Forms.ComboBox
$cboSize.DropDownStyle = 'DropDownList'
$cboSize.Margin = New-Object System.Windows.Forms.Padding(2, 5, 6, 0)
[void]$cboSize.Items.AddRange(@('Small', 'Normal', 'Large', 'Extra large', 'TV'))
# NOTE: not a switch - a PowerShell switch runs EVERY matching clause, so
# overlapping "-le" conditions would return an array, not an index.
$script:SizeMap = @(9, 12, 15, 18, 22)
$idx = 1
for ($i = 0; $i -lt $script:SizeMap.Count; $i++) { if ($script:TextSize -le $script:SizeMap[$i]) { $idx = $i; break } }
if ($script:TextSize -gt $script:SizeMap[-1]) { $idx = $script:SizeMap.Count - 1 }
$cboSize.SelectedIndex = $idx

$chkTop = New-Object System.Windows.Forms.CheckBox
$chkTop.Text = 'Always on top'; $chkTop.AutoSize = $true
$chkTop.Checked = [bool]$script:Config.AlwaysOnTop
$chkTop.Margin = New-Object System.Windows.Forms.Padding(10, 8, 6, 0)

$chkAutoUpdate = New-Object System.Windows.Forms.CheckBox
$chkAutoUpdate.Text = 'Auto-update'; $chkAutoUpdate.AutoSize = $true
$chkAutoUpdate.Checked = [bool]$script:Config.AutoUpdate
$chkAutoUpdate.Margin = New-Object System.Windows.Forms.Padding(10, 8, 6, 0)

$btnNotify = New-Btn 'Notifications...' 150
$btnUpdate = New-Btn 'Check for updates' 160

# becomes visible only after a newer version has been downloaded in the background
$btnRestartNow = New-Btn 'RESTART to apply update' 230 -Strong
$btnRestartNow.Visible   = $false
$btnRestartNow.BackColor = [System.Drawing.Color]::Gold

if ($script:IsGitCheckout) { $chkAutoUpdate.Enabled = $false; $btnUpdate.Enabled = $false; $chkAutoUpdate.Text = 'Auto-update (dev checkout - off)' }

$panelTop.Controls.AddRange(@(
    (New-Lbl 'Name:'), $txtLabel,
    (New-Lbl 'IP / host:'), $txtTarget,
    $btnAdd, $btnEdit, $btnToggle, $btnRemove,
    (New-Lbl 'Search:'), $txtSearch, $btnClearSearch,
    $btnAck, $btnPause, $btnTest,
    (New-Lbl 'Interval s:'), $numInterval,
    (New-Lbl 'Timeout ms:'), $numTimeout,
    (New-Lbl 'Fails->down:'), $numThreshold,
    (New-Lbl 'Text:'), $cboSize,
    $chkTop, $chkAutoUpdate, $btnNotify, $btnUpdate, $btnRestartNow
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
$null = $grid.Columns.Add('cSince',  'Since')
$null = $grid.Columns.Add('cDown',   'Down for')
$grid.Columns['cLabel'].FillWeight  = 130
$grid.Columns['cTarget'].FillWeight = 120
$grid.Columns['cStatus'].FillWeight = 80
$grid.Columns['cLat'].FillWeight    = 60
$grid.Columns['cSince'].FillWeight  = 90
$grid.Columns['cDown'].FillWeight   = 70
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
    $lblBanner.Font   = UiFont 1.75 -Bold
    $lblBanner.Height = [int]($s * 3.4)
    $panelTop.Height  = [int]($s * 8.0)

    $txtLabel.Width  = [int]($s * 13)
    $txtTarget.Width = [int]($s * 14)
    $txtSearch.Width = [int]($s * 14)
    foreach ($n in @($numInterval, $numTimeout, $numThreshold)) { $n.Width = [int]($s * 6.5) }
    $cboSize.Width = [int]($s * 11)

    $btnAck.Font        = UiFont -Bold
    $btnRestartNow.Font = UiFont -Bold
    foreach ($b in @($btnAdd, $btnEdit, $btnToggle, $btnRemove, $btnClearSearch, $btnAck,
                     $btnPause, $btnTest, $btnNotify, $btnUpdate, $btnRestartNow)) {
        $b.Height = [int]($s * 2.6)
    }

    $grid.ColumnHeadersDefaultCellStyle.Font = UiFont 1.0 -Bold
    $grid.ColumnHeadersHeight = [int]($s * 2.8)
    $grid.DefaultCellStyle.Font = UiFont
    $grid.RowTemplate.Height    = [int]($s * 2.5)
    foreach ($r in $grid.Rows) { $r.Height = [int]($s * 2.5) }

    $txtLog.Font = New-Object System.Drawing.Font('Consolas', [single][Math]::Max($s - 2, 8))
    $status.Font = UiFont
    $form.ResumeLayout()
    Refresh-Grid
}

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
        $i = $grid.Rows.Add(@($h.Label, $h.Target, '', '', '', ''))
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
        $row.Cells['cLat'].Value    = if ($h.Enabled -and $h.Status -eq 'UP' -and $null -ne $h.Latency) { "$($h.Latency) ms" } else { '' }
        $row.Cells['cSince'].Value  = if ($h.LastChange) { $h.LastChange.ToString('MM-dd HH:mm:ss') } else { '' }
        $row.Cells['cDown'].Value   = if ($h.Enabled -and $h.Status -eq 'DOWN' -and $h.DownSince) { Format-Duration ((Get-Date) - $h.DownSince) } else { '' }

        $key = "$statusText|$($script:TextSize)"
        if ($h.StyleKey -ne $key) {
            $h.StyleKey = $key
            $row.DefaultCellStyle.BackColor = $bg
            $row.DefaultCellStyle.ForeColor = $fg
            $row.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
            $row.DefaultCellStyle.Font = if ($bold) { UiFont 1.0 -Bold } else { UiFont }
            $row.Height = [int]($script:TextSize * 2.5)
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
    $lblCounts.Text = ('UP: {0}    DOWN: {1}    other: {2}    disabled: {3}    |    every {4}s{5}{6}' -f `
        $up, $down, $oth, $off, [int]$script:numInterval.Value, $(if ($script:Paused) { '   [PAUSED]' } else { '' }), $filter)
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

$btnEdit.Add_Click({ Edit-SelectedHost })

# ---- Notification settings dialog -------------------------------------------
$btnNotify.Add_Click({
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

# ---- Enable / disable --------------------------------------------------------
$btnToggle.Add_Click({
    $sel = @($grid.SelectedRows | ForEach-Object { $_.Tag } | Where-Object { $_ })
    if ($sel.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Select one or more hosts first.', 'Enable / disable', 'OK', 'Information') | Out-Null
        return
    }
    foreach ($h in $sel) {
        $h.Enabled = -not $h.Enabled
        $h.StyleKey = ''
        if ($h.Enabled) {
            $h.Status = 'INIT'; $h.FailCount = 0; $h.Acked = $false
            $h.DownSince = $null; $h.Latency = $null; $h.LastChange = Get-Date
            Write-Event ("ENABLED   : {0} [{1}]" -f $h.Label, $h.Target)
        } else {
            $h.Status = 'OFF'; $h.FailCount = 0; $h.Acked = $false
            $h.DownSince = $null; $h.Latency = $null; $h.LastChange = Get-Date
            $h.Task = $null; $h.Ping = $null
            Write-Event ("DISABLED  : {0} [{1}] - not monitored, no alarm" -f $h.Label, $h.Target)
        }
    }
    Save-Config
    Rebuild-Grid
    Update-Alarm
    Refresh-Banner
    $script:CycleRunning = $false
    Start-CheckCycle
})

# ---- Search ------------------------------------------------------------------
$txtSearch.Add_TextChanged({ Refresh-Grid; Refresh-Status })
$txtSearch.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $_.SuppressKeyPress = $true; $txtSearch.Clear() } })
$btnClearSearch.Add_Click({ $txtSearch.Clear(); $txtSearch.Focus() })

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
    $down = @($script:Hosts | Where-Object { $_.Enabled -and $_.Status -eq 'DOWN' -and -not $_.Acked })
    if ($down.Count -eq 0) { return }
    foreach ($h in $down) { $h.Acked = $true; $h.StyleKey = '' }
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
$cboSize.Add_SelectedIndexChanged({
    Apply-TextSize $script:SizeMap[$cboSize.SelectedIndex]
    Save-Config
    Refresh-Banner
    Refresh-Status
})

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
$script:txtSearch     = $txtSearch
$script:Version       = Get-LocalScriptVersion
$form.Text = "GCL Ping Monitor  -  v:$($script:Version)"

$form.Add_Shown({
    Apply-TextSize $script:TextSize
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
    try { if ($script:HaveMutex -and $script:Mutex) { $script:Mutex.ReleaseMutex(); $script:Mutex.Dispose() } } catch { }
})

[void][System.Windows.Forms.Application]::Run($form)

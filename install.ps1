# GCL Ping Monitor - one-shot installer / updater
# ---------------------------------------------------------------------------
# Run this in Windows PowerShell (no admin needed):
#
#   powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/badshashorif/gcl-ping-monitor/main/install.ps1 | iex"
#
# It installs to  %LOCALAPPDATA%\GCL-PingMonitor , makes a Desktop shortcut and a
# "start with Windows" shortcut, and launches the tool. Run it again any time to
# force an update. Settings/host list (in %APPDATA%) are never touched.
#
# Supported: Windows 10 / 11 and Windows Server 2012 R2 -> 2025
#            (Windows PowerShell 3.0+; 4.0+ recommended - WMF is a free install).
#
# Options (set before running):
#   $env:GCLPM_NOAUTOSTART = 1   -> skip the "start with Windows" shortcut
#   $env:GCLPM_NOLAUNCH    = 1   -> install but don't launch now
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch { }

$Repo   = 'badshashorif/gcl-ping-monitor'
$Branch = 'main'
$Files  = @('GCL-PingMonitor.ps1', 'Start-PingMonitor.cmd', 'install.ps1', 'README.md', 'LICENSE')
$Dest   = Join-Path $env:LOCALAPPDATA 'GCL-PingMonitor'
$Script = Join-Path $Dest 'GCL-PingMonitor.ps1'

function Say($m, $c = 'Gray') { try { Write-Host $m -ForegroundColor $c } catch { Write-Host $m } }

Say ''
Say '  GCL Ping Monitor - installer' Cyan
Say ('  target: {0}' -f $Dest)
Say ''

$isUpdate = Test-Path $Script
$base = "https://raw.githubusercontent.com/$Repo/$Branch/"
Say ('  downloading latest from github.com/{0} ...' -f $Repo)

# download everything first, validate, then write - so a broken web fetch or a
# broken upstream commit can't leave a half-installed folder
$content = @{}
foreach ($name in $Files) {
    $resp = Invoke-WebRequest -Uri ($base + $name) -UseBasicParsing -Headers @{ 'Cache-Control' = 'no-cache' }
    if ($resp.StatusCode -ne 200) { throw "download failed for $name (HTTP $($resp.StatusCode))" }
    $text = [string]$resp.Content
    if ($name -like '*.ps1') {
        $perr = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$perr)
        if ($perr -and $perr.Count) { throw "$name from GitHub has syntax errors - aborting so nothing is overwritten" }
    }
    $content[$name] = $text
}

New-Item -ItemType Directory -Path $Dest -Force | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($name in $Files) {
    [System.IO.File]::WriteAllText((Join-Path $Dest $name), $content[$name], $utf8)
}
Say ('  files {0} in {1}' -f $(if ($isUpdate) { 'updated' } else { 'installed' }), $Dest) Green

# ---- shortcuts ----
$targetArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $Script
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wsh = New-Object -ComObject WScript.Shell

function New-Lnk($path) {
    $s = $wsh.CreateShortcut($path)
    $s.TargetPath       = $psExe
    $s.Arguments        = $targetArgs
    $s.WorkingDirectory = $Dest
    $s.IconLocation     = "$psExe,0"
    $s.Description       = 'Ping monitor with audible down-alarm'
    $s.WindowStyle      = 7
    $s.Save()
}

New-Lnk (Join-Path ([Environment]::GetFolderPath('Desktop')) 'GCL Ping Monitor.lnk')
Say '  Desktop shortcut created' Green

if ($env:GCLPM_NOAUTOSTART -ne '1') {
    New-Lnk (Join-Path ([Environment]::GetFolderPath('Startup')) 'GCL Ping Monitor.lnk')
    Say '  will start automatically with Windows' Green
} else {
    Say '  (skipped start-with-Windows shortcut)'
}

# ---- launch ----
$ErrorActionPreference = 'Continue'
if ($env:GCLPM_NOLAUNCH -ne '1') {
    try {
        $myPid = $PID
        Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $myPid -and $_.CommandLine -like "*-File*$Script*" } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Milliseconds 500
        Start-Process $psExe -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', ('"{0}"' -f $Script)
        )
        Say ''
        Say '  launched. Look for the "GCL Ping Monitor" window.' Green
    } catch {
        Say ''
        Say '  installed OK - start it from the "GCL Ping Monitor" Desktop shortcut.' Yellow
    }
}

Say ''
Say '  to uninstall:  remove the two shortcuts + the folder' DarkGray
Say ('                 {0}' -f $Dest) DarkGray
Say ''

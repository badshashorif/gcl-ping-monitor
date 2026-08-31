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
# Options (set before running):
#   $env:GCLPM_NOAUTOSTART = 1   -> skip the "start with Windows" shortcut
#   $env:GCLPM_NOLAUNCH    = 1   -> install but don't launch now
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls } catch { }

$Repo   = 'badshashorif/gcl-ping-monitor'
$Branch = 'main'
$Dest   = Join-Path $env:LOCALAPPDATA 'GCL-PingMonitor'
$Script = Join-Path $Dest 'GCL-PingMonitor.ps1'
$tmpZip = Join-Path $env:TEMP ('gclpm-' + [Guid]::NewGuid().ToString('N') + '.zip')
$tmpDir = Join-Path $env:TEMP ('gclpm-' + [Guid]::NewGuid().ToString('N'))

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say ''
Say '  GCL Ping Monitor - installer' Cyan
Say ('  target: {0}' -f $Dest)
Say ''

$isUpdate = Test-Path $Script
Say ('  downloading latest from github.com/{0} ...' -f $Repo)
Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $tmpZip -UseBasicParsing
Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
$inner = Get-ChildItem -Path $tmpDir -Directory | Select-Object -First 1
if (-not $inner) { throw 'download looks empty' }

New-Item -ItemType Directory -Path $Dest -Force | Out-Null
Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $Dest -Recurse -Force
Remove-Item -Path $tmpZip, $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
Say ('  files {0} in {1}' -f $(if ($isUpdate) { 'updated' } else { 'installed' }), $Dest) Green

# ---- shortcuts ----
$targetArgs = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $Script
$icon = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
$wsh = New-Object -ComObject WScript.Shell

function New-Lnk($path) {
    $s = $wsh.CreateShortcut($path)
    $s.TargetPath        = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments         = $targetArgs
    $s.WorkingDirectory  = $Dest
    $s.IconLocation      = $icon
    $s.Description        = 'Ping monitor with audible down-alarm'
    $s.WindowStyle        = 7
    $s.Save()
}

$desktop = [Environment]::GetFolderPath('Desktop')
New-Lnk (Join-Path $desktop 'GCL Ping Monitor.lnk')
Say '  Desktop shortcut created' Green

if ($env:GCLPM_NOAUTOSTART -ne '1') {
    $startup = [Environment]::GetFolderPath('Startup')
    New-Lnk (Join-Path $startup 'GCL Ping Monitor.lnk')
    Say '  will start automatically with Windows' Green
} else {
    Say '  (skipped start-with-Windows shortcut)'
}

# ---- launch ----
$ErrorActionPreference = 'Continue'
if ($env:GCLPM_NOLAUNCH -ne '1') {
    try {
        $myPid = $PID
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $myPid -and $_.CommandLine -like "*-File*$Script*" } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch { } }
        Start-Sleep -Milliseconds 500
        Start-Process powershell -WindowStyle Hidden -ArgumentList @(
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

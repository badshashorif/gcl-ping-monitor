# Tests for viewer mode - the part of GCL-PingMonitor.ps1 that turns the
# server's JSON into what this window shows.
#
# The app is one file that builds a WinForms UI on load, so it cannot simply be
# dot-sourced. Instead the functions under test are sliced out by name and
# re-defined here over stubs. That is the same trick the earlier suites used,
# and it is why the functions being tested deliberately touch script-scope
# variables rather than returning collections - see the array-return traps in
# the file's own comments.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ViewerMode.ps1

param([string]$Script = (Join-Path (Split-Path -Parent $PSScriptRoot) 'GCL-PingMonitor.ps1'))

$ErrorActionPreference = 'Stop'
$src = Get-Content -Raw -Path $Script

$script:Failed = 0
$script:Passed = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:Passed++; Write-Host ("  ok   " + $Name) -ForegroundColor DarkGreen }
    else     { $script:Failed++; Write-Host ("  FAIL " + $Name + $(if ($Detail) { " -> $Detail" } else { '' })) -ForegroundColor Red }
}

# ---- lift the functions out of the app -------------------------------------
function Get-FnText {
    param([string]$Name)
    # functions in this file start at column 0 and end with a closing brace at
    # column 0; anchoring on that is what makes the slice unambiguous
    $re = [regex]::new('(?ms)^function\s+' + [regex]::Escape($Name) + '\s*\{.*?^\}', 'Multiline')
    $m = $re.Match($src)
    if (-not $m.Success) { throw "could not find function $Name in $Script" }
    $m.Value
}

# Invoke-Expression has to run HERE, at script scope. Called from inside
# Get-FnText it would define each function in that function's own scope and
# they would all vanish on return - the same scoping trap the app's own comments
# warn about for dialog helpers.
foreach ($fn in 'New-HostState','Get-LossPercent','Add-PingSample','Test-RemoteMode',
                'Get-RemoteBase','ConvertFrom-DurationText','ConvertFrom-ClockText',
                'Set-RemoteFailure','Apply-RemoteSnapshot','Format-Duration') {
    Invoke-Expression (Get-FnText $fn)
}

# ---- stubs ------------------------------------------------------------------
$script:Events   = New-Object System.Collections.ArrayList
$script:UpSounds = 0
$script:Rebuilds = 0
function Write-Event { param([string]$Text) [void]$script:Events.Add($Text) }
function Play-UpSound { $script:UpSounds++ }
function Rebuild-Grid { $script:Rebuilds++ }

function Reset-World {
    param([switch]$RemoteOff)
    $script:Config = [pscustomobject]@{
        LossWindow = 100
        Remote = [pscustomobject]@{
            Enabled = (-not $RemoteOff)
            Url     = 'https://ping.example.net'
            TokenEnc = ''
        }
    }
    $script:Hosts = New-Object System.Collections.Generic.List[object]
    $script:RemoteFails = 0
    $script:RemoteFailLimit = 2
    $script:RemoteError = ''
    $script:RemoteMonitor = ''
    $script:RemoteLastOk = $null
    $script:LastCheck = $null
    $script:Paused = $false
    $script:Events.Clear()
    $script:UpSounds = 0
    $script:Rebuilds = 0
}

function New-Snap {
    param($Hosts, [bool]$Paused = $false)
    [pscustomobject]@{
        v = 1; monitor = 'GCL-MONITOR'; version = '1.0.0'; paused = $Paused
        counts = [pscustomobject]@{ total = @($Hosts).Count; up = 0; down = 0; off = 0 }
        hosts = @($Hosts)
        log = @()
    }
}
function Row {
    param([string]$Label, [string]$Target, [string]$Status = 'UP', $Rtt = 5, $Loss = 0,
          [bool]$Enabled = $true, [bool]$Sound = $true, [bool]$Acked = $false,
          [string]$Since = '', [string]$DownFor = '')
    [pscustomobject]@{
        label = $Label; target = $Target; status = $Status; enabled = $Enabled
        sound = $Sound; acked = $Acked; rtt = $Rtt; loss = $Loss
        since = $Since; downFor = $DownFor
    }
}

Write-Host "`nDuration and clock parsing" -ForegroundColor Cyan
Check 'seconds'        ((ConvertFrom-DurationText '45s') -eq 45)
Check 'minutes+secs'   ((ConvertFrom-DurationText '1m 35s') -eq 95)
Check 'hours+minutes'  ((ConvertFrom-DurationText '1h 2m') -eq 3720)
Check 'days+hours'     ((ConvertFrom-DurationText '2d 4h') -eq 187200)
Check 'zero'           ((ConvertFrom-DurationText '0s') -eq 0)
Check 'empty is null'  ($null -eq (ConvertFrom-DurationText ''))
Check 'junk is null'   ($null -eq (ConvertFrom-DurationText 'ages'))
# every value Format-Duration can produce must survive the round trip, or a
# downtime shown on the phone and one shown here would disagree
$rt = $true
foreach ($secs in 0, 45, 95, 3725, 90000) {
    $text = Format-Duration ([TimeSpan]::FromSeconds($secs))
    if ($null -eq (ConvertFrom-DurationText $text)) { $rt = $false }
}
Check 'round-trips Format-Duration output' $rt

$c = ConvertFrom-ClockText '17:29:10'
Check 'clock parses to today' ($c -ne $null -and $c.Hour -eq 17 -and $c.Minute -eq 29)
Check 'bad clock is null'     ($null -eq (ConvertFrom-ClockText 'nope'))

Write-Host "`nApplying a snapshot" -ForegroundColor Cyan
Reset-World
Apply-RemoteSnapshot (New-Snap @(
    (Row 'RTR'  '10.0.0.1' 'UP'   2  0),
    (Row 'UPS'  '10.0.0.2' 'DOWN' $null 40 -DownFor '1m 35s'),
    (Row 'OLD'  '10.0.0.9' 'OFF'  $null 0 -Enabled $false)))
Check 'all hosts land'        ($script:Hosts.Count -eq 3)
Check 'monitor name recorded' ($script:RemoteMonitor -eq 'GCL-MONITOR')
$rtr = $script:Hosts | Where-Object { $_.Target -eq '10.0.0.1' }
$ups = $script:Hosts | Where-Object { $_.Target -eq '10.0.0.2' }
$old = $script:Hosts | Where-Object { $_.Target -eq '10.0.0.9' }
Check 'UP host keeps its rtt' ($rtr.Status -eq 'UP' -and $rtr.Latency -eq 2)
Check 'DOWN host is DOWN'     ($ups.Status -eq 'DOWN')
Check 'loss comes from the server' ((Get-LossPercent $ups) -eq 40)
Check 'downFor becomes a start time' ($ups.DownSince -ne $null -and
    [Math]::Abs(((Get-Date) - $ups.DownSince).TotalSeconds - 95) -lt 5)
# the window has always shown a not-watched host as Enabled=false and a grey
# row; OFF is the server's word for the same thing
Check 'OFF maps to disabled'  ($old.Enabled -eq $false -and $old.Status -ne 'DOWN')

Write-Host "`nTransitions still make the noise" -ForegroundColor Cyan
Reset-World
Apply-RemoteSnapshot (New-Snap @((Row 'RTR' '10.0.0.1' 'UP' 2)))
$script:Events.Clear()
Apply-RemoteSnapshot (New-Snap @((Row 'RTR' '10.0.0.1' 'DOWN' $null 100 -DownFor '10s')))
Check 'DOWN is logged' (@($script:Events | Where-Object { $_ -match '^DOWN' }).Count -eq 1)
Check 'no up sound on the way down' ($script:UpSounds -eq 0)
$script:Events.Clear()
Apply-RemoteSnapshot (New-Snap @((Row 'RTR' '10.0.0.1' 'UP' 3)))
Check 'RECOVERED is logged' (@($script:Events | Where-Object { $_ -match '^RECOVERED' }).Count -eq 1)
Check 'recovery sound plays once' ($script:UpSounds -eq 1)
Check 'DownSince is cleared' ($null -eq ($script:Hosts[0].DownSince))

Reset-World
Apply-RemoteSnapshot (New-Snap @((Row 'Q' '10.0.0.3' 'DOWN' $null 100 -Sound $false -DownFor '5s')))
$script:UpSounds = 0
Apply-RemoteSnapshot (New-Snap @((Row 'Q' '10.0.0.3' 'UP' 4 -Sound $false)))
Check 'a muted host recovers silently' ($script:UpSounds -eq 0)

Write-Host "`nThe server owns the list" -ForegroundColor Cyan
Reset-World
Apply-RemoteSnapshot (New-Snap @((Row 'A' '10.0.0.1'), (Row 'B' '10.0.0.2')))
Apply-RemoteSnapshot (New-Snap @((Row 'A renamed' '10.0.0.1')))
Check 'removed host disappears' ($script:Hosts.Count -eq 1)
Check 'rename follows the server' ($script:Hosts[0].Label -eq 'A renamed')
Reset-World
Apply-RemoteSnapshot (New-Snap @((Row 'A' '10.0.0.1' 'DOWN' $null 100 -Acked $true -DownFor '30s')))
Check 'ack from a phone silences the desk' ($script:Hosts[0].Acked -eq $true)
Reset-World
Apply-RemoteSnapshot (New-Snap @((Row 'A' '10.0.0.1')) -Paused $true)
Check 'paused follows the server' ($script:Paused -eq $true)

Write-Host "`nLosing contact" -ForegroundColor Cyan
Reset-World
Apply-RemoteSnapshot (New-Snap @((Row 'A' '10.0.0.1' 'UP' 2), (Row 'B' '10.0.0.2' 'UP' 3)))
Set-RemoteFailure 'timeout'
Check 'one failure changes nothing' ($script:Hosts[0].Status -eq 'UP')
Set-RemoteFailure 'timeout'
# the dangerous failure is a board that still says ALL OK over data nobody is
# receiving any more
Check 'two failures blank the board' (@($script:Hosts | Where-Object { $_.Status -eq 'UP' }).Count -eq 0)
Check 'the loss is logged once' (@($script:Events | Where-Object { $_ -match '^REMOTE err' }).Count -eq 1)
$script:Events.Clear()
Apply-RemoteSnapshot (New-Snap @((Row 'A' '10.0.0.1' 'UP' 2), (Row 'B' '10.0.0.2' 'UP' 3)))
Check 'recovery is logged' (@($script:Events | Where-Object { $_ -match 'back in contact' }).Count -eq 1)
Check 'fail counter resets' ($script:RemoteFails -eq 0)
Reset-World
Apply-RemoteSnapshot ([pscustomobject]@{ v = 1 })
Check 'a reply with no hosts is a failure, not an empty board' ($script:RemoteFails -eq 1)

Write-Host "`nMode switch" -ForegroundColor Cyan
Reset-World -RemoteOff
Check 'viewer mode off when disabled' ((Test-RemoteMode) -eq $false)
Reset-World
Check 'viewer mode on when set'       ((Test-RemoteMode) -eq $true)
$script:Config.Remote.Url = ''
Check 'a blank url is not viewer mode' ((Test-RemoteMode) -eq $false)
$script:Config.Remote.Url = 'https://ping.example.net/'
Check 'trailing slash is trimmed'      ((Get-RemoteBase) -eq 'https://ping.example.net')

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host ("{0} passed, {1} FAILED" -f $script:Passed, $script:Failed) -ForegroundColor Red
    exit 1
}
Write-Host ("{0} passed" -f $script:Passed) -ForegroundColor Green
exit 0

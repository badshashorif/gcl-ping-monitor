# GCL Ping Monitor

Windows desktop ping monitor for the support desk. No install, no dependencies —
just Windows PowerShell 5.1 (built into Windows 10/11).

## Download

- **Code → Download ZIP** on the GitHub page, then extract anywhere, **or**
- `git clone https://github.com/badshashorif/gcl-ping-monitor.git`

## Run

Double-click **`Start-PingMonitor.cmd`**.

> First run may show a SmartScreen / "Windows protected your PC" prompt because
> the `.cmd` is unsigned — click **More info → Run anyway**. Or unblock the files:
> right-click each file → Properties → **Unblock**.

Or from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\GCL-PingMonitor.ps1
```

## What it does

- Add / remove hosts (IP or hostname) right in the window — the list is saved automatically.
- Every host is pinged on an interval (default 5s). The row is:
  - **green** = UP (shows latency)
  - **yellow** = missed a ping, still checking
  - **red** = DOWN (after N consecutive fails, default 2)
- While any **un-acknowledged** host is down, a looping alarm sound plays and the
  top banner turns red.
- **Acknowledge alarm** silences the sound. If a *different* host then goes down,
  the alarm re-arms by itself. When a host recovers its ack resets too.
- Every state change (DOWN / RECOVERED / ACK / add / remove) is written to the
  event log, and shown in the black panel at the bottom.

## Settings (top toolbar)

| Field | Meaning |
|-------|---------|
| Interval s | seconds between ping cycles |
| Timeout ms | how long to wait for each reply |
| Fails→down | consecutive failed pings before a host is marked DOWN (flap guard) |
| Always on top | keep the window above other apps |
| Pause / Resume | stop / start pinging without closing |
| Test sound | play the alarm once |

## Files

Config and log live in `%APPDATA%\GCL-PingMonitor\`:

- `config.json` — host list + settings
- `events.log` — full history of up/down events

## Notes

- Runs fully async — all hosts are pinged concurrently, so 50 down hosts do not
  freeze the UI.
- Alarm sound is `C:\Windows\Media\Alarm01.wav` if present, otherwise it falls
  back to the Windows "critical stop" system sound.
- To auto-start with Windows: put a shortcut to `Start-PingMonitor.cmd` in
  `shell:startup`.

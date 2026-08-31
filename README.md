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

## Auto-update

The tool keeps itself current from this GitHub repo — **no re-download needed on
the client machines.**

- On every launch it checks the repo and, if any file changed, pulls the new
  version and restarts itself before the window opens.
- While running it re-checks every few hours (default 6). If a new version is
  found it downloads it in the background and shows a gold **"RESTART to apply
  update"** button — it never closes the window on its own mid-incident.
- **Check for updates** button forces a check now.
- Uncheck **Auto-update** to freeze a machine on its current version.
- Just `git push` your changes to `main` — every installed device picks them up.
  Nothing to version-bump.
- A folder that contains a `.git` (a dev clone) is left alone so local edits are
  never overwritten; auto-update is disabled there.

Requirement: the tool's folder must be user-writable (Desktop / Documents — not
`C:\Program Files`), and the machine needs outbound HTTPS to
`raw.githubusercontent.com`.

## Settings (top toolbar)

| Field | Meaning |
|-------|---------|
| Interval s | seconds between ping cycles |
| Timeout ms | how long to wait for each reply |
| Fails→down | consecutive failed pings before a host is marked DOWN (flap guard) |
| Always on top | keep the window above other apps |
| Auto-update | pull new versions from GitHub automatically |
| Pause / Resume | stop / start pinging without closing |
| Test sound | play the alarm once |
| Check for updates | force a GitHub version check right now |

## Files

Config and log live in `%APPDATA%\GCL-PingMonitor\`:

- `config.json` — host list + settings (auto-update never touches this)
- `events.log` — full history of up/down + update events

The program files themselves live wherever you extracted them and are what
auto-update overwrites.

## Notes

- Runs fully async — all hosts are pinged concurrently, so 50 down hosts do not
  freeze the UI.
- Alarm sound is `C:\Windows\Media\Alarm01.wav` if present, otherwise it falls
  back to the Windows "critical stop" system sound.
- To auto-start with Windows: put a shortcut to `Start-PingMonitor.cmd` in
  `shell:startup`.

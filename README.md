# GCL Ping Monitor

Windows desktop ping monitor for the support desk. No admin rights, no installer
bundle, no dependencies beyond what Windows already ships.

## Supported Windows versions

Needs **Windows PowerShell 3.0+** and **.NET Framework 4.5+** — both already
present on everything below.

| Windows | PowerShell it ships with | Status |
|---|---|---|
| Windows 11 (all builds) | 5.1 | works as-is |
| Windows 10 (1607 and newer) | 5.1 | works as-is |
| Windows Server 2025 / 2022 / 2019 / 2016 | 5.1 | works as-is |
| Windows Server 2012 R2 | 4.0 | works as-is |
| Windows Server 2012 | 3.0 | works; installing [WMF 5.1](https://www.microsoft.com/download/details.aspx?id=54616) is recommended |
| Windows 8.1 | 4.0 | works as-is |
| Windows 7 SP1 | 2.0 | needs WMF 4.0 or 5.1 first |

Verified on Windows 11. The older targets are supported by keeping to
PowerShell 3.0 / .NET 4.5 APIs — nothing newer is used anywhere in the tool. If
PowerShell is older than 4.0 the tool shows a plain message telling you to
install WMF instead of failing with a cryptic error.

**Two caveats for servers:**

- It is a desktop (WinForms) window, so it needs a GUI. **Server Core has no
  GUI** — use a full "Desktop Experience" install, or just run it on the
  support desk PCs, which is what it is for.
- The alarm needs a **working audio output device**. Most servers have none, so
  on a server you get the red banner and the log but no sound.

## Install (recommended)

Open **Windows PowerShell** on the support PC and paste this one line:

```powershell
powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/badshashorif/gcl-ping-monitor/main/install.ps1 | iex"
```

It will:

1. download the latest version into `%LOCALAPPDATA%\GCL-PingMonitor`
2. create a **Desktop** shortcut ("GCL Ping Monitor")
3. set it to **start automatically with Windows**
4. launch it

Run the exact same line again any time to force an update. Your host list and
settings (kept in `%APPDATA%`) are never touched.

Options — set before pasting the line:

```powershell
$env:GCLPM_NOAUTOSTART = 1   # don't add the start-with-Windows shortcut
$env:GCLPM_NOLAUNCH    = 1   # install but don't open it now
```

### Uninstall

Delete these two shortcuts and one folder:

- `%USERPROFILE%\Desktop\GCL Ping Monitor.lnk`
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\GCL Ping Monitor.lnk`
- `%LOCALAPPDATA%\GCL-PingMonitor`

## Install (manual, no installer)

- **Code → Download ZIP** on GitHub → extract to a user-writable folder
  (Desktop / Documents — **not** `C:\Program Files`), **or**
  `git clone https://github.com/badshashorif/gcl-ping-monitor.git`
- Double-click **`Start-PingMonitor.cmd`** (or run
  `powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\GCL-PingMonitor.ps1`)

> First run may show a SmartScreen / "Windows protected your PC" prompt — click
> **More info → Run anyway**, or right-click each file → Properties → **Unblock**.

> A `git clone` is treated as a dev checkout: auto-update is turned **off** there
> so your local edits are safe. Use the ZIP or the installer on machines that
> should auto-update.

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
- The alarm plays `alarm.wav`, a loud two-tone siren the tool generates itself
  into `%APPDATA%\GCL-PingMonitor\` on first run. It is deliberately **not** a
  Windows system sound: many machines have the sound scheme set to "No Sounds",
  which silences `SystemSounds`/`MessageBeep` but not a real .wav file.
- **Test sound** proves the audio path end to end and writes which source it
  used to the log. If that button is silent, it is the machine's audio (muted,
  wrong output device, no sound card), not the tool.
- While the alarm is on, the taskbar button flashes too, so it is noticed even
  when the window is behind something else.
- The installer already sets up start-with-Windows. For a manual copy, put a
  shortcut to `Start-PingMonitor.cmd` in `shell:startup`.

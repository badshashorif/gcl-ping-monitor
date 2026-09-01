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

- **Add / edit / remove** hosts right in the window — the list is saved
  automatically. Edit with the **Edit** button or by **double-clicking a row**.
- **Enable / Disable** any host. A disabled host is not pinged, shows greyed out
  as `DISABLED`, and can never raise the alarm — use it for kit that is down for
  maintenance instead of deleting it.
- **Loss %** column shows rolling packet loss over the last N pings (N is the
  **Loss over** box, default 100). It is colour-graded — amber past 10%, red past
  50% — so a host that is still *UP* but dropping packets cannot be missed.
  Hover the cell for lost/total, lifetime counters and average latency.
- Every enabled host is pinged on an interval (default 5s). The row is:
  - **green** = UP (shows latency)
  - **amber** = missed a ping, still checking
  - **solid red** = DOWN (after N consecutive fails, default 2)
  - **pale red** = DOWN but acknowledged
  - **grey** = disabled
- **DOWN hosts automatically sort to the top** — un-acknowledged first — so
  whatever needs attention is always on screen without scrolling.
- **Search** box filters the list live by name or IP, for when there are a lot
  of hosts. `Esc` or the `x` button clears it.
- While any un-acknowledged host is down: the alarm sounds, the top banner turns
  red, and the taskbar button flashes.
- **ACKNOWLEDGE ALARM** silences it immediately. If a *different* host then goes
  down the alarm re-arms by itself; a host recovering resets its ack too.
- **Text** selector (Small → TV) scales the whole window — fonts, rows, buttons
  — for a big wall monitor read from across the room. It is remembered.
- Only **one copy** can run at a time. Launching it again just brings the
  existing window to the front (two copies would each have their own alarm, so
  acknowledging one would leave the other sounding).
- Every state change (DOWN / RECOVERED / ACK / ADD / EDIT / DISABLE / …) is
  written to the event log and shown in the dark panel at the bottom.

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

## Notifications (Email / Telegram / SMS)

**Notifications...** in the toolbar opens the settings. All three channels are
off by default; turn on any combination.

| Tab | What you need |
|---|---|
| **Email** | SMTP server, port, SSL on/off, username, password, From, To (comma separated) |
| **Telegram** | Bot token from [@BotFather](https://t.me/BotFather) and a chat ID (get it from `https://api.telegram.org/bot<TOKEN>/getUpdates`; group ids start with `-100`) |
| **SMS** | Your gateway's HTTP URL plus the phone numbers |

The SMS tab works with **any HTTP SMS gateway** — put your provider's URL in and
use these placeholders, which get filled in and URL-encoded for you:

```
{apikey}    {phone}    {message}
```

For example a GET gateway:

```
https://api.example.com/send?api_key={apikey}&to={phone}&msg={message}
```

Choose `POST` instead of `GET` if your provider needs a body, and put the body
template in the **POST body** field (same placeholders).

**Send test** in the dialog sends a message immediately — the result (`NOTIFY :
email sent` or `NOTIFY err: ...`) appears in the log panel.

Behaviour:

- **General** tab controls whether to notify on DOWN, on RECOVERY, or both.
- Events are **batched** (default 20s) into a single message, so a link failure
  taking 30 hosts down sends one message, not 30.
- A **max messages/hour** cap (default 20) stops an outage storm burning your SMS
  balance. Suppressed messages are noted in the log.
- Sending runs off the UI thread, so a slow SMTP server never freezes the window.

**Security:** SMTP password, bot token and SMS API key are stored
**DPAPI-encrypted** in `config.json` — never in plain text. DPAPI is tied to that
Windows user on that machine, so copying `config.json` to another PC does not
carry the secrets with it. Each machine is configured once.

## Settings (top toolbar)

| Field | Meaning |
|-------|---------|
| Interval s | seconds between ping cycles |
| Timeout ms | how long to wait for each reply |
| Fails→down | consecutive failed pings before a host is marked DOWN (flap guard) |
| Loss over | how many recent pings the Loss % is calculated from (default 100) |
| Text | Small / Normal / Large / Extra large / TV — scales the whole window |
| Always on top | keep the window above other apps |
| Auto-update | pull new versions from GitHub automatically |
| Pause / Resume | stop / start pinging without closing |
| Test sound | play the alarm once |
| Check for updates | force a GitHub version check right now |
| Edit | change the name or IP of the selected host (or double-click it) |
| Disable / Enable | toggle monitoring for the selected host(s) |
| Search | filter the list by name or IP |

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

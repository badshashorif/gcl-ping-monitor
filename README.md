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
- If **nobody** acknowledges, the sound stops on its own after 5 minutes — but
  the screen keeps showing the fault in red. A **recovery sound** plays when a
  host comes back. Both are under [Alarm sound](#alarm-sound).
- **Text** selector (Small → TV) scales the whole window — fonts, rows, buttons
  — for a big wall monitor read from across the room. It is remembered.
- The **alarm sound can be changed** — seven built-in tones, any Windows sound,
  or a `.wav` of your own. See [Alarm sound](#alarm-sound).
- The window **resizes down to a small corner box** and rearranges itself as it
  shrinks. See [Small window / responsive layout](#small-window--responsive-layout).
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

## Alarm sound

**Monitoring → Alarm sound...** picks what plays while a host is down. Select a
sound and press **Play** to hear it before saving.

| Choice | |
|---|---|
| Two-tone siren | the default — a loud 880/1245 Hz warble |
| Ambulance hi-lo | slower, carries further across a room |
| Fast triple beep | three sharp beeps, then a gap |
| Rapid pulse | the most urgent of the built-ins |
| Rising whoop | a 500 → 1700 Hz sweep |
| Low klaxon | deep, for a noisy room where high tones get lost |
| Soft chime | quiet — for an office where a siren is too much |
| **Windows: …** | anything in `C:\Windows\Media` |
| **Use my own .wav...** | any `.wav` file on the machine |

The seven built-in tones are **generated by the tool itself** into
`%APPDATA%\GCL-PingMonitor\` the first time you pick them — nothing is
downloaded and no media library is needed.

**Repeat every** sets how often the sound restarts while the alarm is on
(default 1.4s). Give a long custom sound a longer gap so it does not cut itself
off.

**Stop sound after N minutes** (default 5) silences an alarm nobody has
acknowledged — so a link that goes down at 2am does not scream all night. It
silences the *sound only*: the banner stays red, the row stays red, the
ACKNOWLEDGE button stays lit and the taskbar keeps flashing, because nobody has
actually seen it yet. It is **not** an auto-acknowledge. If another host goes
down afterwards the sound comes straight back, and the clock restarts — a new
fault is never swallowed by an older one. Set it to **0** to keep sounding
forever.

**Play a recovery sound** (default on, soft chime) plays once when a host comes
back up, so you hear that a link has returned without watching the screen. It
has its own player, so a recovery is audible even while the alarm is still
sounding for some other host. It only fires on a real DOWN → UP recovery, never
on a host's first ever reply at startup.

A custom file must be an uncompressed **.wav (PCM)** — Windows' built-in player
cannot play mp3. If the file is later deleted or moved, the alarm falls back to
the default siren rather than going silent.

## Small window / responsive layout

The window can be dragged down to a small box in the corner of a screen, and it
rearranges itself as it shrinks rather than clipping:

| As it narrows | |
|---|---|
| first | **Since** is dropped |
| then | **Down for** is dropped, headers shorten (`IP`, `ms`, `Loss`), the banner text gets smaller, the status bar switches to `UP 3  DOWN 0  off 0` |
| then | **IP / Host** is dropped |
| smallest | **ms** is dropped — **Name, Status and Loss %** always stay |

Toolbar items that no longer fit move into the `»` dropdown, and **ACKNOWLEDGE**
and **Pause** are pinned so they are never the ones that disappear. If the
window gets too short the event log panel hides itself and gives its space to
the host list; it comes back when there is room again.

The smallest size scales with the text size, so **View → Text size → Small**
gives the smallest possible window. Two shortcuts:

- **View → Compact window** snaps straight to the smallest size
- **View → Normal window size** puts it back

The window's size and position are remembered, so a small corner window stays
small across restarts and updates.

## Notifications (Email / Telegram / SMS / Command)

**Settings → Notifications...** opens the settings. All four channels are off by
default; turn on any combination.

| Tab | What you need |
|---|---|
| **Email** | SMTP server, port, **Security**, username, password, From, To (comma separated) |
| **Telegram** | Bot token from [@BotFather](https://t.me/BotFather) and a chat ID (get it from `https://api.telegram.org/bot<TOKEN>/getUpdates`; group ids start with `-100`) |
| **SMS** | Your gateway's HTTP URL plus the phone numbers |
| **Command (offline)** | A local program to run — see [below](#command-offline--gsm-modem) |

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

### What the message looks like

```
🔴🔴 "niketon pop" Down
Severity: Critical
Timestamp: 2026-09-01 14:14:16
IP / Host: 10.10.10.1

🟢🟢 "niketon pop" Up
Severity: Normal
Timestamp: 2026-09-01 14:15:24
IP / Host: 10.10.10.1
Downtime: 1m 8s

Monitored from: NOC-DESK-1 (192.168.120.108)
```

**Monitored from** is the PC that raised the alert — its name and the IP of the
interface it actually routes out of — so with the tool on several desks you can
tell at a glance which one is reporting. It also goes on the end of the email
subject: `[CRITICAL] "niketon pop" Down - NOC-DESK-1`.

Email and Telegram get this. SMS and the offline command get a plain-ASCII
one-liner instead (`[NOC-DESK-1] "niketon pop" Down - 14:14:16`) — emoji push a
phone into UCS-2 and halve how much fits in one SMS.

### Email security: 465 and 587 are not the same

The **Security** box on the Email tab matters more than it looks:

| Setting | Use it for |
|---|---|
| **Auto** (default) | port 465 → SSL/TLS, anything else → STARTTLS |
| **STARTTLS** | port 587 or 25 — the connection starts plain and is upgraded |
| **SSL / TLS** | port 465 — the connection is encrypted from the first byte |
| **None** | plain SMTP, no encryption |

They are different protocols, not two names for the same thing. .NET's own
`SmtpClient` speaks **only STARTTLS**, so on port 465 it waits for a plaintext
greeting that never arrives and eventually fails with *"The operation has timed
out"* — which is what a lot of "my SMTP works in Outlook but not here" reports
turn out to be. This tool therefore talks SMTP over an SSL stream itself for 465
and 465 works as you would expect.

### Command (offline) — GSM modem

Email, Telegram and the HTTP SMS gateway all need the internet, so when the
**link itself is what failed** none of them can deliver. The **Command** tab is
the answer: it runs a program on the PC, so a GSM/USB modem still gets the alert
out with no connectivity at all.

| Field | |
|---|---|
| **Program / script** | the `.exe`, `.bat`, `.cmd` or `.ps1` to run (**...** browses) |
| **Arguments** | the command line, with placeholders filled in |
| **Numbers (comma)** | optional — with several numbers the command runs once per number |
| **Modem** | picked from the modems and COM ports Windows can see, or typed in |
| **Start in** | optional working directory |
| **Timeout (sec)** | a hung modem tool is killed after this (default 60) |
| **Run once per host** | one run per host event instead of one run per batch |

Placeholders, in **Arguments**:

```
{phone}   {message}   {host}   {target}   {status}
{time}    {pc}        {modem}  {port}     {subject}
```

`{modem}` is whatever the Modem box holds; `{port}` is the `COMx` pulled out of
it, so `HUAWEI Mobile Connect  (COM7)` gives `{port}` = `COM7`.

Examples:

```
Program:    C:\gammu\gammu.exe
Arguments:  sendsms TEXT {phone} -text "{message}"

Program:    C:\smstools\smssend.exe
Arguments:  -p {port} {phone} "{host} is now {status}"

Program:    C:\Windows\System32\cmd.exe
Arguments:  /c C:\scripts\send-alert.bat {phone} "{message}"
```

With **Run once per host** on, `{message}` becomes
`ACCESS_RTR_6 [122.99.103.227] is now DOWN` — one SMS per host, the same shape
as The Dude's `[Device.Name] is now [Service.Status]`. With it off, one run gets
the whole batch (`[PC] DOWN: a, b | UP: c`).

The command runs off the UI thread, its exit code and output go to the event log
(`NOTIFY : command ok` / `NOTIFY err: command exit 3`), and **Send test** fires
it immediately with a fake `TEST-HOST` event.

> The other three channels are unaffected — leave SMS on as well and whichever
> one can get through will.

**Security:** SMTP password, bot token and SMS API key are stored
**DPAPI-encrypted** in `config.json` — never in plain text. DPAPI is tied to that
Windows user on that machine, so copying `config.json` to another PC does not
carry the secrets with it. Each machine is configured once.

## Where things live

The **toolbar** carries only what gets used during a shift — add a host, search,
**ACKNOWLEDGE**, Pause. It is a real toolbar with overflow: anything that does
not fit the window moves into a `»` dropdown instead of wrapping or scrolling,
so it stays one clean line at any window size and any text size. ACKNOWLEDGE and
Pause are pinned and never hide.

Everything set once and forgotten lives in the **menu bar**:

| Menu | Contains |
|---|---|
| **Hosts** | Add, Edit, Disable/Enable, Remove, Exit |
| **View** | Text size (Small → TV), Always on top, Show event log, **Compact / Normal window size** |
| **Monitoring** | Pause/Resume, Test alarm sound, **Alarm sound…**, **Monitoring settings…** (interval, timeout, fails→down, loss window) |
| **Settings** | **Notifications…** (email / Telegram / SMS / offline command), **Export / Import hosts + settings**, Auto-update, Check for updates now |
| **Help** | About, Open data folder, Open project page |

**Right-click any row** for Edit / Disable-Enable / Remove / Acknowledge.

## Backup and recovery

**Settings → Export hosts + settings…** writes one `.json` holding every host and
every setting. **Settings → Import hosts + settings…** reads it back and asks:

- **Yes** — replace everything (hosts *and* settings)
- **No** — only add hosts that are not already in the list (safe merge)
- **Cancel** — do nothing

Use it to move a host list to a new PC, or to keep a backup before a rebuild.
The importer also accepts a plain `config.json` copied from
`%APPDATA%\GCL-PingMonitor\`.

> Notification passwords and tokens are DPAPI-encrypted, so they restore only on
> the **same Windows user on the same machine**. Moving the file to another PC
> carries the hosts and settings but not the secrets — re-enter those in
> Notifications there. That is deliberate.

## Files

Config and log live in `%APPDATA%\GCL-PingMonitor\`:

- `config.json` — host list + settings (auto-update never touches this)
- `events.log` — full history of up/down + update events
- `alarm-*.wav` — the built-in alarm tones, generated on first use

The program files themselves live wherever you extracted them and are what
auto-update overwrites.

## Notes

- Runs fully async — all hosts are pinged concurrently, so 50 down hosts do not
  freeze the UI.
- The alarm plays a real `.wav` the tool generates itself into
  `%APPDATA%\GCL-PingMonitor\` on first use. It is deliberately **not** a
  Windows system sound: many machines have the sound scheme set to "No Sounds",
  which silences `SystemSounds`/`MessageBeep` but not a real .wav file.
- **Test sound** proves the audio path end to end and writes which source it
  used to the log. If that button is silent, it is the machine's audio (muted,
  wrong output device, no sound card), not the tool.
- While the alarm is on, the taskbar button flashes too, so it is noticed even
  when the window is behind something else.
- The installer already sets up start-with-Windows. For a manual copy, put a
  shortcut to `Start-PingMonitor.cmd` in `shell:startup`.

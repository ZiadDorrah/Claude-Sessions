# cs — Claude Code session picker

A small Windows command that lists **every Claude Code session on this PC**, from any project folder, and lets you reopen one or start a new named one. Type `cs` in any terminal.

Claude's built-in `claude --resume` only shows sessions from the folder you're currently in. `cs` shows all of them in one list and moves into the right folder for you before resuming.

```
   #  Last used         Folder                Title
   1  2026-10-06 11:50  my-api                Fix login token refresh
   2  2026-10-06 11:48  my-api                Add pagination to orders endpoint
   3  2026-10-06 11:40  desktop app           Docker & Kubernetes learning guide
   4  2026-10-05 17:08  website               Landing page redesign

Number = open, text = filter, +name = new session, * = show all, Enter = quit: _
```

## Files

| File | Purpose |
|---|---|
| `cs.cmd` | The shortcut you type. It runs the PowerShell script next to it. |
| `claude-sessions.ps1` | All the logic: reads sessions, shows the list, opens or creates sessions. |
| `README.md` | This file. |

## Install

### Quick install

Paste this into PowerShell. It downloads the two files into `C:\Users\<you>\.local\bin`, the folder where the Claude Code installer puts `claude.exe`, which is already on your PATH:

```powershell
$bin = "$env:USERPROFILE\.local\bin"
$base = 'https://raw.githubusercontent.com/ZiadDorrah/Claude-Sessions/main'
New-Item -ItemType Directory -Force $bin | Out-Null
foreach ($f in 'cs.cmd', 'claude-sessions.ps1') { Invoke-WebRequest "$base/$f" -OutFile "$bin\$f" -UseBasicParsing }
```

Open a new terminal and type `cs`. If Windows says `cs` isn't recognized, that folder isn't on your PATH; see step 3 below.

### Manual install

1. Copy `cs.cmd` and `claude-sessions.ps1` **into the same folder**. `cs.cmd` finds the script next to itself.
2. That folder must be on your `PATH`. The easiest choice is `C:\Users\<you>\.local\bin`. The Claude Code installer puts `claude.exe` there and has already added it to PATH. To check, run this in PowerShell and use the folder it shows:
   ```powershell
   Get-Command claude
   ```
3. To use another folder instead, for example `C:\Tools`, add it to PATH once and then open a **new** terminal:
   ```powershell
   [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','User') + ';C:\Tools', 'User')
   ```
4. Type `cs`.

Requirements: Windows with the built-in Windows PowerShell 5.1, and Claude Code (`claude`) on PATH. Nothing else needs to be installed. `cs.cmd` runs the script with `-ExecutionPolicy Bypass`, so Windows script-blocking settings don't stop it.

## Usage

| You type | What happens |
|---|---|
| `cs` | Shows all sessions, newest first |
| `cs api login` | Shows the list already filtered; every word must match |
| `cs + Fix checkout bug` | Starts a new session named "Fix checkout bug" in the current folder, without showing the list |

At the prompt:

| You type | What happens |
|---|---|
| `3` | Opens session #3: moves into its folder and runs `claude --resume <id>` |
| `login` | Filters the list by title, first message, folder and session ID |
| `*` | Clears the filter |
| `1b11db3e` | Opens the session whose ID starts with this (8+ characters, e.g. pasted from somewhere) |
| `+ New task name` | Starts a new session with that name in the current folder |
| `+` | Starts a new session with no name |
| Text that matches no session | Asks `Start a new session named '...' in <folder>? (y/N)`. `y` starts it; anything else goes back to the full list |
| Enter on its own | Quits |

New sessions open in the folder you ran `cs` from, so `cd` into your project first. The name is set with Claude's own `--name` option, so it appears in the prompt box, the terminal title and Claude's `/resume` list.

## How it works

- **Where sessions come from.** Claude Code saves each session as a `.jsonl` file under `C:\Users\<you>\.claude\projects\<project-folder>\`. The script reads every one of them.
- **Titles.** The title shown is, in order of preference:
  1. the name you gave the session
  2. the title Claude generated for it
  3. your first message
  4. your last message
  5. a slash command, only if there is nothing else
- **Hidden sessions.** Sessions that never got a reply from Claude are left out (for example one where you only ran `/clear`), because there is nothing to resume.
- **Why it changes folder.** Claude finds a session by the folder it is started in, so the script `cd`s into the session's original folder before running `claude --resume <id>`. If a session was moved, it uses the folder that matches where the session file is stored.
- **Speed.** About 1–2 seconds for ~20 sessions (~19 MB). It reads the whole history each time so it can find titles, which may be saved anywhere in the file.

## Limitations

- **Desktop app sessions** show as `desktop app` and can't be opened from `cs`. The Claude desktop app is a Windows Store (MSIX) app: the folder it records (under `AppData\Roaming\Claude\...`) only exists inside the app. On disk it is really under `AppData\Local\Packages\Claude_*\LocalCache\Roaming`, so a terminal `claude --resume` can't match it. Choosing one tells you to open it in the desktop app.
- **Deleted folders** show grey with `(missing)` and can't be opened. Claude can only resume a session from its original folder.
- **Don't open a session that's already running** in another window or in the desktop app. Two windows writing to the same conversation will conflict.
- **Each PC lists only its own sessions.** Sessions live in that PC's `C:\Users\<you>\.claude\projects`, so copying the script doesn't bring them along.
- **Names with `"` characters** get the quotes removed, because Windows PowerShell 5.1 passes them to programs incorrectly.
- **Searching** looks at titles, first messages, folders and IDs, not the whole conversation, to stay fast.
- **It relies on Claude Code's session file format** (entries like `custom-title`, `ai-title`, `last-prompt`, `cwd`). A future Claude Code update that changes the format could hide titles or sessions until the script is updated.

## Uninstall

Delete `cs.cmd` and `claude-sessions.ps1` from the folder you installed them in (with the quick install: `C:\Users\<you>\.local\bin\`). Nothing else was changed: no registry entries, no PowerShell profile, no settings.

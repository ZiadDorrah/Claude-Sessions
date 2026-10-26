# cs - list every Claude Code session on this PC and resume the one you pick.
# Usage: cs [filter words]      (launched through cs.cmd in the same folder)
#        cs + new session name  (start a new named session in the current folder)
#        cs -RefreshCache       (internal: the hidden background run described below)
param([switch]$RefreshCache, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Words)

$root = Join-Path $env:USERPROFILE '.claude\projects'

# Session files are append-only, so remember how far each one was read and what was
# found; the next run parses only the lines added since. Delete this file to rebuild.
#
# Opening a transcript that changed makes the antivirus (Kaspersky) rescan the whole
# file before the open returns: half a minute for a big session full of screenshots.
# So sessions already in the cache are listed from it without opening their files, and
# a hidden background run reads their new lines for next time.
$cachePath = Join-Path $env:LOCALAPPDATA 'claude-sessions\cache.json'
$cacheVersion = 1
$ord = [StringComparison]::Ordinal

# The desktop app is a packaged (MSIX) app: its %APPDATA% is virtualized under
# %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming and invisible from a terminal.
$desktopRoaming = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
    Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming' }

function Clean([string]$s) { ($s -replace '\s+', ' ').Trim() }

# Long pasted prompts only bloat the cache; titles and filters need the start.
function Cap([string]$s) { if ($s -and $s.Length -gt 500) { $s.Substring(0, 500) } else { $s } }

function Fit([string]$s, [int]$w) {
    if ($s.Length -gt $w) { $s.Substring(0, $w - 3) + '...' } else { $s.PadRight($w) }
}

# First real prompt the user typed (skips system reminders, IDE context, tool results).
function Get-PromptText($entry) {
    $c = $entry.message.content
    $texts = if ($c -is [string]) { @($c) } else { @($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) }
    foreach ($t in $texts) {
        if ($t -match '<command-name>(.*?)</command-name>') {
            $name = $Matches[1]
            $cmdArgs = if ($t -match '(?s)<command-args>(.*?)</command-args>') { $Matches[1] } else { '' }
            return [pscustomobject]@{ Text = Clean "$name $cmdArgs"; Command = $true }
        }
        if ($t -and -not $t.TrimStart().StartsWith('<')) { return [pscustomobject]@{ Text = Clean $t; Command = $false } }
    }
    return $null
}

# Short folder name; scratch workspaces end in GUID folders, so walk up past those.
function Get-FolderLabel([string]$cwd) {
    if (-not $cwd) { return '?' }
    $parts = $cwd.TrimEnd('\') -split '\\'
    for ($i = $parts.Count - 1; $i -ge 0; $i--) {
        if ($parts[$i] -notmatch '^[0-9a-fA-F-]{20,}$') { return $parts[$i] }
    }
    return $parts[-1]
}

function Read-Cache {
    $map = @{}
    try {
        $data = [IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
        if ($data.Version -eq $cacheVersion) {
            foreach ($p in $data.Files.PSObject.Properties) { $map[$p.Name] = $p.Value }
        }
    } catch { }   # missing or corrupt: everything is re-read
    $map
}

function Save-Cache($map) {
    $tmp = "$cachePath.$PID.tmp"
    try {
        $dir = Split-Path $cachePath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $json = [pscustomobject]@{ Version = $cacheVersion; Files = [pscustomobject]$map } | ConvertTo-Json -Depth 4 -Compress
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
        # Swap in place, so a run reading the cache at the same moment never finds it missing.
        if (Test-Path -LiteralPath $cachePath) { [IO.File]::Replace($tmp, $cachePath, [NullString]::Value) }
        else { [IO.File]::Move($tmp, $cachePath) }
    } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

function Get-SessionFiles {
    Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -File }
}

function New-State {
    [pscustomobject]@{ Offset = [long]0; Title = $null; AiTitle = $null; First = $null; FirstCmd = $null
                       Last = $null; Cwd = $null; Relocated = $null; HasReply = $false }
}

function Read-Bytes([IO.FileStream]$fs, [long]$from, [int]$count) {
    $buf = New-Object byte[] $count
    $fs.Position = $from
    $got = 0
    while ($got -lt $count) {
        $n = $fs.Read($buf, $got, $count - $got)
        if ($n -le 0) { break }
        $got += $n
    }
    , $buf   # the comma stops PowerShell unrolling the array byte by byte
}

# Parse the lines added to $file since $old was saved and return the updated state.
function Update-State([IO.FileInfo]$file, $old) {
    if ($old -and $old.Offset -eq $file.Length) { return $old }

    $s = $old
    $fs = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        # A directory listing can show an old, smaller size for a file still being
        # written; only the open file says for sure whether it was replaced.
        if (-not $s -or $s.Offset -gt $fs.Length) { $s = New-State }

        # Stop after the last complete line; one still being written is read next time.
        $end = $null
        $pos = $fs.Length
        while ($null -eq $end -and $pos -gt $s.Offset) {
            $n = [int][Math]::Min(65536, $pos - $s.Offset)
            $tail = Read-Bytes $fs ($pos - $n) $n
            $i = [Array]::LastIndexOf($tail, [byte]10)
            if ($i -ge 0) { $end = $pos - $n + $i + 1 }
            $pos -= $n
        }
        if ($null -eq $end) { return $s }

        $bytes = Read-Bytes $fs $s.Offset ([int]($end - $s.Offset))
        $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes), [Text.Encoding]::UTF8)
        while ($null -ne ($l = $reader.ReadLine())) {
            if ($l.StartsWith('{"type":"custom-title"', $ord)) { $s.Title = Cap (ConvertFrom-Json $l).customTitle }
            elseif ($l.StartsWith('{"type":"ai-title"', $ord)) { $s.AiTitle = Cap (ConvertFrom-Json $l).aiTitle }
            elseif ($l.StartsWith('{"type":"last-prompt"', $ord)) { $s.Last = Cap (ConvertFrom-Json $l).lastPrompt }
            elseif ($l.StartsWith('{"type":"relocated"', $ord)) { $s.Relocated = (ConvertFrom-Json $l).relocatedCwd }
            elseif ($l.StartsWith('{"parentUuid"', $ord)) {
                if (-not $s.Cwd -and $l -match '"cwd":"((?:[^"\\]|\\.)*)"') { $s.Cwd = [regex]::Unescape($Matches[1]) }
                if (-not $s.HasReply -and $l.Contains('"type":"assistant"')) { $s.HasReply = $true }
                if (-not $s.First -and $l.Contains('"type":"user"') -and -not $l.Contains('"isMeta":true') -and
                    -not $l.Contains('"isSidechain":true') -and -not $l.Contains('"tool_result"') -and
                    -not $l.Contains('"isCompactSummary":true')) {
                    try {
                        $p = Get-PromptText (ConvertFrom-Json $l)
                        if ($p -and $p.Command) { if (-not $s.FirstCmd) { $s.FirstCmd = Cap $p.Text } }
                        elseif ($p) { $s.First = Cap $p.Text }
                    } catch { }
                }
            }
        }
        $s.Offset = $end
    } finally { $fs.Dispose() }
    $s
}

function Get-Session([IO.FileInfo]$file, $st) {
    if (-not $st.HasReply) { return $null }   # e.g. a bare /clear; nothing to resume

    # Claude finds a session by the folder it is started in, so prefer the cwd that
    # matches this session file's project folder name.
    $cwd = $st.Cwd
    $candidates = @($st.Relocated, $cwd) | Where-Object { $_ }
    $match = $candidates | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '-') -eq $file.Directory.Name } | Select-Object -First 1
    if ($match) { $cwd = $match } elseif ($st.Relocated) { $cwd = $st.Relocated }

    $exists = [bool]($cwd -and (Test-Path -LiteralPath $cwd))
    $desktop = $false
    if (-not $exists -and $cwd -and $desktopRoaming -and $cwd.StartsWith("$env:APPDATA\", [StringComparison]::OrdinalIgnoreCase)) {
        $desktop = Test-Path -LiteralPath (Join-Path $desktopRoaming $cwd.Substring($env:APPDATA.Length))
    }

    $shown = @($st.Title, $st.AiTitle, $st.First, $st.Last, $st.FirstCmd) | Where-Object { $_ } | Select-Object -First 1
    [pscustomobject]@{
        Id      = $file.BaseName
        Time    = $file.LastWriteTime
        Cwd     = $cwd
        Folder  = Get-FolderLabel $cwd
        Exists  = $exists
        Desktop = $desktop
        Title   = Clean $shown
        Search  = "$($st.Title) $($st.AiTitle) $($st.First) $($st.FirstCmd) $cwd $($file.BaseName)"
    }
}

function Test-Filter($session, [string[]]$terms) {
    foreach ($t in $terms) {
        if ($session.Search.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Show-List($list, [int]$total, [string]$filter) {
    $width = 120
    try { $width = $Host.UI.RawUI.WindowSize.Width } catch { }
    $numW = [Math]::Max(2, "$($list.Count)".Length)
    $folderW = 20
    $titleW = [Math]::Max(20, $width - $numW - $folderW - 25)

    Write-Host ''
    Write-Host ('  {0}  {1}  {2}  {3}' -f '#'.PadLeft($numW), 'Last used'.PadRight(16), 'Folder'.PadRight($folderW), 'Title') -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) {
        $s = $list[$i]
        $folder = if ($s.Exists) { $s.Folder }
                  elseif ($s.Desktop) { 'desktop app' }
                  else { (Fit $s.Folder ($folderW - 10)).TrimEnd() + ' (missing)' }
        $line = '  {0}  {1}  {2}  {3}' -f "$($i + 1)".PadLeft($numW), $s.Time.ToString('yyyy-MM-dd HH:mm'), (Fit $folder $folderW), (Fit $s.Title $titleW).TrimEnd()
        if ($s.Exists) { Write-Host $line } else { Write-Host $line -ForegroundColor DarkGray }
    }
    if ($filter) { Write-Host "  Filter: '$filter'  ($($list.Count) of $total)" -ForegroundColor Yellow }
}

function Open-Session($s) {
    if ($s.Desktop) {
        Write-Host "'$($s.Title)' is a Claude desktop app session; its folder only exists inside the app, so open it there." -ForegroundColor Yellow
        return
    }
    if (-not $s.Exists) {
        Write-Host "Can't open: the folder no longer exists: $($s.Cwd)" -ForegroundColor Red
        return
    }
    Write-Host "`nResuming: $($s.Title)`n      in: $($s.Cwd)`n" -ForegroundColor Green
    Set-Location -LiteralPath $s.Cwd
    & claude --resume $s.Id
    exit $LASTEXITCODE
}

function Start-NewSession([string]$name) {
    $name = ($name -replace '"', '').Trim()   # Windows PowerShell mangles quotes in native args
    $here = (Get-Location).ProviderPath
    if ($name) {
        Write-Host "`nNew session: $name`n      in: $here`n" -ForegroundColor Green
        & claude --name $name
    } else {
        Write-Host "`nNew session in: $here`n" -ForegroundColor Green
        & claude
    }
    exit $LASTEXITCODE
}

if (-not (Test-Path -LiteralPath $root)) { Write-Host "No Claude sessions folder at $root"; exit 1 }

if ($RefreshCache) {
    # One refresh at a time; the lock is released when this process exits.
    try { $lock = [IO.File]::Open("$cachePath.lock", 'OpenOrCreate', 'ReadWrite', 'None') } catch { exit 0 }
    $cache = Read-Cache
    $fresh = @{}
    foreach ($f in Get-SessionFiles) {
        $old = $cache[$f.FullName]
        try { $fresh[$f.FullName] = Update-State $f $old } catch { if ($old) { $fresh[$f.FullName] = $old } }
    }
    Save-Cache $fresh
    exit 0
}

$cache = Read-Cache
$fresh = @{}
$readAny = $false
$behind = $false
$all = @(Get-SessionFiles |
    ForEach-Object {
        try {
            $old = $cache[$_.FullName]
            if ($old -and $old.HasReply -and ($old.Title -or $old.AiTitle -or $old.First)) {
                $st = $old
                if ($old.Offset -ne $_.Length) { $behind = $true }
            } else {
                $st = Update-State $_ $old
                $readAny = $true
            }
            $fresh[$_.FullName] = $st
            Get-Session $_ $st
        } catch { }
    } |
    Where-Object { $_ } |
    Sort-Object Time -Descending)
if ($readAny) { Save-Cache $fresh }
if ($behind) {
    Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -RefreshCache"
}
if (-not $all.Count) { Write-Host "No Claude sessions found in $root"; exit 1 }

$filter = (($Words | Where-Object { $_ }) -join ' ').Trim()
if ($filter.StartsWith('+')) { Start-NewSession $filter.Substring(1) }

while ($true) {
    $terms = @($filter -split '\s+' | Where-Object { $_ })
    $list = @($all | Where-Object { Test-Filter $_ $terms })
    if ($list.Count) { Show-List $list $all.Count $filter }
    else {
        Write-Host "`nNo sessions match '$filter'." -ForegroundColor Yellow
        $yes = "$(Read-Host "Start a new session named '$filter' in $((Get-Location).ProviderPath)? (y/N)")".Trim()
        if ($yes -match '^(y|yes)$') { Start-NewSession $filter }
        $filter = ''
        continue
    }

    $in = "$(Read-Host "`nNumber = open, text = filter, +name = new session, * = show all, Enter = quit")".Trim()
    if (-not $in) { exit 0 }
    if ($in -eq '*') { $filter = ''; continue }
    if ($in.StartsWith('+')) { Start-NewSession $in.Substring(1) }

    $n = 0
    if ([int]::TryParse($in, [ref]$n)) {
        if ($n -ge 1 -and $n -le $list.Count) { Open-Session $list[$n - 1] }
        else { Write-Host "No session #$n in the list." -ForegroundColor Red }
        continue
    }

    # A pasted session ID (or its first 8+ characters) opens directly.
    if ($in -match '^[0-9a-fA-F-]{8,}$') {
        $byId = @($all | Where-Object { $_.Id.StartsWith($in, [StringComparison]::OrdinalIgnoreCase) })
        if ($byId.Count -eq 1) { Open-Session $byId[0]; continue }
    }

    $filter = $in
}

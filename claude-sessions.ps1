# cs - list every Claude Code session on this PC and resume the one you pick.
# Usage: cs [filter words]      (launched through cs.cmd in the same folder)
#        cs + new session name  (start a new named session in the current folder)
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Words)

$root = Join-Path $env:USERPROFILE '.claude\projects'

# The desktop app is a packaged (MSIX) app: its %APPDATA% is virtualized under
# %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming and invisible from a terminal.
$desktopRoaming = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
    Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming' }

function Clean([string]$s) { ($s -replace '\s+', ' ').Trim() }

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

function Read-Session([IO.FileInfo]$file) {
    $title = $null; $aiTitle = $null; $first = $null; $firstCmd = $null; $last = $null
    $cwd = $null; $relocated = $null; $hasReply = $false
    $fs = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
    try {
        while ($null -ne ($l = $reader.ReadLine())) {
            if ($l.StartsWith('{"type":"custom-title"')) { $title = (ConvertFrom-Json $l).customTitle }
            elseif ($l.StartsWith('{"type":"ai-title"')) { $aiTitle = (ConvertFrom-Json $l).aiTitle }
            elseif ($l.StartsWith('{"type":"last-prompt"')) { $last = (ConvertFrom-Json $l).lastPrompt }
            elseif ($l.StartsWith('{"type":"relocated"')) { $relocated = (ConvertFrom-Json $l).relocatedCwd }
            elseif ($l.StartsWith('{"parentUuid"')) {
                if (-not $cwd -and $l -match '"cwd":"((?:[^"\\]|\\.)*)"') { $cwd = [regex]::Unescape($Matches[1]) }
                if (-not $hasReply -and $l.Contains('"type":"assistant"')) { $hasReply = $true }
                if (-not $first -and $l.Contains('"type":"user"') -and -not $l.Contains('"isMeta":true') -and
                    -not $l.Contains('"isSidechain":true') -and -not $l.Contains('"tool_result"') -and
                    -not $l.Contains('"isCompactSummary":true')) {
                    try {
                        $p = Get-PromptText (ConvertFrom-Json $l)
                        if ($p -and $p.Command) { if (-not $firstCmd) { $firstCmd = $p.Text } }
                        elseif ($p) { $first = $p.Text }
                    } catch { }
                }
            }
        }
    } finally { $reader.Dispose() }

    if (-not $hasReply) { return $null }   # e.g. a bare /clear; nothing to resume

    # Claude finds a session by the folder it is started in, so prefer the cwd that
    # matches this session file's project folder name.
    $candidates = @($relocated, $cwd) | Where-Object { $_ }
    $match = $candidates | Where-Object { ($_ -replace '[^a-zA-Z0-9]', '-') -eq $file.Directory.Name } | Select-Object -First 1
    if ($match) { $cwd = $match } elseif ($relocated) { $cwd = $relocated }

    $exists = [bool]($cwd -and (Test-Path -LiteralPath $cwd))
    $desktop = $false
    if (-not $exists -and $cwd -and $desktopRoaming -and $cwd.StartsWith("$env:APPDATA\", [StringComparison]::OrdinalIgnoreCase)) {
        $desktop = Test-Path -LiteralPath (Join-Path $desktopRoaming $cwd.Substring($env:APPDATA.Length))
    }

    $shown = @($title, $aiTitle, $first, $last, $firstCmd) | Where-Object { $_ } | Select-Object -First 1
    [pscustomobject]@{
        Id      = $file.BaseName
        Time    = $file.LastWriteTime
        Cwd     = $cwd
        Folder  = Get-FolderLabel $cwd
        Exists  = $exists
        Desktop = $desktop
        Title   = Clean $shown
        Search  = "$title $aiTitle $first $firstCmd $cwd $($file.BaseName)"
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

$all = @(Get-ChildItem -LiteralPath $root -Directory |
    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -File } |
    ForEach-Object { try { Read-Session $_ } catch { } } |
    Where-Object { $_ } |
    Sort-Object Time -Descending)
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

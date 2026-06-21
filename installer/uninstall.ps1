# Botzy Tokenizer - uninstaller (Windows native, PowerShell 5.1+).
# Removes the scheduled task, wipes server-side data, removes local files.
# Backups (.bak_*) are preserved (moved aside, path printed). Idempotent.
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $ScriptDir "installer_config.yaml"
$TS = [int][double]::Parse((Get-Date -UFormat %s))

function Say($m) { Write-Host $m }
function Cfg($key) {
  $line = Select-String -Path $ConfigFile -Pattern "^\s*$key\s*:" | Select-Object -First 1
  if (-not $line) { Write-Host "[x] config key '$key' not found"; exit 1 }
  $v = ($line.Line -split ":",2)[1]
  $v = $v -replace '\s+#.*$','' -replace '^\s+','' -replace '\s+$',''
  $v = $v.Trim('"') -replace '\$\{HOME\}',$env:USERPROFILE
  return $v
}

$ServerBase  = Cfg "server_base"
$WipePath    = Cfg "wipe_path"
$CredsPath   = Cfg "creds_path"
$InstallRoot = Split-Path -Parent $CredsPath
$WipeUrl     = "$ServerBase$WipePath"

Say "Botzy Tokenizer uninstaller"
Say "  install root: $InstallRoot"

# 1. remove auto-start: Startup launcher (current) + HKCU Run (round-1) + legacy task
$RunName = "BotzyTokenizerReader"

# current mechanism: Startup-folder .vbs launcher
$VbsPath = Join-Path ([Environment]::GetFolderPath('Startup')) "$RunName.vbs"
if (Test-Path $VbsPath) {
  Remove-Item -Force $VbsPath -ErrorAction SilentlyContinue
  Say "  [ok] Startup launcher removed"
} else { Say "  (no Startup launcher - already removed)" }

# round-1 mechanism: HKCU\...\Run entry (harmless no-op if absent)
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runVal = $null
try { $runVal = (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue).$RunName } catch {}
if ($runVal) {
  Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
  Say "  [ok] auto-start Run entry removed"
} else { Say "  (no Run entry - already removed)" }

# legacy: older installs used a scheduled task - remove it if still present
$task = Get-ScheduledTask -TaskName $RunName -ErrorAction SilentlyContinue
if ($task) {
  Stop-ScheduledTask  -TaskName $RunName -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName $RunName -Confirm:$false
  Say "  [ok] legacy scheduled task removed"
}

# kill a no-service launched reader, if any
$pidFile = Join-Path $InstallRoot "reader.pid"
if (Test-Path $pidFile) {
  $procId = Get-Content $pidFile
  Stop-Process -Id $procId -ErrorAction SilentlyContinue
  Say "  [ok] stopped reader pid $procId"
}

# B1: stop ANY reader bound to THIS install that the pid-file doesn't know about.
# After a reboot the live reader was relaunched by the Startup .vbs under a NEW pid
# (reader.pid is stale), and on Windows it holds reader.out OPEN — an open handle
# LOCKS the file, so a later Remove-Item would throw and abort mid-delete, orphaning
# a half-removed dir AND a reader still bound to 127.0.0.1:8765. Match every
# python/pythonw running local_bridge.py for this install, stop them, and WAIT for
# the handles to release BEFORE we delete.
function Get-InstallReaders($root) {
  try {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -match '^pythonw?\.exe$' -and $_.CommandLine -and
        $_.CommandLine -like '*local_bridge.py*' -and
        ($_.CommandLine -like "*$root*" -or $_.CommandLine -like '*\.botzy-tokenizer\*')
      })
  } catch { return @() }
}
$readers = Get-InstallReaders $InstallRoot
if ($readers.Count -gt 0) {
  foreach ($r in $readers) { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue }
  Say "  [ok] stopping $($readers.Count) reader process(es) bound to this install"
  for ($i = 0; $i -lt 10; $i++) {        # wait up to ~5s for exit + handle release
    Start-Sleep -Milliseconds 500
    if ((Get-InstallReaders $InstallRoot).Count -eq 0) { break }
  }
}
if ((Get-InstallReaders $InstallRoot).Count -gt 0) {
  Say "  [!] a reader is still running - cleanup may be incomplete; close it and re-run."
} else {
  Say "  [ok] no reader process bound to this install"
}

# 2. server-side wipe
# $WipeOk gates whether it is SAFE to delete creds.json: only a confirmed 200/401
# (data gone) clears it. No creds => nothing to wipe => safe to remove.
$WipeOk = $true
if (Test-Path $CredsPath) {
  $creds = Get-Content $CredsPath -Raw | ConvertFrom-Json
  $hdr = @{ Authorization = "Bearer $($creds.install_token)" }
  $body = @{ registry_id = $creds.registry_id } | ConvertTo-Json -Compress
  try {
    Invoke-WebRequest -Uri $WipeUrl -Method POST -Headers $hdr -ContentType "application/json" `
      -Body $body -TimeoutSec 15 -UseBasicParsing | Out-Null
    Say "  [ok] server-side data wiped (200)"
  } catch {
    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    if ($code -eq 401) { Say "  [ok] server-side data already gone (401)" }
    else {
      # B2: wipe NOT confirmed - do NOT delete creds.json (its token is the ONLY
      # thing that can authorise the wipe). Keep it so "re-run later" really works.
      $WipeOk = $false
      Say "  [!] wipe NOT confirmed (HTTP $code) - your server-side data still exists."
    }
  }
} else { Say "  (no creds.json - nothing to wipe server-side)" }

# 3. local cleanup (keep .bak_*)
if (Test-Path $InstallRoot) {
  $BackupsDir = "$InstallRoot-backups"
  $baks = Get-ChildItem -Path $InstallRoot -Recurse -Force -Filter "*.bak_*" -ErrorAction SilentlyContinue
  if ($baks) {
    New-Item -ItemType Directory -Force -Path $BackupsDir | Out-Null
    foreach ($b in $baks) { Move-Item -Force $b.FullName $BackupsDir -ErrorAction SilentlyContinue }
    Say "  [ok] backups preserved at: $BackupsDir"
  }
  if ((Test-Path $CredsPath) -and (-not $WipeOk)) {
    # B2: KEEP creds.json + a wipe_pending marker so a later online re-run can still
    # wipe the server-side row. Remove everything else.
    $CredsName = Split-Path -Leaf $CredsPath
    $marker = Join-Path $InstallRoot "wipe_pending"
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Set-Content -Path $marker -Value "wipe_pending $stamp - server-side data NOT wiped; re-run uninstall.ps1 when back online to remove it." -ErrorAction SilentlyContinue
    Get-ChildItem -Path $InstallRoot -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.Name -ne $CredsName -and $_.Name -ne "wipe_pending") {
        Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue
      }
    }
    Say "  [!] KEPT $CredsName + wipe_pending marker (server wipe unconfirmed)."
    Say "      your server-side data still exists - re-run uninstall.ps1 when ONLINE to wipe it."
  } else {
    # tolerant delete: report what couldn't be removed instead of aborting mid-delete.
    Remove-Item -Recurse -Force $InstallRoot -ErrorAction SilentlyContinue
    if (Test-Path $InstallRoot) {
      Say "  [!] some files under $InstallRoot could not be removed (a reader handle may"
      Say "      still be open). Close any running reader and re-run, or delete it manually."
    } else {
      Say "  [ok] removed $InstallRoot"
    }
  }
} else { Say "  (install root already gone)" }

Say ""
Say "Uninstalled. Widget removal: chrome://extensions -> remove 'Botzy Tokenizer'."
if (Test-Path "$InstallRoot-backups") { Say "Backups kept at: $InstallRoot-backups" }
exit 0

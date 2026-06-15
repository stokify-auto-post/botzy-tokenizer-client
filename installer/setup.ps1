# Botzy Tokenizer - installer (Windows native, PowerShell 5.1+).
# User-level only. No admin. Backup before every change. Idempotent re-run safe.
#
# Env flags (tests/advanced):
#   $env:BOTZY_DRYRUN=1      pre-flight + plan only; no disk/network; exit 0
#   $env:BOTZY_NO_SERVICE=1  skip Task Scheduler registration (reader still launched)
#   $env:BOTZY_NO_BROWSER=1  skip chrome://extensions open + clipboard
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$ConfigFile = Join-Path $ScriptDir "installer_config.yaml"
$TS = [int][double]::Parse((Get-Date -UFormat %s))
$N  = 9
$script:CreatedCreds = $null
$DryRun    = ($env:BOTZY_DRYRUN    -eq "1")
$NoService = ($env:BOTZY_NO_SERVICE -eq "1")
$NoBrowser = ($env:BOTZY_NO_BROWSER -eq "1")

function Say($m)  { Write-Host $m }
function Step($n,$t) { Write-Host "`nSTEP $n/$N`: $t" }
function Die($m)  { Write-Host "`n[x] $m" -ForegroundColor Red; exit 1 }

# read a flat key from installer_config.yaml; strip trailing #comment + quotes;
# expand ${HOME} -> $env:USERPROFILE.
function Cfg($key) {
  $line = Select-String -Path $ConfigFile -Pattern "^\s*$key\s*:" | Select-Object -First 1
  if (-not $line) { Die "config key '$key' not found in $ConfigFile" }
  $v = ($line.Line -split ":",2)[1]
  $v = $v -replace '\s+#.*$','' -replace '^\s+','' -replace '\s+$',''
  $v = $v.Trim('"')
  $v = $v -replace '\$\{HOME\}',$env:USERPROFILE
  return $v
}

function Backup-IfExists($p) {
  if (Test-Path $p) {
    if ($DryRun) { Say "  (dryrun) would back up: $p -> $p.bak_$TS"; return }
    Copy-Item -Recurse -Force $p "$p.bak_$TS"
    Say "  [ok] backup: $p.bak_$TS"
  }
}

try {
  # -------- load config (R13)
  $ServerBase  = Cfg "server_base"
  $EnrollPath  = Cfg "enroll_path"
  $BridgePort  = Cfg "bridge_port"
  $LogDir      = Cfg "reader_log_dir"
  $CredsPath   = Cfg "creds_path"
  $InstallRoot = Split-Path -Parent $CredsPath
  $EnrollUrl   = "$ServerBase$EnrollPath"
  $manifest    = Get-Content (Join-Path $RepoRoot "widget\manifest.json") -Raw | ConvertFrom-Json
  $ClientVer   = if ($manifest.version) { $manifest.version } else { "unknown" }

  Say "Botzy Tokenizer installer  (client_ver=$ClientVer, port=$BridgePort)"
  if ($DryRun) { Say ">>> DRYRUN: no disk or network changes will be made." }

  # -------- STEP 1 pre-flight
  Step 1 "pre-flight checks"
  if (-not (Get-Command python -ErrorAction SilentlyContinue)) { Die "python is required (python.exe on PATH)." }
  # parse python version PS-native (no inline Python: tuples/quotes inside a PS
  # string break the parser on real Windows PowerShell 5.1).
  $raw = (& python --version 2>&1 | Out-String).Trim()   # e.g. "Python 3.14.0"
  if (-not $raw -or $raw -notmatch 'Python\s+(\d+)\.(\d+)') {
    Die "python >= 3.9 required but its version could not be determined (got '$raw')."
  }
  $maj = [int]$Matches[1]; $min = [int]$Matches[2]
  $pyv = "$maj.$min"
  if ($maj -lt 3 -or ($maj -eq 3 -and $min -lt 9)) { Die "python >= 3.9 required (have $pyv)." }
  Say "  os: windows ; python $pyv"

  # -------- STEP 2 idempotency
  Step 2 "idempotency guard"
  if (Test-Path $CredsPath) {
    Say "  already installed (creds.json present at $CredsPath)."
    Say "  to reinstall: run uninstall.ps1 first. Nothing changed."
    exit 0
  }
  Say "  no prior install detected - proceeding."

  # -------- STEP 3 install dirs
  Step 3 "create install dirs"
  if ($DryRun) { Say "  (dryrun) would create: $InstallRoot , $LogDir" }
  else { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; Say "  [ok] $InstallRoot" }

  # -------- STEP 4 copy payload
  Step 4 "copy reader\ + widget\ into install root"
  $ReaderDst = Join-Path $InstallRoot "reader"
  $WidgetDst = Join-Path $InstallRoot "widget"
  if ($DryRun) {
    Say "  (dryrun) would copy reader -> $ReaderDst ; widget -> $WidgetDst"
  } else {
    Backup-IfExists $ReaderDst; Backup-IfExists $WidgetDst
    if (Test-Path $ReaderDst) { Remove-Item -Recurse -Force $ReaderDst }
    if (Test-Path $WidgetDst) { Remove-Item -Recurse -Force $WidgetDst }
    Copy-Item -Recurse (Join-Path $RepoRoot "reader") $ReaderDst
    Copy-Item -Recurse (Join-Path $RepoRoot "widget") $WidgetDst
    Say "  [ok] reader -> $ReaderDst"; Say "  [ok] widget -> $WidgetDst"
  }

  # -------- STEP 5 self-enroll
  Step 5 "self-enroll with the server"
  if ($DryRun) {
    Say "  (dryrun) would POST $EnrollUrl body={client_ver=$ClientVer,invite_code=null}"
  } else {
    $body = @{ client_ver = $ClientVer; invite_code = $null } | ConvertTo-Json -Compress
    try {
      $resp = Invoke-WebRequest -Uri $EnrollUrl -Method POST -ContentType "application/json" `
                -Body $body -TimeoutSec 15 -UseBasicParsing
      $code = [int]$resp.StatusCode
    } catch {
      $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
      $resp = $_.Exception.Response
    }
    switch ($code) {
      201 {
        $json = $resp.Content | ConvertFrom-Json
        if (-not $json.registry_id) { $resp.Content | Set-Content (Join-Path $LogDir "enroll_err.log"); Die "enroll 201 but no registry_id." }
        $resp.Content | Set-Content -Path $CredsPath -Encoding utf8
        # 0600-equivalent: restrict ACL to current user
        icacls $CredsPath /inheritance:r /grant:r "$($env:USERNAME):(R,W)" | Out-Null
        $script:CreatedCreds = $CredsPath
        Say "  [ok] enrolled (201) - creds.json written (user-only ACL)"
      }
      429 { Die "rate limit (429) - try again later." }
      503 { Die "self-enroll disabled server-side (503) - contact ops." }
      0   { Die "could not reach $EnrollUrl (network/timeout)." }
      default {
        if ($resp.Content) { $resp.Content | Set-Content (Join-Path $LogDir "enroll_err.log") }
        Die "enroll failed (HTTP $code) - see $LogDir\enroll_err.log"
      }
    }
  }

  $RegId = "unknown"
  if (Test-Path $CredsPath) { $RegId = (Get-Content $CredsPath -Raw | ConvertFrom-Json).registry_id }
  $RegShort = if ($RegId.Length -ge 8) { $RegId.Substring(0,8) + "..." } else { $RegId }

  # -------- STEP 6 auto-start (Task Scheduler, user-level)
  Step 6 "register auto-start (Task Scheduler, user-level)"
  $ReaderExec = Join-Path $ReaderDst "local_bridge.py"
  if ($NoService) {
    Say "  BOTZY_NO_SERVICE=1 - skipping Task Scheduler."
    if (-not $DryRun) {
      $p = Start-Process -FilePath "python" -ArgumentList "`"$ReaderExec`"" -WindowStyle Hidden -PassThru
      $p.Id | Set-Content (Join-Path $InstallRoot "reader.pid")
      Say "  reader launched (pid $($p.Id)), no scheduled task."
    }
  } elseif ($DryRun) {
    Say "  (dryrun) would register scheduled task 'BotzyTokenizerReader' for: python $ReaderExec"
  } else {
    $action  = New-ScheduledTaskAction -Execute "python" -Argument "`"$ReaderExec`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName "BotzyTokenizerReader" -Action $action -Trigger $trigger `
      -Settings $set -User $env:USERNAME -RunLevel Limited -Force | Out-Null
    Start-ScheduledTask -TaskName "BotzyTokenizerReader"
    Say "  [ok] scheduled task 'BotzyTokenizerReader' registered + started"
  }

  # -------- STEP 7 smoke /health
  Step 7 "smoke test: reader /health"
  if ($DryRun) {
    Say "  (dryrun) would GET http://127.0.0.1:$BridgePort/health (expect ok:true)"
  } else {
    $ok = $false
    for ($i=0; $i -lt 10; $i++) {
      try {
        $h = Invoke-RestMethod -Uri "http://127.0.0.1:$BridgePort/health" -TimeoutSec 3
        if ($h.ok -eq $true) { $ok = $true; break }
      } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $ok) { Die "reader did not answer /health on 127.0.0.1:$BridgePort - see $LogDir\reader.out" }
    Say "  [ok] reader healthy on 127.0.0.1:$BridgePort"
  }

  # -------- STEP 8 browser nudge
  Step 8 "open chrome://extensions + copy widget path"
  if ($NoBrowser) {
    Say "  BOTZY_NO_BROWSER=1 - skipping browser open + clipboard."
  } elseif ($DryRun) {
    Say "  (dryrun) would open chrome://extensions and copy: $WidgetDst"
  } else {
    try { Start-Process "chrome.exe" "chrome://extensions" } catch {
      try { Start-Process "msedge.exe" "edge://extensions" } catch { Say "  (open chrome://extensions manually)" } }
    Set-Clipboard -Value $WidgetDst
    Say "  [ok] widget path copied to clipboard"
    Say ""
    Say "  +----------------------------------------------------------+"
    Say "  |  WIDGET - 2 CLICKS LEFT                                   |"
    Say "  |                                                          |"
    Say "  |  1.  Toggle  'Developer mode'  ON  (top-right)           |"
    Say "  |  2.  Click   'Load unpacked'  ->  Ctrl+V  ->  Enter      |"
    Say "  |                                                          |"
    Say "  |  (folder path is already in your clipboard)              |"
    Say "  +----------------------------------------------------------+"
    Say "   path: $WidgetDst"
  }

  # -------- STEP 9 done
  Step 9 "done"
  if ($DryRun) { Say "  [ok] DRYRUN complete - no changes made. exit 0."; exit 0 }
  $TokenFile = Join-Path $ReaderDst ".bridge_token"
  Say ""
  Say "--------------------------------------------------------------"
  Say " [ok] Botzy Tokenizer installed."
  Say "   registry_id : $RegShort"
  Say "   creds       : $CredsPath"
  Say "   reader      : $ReaderExec"
  Say "   uninstall   : powershell -File `"$ScriptDir\uninstall.ps1`""
  Say "   feedback    : powershell -File `"$ScriptDir\send_feedback.ps1`" `"<note>`""
  if (Test-Path $TokenFile) {
    Say "   optional    : pair the reader - paste this token into the widget"
    Say "                 (Settings -> Bridge token):"
    Say "                 $(Get-Content $TokenFile -Raw)"
  }
  Say "--------------------------------------------------------------"
  exit 0
}
catch {
  Write-Host "`n[x] setup failed: $($_.Exception.Message)" -ForegroundColor Red
  if ($script:CreatedCreds -and (Test-Path $script:CreatedCreds)) {
    Remove-Item -Force $script:CreatedCreds
    Write-Host "  rolled back: removed creds.json created this run." -ForegroundColor Yellow
  }
  exit 1
}

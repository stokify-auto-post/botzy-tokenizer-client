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

  # E1/E4 (soft): the opt-in daily UPLOAD (Fernet) needs `cryptography`; config/URL
  # resolution needs `PyYAML`. Non-fatal — bridge + basic monitoring work without
  # them — but we actively try to provide them (best-effort pip) so the upload/
  # delivery layer isn't silently disabled on a clean machine.
  $UploadDeps = $true
  & python -c "import yaml, cryptography" 2>$null; if ($LASTEXITCODE -ne 0) { $UploadDeps = $false }
  if (-not $UploadDeps -and -not $DryRun) {
    Say "  installing upload deps (cryptography, PyYAML) - best effort, user-level..."
    & python -m pip install --user --quiet cryptography pyyaml 2>$null | Out-Null
    & python -c "import yaml, cryptography" 2>$null; if ($LASTEXITCODE -eq 0) { $UploadDeps = $true }
  }
  if ($UploadDeps) {
    Say "  deps: cryptography + PyYAML present (daily upload enabled)"
  } else {
    Say "  note: cryptography/PyYAML missing and auto-install failed - daily usage"
    Say "        upload/delivery stays OFF until: pip install --user cryptography pyyaml."
    Say "        Bridge + widget + live monitoring are unaffected."
  }

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

  # -------- STEP 6 auto-start (Startup-folder .vbs launcher — admin-less)
  # Round-1 used HKCU\...\Run, but a multi-quoted Run value ("pythonw" "script"
  # --config "..." --logfile "...") is parsed UNRELIABLY by the Run-key launcher
  # at logon (the exact same command runs fine manually). Fix: a .vbs in the
  # user's Startup folder calling WScript.Shell.Run(cmd,0,False) - 0 = hidden
  # (no console flash), and VBScript handles the inner quotes cleanly. No admin.
  Step 6 "register auto-start (Startup-folder launcher, no admin)"
  $ReaderExec = Join-Path $ReaderDst "local_bridge.py"
  $ReaderCfg  = Join-Path $ReaderDst "bridge_local_config.yaml"
  $ReaderOut  = Join-Path $LogDir "reader.out"
  $PidFile    = Join-Path $InstallRoot "reader.pid"
  $RunKey     = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
  $RunName    = "BotzyTokenizerReader"
  $StartupDir = [Environment]::GetFolderPath('Startup')
  $VbsPath    = Join-Path $StartupDir "BotzyTokenizerReader.vbs"

  # resolve pythonw.exe (no-console interpreter); fall back to python.exe hidden.
  $pyw = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
  if (-not $pyw) {
    $pyexe = (Get-Command python -ErrorAction SilentlyContinue).Source
    if ($pyexe) { $cand = $pyexe -replace 'python\.exe$','pythonw.exe'; if (Test-Path $cand) { $pyw = $cand } }
  }
  $Launcher     = if ($pyw) { $pyw } else { (Get-Command python).Source }
  $HiddenViaPyw = [bool]$pyw
  # FULL absolute --config + --logfile so a logon launch (arbitrary cwd) is robust.
  $LaunchArgs   = "`"$ReaderExec`" --config `"$ReaderCfg`" --logfile `"$ReaderOut`""
  $RunCmd       = "`"$Launcher`" $LaunchArgs"
  $VbsEsc       = $RunCmd -replace '"','""'   # VBScript literal: every " is doubled

  if ($DryRun) {
    Say "  (dryrun) would write Startup launcher: $VbsPath"
    Say "  (dryrun) would remove any old HKCU Run '$RunName'"
    Say "  (dryrun) would launch reader hidden ($Launcher) + write $PidFile"
  } else {
    # remove any old round-1 HKCU\...\Run entry (export -> bak -> delete) so no
    # dead/duplicate launcher is left behind.
    $oldRun = $null
    try { $oldRun = (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue).$RunName } catch {}
    if ($oldRun) {
      $oldRun | Set-Content (Join-Path $InstallRoot "run_key.bak_$TS")
      Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
      Say "  [ok] removed old HKCU Run entry (backed up -> $InstallRoot\run_key.bak_$TS)"
    }

    if ($NoService) {
      Say "  BOTZY_NO_SERVICE=1 - skipping Startup launcher (reader still launched)."
    } else {
      # back up an existing launcher, then (re)write the .vbs (idempotent re-run)
      if (Test-Path $VbsPath) {
        Copy-Item -Force $VbsPath "$VbsPath.bak_$TS"
        Say "  [ok] backup: existing launcher -> $VbsPath.bak_$TS"
      }
      $vbs = @(
        "' Botzy Tokenizer - reader auto-start (hidden, no console window).",
        "' Generated by setup.ps1. Delete this file to disable auto-start.",
        'Set sh = CreateObject("WScript.Shell")',
        "sh.Run `"$VbsEsc`", 0, False"
      )
      $genOk = $false; $genErr = "unknown error"
      try {
        Set-Content -Path $VbsPath -Value $vbs -Encoding Default
        if (Test-Path $VbsPath) { $genOk = $true } else { $genErr = "launcher file not found after write" }
      } catch { $genErr = $_.Exception.Message }
      if ($genOk) {
        Say "  [ok] auto-start launcher created: $VbsPath (runs hidden at next logon)"
      } else {
        Say "  [x] auto-start launcher NOT created: $genErr"
        Say "      reader still runs THIS session; to auto-start at logon yourself,"
        Say "      run this command hidden (or drop a Startup shortcut to it):"
        Say "        $RunCmd"
      }
    }

    # launch the reader NOW so the widget + smoke test work immediately, hidden.
    if (-not $HiddenViaPyw) { Say "  [!] pythonw.exe not found - using python.exe hidden (a console may flash)." }
    try {
      $p = Start-Process -FilePath $Launcher -ArgumentList $LaunchArgs -WindowStyle Hidden -PassThru
      $p.Id | Set-Content $PidFile
      Say "  [ok] reader launched (pid $($p.Id)), logging -> $ReaderOut"
    } catch {
      Die "could not launch reader: $($_.Exception.Message)"
    }
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
    if (-not $ok) {
      if (Test-Path $ReaderOut) {
        Say "  --- last lines of $ReaderOut ---"
        Get-Content $ReaderOut -Tail 15 | ForEach-Object { Say "  | $_" }
      } else { Say "  (no $ReaderOut yet - reader never produced output)" }
      Die "reader did not answer /health on 127.0.0.1:$BridgePort (see $ReaderOut above)."
    }
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

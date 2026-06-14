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

# 1. remove scheduled task
$task = Get-ScheduledTask -TaskName "BotzyTokenizerReader" -ErrorAction SilentlyContinue
if ($task) {
  Stop-ScheduledTask  -TaskName "BotzyTokenizerReader" -ErrorAction SilentlyContinue
  Unregister-ScheduledTask -TaskName "BotzyTokenizerReader" -Confirm:$false
  Say "  [ok] scheduled task removed"
} else { Say "  (no scheduled task - already removed)" }

# kill a no-service launched reader, if any
$pidFile = Join-Path $InstallRoot "reader.pid"
if (Test-Path $pidFile) {
  $procId = Get-Content $pidFile
  Stop-Process -Id $procId -ErrorAction SilentlyContinue
  Say "  [ok] stopped reader pid $procId"
}

# 2. server-side wipe
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
    else { Say "  [!] wipe returned HTTP $code - continuing local cleanup; re-run later if needed." }
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
  Remove-Item -Recurse -Force $InstallRoot
  Say "  [ok] removed $InstallRoot"
} else { Say "  (install root already gone)" }

Say ""
Say "Uninstalled. Widget removal: chrome://extensions -> remove 'Botzy Tokenizer'."
if (Test-Path "$InstallRoot-backups") { Say "Backups kept at: $InstallRoot-backups" }
exit 0

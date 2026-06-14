# Botzy Tokenizer - feedback channel (Windows native, PowerShell 5.1+).
#   powershell -File send_feedback.ps1 "your note here"
# The note is the only freeform field sent. No user paths/env/registry_id beyond
# what the server already knows. On 404 the note is queued locally and replayed.
param([Parameter(Mandatory=$true)][string]$Note)
$ErrorActionPreference = "Stop"

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$ConfigFile = Join-Path $ScriptDir "installer_config.yaml"

function Say($m) { Write-Host $m }
function Cfg($key) {
  $line = Select-String -Path $ConfigFile -Pattern "^\s*$key\s*:" | Select-Object -First 1
  if (-not $line) { Write-Host "[x] config key '$key' not found"; exit 1 }
  $v = ($line.Line -split ":",2)[1]
  $v = $v -replace '\s+#.*$','' -replace '^\s+','' -replace '\s+$',''
  $v = $v.Trim('"') -replace '\$\{HOME\}',$env:USERPROFILE
  return $v
}

if ([string]::IsNullOrWhiteSpace($Note)) { Say "usage: send_feedback.ps1 `"<note>`""; exit 2 }
if ($Note.Length -gt 4000) { Say "[x] note too long ($($Note.Length) chars, max 4000)."; exit 2 }

$ServerBase   = Cfg "server_base"
$FeedbackPath = Cfg "feedback_path"
$CredsPath    = Cfg "creds_path"
$InstallRoot  = Split-Path -Parent $CredsPath
$FeedbackUrl  = "$ServerBase$FeedbackPath"
$PendingLog   = Join-Path $InstallRoot "feedback_pending.log"

$manifest  = Get-Content (Join-Path $RepoRoot "widget\manifest.json") -Raw | ConvertFrom-Json
$ClientVer = if ($manifest.version) { $manifest.version } else { "unknown" }
$UtcTs     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$payload = @{ note = $Note; client_ver = $ClientVer; os = "windows"; ts = $UtcTs } | ConvertTo-Json -Compress

$hdr = @{}
if (Test-Path $CredsPath) {
  $tok = (Get-Content $CredsPath -Raw | ConvertFrom-Json).install_token
  if ($tok) { $hdr["Authorization"] = "Bearer $tok" }
}

function Queue-Note {
  New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
  Add-Content -Path $PendingLog -Value $payload
  Say "  note queued locally at $PendingLog"
}

try {
  $resp = Invoke-WebRequest -Uri $FeedbackUrl -Method POST -Headers $hdr `
            -ContentType "application/json" -Body $payload -TimeoutSec 15 -UseBasicParsing
  $ack = ""
  try { $j = $resp.Content | ConvertFrom-Json; $ack = if ($j.ack_id) { $j.ack_id } elseif ($j.id) { $j.id } else { "" } } catch {}
  if ($ack) { Say "thanks, note received. ack: $ack" } else { Say "thanks, note received." }
} catch {
  $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
  switch ($code) {
    404 { Say "feedback endpoint not live yet (404)."; Queue-Note; Say "it will be sent on a future run once the endpoint is up." }
    429 { Say "rate limited (429) - try again later."; Queue-Note }
    0   { Say "could not reach $FeedbackUrl (network/timeout)."; Queue-Note }
    default { Say "feedback POST returned HTTP $code."; Queue-Note }
  }
}
exit 0

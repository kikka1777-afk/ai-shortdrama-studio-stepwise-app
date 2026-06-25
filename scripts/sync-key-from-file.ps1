param(
  [string]$BaseUrl = "https://sub2api.aisite.net/v1",
  [string]$Project = "ai-shortdrama-studio-stepwise-app",
  [string]$ProductionUrl = "https://ai-shortdrama-studio-stepwise-app.vercel.app",
  [string]$KeyFile = "OPENAI_API_KEY.local.txt",
  [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$logPath = Join-Path $PSScriptRoot "sync-key-last.log"

function Log {
  param([string]$Text)
  $line = "[" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "] " + $Text
  $line | Tee-Object -FilePath $logPath -Append
}

function Invoke-Vercel {
  param([string[]]$VercelArgs)

  $vercelCmd = Get-Command vercel -ErrorAction SilentlyContinue
  if ($vercelCmd) {
    & $vercelCmd.Source @VercelArgs 2>&1 | Tee-Object -FilePath $logPath -Append
    if ($LASTEXITCODE -ne 0) { throw "vercel exited with code $LASTEXITCODE" }
    return
  }

  & npx --yes vercel@latest @VercelArgs 2>&1 | Tee-Object -FilePath $logPath -Append
  if ($LASTEXITCODE -ne 0) { throw "npx vercel exited with code $LASTEXITCODE" }
}

function Invoke-VercelWithInput {
  param(
    [string]$InputValue,
    [string[]]$VercelArgs
  )

  $vercelCmd = Get-Command vercel -ErrorAction SilentlyContinue
  if ($vercelCmd) {
    $InputValue | & $vercelCmd.Source @VercelArgs 2>&1 | Tee-Object -FilePath $logPath -Append
    if ($LASTEXITCODE -ne 0) { throw "vercel exited with code $LASTEXITCODE" }
    return
  }

  $InputValue | & npx --yes vercel@latest @VercelArgs 2>&1 | Tee-Object -FilePath $logPath -Append
  if ($LASTEXITCODE -ne 0) { throw "npx vercel exited with code $LASTEXITCODE" }
}

function Set-VercelProductionEnv {
  param(
    [string]$Name,
    [string]$Value
  )

  Log "Syncing $Name to $Project production..."
  try {
    Invoke-Vercel -VercelArgs @("env", "rm", $Name, "production", "--yes", "--no-color", "--project", $Project)
  } catch {
    Log "$Name did not exist or could not be removed first; continuing."
  }
  Invoke-VercelWithInput -InputValue $Value -VercelArgs @("env", "add", $Name, "production", "--no-color", "--project", $Project)
}

function Verify-ProductionStatus {
  if ([string]::IsNullOrWhiteSpace($ProductionUrl)) { return }

  $statusUrl = $ProductionUrl.TrimEnd("/") + "/api/generate"
  Log "Checking production API status: $statusUrl"
  $status = Invoke-RestMethod -Uri $statusUrl -Method Get -TimeoutSec 60
  Log ("Production hasServerKey=" + $status.hasServerKey + "; base=" + $status.base + "; timeoutMs=" + $status.timeoutMs)
}

try {
  Set-Location -LiteralPath $projectRoot
  Remove-Item $logPath -Force -ErrorAction SilentlyContinue
  Log "Target Vercel project: $Project"

  $resolvedKeyFile = Join-Path $PSScriptRoot $KeyFile
  if (!(Test-Path -LiteralPath $resolvedKeyFile)) {
    throw "Missing key file: $resolvedKeyFile"
  }

  $plainKey = (Get-Content -Raw -LiteralPath $resolvedKeyFile).Trim()
  if ([string]::IsNullOrWhiteSpace($plainKey)) {
    throw "OPENAI_API_KEY.local.txt is empty."
  }

  Set-VercelProductionEnv -Name "OPENAI_BASE_URL" -Value $BaseUrl
  Set-VercelProductionEnv -Name "OPENAI_API_KEY" -Value $plainKey

  $plainKey = $null
  [GC]::Collect()

  if (-not $SkipDeploy) {
    Log "Redeploying production..."
    Invoke-Vercel -VercelArgs @("deploy", "--prod", "--no-color", "--non-interactive", "--project", $Project)
  }

  Verify-ProductionStatus

  Log "Done. Teammates can now use the app without entering Base URL or key."
  $global:SyncExitCode = 0
} catch {
  Log "FAILED: $($_.Exception.Message)"
  $global:SyncExitCode = 1
} finally {
  Write-Host ""
  Write-Host "Log file: $logPath"
  Read-Host "Press Enter to close this window"
}

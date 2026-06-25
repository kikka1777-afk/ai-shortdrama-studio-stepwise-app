param(
  [string]$BaseUrl = "https://sub2api.aisite.net/v1",
  [string]$Project = "ai-shortdrama-studio-stepwise-app",
  [string]$ProductionUrl = "https://ai-shortdrama-studio-stepwise-app.vercel.app",
  [switch]$SkipDeploy
)

$ErrorActionPreference = "Stop"

function Get-PlainTextFromSecureString {
  param([securestring]$Secure)

  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
  try {
    [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
}

function Invoke-Vercel {
  param([string[]]$VercelArgs)

  $vercelCmd = Get-Command vercel -ErrorAction SilentlyContinue
  if ($vercelCmd) {
    & $vercelCmd.Source @VercelArgs
    return
  }

  & npx --yes vercel@latest @VercelArgs
}

function Invoke-VercelWithInput {
  param(
    [string]$InputValue,
    [string[]]$VercelArgs
  )

  $vercelCmd = Get-Command vercel -ErrorAction SilentlyContinue
  if ($vercelCmd) {
    $InputValue | & $vercelCmd.Source @VercelArgs
    return
  }

  $InputValue | & npx --yes vercel@latest @VercelArgs
}

function Set-VercelProductionEnv {
  param(
    [string]$Name,
    [string]$Value
  )

  Write-Host "Syncing $Name to Vercel production..."

  try {
    Invoke-Vercel -VercelArgs @("env", "rm", $Name, "production", "--yes", "--no-color", "--project", $Project) | Out-Host
  } catch {
    Write-Host "$Name did not exist or could not be removed first; continuing..."
  }

  Invoke-VercelWithInput -InputValue $Value -VercelArgs @("env", "add", $Name, "production", "--no-color", "--project", $Project) | Out-Host
}

function Verify-ProductionStatus {
  if ([string]::IsNullOrWhiteSpace($ProductionUrl)) { return }

  $statusUrl = $ProductionUrl.TrimEnd("/") + "/api/generate"
  Write-Host "Checking production API status: $statusUrl"
  $status = Invoke-RestMethod -Uri $statusUrl -Method Get -TimeoutSec 60
  Write-Host ("Production hasServerKey=" + $status.hasServerKey + "; base=" + $status.base + "; timeoutMs=" + $status.timeoutMs)
}

try {
  $projectRoot = Split-Path -Parent $PSScriptRoot
  Set-Location -LiteralPath $projectRoot

  Write-Host ""
  Write-Host "Target Vercel project: $Project"
  Write-Host "OPENAI_BASE_URL will be set to: $BaseUrl"
  Write-Host ""

  $secureKey = Read-Host "Paste OPENAI_API_KEY / Sub2API key" -AsSecureString
  $plainKey = Get-PlainTextFromSecureString $secureKey

  if ([string]::IsNullOrWhiteSpace($plainKey)) {
    throw "OPENAI_API_KEY is empty."
  }

  Set-VercelProductionEnv -Name "OPENAI_BASE_URL" -Value $BaseUrl
  Set-VercelProductionEnv -Name "OPENAI_API_KEY" -Value $plainKey

  $plainKey = $null
  [GC]::Collect()

  if (-not $SkipDeploy) {
    Write-Host "Redeploying production..."
    Invoke-Vercel -VercelArgs @("deploy", "--prod", "--no-color", "--non-interactive", "--project", $Project) | Out-Host
  }

  Verify-ProductionStatus

  Write-Host ""
  Write-Host "Done. Teammates can now use the app without entering Base URL or key."
} catch {
  Write-Host ""
  Write-Host "FAILED:" -ForegroundColor Red
  Write-Host $_.Exception.Message -ForegroundColor Red
  Write-Host ""
  Write-Host "If this says Vercel is not logged in, run: vercel login"
} finally {
  Write-Host ""
  Read-Host "Press Enter to close this window"
}

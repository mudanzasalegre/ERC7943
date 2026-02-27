param(
  [string]$PrivateKey = "",
  [string]$RpcUrl = "https://sepolia.base.org",
  [int]$CampaignCount = 3,
  [switch]$SkipBuild,
  [switch]$SkipDev
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Ensure-Command {
  param([string]$Name)

  if (Get-Command $Name -ErrorAction SilentlyContinue) {
    return
  }

  $foundryBin = Join-Path $HOME ".foundry\bin"
  $candidateExe = Join-Path $foundryBin "$Name.exe"
  $candidateBare = Join-Path $foundryBin $Name
  if ((Test-Path $candidateExe) -or (Test-Path $candidateBare)) {
    if ($env:PATH -notlike "*$foundryBin*") {
      $env:PATH = "$foundryBin;$env:PATH"
    }
  }

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "Missing required command: $Name"
  }
}

function Invoke-ExternalStep {
  param(
    [string]$Name,
    [scriptblock]$Action
  )

  Write-Host ""
  Write-Host "==> $Name" -ForegroundColor Cyan
  & $Action
  if ($LASTEXITCODE -ne 0) {
    throw "Step failed: $Name"
  }
}

function Get-LatestRunFile {
  param(
    [string]$ContractsDir,
    [string]$ScriptBaseName,
    [int]$ChainId,
    [datetime]$NotBefore = [datetime]::MinValue
  )

  $scriptDir = Join-Path (Join-Path $ContractsDir "broadcast") "$ScriptBaseName.s.sol"
  $chainDir = Join-Path $scriptDir "$ChainId"
  $direct = Join-Path $chainDir "run-latest.json"
  $threshold = $NotBefore

  $timestamped = @()
  if (Test-Path $chainDir) {
    $timestamped = @(Get-ChildItem -Path $chainDir -File -Filter "run-*.json" -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne "run-latest.json" })
  }

  if ($NotBefore -ne [datetime]::MinValue) {
    $timestamped = @($timestamped | Where-Object { $_.LastWriteTime -ge $threshold })
  }

  $latest = $timestamped |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($latest) {
    return $latest.FullName
  }

  if (Test-Path $direct) {
    if ($NotBefore -eq [datetime]::MinValue) {
      return $direct
    }

    $latestDirect = Get-Item $direct
    if ($latestDirect.LastWriteTime -ge $threshold) {
      return $direct
    }
  }

  if ($NotBefore -ne [datetime]::MinValue) {
    throw "run file not found for $ScriptBaseName (chain $ChainId) after $NotBefore."
  }

  $fallback = Get-ChildItem -Path $scriptDir -Recurse -Filter "run-latest.json" -ErrorAction SilentlyContinue |
    Where-Object {
      if ($NotBefore -eq [datetime]::MinValue) { return $true }
      return $_.LastWriteTime -ge $threshold
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($fallback) {
    return $fallback.FullName
  }

  if (-not $latest) {
    throw "run-latest.json not found for $ScriptBaseName (chain $ChainId, not-before $NotBefore)."
  }

  return $latest.FullName
}

function Test-AddressHasCode {
  param(
    [string]$Address,
    [string]$RpcUrl
  )

  if ([string]::IsNullOrWhiteSpace($Address)) {
    return $false
  }

  $raw = (& cast code $Address --rpc-url $RpcUrl 2>$null) -join ""
  if ($LASTEXITCODE -ne 0) {
    return $false
  }

  $code = $raw.Trim()
  if ([string]::IsNullOrWhiteSpace($code)) {
    return $false
  }
  if ($code -eq "0x") {
    return $false
  }
  if ($code -eq "0x0") {
    return $false
  }

  return $true
}

function Parse-ChainId {
  param([string]$Raw)

  $value = $Raw.Trim()
  if ($value -match "^0x[0-9a-fA-F]+$") {
    return [Convert]::ToInt32($value.Substring(2), 16)
  }
  return [int]$value
}

function Parse-BlockNumber {
  param([string]$Raw)

  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return 0
  }
  $value = $Raw.Trim()
  if ($value -match "^0x[0-9a-fA-F]+$") {
    return [Convert]::ToUInt64($value.Substring(2), 16)
  }
  return [UInt64]$value
}

function Normalize-OptionalAddress {
  param([string]$Address)

  if ([string]::IsNullOrWhiteSpace($Address)) {
    return ""
  }
  if ($Address -eq "0x0000000000000000000000000000000000000000") {
    return ""
  }
  return $Address
}

function Get-CampaignStack {
  param(
    [string]$Factory,
    [string]$CampaignId,
    [string]$RpcUrl
  )

  $signature = "stacks(bytes32)(address,address,address,address,address,address,address,address,address,address,address,address,address,address,address,address,address,address)"
  $raw = (& cast call $Factory $signature $CampaignId --rpc-url $RpcUrl) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to read factory.stacks($CampaignId)"
  }

  $addresses = [regex]::Matches($raw, "0x[a-fA-F0-9]{40}") | ForEach-Object { $_.Value }
  if ($addresses.Count -lt 18) {
    throw "Unexpected stacks() output for $CampaignId. Expected 18 addresses, got $($addresses.Count)."
  }

  $names = @(
    "roleManager",
    "registry",
    "shareToken",
    "treasury",
    "fundingManager",
    "settlementQueue",
    "identityAttestation",
    "compliance",
    "disaster",
    "freezeModule",
    "forcedTransferController",
    "custody",
    "trace",
    "documentRegistry",
    "batchAnchor",
    "snapshot",
    "distribution",
    "insurance"
  )

  $stack = [ordered]@{}
  for ($i = 0; $i -lt $names.Count; $i++) {
    $stack[$names[$i]] = $addresses[$i]
  }

  return [pscustomobject]$stack
}

function Update-EnvFile {
  param(
    [string]$Path,
    [hashtable]$Values
  )

  $lines = New-Object System.Collections.Generic.List[string]
  if (Test-Path $Path) {
    (Get-Content $Path) | ForEach-Object { [void]$lines.Add($_) }
  }

  foreach ($key in $Values.Keys) {
    $escaped = [regex]::Escape($key)
    $newLine = "$key=$($Values[$key])"
    $found = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match "^\s*$escaped=") {
        $lines[$i] = $newLine
        $found = $true
        break
      }
    }

    if (-not $found) {
      [void]$lines.Add($newLine)
    }
  }

  Set-Content -Path $Path -Value $lines -Encoding UTF8
}

function Get-EnvMap {
  param([string]$Path)

  $map = @{}
  if (-not (Test-Path $Path)) {
    return $map
  }

  foreach ($line in Get-Content $Path) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*$') { continue }

    $parts = $line -split "=", 2
    if ($parts.Count -lt 2) { continue }

    $key = $parts[0].Trim()
    if ([string]::IsNullOrWhiteSpace($key)) { continue }

    $map[$key] = $parts[1]
  }

  return $map
}

function Get-EnvMapValueOrDefault {
  param(
    [hashtable]$Map,
    [string]$Key,
    [string]$Default = ""
  )

  if ($Map.ContainsKey($Key)) {
    return [string]$Map[$Key]
  }

  return $Default
}

function Remove-FileWithRetry {
  param(
    [string]$Path,
    [int]$MaxAttempts = 30,
    [int]$DelayMs = 200
  )

  if ([string]::IsNullOrWhiteSpace($Path)) {
    return
  }

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    if (-not (Test-Path $Path)) {
      return
    }

    try {
      Remove-Item -Path $Path -Force -ErrorAction Stop
      return
    }
    catch {
      if ($attempt -lt $MaxAttempts) {
        Start-Sleep -Milliseconds $DelayMs
      }
      else {
        Write-Host "Warning: unable to remove temp file after $MaxAttempts attempts: $Path" -ForegroundColor Yellow
      }
    }
  }
}

function Stop-ProcessTree {
  param([System.Diagnostics.Process]$Process)

  if (-not $Process) {
    return
  }

  if ($Process.HasExited) {
    return
  }

  try {
    & taskkill /PID $Process.Id /T /F | Out-Null
  }
  catch {
    try { $Process.Kill() } catch {}
  }

  try { $Process.WaitForExit(10000) | Out-Null } catch {}
}

function Invoke-NpmDevUntilReady {
  param(
    [string]$WorkingDirectory,
    [int]$ReadyTimeoutSeconds = 300
  )

  $tmpSuffix = "$PID-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
  $stdoutTmp = Join-Path $WorkingDirectory ".deploy-and-wire-dev.$tmpSuffix.stdout.tmp.log"
  $stderrTmp = Join-Path $WorkingDirectory ".deploy-and-wire-dev.$tmpSuffix.stderr.tmp.log"
  $process = $null

  # Always launch through cmd on Windows; npm can resolve to .ps1/.cmd shims that are not valid Win32 executables.
  $process = Start-Process -FilePath $env:ComSpec -ArgumentList "/d /c npm run dev" -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $stdoutTmp -RedirectStandardError $stderrTmp -PassThru

  $readySeen = $false
  $stdoutSeen = 0
  $stderrSeen = 0

  $startedAt = Get-Date
  try {
    while (-not $readySeen) {
      $stdoutLines = @()
      $stderrLines = @()
      if (Test-Path $stdoutTmp) {
        $stdoutLines = @(Get-Content $stdoutTmp -ErrorAction SilentlyContinue)
      }
      if (Test-Path $stderrTmp) {
        $stderrLines = @(Get-Content $stderrTmp -ErrorAction SilentlyContinue)
      }

      for ($i = $stdoutSeen; $i -lt $stdoutLines.Count; $i++) {
        $line = [string]$stdoutLines[$i]
        Write-Host $line
        if ($line -match "Ready in") {
          $readySeen = $true
        }
      }

      for ($i = $stderrSeen; $i -lt $stderrLines.Count; $i++) {
        $line = [string]$stderrLines[$i]
        Write-Host $line
        if ($line -match "Ready in") {
          $readySeen = $true
        }
      }

      $stdoutSeen = $stdoutLines.Count
      $stderrSeen = $stderrLines.Count

      if ($readySeen) {
        break
      }

      if ($process.HasExited) {
        break
      }

      $elapsed = (Get-Date) - $startedAt
      if ($elapsed.TotalSeconds -ge $ReadyTimeoutSeconds) {
        throw "Timed out waiting for Next.js dev server readiness."
      }

      Start-Sleep -Milliseconds 200
    }

    if (-not $readySeen) {
      if ($process.HasExited) {
        throw "npm run dev exited before reaching Ready (exit code: $($process.ExitCode))."
      }
      throw "npm run dev did not report Ready."
    }

    Write-Host "Dev server reached Ready state. Stopping npm run dev for scripted flow." -ForegroundColor Green
  }
  finally {
    Stop-ProcessTree -Process $process
    Remove-FileWithRetry -Path $stdoutTmp
    Remove-FileWithRetry -Path $stderrTmp
  }
}

function Assert-FrontendAbiExports {
  param([string]$WebDir)

  $requiredRelPaths = @(
    "src/abis/contracts/AgriCampaignRegistry.abi.json",
    "src/abis/contracts/CampaignFactory.abi.json",
    "src/abis/contracts/AgriShareToken.abi.json",
    "src/abis/contracts/SettlementQueue.abi.json",
    "src/abis/contracts/YieldAccumulator.abi.json",
    "src/abis/contracts/ComplianceModuleV1.abi.json",
    "src/abis/contracts/IdentityAttestation.abi.json",
    "src/abis/contracts/BatchMerkleAnchor.abi.json",
    "src/abis/interfaces/IAgriDistributionV1.abi.json",
    "src/abis/interfaces/IAgriComplianceV1.abi.json",
    "src/abis/interfaces/IAgriDisasterV1.abi.json",
    "src/abis/interfaces/IAgriModulesV1.abi.json",
    "src/abis/interfaces/IAgriTreasuryV1.abi.json",
    "src/abis/standards/IERC20.abi.json",
    "src/abis/standards/IERC20Decimals.abi.json"
  )

  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($rel in $requiredRelPaths) {
    $full = Join-Path $WebDir $rel
    if (-not (Test-Path $full)) {
      [void]$missing.Add($rel)
    }
  }

  if ($missing.Count -gt 0) {
    throw "ABI export validation failed. Missing files: $($missing -join ', ')"
  }

  Write-Host "ABI export validated (required frontend ABI paths exist)." -ForegroundColor Green
}

if ([string]::IsNullOrWhiteSpace($PrivateKey)) {
  throw "Provide your key with -PrivateKey `"0x...`" (or set $PrivateKey in this script)."
}

if ($PrivateKey -notmatch "^0x[0-9a-fA-F]{64}$") {
  throw "PrivateKey must be a 32-byte hex string with 0x prefix."
}

if ($CampaignCount -lt 1) {
  throw "CampaignCount must be >= 1."
}

$scriptPath = $PSCommandPath
if (-not $scriptPath) {
  $scriptPath = $MyInvocation.MyCommand.Path
}
if (-not $scriptPath) {
  throw "Unable to resolve script path."
}

$repoRoot = Split-Path -Parent $scriptPath
$contractsDir = Join-Path $repoRoot "contracts"
$webDir = Join-Path $repoRoot "web\uagri-dapp"
$webEnvExample = Join-Path $webDir ".env.example"
$webEnvLocal = Join-Path $webDir ".env.local"

if (-not (Test-Path $contractsDir)) {
  throw "contracts directory not found at $contractsDir"
}

if (-not (Test-Path $webDir)) {
  throw "web/uagri-dapp directory not found at $webDir"
}

Ensure-Command "forge"
Ensure-Command "cast"
Ensure-Command "npm"
Ensure-Command "node"

$logPath = Join-Path $repoRoot "deploy-and-wire-log.md"
$logTempPath = Join-Path $repoRoot "deploy-and-wire-log.tmp.txt"
$transcriptStarted = $false
$scriptSucceeded = $false

if (Test-Path $logTempPath) {
  Remove-Item $logTempPath -Force
}

Start-Transcript -Path $logTempPath -Force | Out-Null
$transcriptStarted = $true

try {
  Write-Host ""
  Write-Host "uAgri deploy-and-wire (Base Sepolia)" -ForegroundColor Green
  Write-Host "RPC: $RpcUrl"
  Write-Host "Campaigns to create: $CampaignCount"

  $env:PRIVATE_KEY = $PrivateKey
  $env:RPC_URL = $RpcUrl

  $chainIdRaw = (& cast chain-id --rpc-url $RpcUrl).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to read chain id from RPC URL."
  }

  $chainId = Parse-ChainId -Raw $chainIdRaw
  if ($chainId -ne 84532) {
    throw "Expected Base Sepolia chainId 84532, got $chainId. Check -RpcUrl."
  }

  $factoryAddress = ""
  $deployFromBlock = 0
  $campaignResults = New-Object System.Collections.Generic.List[object]

  Push-Location $contractsDir
  try {
    if (-not $SkipBuild) {
      Invoke-ExternalStep -Name "forge build" -Action { forge build }
    }

    $deployStepStart = Get-Date
    Invoke-ExternalStep -Name "DeployFactory.s.sol" -Action {
      forge script "script/DeployFactory.s.sol:DeployFactory" --rpc-url $RpcUrl --broadcast -vvvv
    }

    $deployRunFile = Get-LatestRunFile -ContractsDir $contractsDir -ScriptBaseName "DeployFactory" -ChainId $chainId -NotBefore $deployStepStart
    $deployRun = Get-Content $deployRunFile -Raw | ConvertFrom-Json
    $factoryAddress = [string]$deployRun.returns.factory.value

    if ([string]::IsNullOrWhiteSpace($factoryAddress)) {
      throw "factory address not found in $deployRunFile"
    }

    $factoryReady = $false
    for ($attempt = 1; $attempt -le 20; $attempt++) {
      if (Test-AddressHasCode -Address $factoryAddress -RpcUrl $RpcUrl) {
        $factoryReady = $true
        break
      }
      Start-Sleep -Milliseconds 400
    }
    if (-not $factoryReady) {
      throw "Factory address $factoryAddress has no code on RPC yet. Aborting before CreateCampaign."
    }

    if ($deployRun.receipts.Count -gt 0) {
      $deployFromBlock = Parse-BlockNumber -Raw ([string]$deployRun.receipts[0].blockNumber)
    }

    Write-Host "Factory: $factoryAddress"
    Write-Host "Deploy from block: $deployFromBlock"

    for ($i = 1; $i -le $CampaignCount; $i++) {
      $tag = "$(Get-Date -Format 'yyyyMMddHHmmss')-$i"
      $env:FACTORY = $factoryAddress
      $env:CAMPAIGN_ID_STR = "uAgri:base-sepolia:test:$tag"
      $env:PLOT_REF_STR = "uAgri:base-sepolia:plot:$tag"
      $env:DEPLOY_MOCK_ASSETS = "true"
      $env:OPEN_DEFAULT_PROFILE = "true"
      $env:BEGIN_ROLEMANAGER_ADMIN_HANDOFF = "false"
      $env:ACCEPT_ROLEMANAGER_ADMIN_HANDOFF = "false"

      if (-not (Test-AddressHasCode -Address $factoryAddress -RpcUrl $RpcUrl)) {
        throw "Factory $factoryAddress is not a deployed contract at current RPC view."
      }

      $createStepStart = Get-Date
      Invoke-ExternalStep -Name "CreateCampaign.s.sol #$i" -Action {
        forge script "script/CreateCampaign.s.sol:CreateCampaign" --rpc-url $RpcUrl --broadcast -vvvv
      }

      $campaignId = ""
      $stack = $null
      $stackRegistry = ""
      $stackRoleManager = ""
      $resolved = $false
      $lastResolveError = $null

      for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
          $createRunFile = Get-LatestRunFile -ContractsDir $contractsDir -ScriptBaseName "CreateCampaign" -ChainId $chainId -NotBefore $createStepStart
          $createRun = Get-Content $createRunFile -Raw | ConvertFrom-Json
          $campaignId = [string]$createRun.returns.campaignId.value

          if ([string]::IsNullOrWhiteSpace($campaignId)) {
            throw "campaignId not found in $createRunFile"
          }

          $stack = Get-CampaignStack -Factory $factoryAddress -CampaignId $campaignId -RpcUrl $RpcUrl
          $stackRegistry = Normalize-OptionalAddress -Address ([string]$stack.registry)
          $stackRoleManager = Normalize-OptionalAddress -Address ([string]$stack.roleManager)

          if ([string]::IsNullOrWhiteSpace($stackRegistry) -or [string]::IsNullOrWhiteSpace($stackRoleManager)) {
            throw "Stack for campaign $campaignId not fully available yet (registry/roleManager empty)."
          }

          $resolved = $true
          break
        }
        catch {
          $lastResolveError = $_
          if ($attempt -lt 8) {
            Start-Sleep -Milliseconds 400
          }
        }
      }

      if (-not $resolved) {
        throw "Unable to resolve campaign #$i metadata after retries. Last error: $lastResolveError"
      }

      $campaignResults.Add([pscustomobject]@{
        index = $i
        campaignId = $campaignId
        roleManager = $stack.roleManager
        registry = $stack.registry
        shareToken = $stack.shareToken
        treasury = $stack.treasury
        fundingManager = $stack.fundingManager
        settlementQueue = $stack.settlementQueue
        distribution = $stack.distribution
        documentRegistry = $stack.documentRegistry
        trace = $stack.trace
      }) | Out-Null

      Write-Host "Campaign #${i}: $campaignId"
    }
  }
  finally {
    Pop-Location
  }

  if ($campaignResults.Count -eq 0) {
    throw "No campaigns created."
  }

  $frontendSourceCampaign = $campaignResults |
    Where-Object {
      (Normalize-OptionalAddress -Address ([string]$_.registry)) -and
      (Normalize-OptionalAddress -Address ([string]$_.roleManager))
    } |
    Select-Object -First 1

  if (-not $frontendSourceCampaign) {
    throw "Unable to resolve non-empty registry/roleManager from created campaigns. Refusing to write empty NEXT_PUBLIC_* values."
  }

  $frontendRegistry = Normalize-OptionalAddress -Address ([string]$frontendSourceCampaign.registry)
  $frontendRoleManager = Normalize-OptionalAddress -Address ([string]$frontendSourceCampaign.roleManager)

  if (-not (Test-Path $webEnvLocal)) {
    if (Test-Path $webEnvExample) {
      Copy-Item $webEnvExample $webEnvLocal
    }
    else {
      New-Item -ItemType File -Path $webEnvLocal | Out-Null
    }
  }

  $existingEnvMap = Get-EnvMap -Path $webEnvLocal

  $envUpdates = [ordered]@{
    NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY = Get-EnvMapValueOrDefault -Map $existingEnvMap -Key "NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_FACTORY"
    NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY = Get-EnvMapValueOrDefault -Map $existingEnvMap -Key "NEXT_PUBLIC_BASE_MAINNET_CAMPAIGN_REGISTRY"
    NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER = Get-EnvMapValueOrDefault -Map $existingEnvMap -Key "NEXT_PUBLIC_BASE_MAINNET_ROLE_MANAGER"
    NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_FACTORY = $factoryAddress
    NEXT_PUBLIC_BASE_SEPOLIA_CAMPAIGN_REGISTRY = $frontendRegistry
    NEXT_PUBLIC_BASE_SEPOLIA_ROLE_MANAGER = $frontendRoleManager
    NEXT_PUBLIC_CAMPAIGN_FACTORY = $factoryAddress
    NEXT_PUBLIC_CAMPAIGN_REGISTRY = $frontendRegistry
    NEXT_PUBLIC_ROLE_MANAGER = $frontendRoleManager
    NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID = Get-EnvMapValueOrDefault -Map $existingEnvMap -Key "NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID"
    NEXT_PUBLIC_BASE_RPC_URL = Get-EnvMapValueOrDefault -Map $existingEnvMap -Key "NEXT_PUBLIC_BASE_RPC_URL"
    NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL = $RpcUrl
    NEXT_PUBLIC_DEFAULT_CHAIN = "base-sepolia"
    NEXT_PUBLIC_DISCOVERY_FROM_BLOCK = [string]$deployFromBlock
  }

  Update-EnvFile -Path $webEnvLocal -Values $envUpdates

  Write-Host ""
  Write-Host "Frontend .env.local updated (keys rewritten if already present):"
  Write-Host "  Source campaign index for registry/roleManager: $($frontendSourceCampaign.index)"
  foreach ($key in $envUpdates.Keys) {
    Write-Host "  $key=$($envUpdates[$key])"
  }

  Write-Host ""
  Write-Host "Created campaigns summary:"
  $campaignResults | Format-Table -AutoSize

  Push-Location $webDir
  try {
    Invoke-ExternalStep -Name "npm run abi:export" -Action { npm run abi:export }
    Assert-FrontendAbiExports -WebDir $webDir
    Invoke-ExternalStep -Name "npm run verify:onchain" -Action { npm run verify:onchain }

    if (-not $SkipDev) {
      Write-Host ""
      Write-Host "==> npm run dev (auto-stop after Ready)" -ForegroundColor Cyan
      Invoke-NpmDevUntilReady -WorkingDirectory $webDir
    }
  }
  finally {
    Pop-Location
  }

  $scriptSucceeded = $true
}
finally {
  if ($transcriptStarted) {
    try {
      Stop-Transcript | Out-Null
    }
    catch {
      # no-op: transcript can already be stopped in host interruption scenarios
    }
  }

  if ($scriptSucceeded) {
    $generatedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"
    $transcriptContent = ""
    if (Test-Path $logTempPath) {
      $transcriptContent = Get-Content $logTempPath -Raw
    }

    $markdownLog = @(
      "# deploy-and-wire log"
      ""
      "Generated: $generatedAt"
      ""
      '```text'
      $transcriptContent
      '```'
      ""
    ) -join "`n"

    Set-Content -Path $logPath -Value $markdownLog -Encoding UTF8

    if (Test-Path $logTempPath) {
      Remove-Item $logTempPath -Force
    }

    Write-Host ""
    Write-Host "Deploy log saved to: $logPath" -ForegroundColor Green
  }
  elseif (Test-Path $logTempPath) {
    Remove-Item $logTempPath -Force
  }
}

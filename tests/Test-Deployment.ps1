$ErrorActionPreference = 'Stop'
$Repository = Split-Path $PSScriptRoot -Parent
$Installer = Join-Path $Repository 'install_agent2_gpo.ps1'

foreach ($Path in @($Installer, (Join-Path $Repository 'New-ZabbixDeployment.ps1'))) {
    $Tokens = $null
    $ParseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$Tokens, [ref]$ParseErrors)
    if ($ParseErrors.Count) {
        throw ($ParseErrors | Out-String)
    }
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw }
        return
    }
    throw "Expected an error matching: $Pattern"
}

# Keep Windows operations mocked; configuration, hashing, and copying use real files.
function Get-WmiObject {
    param($Class)
    if ($Class -eq 'Win32_ComputerSystem') {
        return [pscustomobject]@{ DNSHostName = 'testhost'; Domain = 'example.com' }
    }
    if ($TestState.InstalledVersion) {
        [pscustomobject]@{ Name = 'Zabbix Agent 2 (64-bit)'; Version = $TestState.InstalledVersion }
    }
}
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$Wait, [switch]$PassThru)
    $TestState.InstallCalls++
    $TestState.MsiArguments = $ArgumentList
    Set-Content -LiteralPath $TestState.AgentConfig -Value '# Initial agent configuration'
    [pscustomobject]@{ ExitCode = 0 }
}
function Get-Service { param($Name) [pscustomobject]@{ Name = $Name } }
function Restart-Service { param($Name, [switch]$Force) $TestState.RestartCalls++ }
function Invoke-WebRequest { throw 'Packaged deployment must not download anything.' }

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$PreviousProgramData = $env:ProgramData
$PreviousSystemRoot = $env:SystemRoot
try {
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
    $env:ProgramData = $TestRoot
    $env:SystemRoot = $TestRoot
    $TestState = @{
        AgentConfig = Join-Path $TestRoot 'zabbix_agent2.conf'
        InstalledVersion = ''
        InstallCalls = 0
        RestartCalls = 0
    }
    $MsiPath = Join-Path $TestRoot 'agent.msi'
    Set-Content -LiteralPath $MsiPath -Value 'test MSI content'
    $LldPath = Join-Path $TestRoot 'lld.ps1'
    Set-Content -LiteralPath $LldPath -Value "'LLD test'"
    $ConfigPath = Join-Path $TestRoot 'deployment.json'
    $Package = @{
        DefaultServer = 'zabbix.example.com'
        PskSecret = ''
        DefaultPskId = ''
        LldScript = 'lld.ps1'
        ConfPath = $TestState.AgentConfig
        ZabbixInstallationMSI = 'agent.msi'
        MsiSha256 = (Get-FileHash $MsiPath -Algorithm SHA256).Hash
    }
    function Save-Package { $Package | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath }

    Save-Package
    & $Installer -ConfigPath $ConfigPath
    Assert-True ($TestState.InstallCalls -eq 1) 'A fresh client must install the packaged MSI.'
    Assert-True ($TestState.MsiArguments.Contains($MsiPath)) 'MSI arguments must point to the shared package.'
    Assert-True ($TestState.MsiArguments.Contains('/qn')) 'MSI installation must be quiet.'
    Assert-True ($TestState.MsiArguments.Contains('/norestart')) 'MSI installation must not trigger an automatic reboot.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'Server=zabbix.example.com') 'The package server must be applied.'
    Assert-True (Test-Path (Join-Path $TestRoot 'scripts/lld.ps1')) 'The packaged LLD script must be copied.'
    Assert-True ($TestState.RestartCalls -eq 1) 'Configuration changes must restart the agent.'

    $TestState.InstalledVersion = '7.0.32'
    & $Installer -ConfigPath $ConfigPath
    Assert-True ($TestState.InstallCalls -eq 1) 'An up-to-date client must not reinstall the MSI.'
    Assert-True ($TestState.RestartCalls -eq 1) 'Unchanged configuration must not restart the agent.'

    $BuilderAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $Repository 'New-ZabbixDeployment.ps1'), [ref]$null, [ref]$null)
    $LauncherAssignment = $BuilderAst.Find({
        param($Node)
        $Node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $Node.Left -is [Management.Automation.Language.VariableExpressionAst] -and
        $Node.Left.VariablePath.UserPath -eq 'Launcher'
    }, $true)
    $LauncherPath = Join-Path $TestRoot 'Start-ZabbixDeployment.ps1'
    Set-Content -LiteralPath $LauncherPath -Value $LauncherAssignment.Right.Expression.Value
    Copy-Item -LiteralPath $Installer -Destination $TestRoot
    & $LauncherPath
    & (Join-Path $TestRoot 'install_agent2_gpo.ps1')
    Assert-True ($TestState.InstallCalls -eq 1) 'The generated launcher and sibling config discovery must use the package.'

    $TestState.InstalledVersion = ''
    $Package.MsiSha256 = '0' * 64
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'does not match'
    Assert-True ($TestState.InstallCalls -eq 1) 'A hash mismatch must prevent installation.'

    $Package.ZabbixInstallationMSI = 'missing.msi'
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'MSI is unavailable'
    $Package.DefaultServer = 42
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'string value for DefaultServer'
    $Package.DefaultServer = 'zabbix.example.com'
    $Package.LldScript = 'missing-lld.ps1'
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'LLD script file not found'
    Write-Output 'Deployment checks passed.'
} finally {
    $env:ProgramData = $PreviousProgramData
    $env:SystemRoot = $PreviousSystemRoot
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}

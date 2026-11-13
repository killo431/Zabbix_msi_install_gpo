# Run from an elevated Windows PowerShell 5.1 session. Every system-changing call is mocked
# and ProgramData/TEMP are redirected to a temporary folder.
$ErrorActionPreference = 'Stop'
$CurrentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $CurrentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run the tests from an elevated PowerShell session; the installer refuses to run unelevated.'
}
$Repository = Split-Path $PSScriptRoot -Parent
$Installer = Join-Path $Repository 'install_agent2_gpo.ps1'

foreach ($Path in @(
    $Installer,
    (Join-Path $Repository 'New-ZabbixDeployment.ps1'),
    (Join-Path $Repository 'install_agent2_template.ps1'),
    (Join-Path $Repository 'Test-ZabbixAgentConfiguration.ps1')
)) {
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
function Get-ItemProperty {
    param($Path, $ErrorAction)
    if ($TestState.InstalledVersion) {
        [pscustomobject]@{ DisplayName = 'Zabbix Agent 2 (64-bit)'; DisplayVersion = $TestState.InstalledVersion }
    }
}
function Start-Process {
    param($FilePath, $ArgumentList, $WindowStyle, [switch]$Wait, [switch]$PassThru)
    $TestState.InstallCalls++
    $TestState.MsiArguments = $ArgumentList
    if ($ArgumentList -match '/i "(?<msi>[^"]+)"') {
        $TestState.StagedMsiPath = $Matches.msi
        $TestState.StagedMsiHash = (Get-FileHash -LiteralPath $Matches.msi -Algorithm SHA256).Hash
    }
    $ExitCode = 0
    if ($TestState.MsiExitCodes.Count -gt 0) {
        $ExitCode = $TestState.MsiExitCodes[0]
        $TestState.MsiExitCodes = @($TestState.MsiExitCodes | Select-Object -Skip 1)
    }
    if ($ExitCode -eq 0) {
        Set-Content -LiteralPath $TestState.AgentConfig -Value '# Initial agent configuration'
    }
    [pscustomobject]@{ ExitCode = $ExitCode }
}
function Start-Sleep { param($Seconds) $TestState.Sleeps++ }
function Restart-Service { param($Name, [switch]$Force) $TestState.RestartCalls++; $TestState.RestartedService = $Name }
function Get-Acl {
    param($LiteralPath)
    $Acl = [pscustomobject]@{}
    $Acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($Type) [Security.Principal.SecurityIdentifier]$TestState.AclOwner }
    $Acl
}
function Set-Acl { param($LiteralPath, $AclObject) $TestState.AclPaths += $LiteralPath }
function Copy-Item {
    [CmdletBinding()]
    param($LiteralPath, $Destination, [switch]$Force)
    if ($LiteralPath -eq $TestState.DeniedSource) {
        throw [UnauthorizedAccessException]::new('Test share access denied.')
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    if (-not $OutFile) {
        $TestState.TemplateDownloads++
        $TestState.TemplateUri = $Uri
        return [pscustomobject]@{ Content = (Get-Content -LiteralPath $Installer -Raw) }
    }
    $TestState.DownloadCalls++
    if (-not $TestState.AllowDownload) { throw 'Unexpected MSI download.' }
    if ($TestState.DownloadFails) { throw [IO.IOException]::new('Test HTTPS download failed.') }
    Set-Content -LiteralPath $OutFile -Value $TestState.DownloadContent
}
function Get-Service { param($Name, $ErrorAction) [pscustomobject]@{ Name = $Name; Status = 'Running' } }
function Get-CimInstance {
    param($ClassName, $ErrorAction)
    if ($ClassName -eq 'Win32_Service') {
        return @(
            [pscustomobject]@{ Name = 'Unrelated'; PathName = 'C:\Windows\System32\svchost.exe -k netsvcs' }
            [pscustomobject]@{ Name = 'Zabbix Agent 2'; State = 'Running'; PathName = '"C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe" -c "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf"' }
        )
    }
    [pscustomobject]@{ DNSHostName = 'testhost'; Domain = 'example.com'; PartOfDomain = $true }
}
function New-EventLog { param($LogName, $Source, $ErrorAction) }
function Write-EventLog {
    param($LogName, $Source, $EventId, $EntryType, $Message, $ErrorAction)
    $TestState.Events += "$EntryType/$EventId"
    $TestState.EventMessages += $Message
}
function Get-AuthenticodeSignature {
    param($LiteralPath, $ErrorAction)
    $Subject = if ($TestState.SignatureValid) { 'CN=Zabbix SIA, O=Zabbix SIA, L=Riga, C=LV' } else { 'CN=Someone Else, O=Someone Else' }
    [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = $Subject } }
}
function Test-NetConnection { param($ComputerName, $Port, $InformationLevel, $WarningAction) $true }

$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$PreviousProgramData = $env:ProgramData
$PreviousTemp = $env:TEMP
try {
    New-Item -ItemType Directory -Path $TestRoot | Out-Null
    $env:ProgramData = $TestRoot
    $env:TEMP = $TestRoot
    $TestState = @{
        AgentConfig = Join-Path $TestRoot 'zabbix_agent2.conf'
        InstalledVersion = ''
        InstallCalls = 0
        RestartCalls = 0
        DownloadCalls = 0
        AllowDownload = $false
        DownloadFails = $false
        DownloadContent = 'test MSI content'
        MsiExitCodes = @()
        Sleeps = 0
        AclOwner = 'S-1-5-18'
        AclPaths = @()
        Events = @()
        EventMessages = @()
        SignatureValid = $true
        TemplateDownloads = 0
    }
    $Checker = Join-Path $Repository 'Test-ZabbixAgentConfiguration.ps1'
    $FakeAgent = Join-Path $TestRoot 'zabbix_agent2.exe'
    Set-Content -LiteralPath $FakeAgent -Value 'test agent'
    $PskFile = Join-Path $TestRoot 'agent.psk'
    Set-Content -LiteralPath $PskFile -Value 'DO-NOT-LEAK-THIS-PSK'
    $HealthConfig = Join-Path $TestRoot 'health.conf'
    @(
        'Server=172.17.6.24'
        'ServerActive=zbx01.example.com'
        'Hostname=testhost.example.com'
        'HostMetadata=GAS;windows;ADC;server'
        'TLSConnect=psk'
        'TLSAccept=psk'
        'TLSPSKIdentity=ZabbixPSK'
        "TLSPSKFile=$PskFile"
        'TLSPSKValue=DO-NOT-LEAK-THIS-PSK'
        '#Server=commented duplicate is ignored'
    ) | Set-Content -LiteralPath $HealthConfig
    $HealthSummary = & $Checker -ConfigPath $HealthConfig -AgentExePath $FakeAgent -ExpectedServer '172.17.6.24' -ExpectedServerActive 'zbx01.example.com' -SkipAgentConfigTest
    Assert-True ($HealthSummary.ExitCode -eq 0) 'A correct agent configuration must pass.'
    Assert-True (($HealthSummary | Out-String) -notmatch 'DO-NOT-LEAK-THIS-PSK') 'Health-check output must not leak PSK data.'
    $BadHealthSummary = & $Checker -ConfigPath $HealthConfig -AgentExePath $FakeAgent -ExpectedServer '172.17.6.24' -ExpectedServerActive 'wrong.example.com' -SkipAgentConfigTest -SkipNetworkCheck
    Assert-True ($BadHealthSummary.ExitCode -eq 1) 'A mismatched ServerActive must fail the health check.'

    # Include= files are read, TLSAccept lists are accepted, and duplicates across includes fail.
    $IncludeDirectory = Join-Path $TestRoot 'health.d'
    New-Item -ItemType Directory -Path $IncludeDirectory | Out-Null
    $IncludeConfig = Join-Path $TestRoot 'include.conf'
    @(
        'Server=172.17.6.24'
        'ServerActive=zbx01.example.com;zbx02.example.com'
        'Hostname=testhost.example.com'
        'HostMetadata=GAS;windows;ADC;server'
        'Include=health.d\*.conf'
    ) | Set-Content -LiteralPath $IncludeConfig
    @(
        'TLSConnect=psk'
        'TLSAccept=unencrypted,psk'
        'TLSPSKIdentity=ZabbixPSK'
        "TLSPSKFile=$PskFile"
    ) | Set-Content -LiteralPath (Join-Path $IncludeDirectory 'tls.conf')
    $IncludeSummary = & $Checker -ConfigPath $IncludeConfig -AgentExePath $FakeAgent -ExpectedServer '172.17.6.24' -ExpectedServerActive 'zbx01.example.com;zbx02.example.com' -SkipAgentConfigTest
    Assert-True ($IncludeSummary.ExitCode -eq 0) 'Settings in included files must be honored.'
    Assert-True (@($IncludeSummary.Checks | Where-Object { $_.Check -eq 'PSK transport' -and $_.Status -eq 'WARN' }).Count -eq 1) 'TLSAccept allowing unencrypted must warn, not fail.'
    Assert-True (@($IncludeSummary.Checks | Where-Object { $_.Check -eq 'Active server network' -and $_.Detail -match 'zbx01\.example\.com:10051' }).Count -eq 1) 'Only the first HA node must be tested.'
    'Server=10.0.0.1' | Set-Content -LiteralPath (Join-Path $IncludeDirectory 'dup.conf')
    $DuplicateSummary = & $Checker -ConfigPath $IncludeConfig -AgentExePath $FakeAgent -SkipAgentConfigTest -SkipNetworkCheck
    Assert-True (@($DuplicateSummary.Checks | Where-Object { $_.Check -eq 'Duplicate Server' }).Count -eq 1) 'Duplicates across included files must fail.'
    Assert-True (@($DuplicateSummary.Checks | Where-Object { $_.Check -eq 'Config Server' -and $_.Status -eq 'WARN' }).Count -eq 1) 'A missing expected server must warn.'

    $MsiPath = Join-Path $TestRoot 'agent.msi'
    Set-Content -LiteralPath $MsiPath -Value 'test MSI content'
    $LldPath = Join-Path $TestRoot 'lld.ps1'
    Set-Content -LiteralPath $LldPath -Value "'LLD test'"
    $ConfigPath = Join-Path $TestRoot 'deployment.json'
    $Package = @{
        DefaultServer = 'zabbix.example.com'
        ServerActive = 'zabbix-proxy.example.com'
        HostMetadata = 'GAS;windows;ADC;server'
        HostnameMode = 'FQDN'
        PskSecret = ''
        DefaultPskId = ''
        LldScript = 'lld.ps1'
        ConfPath = $TestState.AgentConfig
        ZabbixAgentVersion = '7.0.32'
        ZabbixInstallationMSI = 'agent.msi'
        MsiSha256 = (Get-FileHash $MsiPath -Algorithm SHA256).Hash
    }
    function Save-Package { $Package | ConvertTo-Json | Set-Content -LiteralPath $ConfigPath }

    Save-Package
    & $Installer -ConfigPath $ConfigPath
    Assert-True ($TestState.InstallCalls -eq 1) 'A fresh client must install the packaged MSI.'
    $SecureRoot = Join-Path $TestRoot 'ZabbixAgent2'
    $StagingRoot = Join-Path $SecureRoot 'staging'
    Assert-True ($TestState.StagedMsiPath.StartsWith($StagingRoot)) 'The MSI must be staged in the secured ProgramData directory, not TEMP.'
    Assert-True ($TestState.StagedMsiHash -eq (Get-FileHash $MsiPath).Hash) 'The shared MSI must be copied to local staging.'
    Assert-True (-not (Test-Path -LiteralPath $TestState.StagedMsiPath)) 'The staging directory must be removed after installation.'
    Assert-True ($TestState.AclPaths -contains $SecureRoot) 'The ProgramData directory must be secured.'
    Assert-True ($TestState.MsiArguments -match '/l\*v "') 'msiexec must write a verbose log.'
    Assert-True (Test-Path (Join-Path $SecureRoot 'logs/install.log')) 'The installer must write a log.'
    Assert-True ($TestState.DownloadCalls -eq 0) 'A reachable shared MSI must not trigger a download.'
    Assert-True ($TestState.MsiArguments.Contains('/qn')) 'MSI installation must be quiet.'
    Assert-True ($TestState.MsiArguments.Contains('/norestart')) 'MSI installation must not trigger an automatic reboot.'
    Assert-True ($TestState.MsiArguments.Contains('SERVERACTIVE="zabbix-proxy.example.com"')) 'The active server must be passed to the MSI, quoted.'
    Assert-True ($TestState.MsiArguments.Contains('HOSTMETADATA="GAS;windows;ADC;server"')) 'Host metadata must be passed to the MSI, quoted.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'Server=zabbix.example.com') 'The package server must be applied.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'ServerActive=zabbix-proxy.example.com') 'The active server must be written to the agent config.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'HostMetadata=GAS;windows;ADC;server') 'The GAS metadata must be written to the agent config.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'Hostname=testhost.example.com') 'The FQDN hostname mode must use the computer FQDN.'
    Assert-True (Test-Path (Join-Path $TestRoot 'scripts/lld.ps1')) 'The packaged LLD script must be copied.'
    Assert-True ($TestState.RestartCalls -eq 1) 'Configuration changes must restart the agent.'
    Assert-True ($TestState.RestartedService -eq 'Zabbix Agent 2') 'The agent service must be found by its executable path.'
    Assert-True ($TestState.Events[-1] -eq 'Information/1000') 'A successful run must write event 1000.'

    $TestState.InstalledVersion = '7.0.32'
    & $Installer -ConfigPath $ConfigPath
    Assert-True ($TestState.InstallCalls -eq 1) 'An up-to-date client must not reinstall the MSI.'
    Assert-True ($TestState.RestartCalls -eq 1) 'Unchanged configuration must not restart the agent.'

    $Package.HostnameMode = 'GAS'
    $Package.HostMetadata = 'GAS;windows;ADC;sql'
    Save-Package
    & $Installer -ConfigPath $ConfigPath
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'Hostname=GAS-testhost') 'GAS hostname mode must use the GAS-prefixed computer name.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'HostMetadata=GAS;windows;ADC;sql') 'SQL packages must apply their configured metadata.'
    Assert-True ($TestState.RestartCalls -eq 2) 'Changed metadata must restart the agent.'

    $Package.PskSecret = '00112233445566778899aabbccddeeff'
    $Package.DefaultPskId = 'TestIdentity'
    Save-Package
    & $Installer -ConfigPath $ConfigPath
    $PskFilePath = Join-Path $SecureRoot 'zabbix_agent2.psk'
    Assert-True ([IO.File]::ReadAllText($PskFilePath) -ceq '00112233445566778899aabbccddeeff') 'The PSK must be written to the secured PSK file.'
    Assert-True ($TestState.AclPaths -contains $PskFilePath) 'The PSK file permissions must be reset.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains "TLSPSKFile=$PskFilePath") 'The PSK file path must be configured.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'TLSPSKIdentity=TestIdentity') 'The PSK identity must be configured.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'TLSConnect=psk') 'PSK transport must be configured.'
    Assert-True (-not ((Get-Content (Join-Path $SecureRoot 'logs/install.log') -Raw) -match '00112233445566778899aabbccddeeff')) 'The log must not contain the PSK.'
    Assert-True ($TestState.RestartCalls -eq 3) 'Enabling PSK must restart the agent.'
    $Package.PskSecret = ''
    $Package.DefaultPskId = ''
    Save-Package
    & $Installer -ConfigPath $ConfigPath
    Assert-True (-not (Test-Path -LiteralPath $PskFilePath)) 'Disabling PSK must remove the PSK file.'
    Assert-True (-not ((Get-Content $TestState.AgentConfig) -match '^TLS')) 'Disabling PSK must remove the PSK configuration.'
    Assert-True ($TestState.RestartCalls -eq 4) 'Disabling PSK must restart the agent.'

    $TestState.AclOwner = 'S-1-5-21-1000000000-1000000000-1000000000-1001'
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'Refusing to use .* owned by'
    $TestState.AclOwner = 'S-1-5-18'

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
    Assert-True ($TestState.DownloadCalls -eq 0) 'A primary MSI integrity failure must not trigger fallback.'

    $Package.MsiSha256 = (Get-FileHash $MsiPath).Hash
    $Package.ZabbixInstallationMSI = 'missing.msi'
    Save-Package
    $TestState.AllowDownload = $true
    & $Installer -ConfigPath $ConfigPath
    Assert-True ($TestState.DownloadCalls -eq 1 -and $TestState.InstallCalls -eq 2) 'A missing shared MSI must use the HTTPS fallback.'

    $Package.ZabbixInstallationMSI = 'agent.msi'
    $TestState.DeniedSource = $MsiPath
    Save-Package
    & $Installer -ConfigPath $ConfigPath
    Assert-True ($TestState.DownloadCalls -eq 2 -and $TestState.InstallCalls -eq 3) 'Share access denied must use the HTTPS fallback.'
    $TestState.DeniedSource = $null

    $TestState.MsiExitCodes = @(1618, 0)
    & $Installer -ConfigPath $ConfigPath
    Assert-True ($TestState.InstallCalls -eq 5 -and $TestState.Sleeps -eq 1) 'Exit code 1618 must be retried after a delay.'
    $TestState.MsiExitCodes = @(1603)
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'exit code 1603'
    Assert-True ($TestState.Events[-1] -eq 'Error/1001') 'A failed run must write event 1001.'
    Assert-True ($TestState.InstallCalls -eq 6) 'A hard MSI failure must not be retried.'

    $Package.ZabbixInstallationMSI = 'missing.msi'
    $TestState.DownloadContent = 'tampered download'
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'does not match'
    Assert-True ($TestState.InstallCalls -eq 6) 'A downloaded MSI with the wrong hash must not install.'
    $TestState.DownloadFails = $true
    $SavedProgressPreference = $ProgressPreference
    $SavedSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'Test HTTPS download failed'
    Assert-True ($TestState.InstallCalls -eq 6) 'An HTTPS failure must not reuse a stale staged MSI.'
    Assert-True ($ProgressPreference -eq $SavedProgressPreference) 'Download failure must restore progress preferences.'
    Assert-True ([Net.ServicePointManager]::SecurityProtocol -eq $SavedSecurityProtocol) 'Download failure must restore TLS preferences.'

    $Package.DefaultServer = 42
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'string value for DefaultServer'
    $Package.DefaultServer = 'zabbix "example".com'
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'DefaultServer must not contain quotes'
    $Package.DefaultServer = 'zabbix.example.com'
    $Package.ZabbixAgentVersion = 'latest'
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'ZabbixAgentVersion must look like'
    $Package.ZabbixAgentVersion = '7.0.32'
    $Package.LldScript = 'missing-lld.ps1'
    Save-Package
    Assert-Fails { & $Installer -ConfigPath $ConfigPath } 'LLD script file not found'

    # Standalone/interactive mode: environment overrides, signature verification, and the irm | iex wrapper.
    $TestState.InstalledVersion = ''
    $TestState.DownloadFails = $false
    $TestState.DownloadContent = 'test MSI content'
    $env:ZABBIX_SERVER = 'env-zabbix.example.com'
    $env:ZABBIX_SERVER_ACTIVE = 'env-proxy.example.com'
    $env:ZABBIX_CONF_PATH = $TestState.AgentConfig
    $env:ZABBIX_AGENT_UNC = $MsiPath
    $env:ZABBIX_PSK_SECRET = 'ffeeddccbbaa99887766554433221100'
    $env:ZABBIX_PSK_ID = 'EnvIdentity'
    $InstallCallsBefore = $TestState.InstallCalls
    & $Installer
    Assert-True ($TestState.InstallCalls -eq $InstallCallsBefore + 1) 'Standalone mode must install from ZABBIX_AGENT_UNC.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'Server=env-zabbix.example.com') 'ZABBIX_SERVER must override the default server.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'TLSPSKIdentity=EnvIdentity') 'ZABBIX_PSK_ID must be applied.'
    Assert-True (-not (Test-Path Env:\ZABBIX_PSK_SECRET)) 'ZABBIX_PSK_SECRET must be cleared after use.'
    Assert-True (-not (($TestState.EventMessages -join "`n") -match 'ffeeddccbbaa99887766554433221100')) 'Events must not contain the PSK.'

    Remove-Item -Path Env:\ZABBIX_PSK_ID
    $TestState.SignatureValid = $false
    Assert-Fails { & $Installer } 'valid Zabbix SIA Authenticode signature'
    $TestState.SignatureValid = $true

    $env:ZABBIX_SERVER = 'template-zabbix.example.com'
    $env:ZABBIX_SCRIPT_REF = 'v1.2.3'
    & (Join-Path $Repository 'install_agent2_template.ps1')
    Assert-True ($TestState.TemplateDownloads -eq 1) 'The template must download the GPO installer.'
    Assert-True ($TestState.TemplateUri -eq 'https://raw.githubusercontent.com/killo431/Zabbix_msi_install_gpo/v1.2.3/install_agent2_gpo.ps1') 'The template must honor ZABBIX_SCRIPT_REF.'
    Assert-True ((Get-Content $TestState.AgentConfig) -contains 'Server=template-zabbix.example.com') 'The template must run the installer with environment overrides.'
    $env:ZABBIX_SCRIPT_REF = 'main;bad'
    Assert-Fails { & (Join-Path $Repository 'install_agent2_template.ps1') } 'unsupported characters'
    Write-Output 'Deployment checks passed.'
} finally {
    foreach ($Name in @('ZABBIX_SERVER', 'ZABBIX_SERVER_ACTIVE', 'ZABBIX_CONF_PATH', 'ZABBIX_AGENT_UNC', 'ZABBIX_PSK_SECRET', 'ZABBIX_PSK_ID', 'ZABBIX_SCRIPT_REF')) {
        Remove-Item -Path "Env:\$Name" -ErrorAction SilentlyContinue
    }
    $env:ProgramData = $PreviousProgramData
    $env:TEMP = $PreviousTemp
    Remove-Item -LiteralPath $TestRoot -Recurse -Force
}

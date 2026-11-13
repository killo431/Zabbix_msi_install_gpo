#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DefaultServer,

    [string]$ServerActive = $DefaultServer,

    [ValidateNotNullOrEmpty()]
    [string]$HostMetadata = 'GAS;windows;ADC;server',

    [ValidateSet('FQDN', 'GAS')]
    [string]$HostnameMode = 'FQDN',

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$ReadAccess,

    [ValidatePattern('^[A-Za-z0-9_-]+\$?$')]
    [string]$ShareName = 'ZabbixAgent2$',

    [string]$PackagePath = (Join-Path $env:ProgramData 'ZabbixDeployment'),

    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$ZabbixAgentVersion = '7.0.32',

    [string]$AgentUnc = "\\gas-fil004\packages\Zabbix Agent 2\zabbix_agent2-$ZabbixAgentVersion-windows-amd64-openssl.msi",

    [Security.SecureString]$PskSecret,

    [string]$DefaultPskId = '',

    [string]$LldScript = '',

    [string]$ConfPath = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf'
)

$ErrorActionPreference = 'Stop'
$ComputerSystem = Get-CimInstance Win32_ComputerSystem
if (-not $ComputerSystem.PartOfDomain) {
    throw 'Domain GPO deployment requires a domain-joined file server.'
}
$InstallerPath = Join-Path $PSScriptRoot 'install_agent2_gpo.ps1'
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw 'Keep New-ZabbixDeployment.ps1 beside install_agent2_gpo.ps1.'
}
if ([string]::IsNullOrWhiteSpace($DefaultServer) -or $DefaultServer -match '[\r\n"]') {
    throw 'DefaultServer must be a nonempty Zabbix server address without quotes or newlines.'
}
if ([string]::IsNullOrWhiteSpace($ServerActive) -or $ServerActive -match '[\r\n"]') {
    throw 'ServerActive must be a nonempty Zabbix server or proxy address without quotes or newlines.'
}
if ($HostMetadata -match '[\r\n"]') {
    throw 'HostMetadata must not contain quotes or newlines.'
}
if (($null -ne $PskSecret) -xor (-not [string]::IsNullOrWhiteSpace($DefaultPskId))) {
    throw 'Supply both PskSecret and DefaultPskId, or omit both.'
}
if ($DefaultPskId -match '[\r\n"]') {
    throw 'DefaultPskId must not contain quotes or newlines.'
}
if ($ConfPath -notmatch '^[A-Za-z]:\\' -or
    (Split-Path $ConfPath -Leaf) -ine 'zabbix_agent2.conf' -or $ConfPath -match '[\r\n"]') {
    throw 'ConfPath must be an absolute local path ending in zabbix_agent2.conf.'
}
if ($LldScript -and -not (Test-Path -LiteralPath $LldScript -PathType Leaf)) {
    throw "LLD script file not found: $LldScript"
}
if ($PackagePath -notmatch '^[A-Za-z]:\\') {
    throw 'PackagePath must be an absolute local Windows path.'
}
$PackagePath = [IO.Path]::GetFullPath($PackagePath)
if (Test-Path -LiteralPath $PackagePath) {
    throw "Use a new package directory; refusing to overwrite $PackagePath."
}
if (Get-SmbShare | Where-Object Name -eq $ShareName) {
    throw "The SMB share $ShareName already exists; choose a different name."
}

$Administrators = ([Security.Principal.SecurityIdentifier]'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value
$System = ([Security.Principal.SecurityIdentifier]'S-1-5-18').Translate([Security.Principal.NTAccount]).Value
$ReaderSids = foreach ($Account in $ReadAccess) {
    $Sid = (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier])
    if ($Sid.Value -in @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')) {
        throw 'Use a dedicated computer security group, not Everyone, Authenticated Users, or Users.'
    }
    $Sid
}
$PlainPsk = ''
if ($null -ne $PskSecret) {
    $SecretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PskSecret)
    try {
        $PlainPsk = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($SecretPointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($SecretPointer)
    }
    if ($PlainPsk -notmatch '^(?:[0-9a-fA-F]{2}){16,256}$') {
        throw 'PskSecret must be 32-512 hexadecimal characters with an even length.'
    }
}

New-Item -ItemType Directory -Path $PackagePath | Out-Null
# Replace inherited access before writing any package configuration or secrets.
$Acl = New-Object Security.AccessControl.DirectorySecurity
$Acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
$Acl.SetAccessRuleProtection($true, $false)
foreach ($Account in @($Administrators, $System)) {
    $Acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $Account, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
foreach ($Sid in $ReaderSids) {
    $Acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $Sid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
}
Set-Acl -LiteralPath $PackagePath -AclObject $Acl

$MsiName = "zabbix_agent2-$ZabbixAgentVersion-windows-amd64-openssl.msi"
$MsiPath = Join-Path $PackagePath $MsiName
$MsiUrl = "https://github.com/killo431/packages/releases/download/main/$MsiName"
$MsiCopied = $false
if (-not [string]::IsNullOrWhiteSpace($AgentUnc)) {
    try {
        Copy-Item -LiteralPath $AgentUnc -Destination $MsiPath -Force -ErrorAction Stop
        $MsiCopied = $true
    } catch [IO.IOException], [UnauthorizedAccessException], [Management.Automation.ItemNotFoundException], [Management.Automation.DriveNotFoundException] {
        Write-Warning "Cannot stage MSI from $AgentUnc; using the HTTPS fallback. $($_.Exception.Message)"
    }
}
if (-not $MsiCopied) {
    $PreviousProgressPreference = $ProgressPreference
    $PreviousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        $ProgressPreference = 'SilentlyContinue'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $MsiUrl -OutFile $MsiPath -UseBasicParsing -ErrorAction Stop | Out-Null
    } finally {
        $ProgressPreference = $PreviousProgressPreference
        [Net.ServicePointManager]::SecurityProtocol = $PreviousSecurityProtocol
    }
}
if ((Get-Item -LiteralPath $MsiPath).Length -eq 0) {
    throw 'The staged MSI is empty. The deployment share has not been created.'
}
$Signature = Get-AuthenticodeSignature -LiteralPath $MsiPath
if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch 'O="?Zabbix SIA"?(,|$)') {
    throw 'The MSI must have a valid Zabbix SIA Authenticode signature. The deployment share has not been created.'
}
function Get-MsiProductVersion {
    param([string]$Path)
    $WindowsInstaller = New-Object -ComObject WindowsInstaller.Installer
    $Database = $WindowsInstaller.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $WindowsInstaller, @($Path, 0))
    $View = $Database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $Database, @("SELECT Value FROM Property WHERE Property='ProductVersion'"))
    try {
        $View.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $View, $null) | Out-Null
        $Record = $View.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $View, $null)
        if ($null -eq $Record) { return $null }
        $Record.GetType().InvokeMember('StringData', 'GetProperty', $null, $Record, 1)
    } finally {
        $View.GetType().InvokeMember('Close', 'InvokeMethod', $null, $View, $null) | Out-Null
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($View)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Database)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($WindowsInstaller)
    }
}
$MsiProductVersion = [string](Get-MsiProductVersion -Path $MsiPath)
if ($MsiProductVersion -notmatch '^(\d+\.\d+\.\d+)' -or [version]$Matches[1] -ne [version]$ZabbixAgentVersion) {
    throw "The MSI reports ProductVersion '$MsiProductVersion', not $ZabbixAgentVersion. The deployment share has not been created."
}
Copy-Item -LiteralPath $InstallerPath -Destination $PackagePath
$PackagedLldScript = ''
if ($LldScript) {
    $ScriptsPath = Join-Path $PackagePath 'scripts'
    New-Item -ItemType Directory -Path $ScriptsPath | Out-Null
    Copy-Item -LiteralPath $LldScript -Destination $ScriptsPath
    $PackagedLldScript = Join-Path 'scripts' (Split-Path $LldScript -Leaf)
}
$Configuration = [ordered]@{
    DefaultServer = $DefaultServer
    ServerActive = $ServerActive
    HostMetadata = $HostMetadata
    HostnameMode = $HostnameMode
    PskSecret = $PlainPsk
    DefaultPskId = $DefaultPskId
    LldScript = $PackagedLldScript
    ConfPath = $ConfPath
    ZabbixAgentVersion = $ZabbixAgentVersion
    ZabbixInstallationMSI = $MsiName
    MsiSha256 = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash
}
$Configuration | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PackagePath 'deployment.json') -Encoding UTF8
$PlainPsk = $null
$Configuration.PskSecret = $null

$Launcher = @'
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'install_agent2_gpo.ps1') -ConfigPath (Join-Path $PSScriptRoot 'deployment.json')
'@
Set-Content -LiteralPath (Join-Path $PackagePath 'Start-ZabbixDeployment.ps1') -Value $Launcher -Encoding UTF8
$Share = New-SmbShare -Name $ShareName -Path $PackagePath -ReadAccess $ReadAccess -FullAccess $Administrators -CachingMode None -FolderEnumerationMode AccessBased
if ($Share.Path -ine $PackagePath) {
    throw 'The deployment share path does not match the package directory.'
}
$ServerFqdn = "$($ComputerSystem.DNSHostName).$($ComputerSystem.Domain)"
Write-Output "\\$ServerFqdn\$ShareName\Start-ZabbixDeployment.ps1"

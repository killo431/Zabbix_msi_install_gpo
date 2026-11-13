##This script is used to install and update zabbix agent version 2 via GPO
#
##Author: https://github.com/Padl3xx
#
##For an elevated interactive PowerShell setup, set ZABBIX_SERVER and run:
##irm https://raw.githubusercontent.com/killo431/Zabbix_msi_install_gpo/main/install_agent2_template.ps1 | iex
##The script can also be deployed as a computer startup GPO script.

# User-configurable variables
$ZabbixMsiUrl = "https://github.com/killo431/packages/releases/download/main/zabbix_agent2-7.0.32-windows-amd64-openssl.msi"
$ZabbixAgentVersion = "7.0.32"
$PskSecret = ""
$DefaultPskId = ""
$DefaultServer = ""
$LldScript = ""
$ConfPath = "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf"

# Environment overrides allow this file to run through irm | iex without editing it first.
if (-not [string]::IsNullOrWhiteSpace($env:ZABBIX_SERVER)) { $DefaultServer = $env:ZABBIX_SERVER }
if (-not [string]::IsNullOrWhiteSpace($env:ZABBIX_PSK_SECRET)) { $PskSecret = $env:ZABBIX_PSK_SECRET }
if (-not [string]::IsNullOrWhiteSpace($env:ZABBIX_PSK_ID)) { $DefaultPskId = $env:ZABBIX_PSK_ID }
if (-not [string]::IsNullOrWhiteSpace($env:ZABBIX_LLD_SCRIPT)) { $LldScript = $env:ZABBIX_LLD_SCRIPT }
if (-not [string]::IsNullOrWhiteSpace($env:ZABBIX_CONF_PATH)) { $ConfPath = $env:ZABBIX_CONF_PATH }
Remove-Item Env:\ZABBIX_PSK_SECRET -ErrorAction SilentlyContinue

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this setup from an elevated PowerShell session."
}

if ([string]::IsNullOrWhiteSpace($DefaultServer)) {
    throw "Set DefaultServer or the ZABBIX_SERVER environment variable to the Zabbix server or proxy address."
}
if ([string]::IsNullOrWhiteSpace($PskSecret) -xor [string]::IsNullOrWhiteSpace($DefaultPskId)) {
    throw "Set both PskSecret and DefaultPskId, or leave both empty."
}
if (-not [string]::IsNullOrWhiteSpace($PskSecret) -and $PskSecret -notmatch '^[0-9A-Fa-f]+$') {
    throw "PskSecret must contain only hexadecimal characters."
}
if ((Split-Path -Path $ConfPath -Leaf) -ine "zabbix_agent2.conf") {
    throw "ConfPath must end with zabbix_agent2.conf so the MSI and agent use the same configuration file."
}
if (-not [string]::IsNullOrWhiteSpace($LldScript) -and -not (Test-Path -LiteralPath $LldScript -PathType Leaf)) {
    throw "LLD script file not found: $LldScript"
}

$InstallFolder = Split-Path -Path $ConfPath -Parent
$PskDirectory = Join-Path -Path $env:ProgramData -ChildPath "ZabbixAgent2"
$PskFilePath = Join-Path -Path $PskDirectory -ChildPath "zabbix_agent2.psk"
$PskFileChanged = $false

if (-not [string]::IsNullOrWhiteSpace($PskSecret)) {
    if (($PskSecret.Length % 2) -ne 0) {
        throw "PskSecret must contain an even number of hexadecimal characters."
    }
    New-Item -ItemType Directory -Path $PskDirectory -Force -ErrorAction Stop | Out-Null
    & "$env:SystemRoot\System32\icacls.exe" $PskDirectory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)(F)' '*S-1-5-32-544:(OI)(CI)(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to secure the PSK directory: $PskDirectory"
    }
    if (-not (Test-Path -LiteralPath $PskFilePath -PathType Leaf)) {
        [System.IO.File]::WriteAllText($PskFilePath, "", [System.Text.Encoding]::ASCII)
    }
    & "$env:SystemRoot\System32\icacls.exe" $PskFilePath /inheritance:r /grant:r '*S-1-5-18:(R)' '*S-1-5-32-544:(F)' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to secure the PSK file: $PskFilePath"
    }
    $PreviousPskSecret = [System.IO.File]::ReadAllText($PskFilePath)
    $PskFileChanged = $PreviousPskSecret -cne $PskSecret
    if ($PskFileChanged) {
        [System.IO.File]::WriteAllText($PskFilePath, $PskSecret, [System.Text.Encoding]::ASCII)
    }
} elseif (Test-Path -LiteralPath $PskFilePath -PathType Leaf) {
    Remove-Item -LiteralPath $PskFilePath -Force -ErrorAction Stop
    $PskFileChanged = $true
}

# Construct the FQDN (Fully Qualified Domain Name) of the local computer
$ComputerSystem = Get-WmiObject -Class Win32_ComputerSystem
$FQDN = $ComputerSystem.DNSHostName + "." + $ComputerSystem.Domain

$ZabbixSoftwareName = "Zabbix Agent 2 (64-bit)"
$InstalledZabbixVersion = (Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -eq $ZabbixSoftwareName }).Version
$InstalledVersion = [version]"0.0.0"
if (-not [string]::IsNullOrWhiteSpace($InstalledZabbixVersion)) {
    if ($InstalledZabbixVersion -match '^\d+\.\d+\.\d+') {
        $InstalledVersion = [version]$Matches[0]
    } else {
        throw "Unable to determine the installed Zabbix Agent 2 version: $InstalledZabbixVersion"
    }
}

$TargetVersion = [version]$ZabbixAgentVersion
$ConfigExists = Test-Path -LiteralPath $ConfPath -PathType Leaf
$InstallRequired = $InstalledVersion -lt $TargetVersion
if (-not $ConfigExists) {
    if ($InstalledVersion -gt $TargetVersion) {
        throw "ConfPath does not exist and the installed agent is newer than the configured MSI; refusing to downgrade. Check ConfPath."
    }
    $InstallRequired = $true
}

if ($InstallRequired) {
    $MsiPath = Join-Path -Path $env:TEMP -ChildPath "zabbix_agent2-$ZabbixAgentVersion-windows-amd64-openssl.msi"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $PreviousProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ZabbixMsiUrl -OutFile $MsiPath -UseBasicParsing -ErrorAction Stop | Out-Null
    } finally {
        $ProgressPreference = $PreviousProgressPreference
    }
    if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf) -or (Get-Item -LiteralPath $MsiPath).Length -eq 0) {
        throw "The Zabbix MSI download failed or produced an empty file: $ZabbixMsiUrl"
    }

    $MsiProperties = @(
        "SERVER=$DefaultServer"
        "HOSTMETADATA=Windows"
        "HOSTNAME=$FQDN"
        "LOGFILESIZE=20"
        "DEBUGLEVEL=3"
        ('INSTALLFOLDER="{0}"' -f $InstallFolder)
        "IGNOREALREADYEXISTSFOLDER=1"
    )

    if (-not [string]::IsNullOrWhiteSpace($PskSecret)) {
        $MsiProperties += @(
            "TLSCONNECT=psk"
            "TLSACCEPT=psk"
            ('TLSPSKIDENTITY="{0}"' -f $DefaultPskId)
            ('TLSPSKFILE="{0}"' -f $PskFilePath)
        )
    }

    $MsiArguments = '/i "{0}" {1} /qn' -f $MsiPath, ($MsiProperties -join ' ')
    $MsiProcess = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $MsiArguments -WindowStyle Hidden -Wait -PassThru
    if ($MsiProcess.ExitCode -notin @(0, 3010)) {
        throw "Zabbix Agent 2 MSI installation failed with exit code $($MsiProcess.ExitCode)."
    }
}

if (-not (Test-Path -LiteralPath $ConfPath -PathType Leaf)) {
    throw "The agent configuration file was not created at ConfPath: $ConfPath"
}

$Configuration = [ordered]@{
    Server = $DefaultServer
    HostMetadata = "Windows"
    Hostname = $FQDN
    LogFileSize = "20"
    DebugLevel = "3"
}
$ManagedPattern = '^\s*#?\s*(Server|HostMetadata|Hostname|LogFileSize|DebugLevel)\s*='
$ConfigLines = @(Get-Content -LiteralPath $ConfPath -ErrorAction Stop | Where-Object { $_ -notmatch $ManagedPattern })

if (-not [string]::IsNullOrWhiteSpace($PskSecret)) {
    $TlsPattern = '^\s*#?\s*(TLSConnect|TLSAccept|TLSPSKIdentity|TLSPSKFile|TLSPSKValue)\s*='
    $ConfigLines = @($ConfigLines | Where-Object { $_ -notmatch $TlsPattern })
    $Configuration['TLSConnect'] = "psk"
    $Configuration['TLSAccept'] = "psk"
    $Configuration['TLSPSKIdentity'] = $DefaultPskId
    $Configuration['TLSPSKFile'] = $PskFilePath
} else {
    $ConfigLines = @($ConfigLines | Where-Object {
        $_ -notmatch '^\s*#?\s*TLSPSK(Identity|File|Value)\s*=' -and
        $_ -notmatch '^\s*#?\s*TLS(Connect|Accept)\s*=\s*psk\s*$'
    })
}

foreach ($Key in $Configuration.Keys) {
    $ConfigLines += "$Key=$($Configuration[$Key])"
}
$NewConfigContent = ($ConfigLines -join "`r`n") + "`r`n"
$OldConfigContent = [System.IO.File]::ReadAllText($ConfPath)
$ConfigurationChanged = $OldConfigContent -cne $NewConfigContent
if ($ConfigurationChanged) {
    $Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [System.IO.File]::WriteAllText($ConfPath, $NewConfigContent, $Utf8NoBom)
}

if (-not [string]::IsNullOrWhiteSpace($LldScript)) {
    $ScriptsFolder = Join-Path -Path $InstallFolder -ChildPath "scripts"
    New-Item -ItemType Directory -Path $ScriptsFolder -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $LldScript -Destination $ScriptsFolder -Force -ErrorAction Stop
}

if ($ConfigurationChanged -or $PskFileChanged) {
    $AgentService = Get-Service -Name "Zabbix Agent2" -ErrorAction SilentlyContinue
    if ($null -eq $AgentService) {
        throw "Agent configuration changed, but the Zabbix Agent2 service was not found."
    }
    Restart-Service -Name "Zabbix Agent2" -Force -ErrorAction Stop
}

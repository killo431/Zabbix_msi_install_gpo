##Zabbix Agent 2 silent installer for computer startup Group Policy.
##Deploy under Computer Configuration -> Policies -> Windows Settings -> Scripts -> Startup -> PowerShell Scripts.
##Set the server and optional PSK/script variables below before assigning the script to a GPO.
##Logs are written to %ProgramData%\ZabbixAgent2\logs (readable by SYSTEM and Administrators only).

param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# User-configurable variables
$ZabbixAgentVersion = "7.0.32"
$ZabbixMsiUrlTemplate = "https://github.com/killo431/packages/releases/download/main/zabbix_agent2-{0}-windows-amd64-openssl.msi"
$ServerActive = ""
$HostMetadata = "GAS;windows;ADC;server"
$HostnameMode = "FQDN"
$PskSecret = ""
$DefaultPskId = ""
$DefaultServer = "172.17.6.24"
$LldScript = ""
$ConfPath = "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf"
$AgentUnc = "\\gas-fil004\packages\Zabbix Agent 2\zabbix_agent2-7.0.32-windows-amd64-openssl.msi"
$ZabbixInstallationMSI = $AgentUnc
$MsiSha256 = ""

$SystemSid = New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-18'
$AdministratorsSid = New-Object -TypeName Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'
# SYSTEM, Administrators, TrustedInstaller
$TrustedOwnerSids = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
$LogFile = $null

function Write-Log {
    param([string]$Message)
    if (-not $script:LogFile) { return }
    try {
        Add-Content -LiteralPath $script:LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Logging must never break deployment.
    }
}

trap {
    Write-Log "ERROR: $($_.Exception.Message)"
    break
}

function Initialize-SecureDirectory {
    # Creates (or re-secures) a directory that only SYSTEM and Administrators can access.
    # Refuses to reuse a directory owned by anyone else, because a standard user could have
    # pre-created it under ProgramData and kept their own access entries.
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $Item = Get-Item -LiteralPath $Path -Force
        if (-not $Item.PSIsContainer) {
            throw "Expected a directory at $Path."
        }
        if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to use $Path because it is a junction or symbolic link."
        }
        $Owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($Owner -notin $TrustedOwnerSids) {
            throw "Refusing to use $Path because it is owned by $Owner, not SYSTEM or Administrators. Inspect and remove it, then rerun."
        }
    } else {
        # No -Force: fail closed if someone creates the directory between the check and here.
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
    $Acl = New-Object -TypeName Security.AccessControl.DirectorySecurity
    $Acl.SetOwner($AdministratorsSid)
    $Acl.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @($SystemSid, $AdministratorsSid)) {
        $Acl.AddAccessRule((New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @(
            $Sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Set-PskFileAcl {
    # Replaces the owner and every access entry, so stale or foreign entries cannot survive.
    param([string]$Path)
    $Acl = New-Object -TypeName Security.AccessControl.FileSecurity
    $Acl.SetOwner($AdministratorsSid)
    $Acl.SetAccessRuleProtection($true, $false)
    $Acl.AddAccessRule((New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($SystemSid, 'Read', 'Allow')))
    $Acl.AddAccessRule((New-Object -TypeName Security.AccessControl.FileSystemAccessRule -ArgumentList @($AdministratorsSid, 'FullControl', 'Allow')))
    Set-Acl -LiteralPath $Path -AclObject $Acl
}

function Get-InstalledAgentVersion {
    # Reads the Uninstall registry keys instead of Win32_Product, which triggers an MSI
    # consistency check (and possible self-repair) of every installed product.
    param([string]$DisplayName)
    $UninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    @(Get-ItemProperty -Path $UninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $DisplayName } |
        ForEach-Object { $_.DisplayVersion }) | Select-Object -First 1
}

function Get-AgentService {
    # Finds the service by executable rather than by display name.
    param([string]$InstallFolder)
    $Services = @(Get-CimInstance -ClassName Win32_Service | Where-Object { $_.PathName -match '(?i)zabbix_agent2\.exe' })
    if ($Services.Count -gt 1) {
        $Preferred = @($Services | Where-Object { $_.PathName.IndexOf($InstallFolder, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($Preferred.Count -gt 0) { $Services = $Preferred }
    }
    $Services | Select-Object -First 1
}

$SecureRoot = Join-Path -Path $env:ProgramData -ChildPath "ZabbixAgent2"
Initialize-SecureDirectory -Path $SecureRoot
$LogDirectory = Join-Path -Path $SecureRoot -ChildPath "logs"
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$LogFile = Join-Path -Path $LogDirectory -ChildPath "install.log"
if ((Test-Path -LiteralPath $LogFile -PathType Leaf) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force
}
Write-Log "Starting Zabbix Agent 2 deployment."

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $PackageConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "deployment.json"
    if (Test-Path -LiteralPath $PackageConfigPath -PathType Leaf) {
        $ConfigPath = $PackageConfigPath
    }
}
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    Write-Log "Using deployment configuration $ConfigPath."
    $Package = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    foreach ($Name in @('DefaultServer', 'ServerActive', 'HostMetadata', 'HostnameMode', 'PskSecret', 'DefaultPskId', 'LldScript', 'ConfPath', 'ZabbixInstallationMSI', 'MsiSha256')) {
        if ($null -eq $Package.PSObject.Properties[$Name] -or $Package.$Name -isnot [string]) {
            throw "Deployment configuration must contain a string value for $Name."
        }
    }
    $DefaultServer = $Package.DefaultServer
    $ServerActive = $Package.ServerActive
    $HostMetadata = $Package.HostMetadata
    $HostnameMode = $Package.HostnameMode
    $PskSecret = $Package.PskSecret
    $DefaultPskId = $Package.DefaultPskId
    $ConfPath = $Package.ConfPath
    $PackageRoot = Split-Path -Path (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path -Parent
    $ZabbixInstallationMSI = Join-Path -Path $PackageRoot -ChildPath $Package.ZabbixInstallationMSI
    $MsiSha256 = $Package.MsiSha256
    if ($MsiSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Deployment configuration must contain the MSI SHA256 hash."
    }
    if (-not [string]::IsNullOrWhiteSpace($Package.LldScript)) {
        $LldScript = Join-Path -Path $PackageRoot -ChildPath $Package.LldScript
    }
    # Optional for packages created before the version was recorded.
    if ($null -ne $Package.PSObject.Properties['ZabbixAgentVersion']) {
        if ($Package.ZabbixAgentVersion -isnot [string]) {
            throw "Deployment configuration must contain a string value for ZabbixAgentVersion."
        }
        $ZabbixAgentVersion = $Package.ZabbixAgentVersion
    }
}

if ($ZabbixAgentVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "ZabbixAgentVersion must look like 7.0.32."
}
$ZabbixMsiUrl = $ZabbixMsiUrlTemplate -f $ZabbixAgentVersion
if ([string]::IsNullOrWhiteSpace($DefaultServer)) {
    throw "Set DefaultServer to the Zabbix server or proxy address before deployment."
}
if ([string]::IsNullOrWhiteSpace($ServerActive)) {
    $ServerActive = $DefaultServer
}
if ([string]::IsNullOrWhiteSpace($HostMetadata)) {
    throw "Set HostMetadata to the expected GAS metadata string."
}
foreach ($Setting in @(
    @{ Name = 'DefaultServer'; Value = $DefaultServer }
    @{ Name = 'ServerActive'; Value = $ServerActive }
    @{ Name = 'HostMetadata'; Value = $HostMetadata }
    @{ Name = 'DefaultPskId'; Value = $DefaultPskId }
    @{ Name = 'ConfPath'; Value = $ConfPath }
)) {
    if ([string]$Setting.Value -match '[\r\n"]') {
        throw "$($Setting.Name) must not contain quotes or newlines."
    }
}
if ($HostnameMode -notin @('FQDN', 'GAS')) {
    throw "HostnameMode must be FQDN or GAS."
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
$PskFilePath = Join-Path -Path $SecureRoot -ChildPath "zabbix_agent2.psk"
$PskFileChanged = $false

if (-not [string]::IsNullOrWhiteSpace($PskSecret)) {
    if (($PskSecret.Length % 2) -ne 0) {
        throw "PskSecret must contain an even number of hexadecimal characters."
    }
    if (-not (Test-Path -LiteralPath $PskFilePath -PathType Leaf)) {
        [System.IO.File]::WriteAllText($PskFilePath, "", [System.Text.Encoding]::ASCII)
    }
    Set-PskFileAcl -Path $PskFilePath
    $PreviousPskSecret = [System.IO.File]::ReadAllText($PskFilePath)
    $PskFileChanged = $PreviousPskSecret -cne $PskSecret
    if ($PskFileChanged) {
        [System.IO.File]::WriteAllText($PskFilePath, $PskSecret, [System.Text.Encoding]::ASCII)
        Write-Log "PSK file updated."
    }
} elseif (Test-Path -LiteralPath $PskFilePath -PathType Leaf) {
    Remove-Item -LiteralPath $PskFilePath -Force -ErrorAction Stop
    $PskFileChanged = $true
    Write-Log "PSK disabled; removed the PSK file."
}

$ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
if ([string]::IsNullOrWhiteSpace($ComputerSystem.DNSHostName)) {
    throw "Unable to determine the computer's DNS host name."
}
$FQDN = if ($HostnameMode -eq 'GAS') {
    "GAS-$($ComputerSystem.DNSHostName)"
} elseif ($ComputerSystem.PartOfDomain -eq $false -or [string]::IsNullOrWhiteSpace($ComputerSystem.Domain)) {
    $ComputerSystem.DNSHostName
} else {
    $ComputerSystem.DNSHostName + "." + $ComputerSystem.Domain
}
if ($FQDN -match '[\r\n"]') {
    throw "The computed hostname contains unsupported characters: $FQDN"
}

$ZabbixSoftwareName = "Zabbix Agent 2 (64-bit)"
$InstalledZabbixVersion = Get-InstalledAgentVersion -DisplayName $ZabbixSoftwareName
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
Write-Log "Installed version $InstalledVersion; target $TargetVersion; install required: $InstallRequired."

if ($InstallRequired) {
    # Stage into a fresh directory only SYSTEM and Administrators can write to, so nobody can
    # swap the MSI between verification and msiexec (C:\Windows\Temp is writable by users).
    $StagingRoot = Join-Path -Path $SecureRoot -ChildPath "staging"
    New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
    $StagingDirectory = Join-Path -Path $StagingRoot -ChildPath ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $StagingDirectory | Out-Null
    try {
        $MsiPath = Join-Path -Path $StagingDirectory -ChildPath "zabbix_agent2-$ZabbixAgentVersion-windows-amd64-openssl.msi"
        $MsiCopied = $false
        if (-not [string]::IsNullOrWhiteSpace($ZabbixInstallationMSI)) {
            try {
                Copy-Item -LiteralPath $ZabbixInstallationMSI -Destination $MsiPath -Force -ErrorAction Stop
                $MsiCopied = $true
                Write-Log "Staged MSI from $ZabbixInstallationMSI."
            } catch [IO.IOException], [UnauthorizedAccessException], [Management.Automation.ItemNotFoundException], [Management.Automation.DriveNotFoundException] {
                Write-Warning "Cannot stage MSI from $ZabbixInstallationMSI; using the HTTPS fallback. $($_.Exception.Message)"
                Write-Log "Cannot stage MSI from $ZabbixInstallationMSI; using the HTTPS fallback. $($_.Exception.Message)"
            }
        }
        if (-not $MsiCopied) {
            $PreviousProgressPreference = $ProgressPreference
            $PreviousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
            try {
                $ProgressPreference = 'SilentlyContinue'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $ZabbixMsiUrl -OutFile $MsiPath -UseBasicParsing -ErrorAction Stop | Out-Null
                Write-Log "Downloaded MSI from $ZabbixMsiUrl."
            } finally {
                $ProgressPreference = $PreviousProgressPreference
                [Net.ServicePointManager]::SecurityProtocol = $PreviousSecurityProtocol
            }
        }
        if (-not (Test-Path -LiteralPath $MsiPath -PathType Leaf) -or (Get-Item -LiteralPath $MsiPath).Length -eq 0) {
            throw "The staged Zabbix MSI is missing or empty: $MsiPath"
        }
        if (-not [string]::IsNullOrWhiteSpace($MsiSha256)) {
            if ((Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256 -ErrorAction Stop).Hash -ine $MsiSha256) {
                throw "The deployment MSI does not match the configured SHA256 hash."
            }
        } else {
            $Signature = Get-AuthenticodeSignature -LiteralPath $MsiPath -ErrorAction Stop
            if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch 'O="?Zabbix SIA"?(,|$)') {
                throw "The staged MSI must have a valid Zabbix SIA Authenticode signature."
            }
        }

        $MsiProperties = @(
            ('SERVER="{0}"' -f $DefaultServer)
            ('SERVERACTIVE="{0}"' -f $ServerActive)
            ('HOSTMETADATA="{0}"' -f $HostMetadata)
            ('HOSTNAME="{0}"' -f $FQDN)
            'LOGFILESIZE=20'
            'DEBUGLEVEL=3'
            ('INSTALLFOLDER="{0}"' -f $InstallFolder)
            'IGNOREALREADYEXISTSFOLDER=1'
        )

        if (-not [string]::IsNullOrWhiteSpace($PskSecret)) {
            $MsiProperties += @(
                'TLSCONNECT=psk'
                'TLSACCEPT=psk'
                ('TLSPSKIDENTITY="{0}"' -f $DefaultPskId)
                ('TLSPSKFILE="{0}"' -f $PskFilePath)
            )
        }

        $MsiLog = Join-Path -Path $LogDirectory -ChildPath ('msiexec-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
        $MsiArguments = '/i "{0}" {1} /qn /norestart /l*v "{2}"' -f $MsiPath, ($MsiProperties -join ' '), $MsiLog
        # 1618 = another installation is in progress (common at startup alongside Windows Update).
        $MaxAttempts = 5
        for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
            $MsiProcess = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $MsiArguments -WindowStyle Hidden -Wait -PassThru
            if ($MsiProcess.ExitCode -ne 1618 -or $Attempt -eq $MaxAttempts) { break }
            Write-Log "Another installation is in progress (1618); retrying in 60 seconds (attempt $Attempt of $MaxAttempts)."
            Start-Sleep -Seconds 60
        }
        Write-Log "msiexec exited with code $($MsiProcess.ExitCode); log: $MsiLog"
        if ($MsiProcess.ExitCode -notin @(0, 3010)) {
            throw "Zabbix Agent 2 MSI installation failed with exit code $($MsiProcess.ExitCode). See $MsiLog."
        }
    } finally {
        Remove-Item -LiteralPath $StagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Path -LiteralPath $ConfPath -PathType Leaf)) {
    throw "The agent configuration file was not created at ConfPath: $ConfPath"
}

$Configuration = [ordered]@{
    Server = $DefaultServer
    ServerActive = $ServerActive
    HostMetadata = $HostMetadata
    Hostname = $FQDN
    LogFileSize = "20"
    DebugLevel = "3"
}
$ManagedPattern = '^\s*#?\s*(Server|ServerActive|HostMetadata|Hostname|LogFileSize|DebugLevel)\s*='
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
    Write-Log "Agent configuration updated."
}

if (-not [string]::IsNullOrWhiteSpace($LldScript)) {
    $ScriptsFolder = Join-Path -Path $InstallFolder -ChildPath "scripts"
    New-Item -ItemType Directory -Path $ScriptsFolder -Force -ErrorAction Stop | Out-Null
    Copy-Item -LiteralPath $LldScript -Destination $ScriptsFolder -Force -ErrorAction Stop
}

if ($ConfigurationChanged -or $PskFileChanged) {
    $AgentService = Get-AgentService -InstallFolder $InstallFolder
    if ($null -eq $AgentService) {
        throw "Agent configuration changed, but no service running zabbix_agent2.exe was found."
    }
    Restart-Service -Name $AgentService.Name -Force -ErrorAction Stop
    Write-Log "Restarted service '$($AgentService.Name)'."
}
Write-Log "Deployment finished."

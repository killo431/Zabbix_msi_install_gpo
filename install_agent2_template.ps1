##Interactive Zabbix Agent 2 setup through irm | iex.
##Original author: https://github.com/Padl3xx
#
##This wrapper keeps the published irm URL working. All installation logic lives in
##install_agent2_gpo.ps1 so the GPO and interactive paths cannot drift apart.
#
##In an elevated PowerShell session:
##  $env:ZABBIX_SERVER = "zabbix.example.com"
##  $env:ZABBIX_SCRIPT_REF = "<release tag or commit SHA>"   # recommended: pin what you run
##  irm https://raw.githubusercontent.com/killo431/Zabbix_msi_install_gpo/main/install_agent2_template.ps1 | iex
#
##Other overrides: ZABBIX_SERVER_ACTIVE, ZABBIX_HOST_METADATA, ZABBIX_HOSTNAME_MODE, ZABBIX_PSK_SECRET,
##ZABBIX_PSK_ID, ZABBIX_LLD_SCRIPT, ZABBIX_CONF_PATH, ZABBIX_AGENT_UNC. ZABBIX_PSK_SECRET is cleared after use.

& {
    $ErrorActionPreference = 'Stop'
    $Ref = $env:ZABBIX_SCRIPT_REF
    if ([string]::IsNullOrWhiteSpace($Ref)) {
        $Ref = 'main'
        Write-Warning "ZABBIX_SCRIPT_REF is not set; running the installer from the main branch. Pin a tag or commit SHA in production."
    }
    if ($Ref -notmatch '^[A-Za-z0-9._/-]+$') {
        throw "ZABBIX_SCRIPT_REF contains unsupported characters."
    }
    $InstallerUrl = "https://raw.githubusercontent.com/killo431/Zabbix_msi_install_gpo/$Ref/install_agent2_gpo.ps1"
    $PreviousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    $PreviousProgressPreference = $ProgressPreference
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        $InstallerSource = (Invoke-WebRequest -Uri $InstallerUrl -UseBasicParsing).Content
    } finally {
        [Net.ServicePointManager]::SecurityProtocol = $PreviousSecurityProtocol
        $ProgressPreference = $PreviousProgressPreference
    }
    if ($InstallerSource -isnot [string] -or $InstallerSource -notmatch 'Zabbix Agent 2 silent installer') {
        throw "Downloaded content from $InstallerUrl is not the Zabbix installer."
    }
    & ([scriptblock]::Create($InstallerSource))
}

# Zabbix_msi_install_gpo

Silent Zabbix Agent 2 deployment for Windows using MSI version 7.0.32.

## Group Policy deployment

### Create a deployment share and package

Download or clone this repository to a domain-joined Windows file server. In
**elevated Windows PowerShell 5.1**, run:

```powershell
.\New-ZabbixDeployment.ps1 -DefaultServer "zabbix.example.com" `
    -ReadAccess "CONTOSO\Zabbix Deployment Computers"
```

Create that AD security group first and add the target **computer accounts**,
not users. The runner creates a new `C:\ProgramData\ZabbixDeployment` directory
and `ZabbixAgent2$` SMB share. Use `-PackagePath` and `-ShareName` to change them.
It refuses to overwrite an existing directory or share.

The package contains the signed 7.0.32 MSI, `deployment.json`, the installer,
and `Start-ZabbixDeployment.ps1`. The runner checks the MSI's Authenticode
signature and records its SHA256 hash, which the installer verifies before use.
An optional `-LldScript` file is copied into the package. Clients read the MSI
from the share instead of downloading it from the internet.

For PSK authentication, provide a matching identity and securely prompted key:

```powershell
$psk = Read-Host "PSK (hexadecimal)" -AsSecureString
.\New-ZabbixDeployment.ps1 -DefaultServer "zabbix.example.com" `
    -ReadAccess "CONTOSO\Zabbix Deployment Computers" `
    -PskSecret $psk -DefaultPskId "WindowsAgents"
```

**Secrets:** `deployment.json` stores the PSK in plaintext so clients can install
it. Both NTFS and SMB permissions restrict package readers to the supplied
group, with administrator/SYSTEM management access. Every allowed computer
can read the shared key; use a narrowly scoped group and do not commit generated
packages or copy secrets into SYSVOL/NETLOGON.

Add the **UNC launcher path printed by the runner** to the GPO's computer
startup PowerShell scripts, then link the GPO to the target computers' OU.
Keep the launcher in the share beside its configuration and installer.
Enable **Always wait for the network at computer startup and logon** and ensure
the computers can reach the share over SMB (TCP 445). Only the file server needs
internet access during package creation. The runner does not create or link a
GPO, modify firewall rules, or change execution-policy/domain signing settings.
If script signing is required, sign the packaged scripts before deployment.
Failures stop setup; any partial directory is left for inspection, not published
as a new share before the package is complete.

### Manual startup-script deployment

Use `install_agent2_gpo.ps1` as a computer startup PowerShell script:

1. Set `$DefaultServer` to your Zabbix server or proxy address. Optionally set `$PskSecret`, `$DefaultPskId`, `$LldScript`, and `$ConfPath` at the top of the script.
2. In Group Policy Management, add the script under **Computer Configuration → Policies → Windows Settings → Scripts (Startup/Shutdown) → Startup → PowerShell Scripts**.
3. Link the GPO to the target computers' OU.

The MSI runs quietly. Installation/configuration errors are raised by the script.

## Interactive PowerShell setup

Run an elevated PowerShell session, set your server address, then fetch and execute `install_agent2_template.ps1`:

```powershell
$env:ZABBIX_SERVER = "zabbix.example.com"
irm https://raw.githubusercontent.com/killo431/Zabbix_msi_install_gpo/main/install_agent2_template.ps1 | iex
```

Optional environment overrides are `ZABBIX_PSK_SECRET`, `ZABBIX_PSK_ID`, `ZABBIX_LLD_SCRIPT`, and `ZABBIX_CONF_PATH`. The PSK secret environment variable is removed by the script after it is read.

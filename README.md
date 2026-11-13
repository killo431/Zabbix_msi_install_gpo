# Zabbix_msi_install_gpo

Silent Zabbix Agent 2 deployment for Windows using MSI version 7.0.32.

## Group Policy deployment

### Create a deployment share and package

Download or clone this repository to a domain-joined Windows file server. In
**elevated Windows PowerShell 5.1**, run:

```powershell
.\New-ZabbixDeployment.ps1 -DefaultServer "zabbix.example.com" `
    -ServerActive "zbx01.example.com" `
    -HostMetadata "GAS;windows;ADC;server" `
    -ReadAccess "CONTOSO\Zabbix Deployment Computers"
```

Create that AD security group first and add the target **computer accounts**,
not users. The runner creates a new `C:\ProgramData\ZabbixDeployment` directory
and `ZabbixAgent2$` SMB share. Use `-PackagePath` and `-ShareName` to change them.
It refuses to overwrite an existing directory or share. The primary MSI source
is `\\gas-fil004\packages\Zabbix Agent 2\zabbix_agent2-7.0.32-windows-amd64-openssl.msi`,
matching the original deployment script; use `-AgentUnc` to select another source.
The runner copies from this share first and uses the GitHub download only if
copying fails or the source is missing/inaccessible. Use `-ZabbixAgentVersion`
to package a different agent release; the MSI file name, default UNC path, and
download URL follow it, and the runner refuses an MSI whose internal
ProductVersion does not match. The version is recorded in `deployment.json`.

`ServerActive` defaults to `DefaultServer` when omitted. `HostMetadata` defaults
to `GAS;windows;ADC;server`; use `GAS;windows;ADC;sql` for SQL servers. Choose
`-HostnameMode GAS` to advertise `GAS-<computername>` instead of the default
FQDN. Create role/site-specific packages as needed and ensure each metadata
value exactly matches the corresponding Zabbix autoregistration regex.

The package contains the signed 7.0.32 MSI, `deployment.json`, the installer,
and `Start-ZabbixDeployment.ps1`. The runner checks the MSI's Authenticode
signature and records its SHA256 hash, which the installer verifies before use.
An optional `-LldScript` file is copied into the package. Clients copy the MSI
from the deployment share to local staging before running it. If that MSI
cannot be copied, they fall back to the fixed GitHub HTTPS URL.
An empty MSI, invalid signature, or SHA256 mismatch stops deployment rather
than silently switching sources. Downloads must match the package's SHA256 hash.

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
the computers can reach the share over SMB (TCP 445). Internet access is needed
only on machines using the download fallback. Clients still need the launcher,
configuration, and any LLD script; fallback replaces only the MSI, not the
entire deployment share. The runner does not create or link a
GPO, modify firewall rules, or change execution-policy/domain signing settings.
If script signing is required, sign the packaged scripts before deployment.
Failures stop setup; any partial directory is left for inspection, not published
as a new share before the package is complete.

### Manual startup-script deployment

Use `install_agent2_gpo.ps1` as a computer startup PowerShell script:

1. Set `$DefaultServer` and `$ServerActive` to your Zabbix server/proxy addresses. Set `$HostMetadata` to the exact autoregistration metadata string (for example `GAS;windows;ADC;server` or `GAS;windows;ADC;sql`). `$HostnameMode` defaults to FQDN; set it to `GAS` to advertise `GAS-<computername>`. Optionally set `$PskSecret`, `$DefaultPskId`, `$LldScript`, and `$ConfPath`.
2. In Group Policy Management, add the script under **Computer Configuration → Policies → Windows Settings → Scripts (Startup/Shutdown) → Startup → PowerShell Scripts**.
3. Link the GPO to the target computers' OU.

The MSI runs quietly. Installation/configuration errors are raised by the script.

### Client-side behavior and logs

- **Logs:** each run appends to `%ProgramData%\ZabbixAgent2\logs\install.log`
  (rotated at 1 MB), and every MSI run writes a verbose
  `msiexec-<timestamp>.log` beside it. PSK values are never logged.
- **Secured working directory:** `%ProgramData%\ZabbixAgent2` (PSK file, logs,
  MSI staging) is reset on every run so only SYSTEM and Administrators can
  access it. If that directory exists but is owned by anyone other than
  SYSTEM, Administrators, or TrustedInstaller, or is a junction, the installer
  stops: a standard user may have created it in advance. Inspect and delete it,
  then let the startup script run again.
- **MSI staging:** the MSI is copied or downloaded into a new, per-run folder
  inside that directory (not `%TEMP%`), verified, installed, and deleted.
- **Installed version detection** reads the Windows Uninstall registry keys
  instead of `Win32_Product`.
- **Busy installer:** exit code 1618 (another installation in progress) is
  retried up to five times, 60 seconds apart.
- **Service restart:** the agent service is located by its `zabbix_agent2.exe`
  path rather than by name.

## Automatic agent configuration check

Run `Test-ZabbixAgentConfiguration.ps1` on an agent to check its configuration
directives, service and executable, PSK file presence when PSK mode is enabled,
the agent's built-in config test, and TCP reachability to the first
`ServerActive` endpoint. It is read-only and returns an object with an `ExitCode`
of `1` if any checks fail:

```powershell
$result = .\Test-ZabbixAgentConfiguration.ps1 `
    -ExpectedServer "zabbix.example.com" `
    -ExpectedServerActive "zbx01.example.com" `
    -ExpectedHostMetadata "GAS;windows;ADC;server" `
    -HostnameMode FQDN
if ($result.ExitCode -ne 0) { Write-Error "Zabbix agent check failed." }
```

Set `-ExpectedHostMetadata "GAS;windows;ADC;sql"` for SQL hosts or
`-HostnameMode GAS` for `GAS-<computername>` hostnames. See
`ZABBIX_CONFIGURATION_AGENT_PROMPT.md` for a reusable read-only diagnostic
prompt and approval-gated remediation guidance. The checker does not verify
server-side host registration, item state, or triggers.

## Interactive PowerShell setup

Run an elevated PowerShell session, set your server address, then fetch and execute `install_agent2_template.ps1`:

```powershell
$env:ZABBIX_SERVER = "zabbix.example.com"
irm https://raw.githubusercontent.com/killo431/Zabbix_msi_install_gpo/main/install_agent2_template.ps1 | iex
```

Optional environment overrides are `ZABBIX_PSK_SECRET`, `ZABBIX_PSK_ID`, `ZABBIX_LLD_SCRIPT`, `ZABBIX_CONF_PATH`, and `ZABBIX_AGENT_UNC`. The PSK secret environment variable is removed by the script after it is read.
Use `ZABBIX_SERVER_ACTIVE`, `ZABBIX_HOST_METADATA`, and `ZABBIX_HOSTNAME_MODE` to override the active-check destination, exact GAS metadata, and `FQDN`/`GAS` hostname mode.

The standalone GPO and `irm | iex` installers also prefer `$AgentUnc` (the
original FIL004 MSI path) and use the GitHub download only when staging from
that source fails. Both require a valid Zabbix SIA Authenticode signature when
no deployment-package SHA256 hash is provided. They use the current execution
identity to access SMB; no SMB credentials are embedded or passed to `net use`.

# Zabbix_msi_install_gpo

Silent Zabbix Agent 2 deployment for Windows using MSI version 7.0.32.

## Group Policy deployment

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

##This script is used to install and update zabbix agent version 2 via GPO
#
##Author: https://github.com/Padl3xx
#
##The script starts the GPO when the computer starts, it is applied to computers, not users.
##Create a new GPO, go to, Computer Configuration -> Policies -> Windows Settings -> Scripts -> Startup -> Powershell Scripts -> Add.
##Dont forget to link the GPO on specified OU :-)
##It should probably work if you run the installation directly from your computer, but I haven't tried that.
#
# Construct the FQDN (Fully Qualified Domain Name) of the local computer
$FQDN=(Get-WmiObject win32_computersystem).DNSHostName+"."+(Get-WmiObject win32_computersystem).Domain


#User-configurable variables
$ZabbixInstallationMSI = "\\yourdomain.com\NETLOGON\ZabbixAgent2\zabbix_agent2-7.0.9-windows-amd64-openssl.msi"
$ZabbixAgentVersion = "7.0.9"
$PskSecret = ""
$DefaultPskId = ""
$DefaultServer = "8.8.8.8"
$LldScript = ""
$ConfPath = "C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf"
#$ZabbixInstallationFolder = "\\$FQDN\c$\Program Files\Zabbix Agent 2\"
#$ZabbixPluginFolder = "\\yourdomain.com\NETLOGON\ZabbixAgent2\zabbix_agent2.d\"
#$ZabbixScriptsFolder = "\\yourdomain.com\NETLOGON\ZabbixAgent2\scripts"

if ([string]::IsNullOrWhiteSpace($PskSecret) -xor [string]::IsNullOrWhiteSpace($DefaultPskId)) {
    throw "Set both PskSecret and DefaultPskId, or leave both empty."
}

# Be careful what you change here

if (get-service -Name "Zabbix Agent2") { 
Stop-Service -Name "Zabbix Agent2" -Force
sc.exe stop "Zabbix Agent2"
Start-Sleep -s 1
Remove-Item C:\Zabbix -Recurse -Force
sc.exe delete "Zabbix Agent2"
}

$ZabbixSoftwareName = "Zabbix Agent 2 (64-bit)"
$InstalledZabbixVersion = (Get-WmiObject -Class Win32_Product | Where-Object { $_.Name -eq $ZabbixSoftwareName }).Version

# Extract the major version from the installed version
$InstalledVersion = $InstalledZabbixVersion -replace "(\d+\.\d+\.\d+).*", '$1'

$Arguments = @(
    "SERVER=$DefaultServer"
    "HOSTMETADATA=Windows"
    "HOSTNAME=$FQDN"
    "LOGFILESIZE=20"
    "DEBUGLEVEL=3"
)
if (-not [string]::IsNullOrWhiteSpace($PskSecret)) {
    $Arguments += "TLSPSKIDENTITY=$DefaultPskId"
    $Arguments += "TLSPSKVALUE=$PskSecret"
}
$Arguments += "/qn"

if ([System.Version]$InstalledVersion -lt [System.Version]$ZabbixAgentVersion) {
    # The installed version is different from the desired version, so perform the installation or update

    if (Test-Path $ZabbixInstallationMSI) {
        # The installation file is available, so start the installation process
		Start-Process -FilePath "$ZabbixInstallationMSI" -ArgumentList ($Arguments -join ' ') -Wait
	Start-Sleep -s 1	
	#if (Test-Path $ConfPath) {
	#(Get-Content $ConfPath) -replace '^(#?\s*LogFileSize=.*)', 'LogFileSize=20' |
    #ForEach-Object {$_ -replace '^(#?\s*DebugLevel=.*)', 'DebugLevel=3'} |
    #ForEach-Object {$_ -replace '^(ServerActive=.*)', '#ServerActive='} |
    #Set-Content $ConfPath -Force
	#} else {
    #"[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Error: File $ConfPath does not exist!" | Set-Content $FailLog -Force
	#}
		#Copy-Item -Path @($ZabbixPluginFolder, $ZabbixScriptsFolder) -Destination $ZabbixInstallationFolder -Force -Recurse
    } else {
        # The installation file is not available, exit the script
        exit
    }

}

if (-not [string]::IsNullOrWhiteSpace($LldScript)) {
    if (-not (Test-Path -LiteralPath $LldScript -PathType Leaf)) {
        throw "LLD script file not found: $LldScript"
    }

    $ScriptsFolder = Join-Path -Path (Split-Path -Path $ConfPath -Parent) -ChildPath "scripts"
    New-Item -ItemType Directory -Path $ScriptsFolder -Force | Out-Null
    Copy-Item -LiteralPath $LldScript -Destination $ScriptsFolder -Force
}

## Function to update plugin and scripts folders if changes are detected
#if (!(Test-Path -Path "$(Split-Path -Path $ConfPath -Parent)\zabbix_agent2.d" -PathType Container)) {
##if not exist, folder is created
#    New-Item -ItemType Directory -Path "$(Split-Path -Path $ConfPath -Parent)\zabbix_agent2.d" -Force
#}
#
#if (!(Test-Path -Path "$(Split-Path -Path $ConfPath -Parent)\scripts" -PathType Container)) {
##if not exist, folder is created
#    New-Item -ItemType Directory -Path "$(Split-Path -Path $ConfPath -Parent)\scripts" -Force
#}
#
## Function to synchronize files of specified folders
#function Sync-Folder {
#    param(
#        [string]$sourceFolder,
#        [string]$destinationFolder
#    )
#    
#    $sourceFiles = Get-ChildItem -Path $sourceFolder -File
#    foreach ($file in $sourceFiles) {
#        $destinationFile = Join-Path -Path $destinationFolder -ChildPath $file.Name
#        if (!(Test-Path -Path $destinationFile -PathType Leaf)) {
#            #sync
#            Copy-Item -Path $file.FullName -Destination $destinationFolder
#        }
#    }
#}
#
## Sync files from given folders
#Sync-Folder -sourceFolder $ZabbixPluginFolder -destinationFolder "$(Split-Path -Path $ConfPath -Parent)\zabbix_agent2.d\"
#Sync-Folder -sourceFolder $ZabbixScriptsFolder -destinationFolder "$(Split-Path -Path $ConfPath -Parent)\scripts\"

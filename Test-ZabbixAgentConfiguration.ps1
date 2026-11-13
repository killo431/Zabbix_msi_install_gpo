#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf',
    [string]$AgentExePath = 'C:\Program Files\Zabbix Agent 2\zabbix_agent2.exe',
    [string]$ExpectedServer = '',
    [string]$ExpectedServerActive = '',
    [string]$ExpectedHostMetadata = 'GAS;windows;ADC;server',
    [ValidateSet('FQDN', 'GAS')]
    [string]$HostnameMode = 'FQDN',
    [string]$ExpectedHostname = '',
    [switch]$SkipNetworkCheck,
    [switch]$SkipAgentConfigTest
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ExpectedServerActive)) {
    $ExpectedServerActive = $ExpectedServer
}

$Checks = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param(
        [ValidateSet('PASS', 'WARN', 'FAIL')]
        [string]$Status,
        [string]$Check,
        [string]$Detail
    )
    $Checks.Add([pscustomobject]@{
        Status = $Status
        Check = $Check
        Detail = $Detail
    })
}

$ConfigValues = @{}
$ConfigKeys = @{}
$ConfigReadable = $false
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Add-Check FAIL 'Configuration file' "Not found: $ConfigPath"
} else {
    try {
        foreach ($Line in Get-Content -LiteralPath $ConfigPath -ErrorAction Stop) {
            if ($Line -match '^\s*(?<key>[A-Za-z][A-Za-z0-9]*)\s*=\s*(?<value>.*)$') {
                $Key = $Matches.key
                $Value = $Matches.value.Trim()
                if (-not $ConfigKeys.ContainsKey($Key)) {
                    $ConfigKeys[$Key] = 0
                }
                $ConfigKeys[$Key]++
                if ($Key -match '^TLSPSKValue$') {
                    $Value = '[redacted]'
                }
                $ConfigValues[$Key] = $Value
            }
        }
        $ConfigReadable = $true
        Add-Check PASS 'Configuration file' "Readable: $ConfigPath"
    } catch {
        Add-Check FAIL 'Configuration file' "Cannot read configuration: $($_.Exception.Message)"
    }
}

if ($ConfigReadable) {
    $ExpectedHostnameResolved = $ExpectedHostname
    if ([string]::IsNullOrWhiteSpace($ExpectedHostnameResolved)) {
        try {
            $Computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($HostnameMode -eq 'GAS') {
                $ExpectedHostnameResolved = "GAS-$($Computer.DNSHostName)"
            } else {
                $ExpectedHostnameResolved = "$($Computer.DNSHostName).$($Computer.Domain)"
            }
        } catch {
            Add-Check WARN 'Expected hostname' "Unable to determine local hostname: $($_.Exception.Message)"
        }
    }

    $Expectations = @(
        @{ Key = 'Server'; Expected = $ExpectedServer }
        @{ Key = 'ServerActive'; Expected = $ExpectedServerActive }
        @{ Key = 'HostMetadata'; Expected = $ExpectedHostMetadata }
        @{ Key = 'Hostname'; Expected = $ExpectedHostnameResolved }
    )
    foreach ($Expectation in $Expectations) {
        $Key = $Expectation.Key
        $Expected = [string]$Expectation.Expected
        if ([string]::IsNullOrWhiteSpace($Expected)) {
            continue
        }
        if (-not $ConfigValues.ContainsKey($Key)) {
            Add-Check FAIL "Config $Key" 'Directive is missing.'
        } elseif ($ConfigValues[$Key] -cne $Expected) {
            Add-Check FAIL "Config $Key" "Expected '$Expected'; found '$($ConfigValues[$Key])'."
        } else {
            Add-Check PASS "Config $Key" "Matches expected value '$Expected'."
        }
    }

    $ManagedKeys = @('Server', 'ServerActive', 'HostMetadata', 'Hostname', 'TLSConnect', 'TLSAccept', 'TLSPSKIdentity', 'TLSPSKFile')
    foreach ($Key in $ManagedKeys) {
        if ($ConfigKeys.ContainsKey($Key) -and $ConfigKeys[$Key] -gt 1) {
            Add-Check FAIL "Duplicate $Key" "Found $($ConfigKeys[$Key]) active definitions; keep one active definition."
        }
    }

    $UsesPsk = ($ConfigValues['TLSConnect'] -eq 'psk' -or $ConfigValues['TLSAccept'] -eq 'psk')
    if ($UsesPsk) {
        if ($ConfigValues['TLSConnect'] -ne 'psk' -or $ConfigValues['TLSAccept'] -ne 'psk') {
            Add-Check FAIL 'PSK transport' 'TLSConnect and TLSAccept must both be psk when PSK transport is used.'
        } else {
            Add-Check PASS 'PSK transport' 'TLSConnect and TLSAccept are both psk.'
        }
        if ([string]::IsNullOrWhiteSpace($ConfigValues['TLSPSKIdentity'])) {
            Add-Check FAIL 'PSK identity' 'TLSPSKIdentity is missing or empty.'
        } else {
            Add-Check PASS 'PSK identity' 'Identity is configured; value is not displayed.'
        }
        $PskFile = [string]$ConfigValues['TLSPSKFile']
        if ([string]::IsNullOrWhiteSpace($PskFile) -or -not (Test-Path -LiteralPath $PskFile -PathType Leaf)) {
            Add-Check FAIL 'PSK file' 'TLSPSKFile is missing or points to a file that does not exist.'
        } else {
            Add-Check PASS 'PSK file' "Configured PSK file exists: $PskFile"
        }
    } else {
        Add-Check WARN 'PSK transport' 'PSK is not configured; verify this matches the Zabbix host encryption settings.'
    }
}

$Service = $null
foreach ($ServiceName in @('Zabbix Agent 2', 'Zabbix Agent2')) {
    $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($Service) { break }
}
if (-not $Service) {
    Add-Check FAIL 'Windows service' 'Zabbix Agent 2 service was not found.'
} elseif ($Service.Status -ne 'Running') {
    Add-Check FAIL 'Windows service' "Service status is $($Service.Status)."
} else {
    Add-Check PASS 'Windows service' 'Zabbix Agent 2 is running.'
}

if (-not (Test-Path -LiteralPath $AgentExePath -PathType Leaf)) {
    Add-Check FAIL 'Agent executable' "Not found: $AgentExePath"
} else {
    try {
        $AgentVersion = (Get-Item -LiteralPath $AgentExePath -ErrorAction Stop).VersionInfo.ProductVersion
        Add-Check PASS 'Agent executable' "Found Zabbix Agent 2 $AgentVersion."
    } catch {
        Add-Check WARN 'Agent executable' "Found executable but could not read its version: $($_.Exception.Message)"
    }
    if (-not $SkipAgentConfigTest -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        try {
            $null = & $AgentExePath -T -c $ConfigPath 2>&1
            $TestExitCode = $LASTEXITCODE
            if ($TestExitCode -eq 0) {
                Add-Check PASS 'Agent config validation' 'zabbix_agent2 -T accepted the configuration.'
            } else {
                Add-Check FAIL 'Agent config validation' "zabbix_agent2 -T exited with code $TestExitCode. Output is suppressed to avoid leaking config values."
            }
        } catch {
            Add-Check FAIL 'Agent config validation' "Unable to run zabbix_agent2 -T: $($_.Exception.Message)"
        }
    } elseif ($SkipAgentConfigTest) {
        Add-Check WARN 'Agent config validation' 'Skipped by request.'
    }
}

if (-not $SkipNetworkCheck) {
    $ActiveTarget = [string]$ConfigValues['ServerActive']
    if ([string]::IsNullOrWhiteSpace($ActiveTarget)) { $ActiveTarget = $ExpectedServerActive }
    $ActiveEndpoint = ($ActiveTarget -split ',')[0].Trim()
    if ($ActiveEndpoint -match '^\[(?<host>[^\]]+)\](?::(?<port>\d+))?$') {
        $ActiveHost = $Matches.host
        $ActivePort = if ($Matches.port) { [int]$Matches.port } else { 10051 }
    } elseif ($ActiveEndpoint -match '^(?<host>[^:]+)(?::(?<port>\d+))?$') {
        $ActiveHost = $Matches.host
        $ActivePort = if ($Matches.port) { [int]$Matches.port } else { 10051 }
    } else {
        $ActiveHost = $null
    }
    if ($ActiveHost) {
        try {
            $Reachable = Test-NetConnection -ComputerName $ActiveHost -Port $ActivePort -InformationLevel Quiet -WarningAction SilentlyContinue
            if ($Reachable) {
                Add-Check PASS 'Active server network' "TCP $ActiveHost`:$ActivePort is reachable."
            } else {
                Add-Check WARN 'Active server network' "TCP $ActiveHost`:$ActivePort did not respond; verify routing and firewall access."
            }
        } catch {
            Add-Check WARN 'Active server network' "Could not test TCP $ActivePort to $ActiveHost`: $($_.Exception.Message)"
        }
    } else {
        Add-Check WARN 'Active server network' 'Could not parse the first ServerActive endpoint; skipped connectivity check.'
    }
} else {
    Add-Check WARN 'Active server network' 'Skipped by request.'
}

$Checks | Format-Table -AutoSize | Out-String | Write-Host
$FailureCount = @($Checks | Where-Object Status -eq 'FAIL').Count
$WarningCount = @($Checks | Where-Object Status -eq 'WARN').Count
$ExitCode = 0
if ($FailureCount -gt 0) { $ExitCode = 1 }
$Summary = [pscustomobject]@{
    ExitCode = $ExitCode
    Failures = $FailureCount
    Warnings = $WarningCount
    Checks = $Checks.ToArray()
}
Write-Output $Summary

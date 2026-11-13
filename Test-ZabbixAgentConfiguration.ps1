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

function Read-AgentConfigFile {
    # Parses one file and follows Include= directives (relative paths resolve from the main config folder).
    param([string]$Path, [int]$Depth = 0)
    if ($Depth -gt 5) {
        throw "Include nesting is deeper than 5 levels at $Path."
    }
    foreach ($Line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if ($Line -notmatch '^\s*(?<key>[A-Za-z][A-Za-z0-9.]*)\s*=\s*(?<value>.*)$') {
            continue
        }
        $Key = $Matches.key
        $Value = $Matches.value.Trim()
        if ($Key -eq 'Include') {
            $IncludePath = $Value.Trim('"')
            if (-not [IO.Path]::IsPathRooted($IncludePath)) {
                $IncludePath = Join-Path -Path (Split-Path -Path $ConfigPath -Parent) -ChildPath $IncludePath
            }
            if (Test-Path -LiteralPath $IncludePath -PathType Container) {
                $IncludedFiles = @(Get-ChildItem -LiteralPath $IncludePath -File -ErrorAction Stop)
            } else {
                $IncludedFiles = @(Get-ChildItem -Path $IncludePath -File -ErrorAction SilentlyContinue)
            }
            if ($IncludedFiles.Count -eq 0 -and $IncludePath -notmatch '[*?]') {
                Add-Check WARN 'Configuration include' "Include target not found: $IncludePath"
            }
            foreach ($IncludedFile in $IncludedFiles) {
                Read-AgentConfigFile -Path $IncludedFile.FullName -Depth ($Depth + 1)
            }
            continue
        }
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

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Add-Check FAIL 'Configuration file' "Not found: $ConfigPath"
} else {
    try {
        Read-AgentConfigFile -Path $ConfigPath
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
            if ($Key -in @('Server', 'ServerActive')) {
                Add-Check WARN "Config $Key" 'No expected value supplied; not verified. Pass -ExpectedServer.'
            }
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

    $TlsAcceptModes = @(([string]$ConfigValues['TLSAccept']) -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    $UsesPsk = ($ConfigValues['TLSConnect'] -eq 'psk' -or $TlsAcceptModes -contains 'psk')
    if ($UsesPsk) {
        if ($ConfigValues['TLSConnect'] -ne 'psk' -or $TlsAcceptModes -notcontains 'psk') {
            Add-Check FAIL 'PSK transport' 'TLSConnect must be psk and TLSAccept must include psk when PSK transport is used.'
        } elseif ($TlsAcceptModes -contains 'unencrypted') {
            Add-Check WARN 'PSK transport' 'TLSAccept also allows unencrypted connections; remove it once all servers/proxies use PSK.'
        } else {
            Add-Check PASS 'PSK transport' 'TLSConnect and TLSAccept use psk.'
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
try {
    # Locate the service by executable so the check does not depend on the service name.
    $Service = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
        Where-Object { $_.PathName -match '(?i)zabbix_agent2\.exe' }) | Select-Object -First 1
} catch {
    Add-Check WARN 'Windows service' "Unable to query services: $($_.Exception.Message)"
}
if (-not $Service) {
    Add-Check FAIL 'Windows service' 'No service running zabbix_agent2.exe was found.'
} elseif ($Service.State -ne 'Running') {
    Add-Check FAIL 'Windows service' "Service '$($Service.Name)' state is $($Service.State)."
} else {
    Add-Check PASS 'Windows service' "Service '$($Service.Name)' is running."
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
    # ',' separates servers/proxies; ';' separates nodes of one HA cluster. Test the first node.
    $ActiveEndpoint = (($ActiveTarget -split ',')[0] -split ';')[0].Trim()
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

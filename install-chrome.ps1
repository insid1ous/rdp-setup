#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Run as administrator under the Windows account that will use Proxifier,
after basic-setup.ps1 and a manual restart.
Requires curl.exe (included with current Windows 10/11 installations).
Prompts for a SOCKS5 proxy, installs/configures Proxifier, and verifies routing.
The supplied profile stores the proxy password in plaintext, as requested.
Use -SystemWideLicense to register in HKLM instead of HKCU.
A timeout does not uninstall or stop Proxifier or undo configuration.
Checks the public IP and observed DNS resolver using whoer.to's live check flow:
https://whoer.to/ip -> /ip2co; random.edns.ip-api.com/json -> /ip2co.
Both must report DE in the same attempt within 180 seconds; otherwise no Chrome download.
This checks the resolver observed by that test, not every resolver or browser DoH.
These are website endpoints, not a guaranteed stable API. Unknown results fail closed.
Exit codes: 0 = installer completed; 1 = failure; 2 = proxy or country-check timeout.
#>
[CmdletBinding()]
param(
    [switch]$SystemWideLicense
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
$chromeInstaller = $null
$installer = $null
$proxyPassword = $null
$exitCode = 1

# curl config is passed over stdin so credentials do not appear in its command line.
function ConvertTo-CurlQuoted([string]$Value) {
    if ($Value -match '[\r\n\x00]') { throw 'Input cannot contain line breaks or NUL.' }
    '"' + $Value.Replace('\', '\\').Replace('"', '\"').Replace("`t", '\t') + '"'
}

function Get-PublicIp {
    param([string]$ProxyEndpoint, [string]$Credentials, [double]$Timeout = 20)
    $seconds = $Timeout.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    $config = @(
        'url = "https://api.ipify.org/?format=plain"'
        'silent'
        'fail'
        'ipv4'
        "max-time = $seconds"
        'connect-timeout = 10'
    )
    if ($ProxyEndpoint) {
        $config += 'proxy = ' + (ConvertTo-CurlQuoted $ProxyEndpoint)
        $config += 'proxy-user = ' + (ConvertTo-CurlQuoted $Credentials)
        $config += 'noproxy = ""'
    } else {
        # No application-level proxy: Proxifier must intercept the connection.
        $config += 'proxy = ""'
        $config += 'noproxy = "*"'
    }
    $oldEncoding = $OutputEncoding
    try {
        $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $response = ($config -join "`n") | & $script:CurlPath --disable --config -
        $curlExit = $LASTEXITCODE
    } finally {
        $OutputEncoding = $oldEncoding
    }
    if ($curlExit -ne 0) { throw "IP request failed (curl exit code $curlExit). Response: $response" }
    $value = ($response -join '').Trim()
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($value, [ref]$parsed)) {
        throw 'ipify did not return a valid IP address.'
    }
    $parsed.ToString()
}


function Get-CheckResponse([string]$Uri) {
    $remaining = 180 - $script:checkTimer.Elapsed.TotalSeconds
    if ($remaining -le 0) { throw 'Country-check deadline reached.' }
    $limit = [Math]::Min(15, $remaining).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
    # Disable curl config/environment proxies, so Proxifier controls routing.
    # --max-time bounds the whole request, including DNS and connection setup.
    $response = & $script:CurlPath --disable --silent --show-error --fail `
        --noproxy '*' --max-time $limit --connect-timeout $limit `
        --header 'Cache-Control: no-cache' $Uri
    if ($LASTEXITCODE -ne 0) { throw "Check request failed (curl exit $LASTEXITCODE)." }
    return ($response -join "`n").Trim()
}
function ConvertFrom-Jsonp([string]$Text, [string]$Callback) {
    $pattern = '(?s)^\s*' + [regex]::Escape($Callback) + '\s*\((.*)\)\s*;?\s*$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { throw "Unexpected $Callback response; cannot validate country." }
    # Parse JSON only; never execute JavaScript returned by the website.
    return ($match.Groups[1].Value | ConvertFrom-Json)
}
function Confirm-Ip([string]$Value) {
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed)) {
        throw 'The check returned an invalid IP address.'
    }
    return $parsed.ToString()
}
function Get-WhoerCountry([string]$Ip) {
    $uri = 'https://whoer.to/ip2co?ip=' + [Uri]::EscapeDataString($Ip)
    $result = ConvertFrom-Jsonp (Get-CheckResponse $uri) 'ip2co'
    $codes = @([regex]::Matches([string]$result.output, '(?i)\bflag-([a-z]{2})\b') |
        ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Select-Object -Unique)
    if ($codes.Count -ne 1) { throw 'whoer.to did not report a single recognizable country.' }
    return $codes[0]
}

try {
    $script:CurlPath = (Get-Command curl.exe -CommandType Application -ErrorAction Stop).Source
    $proxyIp = (Read-Host 'SOCKS5 proxy IP address').Trim()
    $parsedProxy = $null
    if (-not [Net.IPAddress]::TryParse($proxyIp, [ref]$parsedProxy)) {
        throw 'Enter a valid IPv4 or IPv6 proxy address.'
    }
    $proxyPort = 0
    if (-not [int]::TryParse((Read-Host 'SOCKS5 proxy port'), [ref]$proxyPort) -or
        $proxyPort -lt 1 -or $proxyPort -gt 65535) { throw 'Port must be 1-65535.' }
    $proxyUsername = Read-Host 'SOCKS5 proxy username'
    if ([string]::IsNullOrEmpty($proxyUsername) -or $proxyUsername.Contains(':')) {
        throw 'Username must be nonempty and cannot contain a colon (curl limitation).'
    }
    $securePassword = Read-Host 'SOCKS5 proxy password' -AsSecureString
    $proxyPassword = (New-Object System.Net.NetworkCredential('', $securePassword)).Password
    if ([string]::IsNullOrEmpty($proxyPassword)) { throw 'Password cannot be empty.' }
    foreach ($credentialPart in @($proxyUsername, $proxyPassword)) {
        $byteCount = [Text.Encoding]::UTF8.GetByteCount($credentialPart)
        if ($byteCount -gt 255) { throw 'SOCKS5 credentials must each fit in 255 UTF-8 bytes.' }
    }
    $addressForUrl = $parsedProxy.ToString()
    if ($parsedProxy.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
        $addressForUrl = '[' + $addressForUrl + ']'
    }
    Write-Host 'Validating SOCKS5 proxy...'
    $proxyPublicIp = Get-PublicIp -ProxyEndpoint "socks5h://${addressForUrl}:$proxyPort" `
        -Credentials ($proxyUsername + ':' + $proxyPassword)
    Write-Host "Proxy public IP: $proxyPublicIp"

    # Single-quoted here-string preserves literal %ComputerName% tokens.
    [xml]$profile = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<ProxifierProfile version="102" platform="Windows" product_id="0" product_minver="400">
  <Options>
    <Resolve>
    	<AutoModeDetection enabled="false" />
    	<ViaProxy enabled="true" />
    	<BlockNonATypes enabled="true" />
      <ExclusionList OnlyFromListMode="false">%ComputerName%; localhost; *.local</ExclusionList>
      <DnsUdpMode>0</DnsUdpMode>
    </Resolve>
    <Encryption mode="disabled" />
    <ConnectionLoopDetection enabled="true" resolve="true" />
    <Udp mode="mode_block_all" />
    <LeakPreventionMode enabled="true" />
    <ProcessOtherUsers enabled="false" />
    <ProcessServices enabled="false" />
    <HandleDirectConnections enabled="false" />
    <HttpProxiesSupport enabled="false" />
  </Options>
  <ProxyList>
    <Proxy id="101" type="SOCKS5">
      <Authentication enabled="true">
        <Password />
        <Username />
      </Authentication>
      <Options>48</Options>
      <Port />
      <Address />
    </Proxy>
  </ProxyList>
  <ChainList />
  <RuleList>
    <Rule enabled="true">
      <Action type="Direct" />
      <Targets>localhost; 127.0.0.1; %ComputerName%; ::1</Targets>
      <Name>Localhost</Name>
    </Rule>
    <Rule enabled="true">
      <Action type="Proxy">101</Action>
      <Name>Default</Name>
    </Rule>
  </RuleList>
</ProxifierProfile>
'@
    # InnerText correctly escapes XML-sensitive characters in all input.
    $profile.SelectSingleNode('//Proxy/Authentication/Password').InnerText = $proxyPassword
    $profile.SelectSingleNode('//Proxy/Authentication/Username').InnerText = $proxyUsername
    $profile.SelectSingleNode('//Proxy/Port').InnerText = [string]$proxyPort
    $profile.SelectSingleNode('//Proxy/Address').InnerText = $parsedProxy.ToString()
    $profileDir = Join-Path $env:APPDATA 'Proxifier4\Profiles'
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    $profilePath = Join-Path $profileDir 'Default.ppx'
    if (Test-Path -LiteralPath $profilePath) {
        $backup = $profilePath + '.' + [Guid]::NewGuid().ToString('N') + '.bak'
        Copy-Item -LiteralPath $profilePath -Destination $backup
        Write-Host "Previous profile backed up to: $backup"
    }
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $settings.Encoding = New-Object System.Text.UTF8Encoding($false)
    $writer = [Xml.XmlWriter]::Create($profilePath, $settings)
    try { $profile.Save($writer) } finally { $writer.Dispose() }
    Write-Host "Profile saved: $profilePath"

    # Proxifier is a 32-bit application; explicitly use its registry view.
    $hive = [Microsoft.Win32.RegistryHive]::CurrentUser
    if ($SystemWideLicense) { $hive = [Microsoft.Win32.RegistryHive]::LocalMachine }
    $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry32)
    try {
        $license = $baseKey.CreateSubKey('Software\Initex\Proxifier\License')
        try {
            $license.SetValue('Key', 'DAZPH-G39D3-R4QY7-9PVAY-VQ6BU', [Microsoft.Win32.RegistryValueKind]::String)
            $license.SetValue('Owner', 'insid1ous', [Microsoft.Win32.RegistryValueKind]::String)
        } finally { $license.Dispose() }
    } finally { $baseKey.Dispose() }

    $installer = Join-Path ([IO.Path]::GetTempPath()) ('ProxifierSetup-' + [Guid]::NewGuid().ToString('N') + '.exe')
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host 'Downloading Proxifier...'
    Invoke-WebRequest -Uri 'https://www.proxifier.com/download/ProxifierSetup.exe' `
        -OutFile $installer -UseBasicParsing -TimeoutSec 120
    Write-Host 'Installing Proxifier...'
    $setup = Start-Process -FilePath $installer -ArgumentList '/SILENT', '/NORESTART' -Wait -PassThru
    if ($setup.ExitCode -ne 0) { throw "Installer returned exit code $($setup.ExitCode)." }

    $exe = 'C:\Program Files (x86)\Proxifier\Proxifier.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Proxifier executable not found: $exe" }
    Write-Host 'Starting Proxifier and loading Default.ppx...'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Start-Process -FilePath $exe -ArgumentList ('"' + $profilePath + '" silent-load') | Out-Null
    $matched = $false
    $lastResult = 'No successful IP response.'
    while ($timer.Elapsed.TotalSeconds -lt 180) {
        $remaining = 180 - $timer.Elapsed.TotalSeconds
        if ($remaining -lt 0.1) { break }
        try {
            $observedIp = Get-PublicIp -Timeout ([Math]::Min(10, $remaining))
            $lastResult = "Last observed IP: $observedIp"
            if ($observedIp -eq $proxyPublicIp -and $timer.Elapsed.TotalSeconds -le 180) {
                $matched = $true
                break
            }
            Write-Host "Current IP: $observedIp; waiting for $proxyPublicIp..."
        } catch {
            $lastResult = $_.Exception.Message
            Write-Host 'IP check failed; retrying...'
        }
        $remaining = 180 - $timer.Elapsed.TotalSeconds
        if ($remaining -gt 0) {
            Start-Sleep -Milliseconds ([int][Math]::Min(5000, $remaining * 1000))
        }
    }
    $timer.Stop()
    if (-not $matched) {
        $exitCode = 2
        throw "Aborted: normal requests did not return $proxyPublicIp within 3 minutes. $lastResult"
    }
    Write-Host "Success: normal requests now return $proxyPublicIp." -ForegroundColor Green


    $script:checkTimer = [Diagnostics.Stopwatch]::StartNew()
    $verified = $false
    $lastResult = 'No successful check.'
    Write-Host 'Waiting up to 3 minutes for whoer.to to report German public IP and DNS...'
    while ($script:checkTimer.Elapsed.TotalSeconds -lt 180) {
        try {
            $publicIp = Confirm-Ip (Get-CheckResponse ('https://whoer.to/ip?check=' + [Guid]::NewGuid().ToString('N')))
            $ipCountry = Get-WhoerCountry $publicIp
            # Fresh hostname triggers a DNS lookup, matching whoer.to/js/main.js.
            $dnsUri = 'https://' + [Guid]::NewGuid().ToString('N') + '.edns.ip-api.com/json?callback=dns'
            $dnsResult = ConvertFrom-Jsonp (Get-CheckResponse $dnsUri) 'dns'
            $dnsIp = Confirm-Ip ([string]$dnsResult.dns.ip)
            $dnsCountry = Get-WhoerCountry $dnsIp
            $lastResult = "Public IP: $publicIp ($ipCountry); DNS: $dnsIp ($dnsCountry)"
            Write-Host $lastResult
            if ($ipCountry -eq 'DE' -and $dnsCountry -eq 'DE' -and $script:checkTimer.Elapsed.TotalSeconds -lt 180) {
                $verified = $true
                break
            }
        } catch {
            $lastResult = $_.Exception.Message
            Write-Host "Check incomplete: $lastResult"
        }
        $remaining = 180 - $script:checkTimer.Elapsed.TotalSeconds
        if ($remaining -gt 0) {
            Write-Host ('Retrying... {0:N0} seconds left.' -f $remaining)
            Start-Sleep -Milliseconds ([int][Math]::Min(5000, $remaining * 1000))
        }
    }
    $script:checkTimer.Stop()
    if (-not $verified) {
        $exitCode = 2
        throw "Aborted: German public IP and DNS were not both confirmed within 3 minutes. $lastResult"
    }
    Write-Host 'German public IP and DNS confirmed. Installing Chrome...' -ForegroundColor Green

    # Download only after both country checks succeed.
    # Preserve the supplied installer tags, replacing iid with a fresh GUID.
    $chromeInstallId = [Guid]::NewGuid().ToString('B').ToUpperInvariant()
    $chromeTag = 'appguid={8A69D345-D564-463C-AFF1-A69D9E530F96}' +
        '&iid=' + $chromeInstallId +
        '&lang=de&browser=4&usagestats=0&appname=Google%20Chrome' +
        '&needsadmin=prefers&ap=-arch_x64-statsdef_1&installdataindex=empty'
    $chromeUrl = 'https://dl.google.com/tag/s/' + [Uri]::EscapeDataString($chromeTag) +
        '/update2/installers/ChromeSetup.exe'
    $chromeInstaller = Join-Path ([IO.Path]::GetTempPath()) `
        ('ChromeSetup-' + [Guid]::NewGuid().ToString('N') + '.exe')
    Write-Host "Downloading Chrome (installer ID: $chromeInstallId)..."
    Invoke-WebRequest -Uri $chromeUrl -OutFile $chromeInstaller -UseBasicParsing -TimeoutSec 600
    Write-Host 'Starting the normal Chrome installer; its installation window will show progress...'
    $chromeSetup = Start-Process -FilePath $chromeInstaller -Wait -PassThru
    if ($chromeSetup.ExitCode -ne 0) {
        throw "Chrome installer returned exit code $($chromeSetup.ExitCode)."
    }
    Write-Host 'Chrome installer completed successfully.' -ForegroundColor Green

    $exitCode = 0
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
} finally {
    $proxyPassword = $null
    if ($installer -and (Test-Path -LiteralPath $installer)) {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
    if ($chromeInstaller -and (Test-Path -LiteralPath $chromeInstaller)) {
        Remove-Item -LiteralPath $chromeInstaller -Force -ErrorAction SilentlyContinue
    }
}
Write-Host "Script finished with exit code $exitCode. Review the output above."
Read-Host 'Press Enter to exit' | Out-Null
exit $exitCode

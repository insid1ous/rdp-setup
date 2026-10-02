#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Run after Setup-Proxifier.ps1. Does not stop or reconfigure Proxifier.
Requires curl.exe. Uses ordinary connections intercepted by the existing proxy.
Checks the public IP and observed DNS resolver using whoer.to's live check flow:
https://whoer.to/ip -> /ip2co; random.edns.ip-api.com/json -> /ip2co.
Both must report DE in the same attempt within 180 seconds; otherwise no download.
This checks the resolver observed by that test, not every resolver or browser DoH.
These are website endpoints, not a guaranteed stable API. Unknown results fail closed.
Exit codes: 0 = installer completed; 1 = failure; 2 = country-check timeout.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'Continue'
$chromeInstaller = $null
$exitCode = 1

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
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
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
    if ($chromeInstaller -and (Test-Path -LiteralPath $chromeInstaller)) {
        Remove-Item -LiteralPath $chromeInstaller -Force -ErrorAction SilentlyContinue
    }
}
exit $exitCode

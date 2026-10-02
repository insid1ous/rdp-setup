#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Run as administrator under the Windows account that will use Proxifier.
Requires curl.exe (included with current Windows 10/11 installations).
The supplied profile stores the proxy password in plaintext, as requested.
Exit codes: 0 = completed; 1 = setup/validation failure; 2 = proxy timeout;
3 = proxy verified, but one or more Windows configuration steps incomplete.
Restart manually after completion to apply all language/locale settings.
Activation and German configuration run before proxy setup.
Run Install-Chrome.ps1 separately after proxy setup to validate German IP/DNS and install Chrome.
Language downloads require Windows Update connectivity.
Any running Proxifier.exe processes are forcibly stopped before Windows configuration.
On systems without Install-Language, optionally supply -GermanLanguagePackPath
with an official de-DE language-pack CAB matching the Windows build/architecture.
Use -SystemWideLicense to register in HKLM instead of HKCU.
A timeout does not uninstall or stop Proxifier or undo configuration.
#>
[CmdletBinding()]
param(
    [switch]$SystemWideLicense,
    [string]$GermanLanguagePackPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Show native progress for language installation, servicing, and downloads.
$ProgressPreference = 'Continue'
$exitCode = 1
$installer = $null
$proxyPassword = $null

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
    if ($curlExit -ne 0) { throw "IP request failed (curl exit code $curlExit)." }
    $value = ($response -join '').Trim()
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($value, [ref]$parsed)) {
        throw 'ipify did not return a valid IP address.'
    }
    $parsed.ToString()
}

try {
    Write-Host 'Stopping any running Proxifier.exe processes...'
    $proxifierProcesses = @(Get-Process -Name 'Proxifier' -ErrorAction SilentlyContinue)
    foreach ($process in $proxifierProcesses) {
        if (-not $process.HasExited) {
            Stop-Process -InputObject $process -Force -ErrorAction Stop
            if (-not $process.WaitForExit(10000)) {
                throw "Proxifier.exe (PID $($process.Id)) did not exit within 10 seconds."
            }
        }
    }
    if (Get-Process -Name 'Proxifier' -ErrorAction SilentlyContinue) {
        throw 'Proxifier.exe is still running or restarted. Aborting before Windows configuration.'
    }

    # Complete activation and language downloads before configuring/starting Proxifier.
    $configurationIssues = New-Object 'System.Collections.Generic.List[string]'
    function Invoke-ConfigurationStep {
        param([string]$Name, [scriptblock]$Action)
        Write-Host $Name
        try { & $Action } catch {
            $message = $Name + ': ' + $_.Exception.Message
            $configurationIssues.Add($message)
            Write-Warning $message
        }
    }

    $edition = $null
    try {
        Import-Module Dism -ErrorAction Stop
        $edition = (Get-WindowsEdition -Online -ErrorAction Stop).Edition
        Write-Host "Detected Windows edition: $edition"
    } catch {
        $configurationIssues.Add('Could not determine Windows edition: ' + $_.Exception.Message)
    }
    $editionKeys = @{
        Core                    = 'TX9XD-98N7V-6WMQ6-BX7FG-H8Q99'
        CoreN                   = '3KHY7-WNT83-DGQKR-F7HPR-844BM'
        CoreSingleLanguage      = '7HNRX-D7KGG-3K4RQ-4WPJ4-YTDFH'
        CoreCountrySpecific     = 'PVMJN-6DFY6-9CCP6-7BKTT-D3WVR'
        Professional            = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'
        ProfessionalN           = 'MH37W-N47XK-V7XM9-C7227-GCQG9'
        Education               = 'NW6C2-QMPVW-D7KKK-3GKT6-VCFB2'
        EducationN              = '2WH4N-8QGBV-H22JP-CT43Q-MDWWJ'
        Enterprise              = 'NPPR9-FWDCX-D2C8J-H872K-2YT43'
        EnterpriseN             = 'DPH2V-TTNVB-4X9Q3-TJR4H-KHJW4'
    }
    Invoke-ConfigurationStep 'Installing the edition-specific key and attempting Windows activation...' {
        if (-not $edition -or -not $editionKeys.ContainsKey($edition)) {
            throw "No supplied key matches edition '$edition'; Windows key left unchanged."
        }
        $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
        $slmgr = Join-Path $env:SystemRoot 'System32\slmgr.vbs'
        function Invoke-Slmgr {
            param([string[]]$SlmgrArguments)
            # Console host avoids modal Windows Script Host message boxes.
            $output = & $cscript //Nologo $slmgr @SlmgrArguments 2>&1
            $code = $LASTEXITCODE
            $output | ForEach-Object { Write-Host "$_" }
            # slmgr can print an HRESULT failure even when cscript exits with 0.
            if ($code -ne 0 -or (($output -join "`n") -match '(?i)0x[89a-f][0-9a-f]{7}')) {
                throw "slmgr $($SlmgrArguments[0]) failed; see output above."
            }
        }
        Invoke-Slmgr -SlmgrArguments @('/ipk', $editionKeys[$edition])
        if ($edition -in @('Core', 'CoreN', 'CoreSingleLanguage', 'CoreCountrySpecific')) {
            throw 'The supplied Home key was installed, but Home editions do not support KMS activation. KMS configuration and activation were skipped.'
        }
        Invoke-Slmgr -SlmgrArguments @('/skms', 'kms9.msguides.com')
        Invoke-Slmgr -SlmgrArguments @('/ato')
        # Confirm actual Windows licensing status instead of assuming command success.
        $partialKey = $editionKeys[$edition].Substring($editionKeys[$edition].Length - 5)
        $products = @(Get-CimInstance -ClassName SoftwareLicensingProduct `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" |
            Where-Object { $_.PartialProductKey -eq $partialKey -and $_.LicenseStatus -eq 1 })
        if ($products.Count -eq 0) {
            throw 'Activation was attempted, but Windows does not report the installed key as licensed.'
        }
        Write-Host 'Windows reports an activated license.' -ForegroundColor Green
    }

    Invoke-ConfigurationStep 'Installing German Windows display language...' {
        $muiPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\MUI\UILanguages\de-DE'
        if (-not (Test-Path $muiPath)) {
            if (-not $edition) { throw 'Edition detection failed; cannot check display-language restrictions.' }
            if ($edition -in @('CoreSingleLanguage', 'CoreCountrySpecific')) {
                throw 'This edition restricts display languages. A supported German installation or edition upgrade is required.'
            }
            if (Get-Command Install-Language -ErrorAction SilentlyContinue) {
                Install-Language -Language de-DE -CopyToSettings -Verbose -ErrorAction Stop | Out-Host
            } elseif ($GermanLanguagePackPath) {
                $cab = (Resolve-Path -LiteralPath $GermanLanguagePackPath -ErrorAction Stop).ProviderPath
                Add-WindowsPackage -Online -PackagePath $cab -NoRestart -Verbose -ErrorAction Stop | Out-Host
            } else {
                throw 'Install-Language is unavailable. Install the German display-language pack in Settings, or rerun with -GermanLanguagePackPath pointing to a matching official de-DE CAB.'
            }
        }
        if (-not (Test-Path $muiPath)) {
            throw 'German display resources are not registered yet. Restart if installation is pending, then rerun.'
        }
        Set-WinUILanguageOverride -Language de-DE
        if (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue) {
            Set-SystemPreferredUILanguage -Language de-DE
        }
    }

    Invoke-ConfigurationStep 'Setting German language preferences and QWERTZ keyboard...' {
        $languages = New-WinUserLanguageList -Language de-DE
        $languages[0].InputMethodTips.Clear()
        $languages[0].InputMethodTips.Add('0407:00000407')
        Set-WinUserLanguageList -LanguageList $languages -Force
        Set-WinDefaultInputMethodOverride -InputTip '0407:00000407'
    }
    Invoke-ConfigurationStep 'Setting Germany region and German regional formats...' {
        Set-WinHomeLocation -GeoId 94
        Set-Culture -CultureInfo de-DE
        # Explicit defaults also replace any pre-existing per-user custom formats.
        $international = 'HKCU:\Control Panel\International'
        $formats = @{
            sShortDate = 'dd.MM.yyyy'; sLongDate = 'dddd, d. MMMM yyyy'
            sShortTime = 'HH:mm'; sTimeFormat = 'HH:mm:ss'
            sDecimal = ','; sThousand = '.'; sList = ';'
            sCurrency = [string][char]0x20AC; sMonDecimalSep = ','; sMonThousandSep = '.'
            iCurrDigits = '2'; iCurrency = '3'; iNegCurr = '8'
            iMeasure = '0'; iFirstDayOfWeek = '0'; iFirstWeekOfYear = '2'; iTime = '1'
        }
        foreach ($entry in $formats.GetEnumerator()) {
            New-ItemProperty -Path $international -Name $entry.Key -Value $entry.Value `
                -PropertyType String -Force | Out-Null
        }
    }
    Invoke-ConfigurationStep 'Setting German system locale for non-Unicode applications...' {
        Set-WinSystemLocale -SystemLocale de-DE
    }
    Invoke-ConfigurationStep 'Setting Europe/Berlin time with automatic daylight-saving changes...' {
        # Windows ID corresponding to Europe/Berlin. No _dstoff suffix.
        & "$env:SystemRoot\System32\tzutil.exe" /s 'W. Europe Standard Time'
        if ($LASTEXITCODE -ne 0) { throw 'tzutil could not set the time zone.' }
        if ((Get-TimeZone).Id -ne 'W. Europe Standard Time') {
            throw 'Time-zone verification failed.'
        }
    }
    Invoke-ConfigurationStep 'Copying international settings to the welcome screen and new accounts...' {
        if (Get-Command Copy-UserInternationalSettingsToSystem -ErrorAction SilentlyContinue) {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
        } else {
            throw 'Automatic copy is unavailable on this Windows version. Use intl.cpl > Administrative > Copy settings to apply current settings to the welcome screen and new accounts.'
        }
    }
    Write-Host 'Restart Windows manually to finish applying language and locale changes.' -ForegroundColor Yellow

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
      <AutoModeDetection enabled="true" />
      <ViaProxy enabled="false" />
      <BlockNonATypes enabled="false" />
      <ExclusionList OnlyFromListMode="false">%ComputerName%; localhost; *.local</ExclusionList>
      <DnsUdpMode>0</DnsUdpMode>
    </Resolve>
    <Encryption mode="disabled" />
    <ConnectionLoopDetection enabled="true" resolve="true" />
    <Udp mode="mode_bypass" />
    <LeakPreventionMode enabled="false" />
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

    if ($configurationIssues.Count -gt 0) {
        Write-Warning ('Windows configuration is incomplete:' + "`n - " + ($configurationIssues -join "`n - "))
        $exitCode = 3
    } else {
        Write-Host 'Windows key and German configuration applied successfully.' -ForegroundColor Green
        $exitCode = 0
    }
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
} finally {
    $proxyPassword = $null
    if ($installer -and (Test-Path -LiteralPath $installer)) {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}
exit $exitCode

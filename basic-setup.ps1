#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
Run as administrator under the Windows account that will use Proxifier.
Exit codes: 0 = completed; 1 = setup failure;
3 = one or more Windows configuration steps incomplete.
Restart manually after completion to apply all language/locale settings.
Run install-chrome.ps1 separately after restarting to configure Proxifier,
validate German IP/DNS, and install Chrome.
Language downloads require Windows Update connectivity.
Any running Proxifier.exe processes are forcibly stopped before Windows configuration.
On systems without Install-Language, optionally supply -GermanLanguagePackPath
with an official de-DE language-pack CAB matching the Windows build/architecture.
#>
[CmdletBinding()]
param(
    [string]$GermanLanguagePackPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Show native progress for language installation, servicing, and downloads.
$ProgressPreference = 'Continue'
$exitCode = 1


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

    if ($configurationIssues.Count -gt 0) {
        Write-Warning ('Windows configuration is incomplete:' + "`n - " + ($configurationIssues -join "`n - "))
        $exitCode = 3
    } else {
        Write-Host 'Windows key and German configuration applied successfully.' -ForegroundColor Green
        $exitCode = 0
    }
} catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
}

Write-Host "Script finished with exit code $exitCode. Review the output above."
Read-Host 'Press Enter to exit, then restart the system' | Out-Null
exit $exitCode

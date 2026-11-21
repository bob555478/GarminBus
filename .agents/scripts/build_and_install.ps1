$ErrorActionPreference = "SilentlyContinue"

# Drain stdin JSON payload sent by Antigravity hook runner
try {
    $null = [Console]::In.ReadToEnd()
} catch {}

$popupTitle = "GarminBus Build & Install"
$popupMessage = ""
$popupIcon = 64 # 64 = Information, 48 = Warning, 16 = Error

try {
    # Works whether .agents is inside GaminBus\ or GaminBus\GarminBus\
    $candidateRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    if (Test-Path (Join-Path $candidateRoot "monkey.jungle")) {
        $appDir = $candidateRoot
        $projectRoot = Resolve-Path (Join-Path $candidateRoot "..")
    } else {
        $projectRoot = $candidateRoot
        $appDir = Join-Path $projectRoot "GarminBus"
    }

    $sdkRoot = Join-Path $env:APPDATA "Garmin\ConnectIQ\Sdks"
    $monkeyc = Get-ChildItem -Path $sdkRoot -Filter "monkeyc.bat" -Recurse | Select-Object -First 1 -ExpandProperty FullName

    if (-not $monkeyc) {
        $popupMessage = "Build Failed: Garmin Connect IQ SDK (monkeyc.bat) not found."
        $popupIcon = 16
    } else {
        $jungle = Join-Path $appDir "monkey.jungle"
        $outPrg = Join-Path $appDir "bin\GarminBus.prg"
        $devKey = Join-Path $projectRoot "developer_key"

        # 1. Build GarminBus.prg
        $buildOutput = & $monkeyc -d fr255m -f $jungle -o $outPrg -y $devKey -w 2>&1
        $buildExitCode = $LASTEXITCODE

        if ($buildExitCode -ne 0 -or -not (Test-Path $outPrg)) {
            $errText = ($buildOutput | Out-String).Trim()
            if ($errText.Length -gt 350) {
                $errText = $errText.Substring(0, 350) + "..."
            }
            $popupMessage = "Build FAILED (Exit Code $buildExitCode):`n`n$errText"
            $popupIcon = 16
        } else {
            # 2. Install to connected Forerunner 255 Music via MTP if plugged in
            $shell = New-Object -ComObject Shell.Application
            $myComp = $shell.NameSpace(17)
            $watch = $myComp.Items() | Where-Object { $_.Name -like "*Forerunner*" } | Select-Object -First 1

            if (-not $watch) {
                $popupMessage = "Build SUCCESSFUL!`n`nInstall Skipped: Forerunner 255 Music is not connected via USB."
                $popupIcon = 48
            } else {
                $storage = $watch.GetFolder.Items() | Where-Object { $_.Name -eq "Internal Storage" } | Select-Object -First 1
                $garmin = if ($storage) { $storage.GetFolder.Items() | Where-Object { $_.Name -eq "GARMIN" } | Select-Object -First 1 } else { $null }
                $apps = if ($garmin) { $garmin.GetFolder.Items() | Where-Object { $_.Name -eq "APPS" } | Select-Object -First 1 } else { $null }

                $binDir = Join-Path $appDir "bin"
                $binFolder = $shell.NameSpace($binDir)
                $prgItem = $binFolder.ParseName("GarminBus.prg")

                if ($garmin -and $prgItem) {
                    if ($apps) {
                        $apps.GetFolder.CopyHere($prgItem, 20)
                    }
                    $garmin.GetFolder.CopyHere($prgItem, 20)
                    Start-Sleep -Seconds 3

                    # Verify file is present on watch
                    $verified = $false
                    if ($apps) {
                        $found = $apps.GetFolder.Items() | Where-Object { $_.Name -eq "GarminBus.prg" } | Select-Object -First 1
                        if ($found) { $verified = $true }
                    }
                    if ($verified) {
                        $popupMessage = "Build & Install SUCCESSFUL!`n`nGarminBus.prg was compiled and verified in GARMIN\APPS on Forerunner 255 Music."
                        $popupIcon = 64
                    } else {
                        $popupMessage = "Build SUCCESSFUL, but Install Verification FAILED on Forerunner 255 Music."
                        $popupIcon = 16
                    }
                } else {
                    $popupMessage = "Build SUCCESSFUL, but could not access GARMIN folder on Forerunner 255 Music."
                    $popupIcon = 16
                }
            }
        }
    }
} catch {
    $popupMessage = "Build/Install Hook Error:`n$($_.Exception.Message)"
    $popupIcon = 16
}

# Launch a non-blocking Windows popup dialog so the user sees the result immediately without stalling the hook
if ($popupMessage) {
    try {
        $encodedMsg = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($popupMessage))
        $encodedTitle = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($popupTitle))
        $popupCmd = "`$m = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedMsg')); `$t = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$encodedTitle')); (New-Object -ComObject WScript.Shell).Popup(`$m, 10, `$t, $popupIcon + 4096) | Out-Null"
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $popupCmd
    } catch {}
}

# Output required Stop hook JSON decision so the agent finishes normally
[Console]::Out.WriteLine('{"decision":"allow"}')

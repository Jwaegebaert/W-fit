<#
.SYNOPSIS
  Tests and builds the watch app; with -Device also installs it.
.EXAMPLE
  ./watch/build.ps1
.EXAMPLE
  ./watch/build.ps1 -Device 192.168.1.50:41234
#>
param(
    # Serial of the watch as shown by "adb devices" (address:port for wireless debugging).
    [string]$Device
)
$ErrorActionPreference = 'Stop'

if (-not $env:JAVA_HOME) { $env:JAVA_HOME = 'C:\Program Files\Android\Android Studio\jbr' }
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }

& (Join-Path $PSScriptRoot 'gradlew.bat') -p $PSScriptRoot :app:testDebugUnitTest :app:assembleRelease
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
$apk = Join-Path $PSScriptRoot 'app\build\outputs\apk\release\app-release.apk'
Write-Host "Built $apk"

if ($Device) {
    $adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
    $kind = & $adb -s $Device shell getprop ro.build.characteristics
    # The phone app has the same id: installing this one on the phone would replace it.
    if ("$kind" -notmatch 'watch') { throw "$Device is not a watch (characteristics: $kind). Nothing installed." }
    & $adb -s $Device install -r $apk
    if ($LASTEXITCODE -ne 0) { throw 'Install failed.' }
}

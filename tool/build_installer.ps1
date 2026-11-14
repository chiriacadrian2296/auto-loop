# Builds the release and the installer: build\installer\AutoLoop-Setup-<version>.exe
# Needs Inno Setup 6 (winget install JRSoftware.InnoSetup).
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value

$iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 non trovato: winget install JRSoftware.InnoSetup' }

# A clean build: in release Flutter keeps only the icons in use, and an
# incremental build can reuse an old subset.
flutter clean | Out-Null
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'flutter build non riuscito' }

& $iscc "/DAppVersion=$version" installer\autoloop.iss
if ($LASTEXITCODE -ne 0) { throw 'ISCC non riuscito' }
Write-Host "Installer: build\installer\AutoLoop-Setup-$version.exe"

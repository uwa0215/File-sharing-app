$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$FlutterBin = "$env:LOCALAPPDATA\flutter\bin"
if (Test-Path $FlutterBin) {
  $env:Path = "$FlutterBin;" + $env:Path
}

$DistDir = Join-Path $Root "dist"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

Write-Host "=== Building DeviceBridge Windows USB Installer (.exe) ===" -ForegroundColor Cyan
Push-Location (Join-Path $Root "windows_host")
try {
  flutter pub get
  flutter analyze
  flutter test
  flutter build windows --release

  $IsccCandidates = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
  )
  $Iscc = $IsccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if (-not $Iscc) {
    throw "Inno Setup 6 (ISCC.exe) not found. Install JRSoftware.InnoSetup."
  }

  & $Iscc "installer\devicebridge.iss"
  $SetupExe = Get-ChildItem "build\installer\DeviceBridge-Windows-*.exe" | Select-Object -First 1
  if ($SetupExe) {
    $DestExe = Join-Path $DistDir $SetupExe.Name
    Copy-Item $SetupExe.FullName $DestExe -Force
    Write-Host "Created Windows Installer: $DestExe" -ForegroundColor Green
  }
} finally {
  Pop-Location
}

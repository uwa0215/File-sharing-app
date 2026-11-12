param(
  [switch]$WindowsOnly,
  [switch]$AndroidOnly
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$FlutterBin = "$env:LOCALAPPDATA\flutter\bin"
if (Test-Path $FlutterBin) {
  $env:Path = "$FlutterBin;" + $env:Path
}
$UserJdk = "$env:LOCALAPPDATA\Android\jdk-17"
if (-not $env:JAVA_HOME -and (Test-Path "$UserJdk\bin\java.exe")) {
  $env:JAVA_HOME = $UserJdk
  $env:Path = "$UserJdk\bin;" + $env:Path
}
$UserSdk = "$env:LOCALAPPDATA\Android\Sdk"
if (-not $env:ANDROID_HOME -and (Test-Path $UserSdk)) {
  $env:ANDROID_HOME = $UserSdk
  $env:ANDROID_SDK_ROOT = $UserSdk
}

$DistDir = Join-Path $Root "dist"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

if (-not $AndroidOnly) {
  Write-Host "=== Building Windows Host (.exe installer) ===" -ForegroundColor Cyan
  Push-Location (Join-Path $Root "windows_host")
  try {
    flutter pub get
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
      Copy-Item $SetupExe.FullName (Join-Path $DistDir $SetupExe.Name) -Force
      Write-Host "Created Windows Installer: $(Join-Path $DistDir $SetupExe.Name)" -ForegroundColor Green
    }
  } finally {
    Pop-Location
  }
}

if (-not $WindowsOnly) {
  Write-Host "=== Building Android Companion (.apk) ===" -ForegroundColor Cyan
  Push-Location (Join-Path $Root "mobile_companion")
  try {
    flutter pub get
    flutter build apk --release
    $Apk = Join-Path "build\app\outputs\flutter-apk" "app-release.apk"
    if (-not (Test-Path $Apk)) {
      throw "APK build output not found at $Apk"
    }
    $OutApk = Join-Path $DistDir "DeviceBridge-Android-1.0.0.apk"
    Copy-Item $Apk $OutApk -Force
    Write-Host "Created Android Installer: $OutApk" -ForegroundColor Green
  } finally {
    Pop-Location
  }
}


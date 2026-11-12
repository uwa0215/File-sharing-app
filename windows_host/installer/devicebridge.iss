; DeviceBridge Windows Native Installer Script (Inno Setup 6+)
; Build steps:
;   1. flutter build windows --release
;   2. iscc installer\devicebridge.iss

#define MyAppName "DeviceBridge"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "DeviceBridge"
#define MyAppExeName "windows_host.exe"
#define ReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{8D7C9E42-3A61-4E5B-9A2D-7F3E4B5A910C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=..\build\installer
OutputBaseFilename=DeviceBridge-Windows-{#MyAppVersion}-Setup
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequired=lowest

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; Core Flutter Windows runner, flutter_windows.dll, data/, and plugin DLLs
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent


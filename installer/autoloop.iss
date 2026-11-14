; Installer for AutoLoop (Inno Setup 6). Build it with tool\build_installer.ps1,
; which compiles the release first and passes the version from pubspec.yaml.
; The result is build\installer\AutoLoop-Setup-<version>.exe.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
; Never change the AppId: it is how Windows recognises updates of the same app.
AppId={{5C7E2A1B-9D3F-4C8E-A6B2-1F0D7E3C9A54}
AppName=AutoLoop
AppVersion={#AppVersion}
AppVerName=AutoLoop {#AppVersion}
AppPublisher=AutoLoop
DefaultDirName={autopf}\AutoLoop
DefaultGroupName=AutoLoop
DisableProgramGroupPage=yes
; Installs for the current user without admin rights; the dialog lets the user
; choose an install for everyone instead.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\build\installer
OutputBaseFilename=AutoLoop-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\AutoLoop.exe
UninstallDisplayName=AutoLoop
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "it"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; AutoLoop.exe needs its DLLs and the data folder next to it: the whole folder.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\AutoLoop"; Filename: "{app}\AutoLoop.exe"
Name: "{autodesktop}\AutoLoop"; Filename: "{app}\AutoLoop.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\AutoLoop.exe"; Description: "{cm:LaunchProgram,AutoLoop}"; Flags: nowait postinstall skipifsilent

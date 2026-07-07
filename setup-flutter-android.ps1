#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host $msg -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
}

function Add-ToMachinePathIfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$PathToAdd
    )

    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $parts = $current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    if ($parts -notcontains $PathToAdd) {
        $newPath = ($parts + $PathToAdd) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Host "Added to PATH: $PathToAdd" -ForegroundColor Green
    }
    else {
        Write-Host "Already in PATH: $PathToAdd" -ForegroundColor Yellow
    }
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Test-CommandExists {
    param(
        [Parameter(Mandatory = $true)][string]$Command
    )
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Write-Step "Installing $Name"
    winget install --id $Id -e --accept-package-agreements --accept-source-agreements --silent

    if ($LASTEXITCODE -ne 0) {
        Write-Host "winget install for $Name returned code $LASTEXITCODE" -ForegroundColor Yellow
    }
}

function Get-LatestFlutterWindowsStableZip {
    $jsonUrl = "https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json"
    $json = Invoke-RestMethod -Uri $jsonUrl
    $stableHash = $json.current_release.stable
    $release = $json.releases | Where-Object { $_.hash -eq $stableHash } | Select-Object -First 1

    if (-not $release) {
        throw "Could not determine latest stable Flutter release."
    }

    return "https://storage.googleapis.com/flutter_infra_release/releases/" + $release.archive
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

Write-Step "Checking winget"
if (-not (Test-CommandExists "winget")) {
    throw "winget is not installed. Install App Installer from Microsoft Store and retry."
}

$BaseDir            = Join-Path $env:USERPROFILE "dev"
$FlutterDir         = Join-Path $BaseDir "flutter"
$TempDir            = Join-Path $env:TEMP "flutter-android-setup"
$FlutterZip         = Join-Path $TempDir "flutter_windows_stable.zip"

$AndroidSdkRoot     = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$CmdlineToolsRoot   = Join-Path $AndroidSdkRoot "cmdline-tools"
$CmdlineToolsLatest = Join-Path $CmdlineToolsRoot "latest"
$AndroidZip         = Join-Path $TempDir "commandlinetools.zip"

$AndroidCmdlineToolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"

Write-Step "Creating directories"
Ensure-Directory -Path $BaseDir
Ensure-Directory -Path $TempDir
Ensure-Directory -Path $AndroidSdkRoot
Ensure-Directory -Path $CmdlineToolsRoot

Write-Step "Installing Git"
Install-WingetPackage -Id "Git.Git" -Name "Git"

Write-Step "Installing JDK 17"
Install-WingetPackage -Id "EclipseAdoptium.Temurin.17.JDK" -Name "Temurin JDK 17"

Refresh-SessionPath

Write-Step "Finding JAVA_HOME"
$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if (-not $javaCmd) {
    throw "java command not found after JDK install. Open a new admin PowerShell and rerun the script."
}

$javaExe = $javaCmd.Source
$javaBinDir = Split-Path $javaExe -Parent
$javaHome = Split-Path $javaBinDir -Parent

[Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
$env:JAVA_HOME = $javaHome
Write-Host "JAVA_HOME = $javaHome" -ForegroundColor Green

Add-ToMachinePathIfMissing -PathToAdd (Join-Path $javaHome "bin")
Refresh-SessionPath

Write-Step "Downloading latest stable Flutter SDK"
$flutterZipUrl = Get-LatestFlutterWindowsStableZip
Write-Host "Flutter URL: $flutterZipUrl" -ForegroundColor DarkGray
Invoke-WebRequest -Uri $flutterZipUrl -OutFile $FlutterZip

if (Test-Path $FlutterDir) {
    Write-Step "Removing existing Flutter directory"
    Remove-Item -Recurse -Force $FlutterDir
}

Write-Step "Extracting Flutter SDK"
Expand-Archive -Path $FlutterZip -DestinationPath $BaseDir -Force

Add-ToMachinePathIfMissing -PathToAdd (Join-Path $FlutterDir "bin")
Refresh-SessionPath

Write-Step "Downloading Android command-line tools"
Invoke-WebRequest -Uri $AndroidCmdlineToolsUrl -OutFile $AndroidZip

if (Test-Path $CmdlineToolsLatest) {
    Remove-Item -Recurse -Force $CmdlineToolsLatest
}
Ensure-Directory -Path $CmdlineToolsLatest

Write-Step "Extracting Android command-line tools"
Expand-Archive -Path $AndroidZip -DestinationPath $CmdlineToolsLatest -Force

# Fix nested archive structure:
# latest\cmdline-tools\bin  -> latest\bin
$NestedCmdlineTools = Join-Path $CmdlineToolsLatest "cmdline-tools"
if (Test-Path $NestedCmdlineTools) {
    Write-Step "Fixing Android cmdline-tools directory layout"
    Get-ChildItem -Path $NestedCmdlineTools -Force | ForEach-Object {
        Move-Item -Path $_.FullName -Destination $CmdlineToolsLatest -Force
    }
    Remove-Item -Recurse -Force $NestedCmdlineTools
}

[Environment]::SetEnvironmentVariable("ANDROID_HOME", $AndroidSdkRoot, "Machine")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $AndroidSdkRoot, "Machine")
$env:ANDROID_HOME = $AndroidSdkRoot
$env:ANDROID_SDK_ROOT = $AndroidSdkRoot

Add-ToMachinePathIfMissing -PathToAdd (Join-Path $AndroidSdkRoot "platform-tools")
Add-ToMachinePathIfMissing -PathToAdd (Join-Path $CmdlineToolsLatest "bin")
Refresh-SessionPath

Write-Step "Verifying required commands"
$flutterBat = Join-Path $FlutterDir "bin\flutter.bat"
$sdkManagerBat = Join-Path $CmdlineToolsLatest "bin\sdkmanager.bat"

if (-not (Test-Path $flutterBat)) {
    throw "flutter.bat not found at: $flutterBat"
}
if (-not (Test-Path $sdkManagerBat)) {
    throw "sdkmanager.bat not found at: $sdkManagerBat"
}

Write-Step "Accepting Android licenses"
$licenseYes = @"
y
y
y
y
y
y
y
y
y
y
"@

$licenseYes | & $sdkManagerBat --sdk_root=$AndroidSdkRoot --licenses

Write-Step "Installing Android SDK packages"
& $sdkManagerBat --sdk_root=$AndroidSdkRoot `
    "platform-tools" `
    "platforms;android-34" `
    "build-tools;34.0.0" `
    "cmdline-tools;latest"

Write-Step "Running flutter doctor"
& $flutterBat doctor

Write-Step "Setup finished"
Write-Host ""
Write-Host "Now close this PowerShell and open a new terminal." -ForegroundColor Green
Write-Host "Then run:" -ForegroundColor Green
Write-Host "  flutter doctor" -ForegroundColor White
Write-Host "  flutter create myapp" -ForegroundColor White
Write-Host "  cd myapp" -ForegroundColor White
Write-Host "  flutter build apk" -ForegroundColor White
Write-Host ""
Write-Host "APK output:" -ForegroundColor Green
Write-Host "  build\app\outputs\flutter-apk\app-release.apk" -ForegroundColor White

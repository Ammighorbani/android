#Requires -RunAsAdministrator
$ErrorActionPreference = "Stop"

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host $msg -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
}

function Test-CommandExists {
    param([Parameter(Mandatory = $true)][string]$Command)
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

function Refresh-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Add-ToMachinePathIfMissing {
    param([Parameter(Mandatory = $true)][string]$PathToAdd)

    $current = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($current)) { $current = "" }

    $parts = $current -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    if ($parts -notcontains $PathToAdd) {
        $newPath = (($parts + $PathToAdd) | Select-Object -Unique) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
        Write-Host "Added to PATH: $PathToAdd" -ForegroundColor Green
    } else {
        Write-Host "Already in PATH: $PathToAdd" -ForegroundColor Yellow
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Remove-FileIfExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path $Path) {
        Remove-Item -Force $Path
    }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$Retries = 3
    )

    Ensure-Directory -Path (Split-Path $OutFile -Parent)

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Host "Download attempt $i / $Retries" -ForegroundColor DarkCyan
            Remove-FileIfExists -Path $OutFile

            if (Test-CommandExists "curl.exe") {
                & curl.exe -L --fail --retry 5 --retry-delay 2 -o $OutFile $Url
                if ($LASTEXITCODE -ne 0) {
                    throw "curl.exe failed with exit code $LASTEXITCODE"
                }
            }
            elseif (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
                Start-BitsTransfer -Source $Url -Destination $OutFile
            }
            else {
                Invoke-WebRequest -Uri $Url -OutFile $OutFile
            }

            if (-not (Test-Path $OutFile)) {
                throw "Downloaded file not found: $OutFile"
            }

            $size = (Get-Item $OutFile).Length
            if ($size -lt 1024) {
                throw "Downloaded file is suspiciously small: $size bytes"
            }

            Write-Host "Downloaded successfully: $OutFile" -ForegroundColor Green
            return
        }
        catch {
            Write-Host "Download failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($i -eq $Retries) { throw }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name
    )

    Write-Step "Installing $Name"
    winget install --id $Id -e --accept-package-agreements --accept-source-agreements --silent
}

function Resolve-WorkingUrl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Candidates
    )

    foreach ($url in $Candidates) {
        try {
            Write-Host "Testing URL: $url" -ForegroundColor DarkGray

            if (Test-CommandExists "curl.exe") {
                & curl.exe -I -L --fail --silent --show-error $url | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Working URL found: $url" -ForegroundColor Green
                    return $url
                }
            } else {
                $resp = Invoke-WebRequest -Uri $url -Method Head -ErrorAction Stop
                if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                    Write-Host "Working URL found: $url" -ForegroundColor Green
                    return $url
                }
            }
        }
        catch {
            Write-Host "Not working: $url" -ForegroundColor Yellow
        }
    }

    throw "No working URL found."
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

function Get-LatestAndroidCmdlineToolsUrl {
    $metaUrl = "https://dl.google.com/android/repository/repository2-1.xml"
    [xml]$xml = Invoke-RestMethod -Uri $metaUrl

    $nodes = $xml.repository.remotePackage | Where-Object { $_.path -like "cmdline-tools;latest" }
    if (-not $nodes) {
        throw "Could not find cmdline-tools;latest in repository XML."
    }

    $archives = $nodes.license | Out-Null
    $package = $xml.repository.remotePackage | Where-Object { $_.path -eq "cmdline-tools;latest" } | Select-Object -First 1
    if (-not $package) {
        throw "Could not resolve Android cmdline-tools package."
    }

    # Fallback candidates if XML parsing is not enough
    $candidates = @(
        "https://dl.google.com/android/repository/commandlinetools-win-14742923_latest.zip",
        "https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip",
        "https://dl.google.com/android/repository/commandlinetools-win-12996373_latest.zip",
        "https://dl.google.com/android/repository/commandlinetools-win-12700392_latest.zip",
        "https://dl.google.com/android/repository/commandlinetools-win-12266719_latest.zip",
        "https://dl.google.com/android/repository/commandlinetools-win-14742923_latest.zip"
    )
    return Resolve-WorkingUrl -Candidates $candidates
}

Write-Step "Checking winget"
if (-not (Test-CommandExists "winget")) {
    throw "winget is not installed. Install App Installer from Microsoft Store and retry."
}

$BaseDir          = Join-Path $env:USERPROFILE "dev"
$FlutterDir       = Join-Path $BaseDir "flutter"
$TempDir          = Join-Path $env:TEMP "flutter-android-setup"
$FlutterZip       = Join-Path $TempDir "flutter_windows_stable.zip"
$AndroidSdkRoot   = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$CmdToolsRoot     = Join-Path $AndroidSdkRoot "cmdline-tools"
$CmdToolsLatest   = Join-Path $CmdToolsRoot "latest"
$AndroidZip       = Join-Path $TempDir "commandlinetools.zip"

Ensure-Directory -Path $BaseDir
Ensure-Directory -Path $TempDir
Ensure-Directory -Path $AndroidSdkRoot
Ensure-Directory -Path $CmdToolsRoot

Write-Step "Installing Git"
Install-WingetPackage -Id "Git.Git" -Name "Git"

Write-Step "Installing JDK 17"
Install-WingetPackage -Id "EclipseAdoptium.Temurin.17.JDK" -Name "Temurin JDK 17"

Refresh-SessionPath

Write-Step "Finding JAVA_HOME"
$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if (-not $javaCmd) {
    throw "java command not found after JDK install. Open a new terminal and rerun."
}
$javaExe = $javaCmd.Source
$javaBinDir = Split-Path $javaExe -Parent
$javaHome = Split-Path $javaBinDir -Parent

[Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
$env:JAVA_HOME = $javaHome
Add-ToMachinePathIfMissing -PathToAdd (Join-Path $javaHome "bin")
Refresh-SessionPath

Write-Step "Downloading Flutter SDK"
$flutterZipUrl = Get-LatestFlutterWindowsStableZip
Write-Host "Flutter URL: $flutterZipUrl" -ForegroundColor DarkGray
Download-File -Url $flutterZipUrl -OutFile $FlutterZip -Retries 3

if (Test-Path $FlutterDir) {
    Write-Step "Removing old Flutter directory"
    Remove-Item -Recurse -Force $FlutterDir
}

Write-Step "Extracting Flutter SDK"
Expand-Archive -Path $FlutterZip -DestinationPath $BaseDir -Force

Add-ToMachinePathIfMissing -PathToAdd (Join-Path $FlutterDir "bin")
Refresh-SessionPath

Write-Step "Resolving Android command-line tools URL"
$androidCmdlineUrl = Get-LatestAndroidCmdlineToolsUrl
Write-Host "Android CLI URL: $androidCmdlineUrl" -ForegroundColor DarkGray

Write-Step "Downloading Android command-line tools"
Download-File -Url $androidCmdlineUrl -OutFile $AndroidZip -Retries 3

if (Test-Path $CmdToolsLatest) {
    Remove-Item -Recurse -Force $CmdToolsLatest
}
Ensure-Directory -Path $CmdToolsLatest

Write-Step "Extracting Android command-line tools"
Expand-Archive -Path $AndroidZip -DestinationPath $CmdToolsLatest -Force

# Fix nested cmdline-tools directory layout if needed
$Nested = Join-Path $CmdToolsLatest "cmdline-tools"
if (Test-Path $Nested) {
    Get-ChildItem -Path $Nested -Force | ForEach-Object {
        Move-Item -Path $_.FullName -Destination $CmdToolsLatest -Force
    }
    Remove-Item -Recurse -Force $Nested
}

[Environment]::SetEnvironmentVariable("ANDROID_HOME", $AndroidSdkRoot, "Machine")
[Environment]::SetEnvironmentVariable("ANDROID_SDK_ROOT", $AndroidSdkRoot, "Machine")
$env:ANDROID_HOME = $AndroidSdkRoot
$env:ANDROID_SDK_ROOT = $AndroidSdkRoot

Add-ToMachinePathIfMissing -PathToAdd (Join-Path $AndroidSdkRoot "platform-tools")
Add-ToMachinePathIfMissing -PathToAdd (Join-Path $CmdToolsLatest "bin")
Refresh-SessionPath

Write-Step "Verifying sdkmanager"
$sdkManagerBat = Join-Path $CmdToolsLatest "bin\sdkmanager.bat"
if (-not (Test-Path $sdkManagerBat)) {
    throw "sdkmanager.bat not found at $sdkManagerBat"
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
$flutterBat = Join-Path $FlutterDir "bin\flutter.bat"
& $flutterBat doctor

Write-Step "Done"
Write-Host "Close this terminal and open a new one, then run:" -ForegroundColor Green
Write-Host "  flutter doctor" -ForegroundColor White
Write-Host "  flutter create myapp" -ForegroundColor White
Write-Host "  cd myapp" -ForegroundColor White
Write-Host "  flutter build apk" -ForegroundColor White

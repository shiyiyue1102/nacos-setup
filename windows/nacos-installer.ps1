# Nacos Setup Installer for Windows (PowerShell)
# This script installs nacos-cli and prepares nacos-setup for WSL2.

$ErrorActionPreference = "Stop"

# =============================
# Configuration
# =============================
$DownloadBaseUrl = "https://download.nacos.io"
$WindowsSetupZipBase = "https://download.nacos.io"
$NacosCliVersion = if ($env:NACOS_CLI_VERSION) { $env:NACOS_CLI_VERSION } else { "0.0.1" }
$NacosSetupVersion = if ($env:NACOS_SETUP_VERSION) { $env:NACOS_SETUP_VERSION } else { "0.0.2" }
$CacheDir = Join-Path $env:USERPROFILE ".nacos\cache"
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\nacos-cli"
$BinName = "nacos-cli.exe"
$SetupInstallDir = Join-Path $env:LOCALAPPDATA "Programs\nacos-setup"
$SetupScriptName = "nacos-setup.ps1"
$SetupCmdName = "nacos-setup.cmd"

# =============================
# Helpers
# =============================
function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Success($msg) { Write-Host "[SUCCESS] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-ErrorMsg($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Ensure-Directory($path) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null }
}

function Add-ToUserPath($dir) {
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($current -and $current.Split(';') -contains $dir) { return }
    $newPath = if ($current) { "$current;$dir" } else { $dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
}

function Download-File($url, $output) {
    Write-Info "Downloading from $url"
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output
    } else {
        Invoke-WebRequest -Uri $url -OutFile $output
    }
}

# =============================
# Main
# =============================
Write-Host ""
Write-Host "========================================"
Write-Host "  Nacos Installer (Windows)"
Write-Host "========================================"
Write-Host ""

Write-Info "Preparing to install nacos-cli version $NacosCliVersion..."

Ensure-Directory $CacheDir
Ensure-Directory $InstallDir
Ensure-Directory $SetupInstallDir

$os = "windows"
$arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$zipName = "nacos-cli-$NacosCliVersion-$os-$arch.zip"
$zipPath = Join-Path $CacheDir $zipName
$downloadUrl = "$DownloadBaseUrl/$zipName"

if (-not (Test-Path $zipPath) -or (Get-Item $zipPath).Length -eq 0) {
    Download-File $downloadUrl $zipPath
} else {
    Write-Info "Found cached package: $zipPath"
}

Write-Info "Extracting nacos-cli..."
$extractDir = Join-Path $env:TEMP ("nacos-cli-extract-" + [Guid]::NewGuid().ToString())
Ensure-Directory $extractDir
Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

$expected = "nacos-cli-$NacosCliVersion-$os-$arch.exe"
$binaryPath = Get-ChildItem -Path $extractDir -Recurse -Filter $expected | Select-Object -First 1
if (-not $binaryPath) {
    Write-ErrorMsg "Binary file not found in package. Expected: $expected"
    Write-Info "Available files in package:"
    Get-ChildItem -Path $extractDir -Recurse | ForEach-Object { "  $($_.FullName)" }
    exit 1
}

Copy-Item -Path $binaryPath.FullName -Destination (Join-Path $InstallDir $BinName) -Force

Add-ToUserPath $InstallDir

Remove-Item -Recurse -Force $extractDir

Write-Success "nacos-cli $NacosCliVersion installed to $InstallDir\\$BinName"

Write-Info "Preparing nacos-setup (WSL2 required)..."

$setupZipName = "nacos-setup-$NacosSetupVersion.zip"
$setupZipPath = Join-Path $CacheDir $setupZipName
$setupZipUrl = "$WindowsSetupZipBase/$setupZipName"

if (-not (Test-Path $setupZipPath) -or (Get-Item $setupZipPath).Length -eq 0) {
    Download-File $setupZipUrl $setupZipPath
} else {
    Write-Info "Found cached package: $setupZipPath"
}

Write-Info "Extracting nacos-setup windows scripts..."
$extractDir = Join-Path $env:TEMP ("nacos-setup-windows-extract-" + [Guid]::NewGuid().ToString())
Ensure-Directory $extractDir
Expand-Archive -Path $setupZipPath -DestinationPath $extractDir -Force

$windowsDir = Get-ChildItem -Path $extractDir -Directory -Recurse | Where-Object { $_.Name -eq "windows" } | Select-Object -First 1
if (-not $windowsDir) {
    Write-ErrorMsg "windows directory not found in $setupZipName"
    exit 1
}

Copy-Item -Path (Join-Path $windowsDir.FullName "*") -Destination $SetupInstallDir -Recurse -Force

$setupScriptPath = Join-Path $SetupInstallDir $SetupScriptName
if (-not (Test-Path $setupScriptPath)) {
    Write-ErrorMsg "nacos-setup.ps1 not found after extraction"
    exit 1
}

# Normalize quotes to avoid PowerShell parsing issues on some systems
$content = Get-Content -Path $setupScriptPath -Raw
$content = $content -replace "[\u2018\u2019]", "'"
$content = $content -replace "[\u201C\u201D]", '"'
Set-Content -Path $setupScriptPath -Value $content -Encoding UTF8
Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue

$setupCmdPath = Join-Path $SetupInstallDir $SetupCmdName
@"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0$SetupScriptName" %*
"@ | Set-Content -Path $setupCmdPath -Encoding ASCII

Add-ToUserPath $SetupInstallDir

Write-Success "nacos-setup installed to $SetupInstallDir\\$SetupScriptName"
Write-Info "You can now run: nacos-setup --help"
Write-Info "Please reopen your terminal to load updated PATH."

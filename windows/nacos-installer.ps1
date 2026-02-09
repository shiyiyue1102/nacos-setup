# Nacos Setup Installer for Windows (PowerShell)
# This script installs nacos-cli and prepares nacos-setup for WSL2.

$ErrorActionPreference = "Stop"

# =============================
# Helpers (Define early for use in initialization)
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
    if ($current -and $current.Split(';') -contains $dir) { 
        Write-Info "PATH already contains: $dir"
        return 
    }
    $newPath = if ($current) { "$current;$dir" } else { $dir }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    Write-Success "Added to PATH: $dir"
}

function Refresh-SessionPath() {
    # Refresh PATH in current session by combining Machine and User paths
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
    Write-Info "PATH refreshed in current session"
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
# Check Admin and Get Real User
# =============================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Get the actual user directory even when running as admin
$realUserProfile = $env:USERPROFILE

# If running as admin and USERPROFILE points to SYSTEM, try to find real user
if ($isAdmin -and ($env:USERPROFILE -match 'systemprofile|system32')) {
    try {
        # Try to get the logged-in user from Win32_ComputerSystem
        $computerSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($computerSystem -and $computerSystem.UserName) {
            $userName = $computerSystem.UserName
            # Extract just the username if it's in DOMAIN\USER format
            if ($userName -match '\\(.+)$') {
                $userName = $matches[1]
            }
            # Verify the user directory exists
            $userDir = "C:\Users\$userName"
            if (Test-Path $userDir) {
                $realUserProfile = $userDir
            }
        }
    } catch {
        # If WMI fails, try alternative methods
    }
    
    # If still not found, try to find from environment or registry
    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            # Try LOGONSERVER environment variable (works in some scenarios)
            if ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') {
                $userDir = "C:\Users\$env:USERNAME"
                if (Test-Path $userDir) {
                    $realUserProfile = $userDir
                }
            }
        } catch {
        }
    }
    
    # Last resort: scan for most recently modified user profile
    if ($realUserProfile -match 'systemprofile|system32') {
        try {
            $profiles = @(Get-ChildItem "C:\Users" -Directory -ErrorAction SilentlyContinue | 
                Where-Object { 
                    $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') -and
                    (Test-Path (Join-Path $_.FullName 'AppData'))
                } | Sort-Object LastWriteTime -Descending)
            
            if ($profiles.Count -gt 0) {
                $realUserProfile = $profiles[0].FullName
            }
        } catch {
        }
    }
    
    # Final check: if still couldn't determine, use a reasonable fallback
    if ($realUserProfile -match 'systemprofile|system32') {
        Write-Warn "Could not detect real user, using default install location"
        $realUserProfile = "C:\Users\Administrator"
    }
}

# Get real LocalAppData
$realLocalAppData = Join-Path $realUserProfile "AppData\Local"

# =============================
# Configuration
# =============================
$DownloadBaseUrl = "https://download.nacos.io"
$WindowsSetupZipBase = "https://download.nacos.io"
$NacosCliVersion = if ($env:NACOS_CLI_VERSION) { $env:NACOS_CLI_VERSION } else { "0.0.1" }
$NacosSetupVersion = if ($env:NACOS_SETUP_VERSION) { $env:NACOS_SETUP_VERSION } else { "0.0.1" }
$CacheDir = Join-Path $realUserProfile ".nacos\cache"
$InstallDir = Join-Path $realLocalAppData "Programs\nacos-cli"
$BinName = "nacos-cli.exe"
$SetupInstallDir = Join-Path $realLocalAppData "Programs\nacos-setup"
$SetupScriptName = "nacos-setup.ps1"
$SetupCmdName = "nacos-setup.cmd"

# =============================
# Main
# =============================
Write-Host ""
Write-Host "========================================"
Write-Host "  Nacos Installer (Windows)"
Write-Host "========================================"
Write-Host ""

if ($isAdmin) {
    Write-Warn "Running as Administrator detected"
    Write-Info "Installing to user directory: $realUserProfile"
}

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
Write-Host ""

Write-Info "Preparing nacos-setup (WSL2 required)..."

$setupZipName = "nacos-setup-windows-$NacosSetupVersion.zip"
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

# The zip contains nacos-setup-windows-VERSION directory with all files directly inside
$setupDir = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
if (-not $setupDir) {
    Write-ErrorMsg "Failed to find extracted directory in $setupZipName"
    exit 1
}

# Verify required files exist
$setupScriptInZip = Join-Path $setupDir.FullName $SetupScriptName
if (-not (Test-Path $setupScriptInZip)) {
    Write-ErrorMsg "$SetupScriptName not found in package"
    exit 1
}

Copy-Item -Path (Join-Path $setupDir.FullName "*") -Destination $SetupInstallDir -Recurse -Force

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
# Refresh PATH in current session to make commands available immediately
Refresh-SessionPath

Write-Host ""
Write-Success "nacos-setup installed to $SetupInstallDir\\$SetupScriptName"
Write-Host ""
Write-Info "Installation Summary:"
Write-Info "  nacos-cli: $InstallDir\\$BinName"
Write-Info "  nacos-setup: $SetupInstallDir\\$SetupCmdName"
Write-Host ""
Write-Success "Installation complete! You can now use the commands:"
Write-Info "  nacos-cli --help"
Write-Info "  nacos-setup --help"
Write-Host ""

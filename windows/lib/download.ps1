# Download management for Windows nacos-setup
. $PSScriptRoot\common.ps1

$Global:CacheDir = if ($env:NACOS_CACHE_DIR) { $env:NACOS_CACHE_DIR } else { Join-Path $env:USERPROFILE ".nacos\cache" }
$Global:DownloadBaseUrl = "https://download.nacos.io/nacos-server"
$Global:RefererUrl = "https://nacos.io/download/nacos-server/"

function Download-File($url, $output) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $output
    } else {
        Invoke-WebRequest -Uri $url -OutFile $output
    }
}

function Download-Nacos($version) {
    Ensure-Directory $Global:CacheDir
    $zipName = "nacos-server-$version.zip"
    $downloadUrl = "$Global:DownloadBaseUrl/$zipName?spm=nacos_install&file=$zipName"
    $cached = Join-Path $Global:CacheDir $zipName

    if (Test-Path $cached -PathType Leaf -and (Get-Item $cached).Length -gt 0) {
        Write-Info "Found cached package: $cached"
        return $cached
    }

    Write-Info "Downloading Nacos version: $version"
    Download-File $downloadUrl $cached
    return $cached
}

function Extract-NacosToTemp($zipFile) {
    if (-not (Test-Path $zipFile)) { throw "Zip file not found: $zipFile" }
    $tmpDir = Join-Path $env:TEMP ("nacos-extract-" + [Guid]::NewGuid().ToString())
    Ensure-Directory $tmpDir
    Expand-Archive -Path $zipFile -DestinationPath $tmpDir -Force
    $extracted = Get-ChildItem -Path $tmpDir -Directory | Where-Object { $_.Name -eq "nacos" } | Select-Object -First 1
    if (-not $extracted) { throw "Could not find extracted nacos directory" }
    return $extracted.FullName
}

function Install-Nacos($sourceDir, $targetDir) {
    if (-not (Test-Path $sourceDir)) { throw "Source directory not found: $sourceDir" }
    if (Test-Path $targetDir) { Remove-Item -Recurse -Force $targetDir }
    Ensure-Directory (Split-Path $targetDir -Parent)
    Move-Item -Path $sourceDir -Destination $targetDir
    if (-not (Test-Path (Join-Path $targetDir "conf\application.properties"))) {
        throw "Installation verification failed: missing configuration"
    }
    return $true
}

function Cleanup-TempDir($dir) {
    if ($dir -and (Test-Path $dir)) { Remove-Item -Recurse -Force $dir }
}

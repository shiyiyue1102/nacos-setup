# Java management for Windows nacos-setup
. $PSScriptRoot\common.ps1

function Write-DebugLog($msg) {
    if ($env:NACOS_DEBUG -eq "1") { Write-Info "[DEBUG] $msg" }
}

function Get-JavaVersion($javaCmd) {
    if (-not $javaCmd) { return 0 }

    $resolvedCmd = $javaCmd
    if (Test-Path $resolvedCmd) {
        $resolvedCmd = (Resolve-Path $resolvedCmd).Path
    } else {
        $cmdInfo = Get-Command $resolvedCmd -ErrorAction SilentlyContinue
        if ($cmdInfo -and $cmdInfo.Source) { $resolvedCmd = $cmdInfo.Source }
    }

    Write-DebugLog "Java command resolved to: $resolvedCmd"

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    try {
        $outputText = (& cmd /c "`"$resolvedCmd`" -version 2>&1" | Out-String)
        $firstLine = ($outputText -split "`r?`n" | Select-Object -First 1)
        if ($firstLine) { Write-DebugLog "java -version: $firstLine" }

        if ($outputText -match 'version\s+"([0-9]+)') { return [int]$Matches[1] }
        if ($outputText -match 'version\s+"1\.([0-9]+)') { return [int]$Matches[1] }
        if ($outputText -match '"([0-9]+)\.[0-9]+') { return [int]$Matches[1] }

        $settingsText = (& cmd /c "`"$resolvedCmd`" -XshowSettings:properties -version 2>&1" | Out-String)
        $settingsLine = ($settingsText -split "`r?`n" | Where-Object { $_ -match '^\s*java\.version\s*=' } | Select-Object -First 1)
        if ($settingsLine) { Write-DebugLog "java.version: $settingsLine" }
        if ($settingsText -match '(?m)^\s*java\.version\s*=\s*([0-9]+)') { return [int]$Matches[1] }
        if ($settingsText -match '(?m)^\s*java\.version\s*=\s*1\.([0-9]+)') { return [int]$Matches[1] }
        if ($settingsText -match '(?m)^\s*java\.version\s*=\s*([0-9]+)\.[0-9]+') { return [int]$Matches[1] }
    } catch {
        Write-DebugLog "Get-JavaVersion error: $($_.Exception.Message)"
    } finally {
        $ErrorActionPreference = $oldEap
    }

    try {
        $fileVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($resolvedCmd).FileVersion
        if ($fileVersion) { Write-DebugLog "java.exe file version: $fileVersion" }
        if ($fileVersion -and $fileVersion -match '^([0-9]+)\.') { return [int]$Matches[1] }
    } catch {}
    return 0
}

function Find-JavaInPath {
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java -is [System.Array]) { $java = $java | Select-Object -First 1 }
    if ($java) {
        if ($java.Source) { return $java.Source }
        if ($java.Path) { return $java.Path }
    }
    return $null
}

function Check-JavaRequirements($nacosVersion, $advancedMode) {
    $required = 8
    if ($nacosVersion) {
        $major = [int]($nacosVersion.Split('.')[0])
        if ($major -ge 3) {
            $required = 17
            Write-Info "Nacos $nacosVersion requires Java 17 or later"
        }
    }

    $javaCmd = $null
    $javaVersion = 0

    if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        $javaCmd = Join-Path $env:JAVA_HOME "bin\java.exe"
        $javaVersion = Get-JavaVersion $javaCmd
        Write-Info "Found Java from JAVA_HOME: $env:JAVA_HOME (version: $javaVersion)"
        if ($javaVersion -lt $required) { $javaCmd = $null }
    }

    if (-not $javaCmd) {
        $javaCmd = Find-JavaInPath
        if ($javaCmd) {
            $javaVersion = Get-JavaVersion $javaCmd
            Write-Info "Found Java in PATH (version: $javaVersion)"
            if ($javaVersion -lt $required) { $javaCmd = $null }
        }
    }

    if (-not $javaCmd) {
        Write-ErrorMsg "Java not found or version too old. Please install Java $required+"
        return $false
    }

    if ($javaVersion -lt 8) {
        Write-ErrorMsg "Java version must be 8 or later (found: $javaVersion)"
        return $false
    }

    Write-Info "Java version: $javaVersion - OK"
    return $true
}

function Get-JavaRuntimeOptions {
    try {
        $javaCmd = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\java.exe" } else { "java" }
        $output = & $javaCmd -version 2>&1 | Select-Object -First 1
        if ($output -match 'version "([0-9]+)') {
            $major = [int]$Matches[1]
            if ($major -ge 9) {
                return "--add-opens java.base/java.io=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED --add-opens java.base/java.util.concurrent=ALL-UNNAMED --add-opens java.base/sun.net.util=ALL-UNNAMED"
            }
        }
    } catch {}
    return ""
}

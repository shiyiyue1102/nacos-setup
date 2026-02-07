# Java management for Windows nacos-setup
. $PSScriptRoot\common.ps1

function Get-JavaVersion($javaCmd) {
    try {
        $output = & $javaCmd -version 2>&1 | Select-Object -First 1
        if ($output -match 'version "([0-9]+)') { return [int]$Matches[1] }
        if ($output -match 'version "1\.([0-9]+)') { return [int]$Matches[1] }
    } catch {}
    return 0
}

function Find-JavaInPath {
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java) { return $java.Path }
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

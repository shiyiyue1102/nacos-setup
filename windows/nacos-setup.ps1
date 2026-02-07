# Nacos Setup for Windows (PowerShell)
# Native PowerShell implementation (no WSL required)

$ErrorActionPreference = "Stop"

# =============================
# Configuration
# =============================
$NacosSetupVersion = "0.0.1"

# =============================
# Helpers
# =============================
. $PSScriptRoot\lib\common.ps1
. $PSScriptRoot\lib\download.ps1
. $PSScriptRoot\lib\port_manager.ps1
. $PSScriptRoot\lib\config_manager.ps1
. $PSScriptRoot\lib\java_manager.ps1
. $PSScriptRoot\lib\process_manager.ps1

# =============================
# Main
# =============================
Write-Host ""
Write-Host "========================================"
Write-Host "  Nacos Setup (Windows Native)"
Write-Host "========================================"
Write-Host ""

# =============================
# Defaults
# =============================
$DefaultVersion = "3.1.1"
$DefaultInstallDir = Join-Path $env:USERPROFILE "ai-infra\nacos"
$DefaultMode = "standalone"
$DefaultPort = 8848
$DefaultReplicaCount = 3
$MinimumVersion = "2.4.0"

$Mode = $DefaultMode
$Version = $DefaultVersion
$AutoStart = $true
$AdvancedMode = $false
$DetachMode = $false
$InstallDir = ""
$Port = $DefaultPort
$AllowKill = $false

$ClusterId = ""
$ReplicaCount = $DefaultReplicaCount
$ClusterBaseDir = Join-Path $DefaultInstallDir "cluster"
$BasePort = $DefaultPort
$CleanMode = $false
$JoinMode = $false
$LeaveMode = $false
$NodeIndex = ""

$DatasourceConfMode = $false
$Global:StartedPids = @()

function Print-Usage {
    Write-Host "Nacos Setup - Windows Native"
    Write-Host "Usage: nacos-setup [OPTIONS]"
}

function Parse-Arguments($argv) {
    $argsList = @()
    foreach ($arg in $argv) {
        switch ($arg) {
            "--adv" { $Global:AdvancedMode = $true }
            "--detach" { $Global:DetachMode = $true }
            "--clean" { $Global:CleanMode = $true }
            "--join" { $Global:JoinMode = $true }
            "--no-start" { $Global:AutoStart = $false }
            "--kill" { $Global:AllowKill = $true }
            "--datasource-conf" { $Global:DatasourceConfMode = $true }
            default { $argsList += $arg }
        }
    }

    for ($i=0; $i -lt $argsList.Count; $i++) {
        $a = $argsList[$i]
        switch ($a) {
            "-v" { $Global:Version = $argsList[$i+1]; $i++ }
            "--version" { $Global:Version = $argsList[$i+1]; $i++ }
            "-p" { $Global:Port = [int]$argsList[$i+1]; $Global:BasePort = $Global:Port; $i++ }
            "--port" { $Global:Port = [int]$argsList[$i+1]; $Global:BasePort = $Global:Port; $i++ }
            "-d" { $Global:InstallDir = $argsList[$i+1]; $i++ }
            "--dir" { $Global:InstallDir = $argsList[$i+1]; $i++ }
            "-c" { $Global:Mode = "cluster"; $Global:ClusterId = $argsList[$i+1]; $i++ }
            "--cluster" { $Global:Mode = "cluster"; $Global:ClusterId = $argsList[$i+1]; $i++ }
            "-n" { $Global:ReplicaCount = [int]$argsList[$i+1]; $i++ }
            "--nodes" { $Global:ReplicaCount = [int]$argsList[$i+1]; $i++ }
            "--leave" { $Global:LeaveMode = $true; $Global:NodeIndex = $argsList[$i+1]; $i++ }
            "-h" { Print-Usage; exit 0 }
            "--help" { Print-Usage; exit 0 }
            default { Write-ErrorMsg "Unknown option: $a"; exit 1 }
        }
    }
}

function Validate-Arguments {
    if (-not (Version-Ge $Global:Version $MinimumVersion)) {
        Write-ErrorMsg "Nacos version $Global:Version is not supported"
        exit 1
    }
    if ($Global:Mode -eq "cluster") {
        if (-not $Global:ClusterId -and -not $Global:LeaveMode) {
            Write-ErrorMsg "Cluster ID is required"
            exit 1
        }
    }
}

function Get-NodeMainPort($nodeDir, $version) {
    $configFile = Join-Path $nodeDir "conf\application.properties"
    if (-not (Test-Path $configFile)) { return $null }
    $major = [int]($version.Split('.')[0])
    $key = if ($major -ge 3) { "nacos.server.main.port" } else { "server.port" }
    $line = Get-Content -Path $configFile | Where-Object { $_ -match "^$key=" } | Select-Object -First 1
    if ($line -and $line -match "^$key=(.*)$") { return [int]$Matches[1] }
    return $null
}

function Get-NodeConsolePort($nodeDir) {
    $configFile = Join-Path $nodeDir "conf\application.properties"
    if (-not (Test-Path $configFile)) { return $null }
    $line = Get-Content -Path $configFile | Where-Object { $_ -match "^nacos.console.port=" } | Select-Object -First 1
    if ($line -and $line -match "^nacos.console.port=(.*)$") { return [int]$Matches[1] }
    return $null
}

function Run-Standalone {
    Write-Info "Nacos Standalone Installation"
    if (-not $Global:InstallDir) {
        $Global:InstallDir = Join-Path $DefaultInstallDir "standalone\nacos-$Global:Version"
    }
    Write-Info "Target Nacos version: $Global:Version"
    Write-Info "Installation directory: $Global:InstallDir"

    if (-not (Check-JavaRequirements $Global:Version $Global:AdvancedMode)) { exit 1 }

    $zip = Download-Nacos $Global:Version
    $extracted = Extract-NacosToTemp $zip
    Install-Nacos $extracted $Global:InstallDir
    Cleanup-TempDir (Split-Path $extracted -Parent)

    $ports = Allocate-StandalonePorts $Global:Port $Global:Version $Global:AdvancedMode $Global:AllowKill
    $serverPort = $ports[0]
    $consolePort = $ports[1]

    $configFile = Join-Path $Global:InstallDir "conf\application.properties"
    Update-PortConfig $configFile $serverPort $consolePort $Global:Version
    Configure-Standalone-Security $configFile $Global:AdvancedMode

    $ds = Load-GlobalDatasourceConfig
    if ($ds) { Apply-DatasourceConfig $configFile $ds | Out-Null }

    if ($Global:AutoStart) {
        $pid = Start-NacosProcess $Global:InstallDir "standalone" $false
        if ($pid) { Write-Info "Nacos started with PID: $pid"; $Global:StartedPids += $pid }
        if (Wait-ForNacosReady $serverPort $consolePort $Global:Version 60) {
            if ($Global:NACOS_PASSWORD -and $Global:NACOS_PASSWORD -ne "nacos") {
                Initialize-AdminPassword $serverPort $consolePort $Global:Version $Global:NACOS_PASSWORD | Out-Null
            }
        }
        $major = [int]($Global:Version.Split('.')[0])
        $consoleUrl = if ($major -ge 3) { "http://localhost:$consolePort/index.html" } else { "http://localhost:$serverPort/nacos/index.html" }
        Print-CompletionInfo $Global:InstallDir $consoleUrl $serverPort $consolePort $Global:Version "nacos" $Global:NACOS_PASSWORD

        if (Copy-PasswordToClipboard $Global:NACOS_PASSWORD) { Write-Info "Password copied to clipboard" }
        Open-Browser $consoleUrl | Out-Null

        if (-not $Global:DetachMode -and $pid) {
            Write-Info "Press Ctrl+C to stop Nacos"
            try { Wait-Process -Id $pid } catch {}
        }
    }
}

function Run-Cluster {
    Write-Info "Nacos Cluster Installation"
    $clusterDir = Join-Path $ClusterBaseDir $Global:ClusterId
    if (Test-Path $clusterDir) {
        if ($Global:CleanMode) {
            Write-Warn "Cleaning existing cluster..."
            Remove-Item -Recurse -Force $clusterDir
        } elseif (-not $Global:JoinMode -and -not $Global:LeaveMode) {
            Write-ErrorMsg "Cluster '$($Global:ClusterId)' already exists"
            exit 1
        }
    }
    Ensure-Directory $clusterDir

    if (-not (Check-JavaRequirements $Global:Version $Global:AdvancedMode)) { exit 1 }

    $zip = Download-Nacos $Global:Version
    Configure-Cluster-Security $clusterDir $Global:AdvancedMode

    $ds = Load-GlobalDatasourceConfig
    $useDerby = -not $ds

    if ($Global:JoinMode -or $Global:LeaveMode) {
        $existingNodes = Get-ChildItem -Path $clusterDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^[0-9]+-v' } |
            Sort-Object { [int]($_.Name -split '-v')[0] }
    } else {
        $existingNodes = @()
    }

    if ($Global:LeaveMode) {
        $idx = [int]$Global:NodeIndex
        $nodeDir = Join-Path $clusterDir "$idx-v$($Global:Version)"
        $removedPort = $null
        if (Test-Path $nodeDir) {
            $removedPort = Get-NodeMainPort $nodeDir $Global:Version
            Remove-Item -Recurse -Force $nodeDir
        }
        foreach ($node in $existingNodes) {
            $conf = Join-Path $node.FullName "conf\cluster.conf"
            if (Test-Path $conf) {
                if ($removedPort) {
                    $lines = Get-Content -Path $conf | Where-Object { $_ -notmatch ":$removedPort$" }
                } else {
                    $lines = Get-Content -Path $conf
                }
                $lines | Set-Content -Path $conf -Encoding UTF8
            }
        }
        Write-Info "Node $idx removed"
        return
    }

    $existingMainPorts = @()
    $existingConsolePorts = @()
    if ($existingNodes.Count -gt 0) {
        foreach ($node in $existingNodes) {
            $mp = Get-NodeMainPort $node.FullName $Global:Version
            if ($mp) { $existingMainPorts += $mp }
            $cp = Get-NodeConsolePort $node.FullName
            if ($cp) { $existingConsolePorts += $cp }
        }
    }

    if ($Global:JoinMode) {
        $Global:ReplicaCount = $existingNodes.Count + 1
    }

    $nodeMain = @()
    $nodeConsole = @()

    if ($existingMainPorts.Count -gt 0 -and $Global:JoinMode) {
        $nodeMain = $existingMainPorts
        $nodeConsole = $existingConsolePorts
        $newIndex = ($existingNodes | ForEach-Object { ($_ .Name -split '-v')[0] } | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum + 1
        $candidatePort = $Global:BasePort + ($newIndex * 10)
        $newMain = Find-AvailableNacosPort $candidatePort
        if (-not $newMain) { throw "No available port for new node" }
        $nodeMain += $newMain
        if ([int]($Global:Version.Split('.')[0]) -ge 3) {
            $newConsole = Find-AvailablePort (8080 + $newIndex * 10)
            if (-not $newConsole) { $newConsole = Find-AvailablePort 18080 }
            $nodeConsole += $newConsole
        } else {
            $nodeConsole += 0
        }
    } else {
        $ports = Allocate-ClusterPorts $Global:BasePort $Global:ReplicaCount $Global:Version
        foreach ($pair in $ports) {
            $parts = $pair.Split(':')
            $nodeMain += [int]$parts[0]
            $nodeConsole += [int]$parts[1]
        }
    }

    $localIp = Get-LocalIp
    for ($i=0; $i -lt $Global:ReplicaCount; $i++) {
        $nodeName = "$i-v$($Global:Version)"
        $nodeDir = Join-Path $clusterDir $nodeName

        if (-not (Test-Path $nodeDir)) {
            $tempDir = Extract-NacosToTemp $zip
            Install-Nacos $tempDir $nodeDir
            Cleanup-TempDir (Split-Path $tempDir -Parent)
        }

        $nodeClusterConf = Join-Path $nodeDir "conf\cluster.conf"
        if (-not (Test-Path $nodeClusterConf) -or -not $Global:JoinMode) {
            @() | Set-Content -Path $nodeClusterConf -Encoding UTF8
            for ($j=0; $j -le $i; $j++) {
                Add-Content -Path $nodeClusterConf -Value "$localIp:$($nodeMain[$j])"
            }
        }

        $configFile = Join-Path $nodeDir "conf\application.properties"
        if (-not $Global:JoinMode -or -not (Test-Path $configFile)) {
            Update-PortConfig $configFile $nodeMain[$i] $nodeConsole[$i] $Global:Version
            Apply-SecurityConfig $configFile $Global:TOKEN_SECRET $Global:IDENTITY_KEY $Global:IDENTITY_VALUE
            if ($ds) { Apply-DatasourceConfig $configFile $ds | Out-Null } elseif ($useDerby) { Configure-Derby-For-Cluster $configFile }
        }
    }

    if ($Global:AutoStart) {
        $pids = @()
        for ($i=0; $i -lt $Global:ReplicaCount; $i++) {
            $nodeDir = Join-Path $clusterDir "$i-v$($Global:Version)"
            $pid = Start-NacosProcess $nodeDir "cluster" $useDerby
            if ($pid) { Write-Info "Node $i started (PID: $pid)"; $pids += $pid; $Global:StartedPids += $pid }

            if (Wait-ForNacosReady $nodeMain[$i] $nodeConsole[$i] $Global:Version 60) {
                Write-Info "Node $i ready"
            }

            if ($i -gt 0) {
                for ($j=0; $j -lt $i; $j++) {
                    $prevConf = Join-Path $clusterDir "$j-v$($Global:Version)\conf\cluster.conf"
                    if (Test-Path $prevConf) { Add-Content -Path $prevConf -Value "$localIp:$($nodeMain[$i])" }
                }
            }
        }

        if ($Global:NACOS_PASSWORD -and $Global:NACOS_PASSWORD -ne "nacos") {
            Initialize-AdminPassword $nodeMain[0] $nodeConsole[0] $Global:Version $Global:NACOS_PASSWORD | Out-Null
        }

        if (-not $Global:DetachMode -and $pids.Count -gt 0) {
            Write-Info "Press Ctrl+C to stop cluster"
            foreach ($pid in $pids) {
                try { Wait-Process -Id $pid } catch {}
            }
        }
    }
}

try {
    Parse-Arguments $args
    if ($DatasourceConfMode) {
        Configure-DatasourceConf
        exit 0
    }
    Validate-Arguments

    switch ($Mode) {
        "standalone" { Run-Standalone }
        "cluster" { Run-Cluster }
        default { Write-ErrorMsg "Unknown mode: $Mode"; exit 1 }
    }
} finally {
    if (-not $DetachMode -and $Global:StartedPids.Count -gt 0) {
        foreach ($pid in $Global:StartedPids) {
            try { Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

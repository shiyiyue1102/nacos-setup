# Port management for Windows nacos-setup
. $PSScriptRoot\common.ps1

function Test-PortAvailable($port) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop
        if ($conn) { return $false }
    } catch {}
    return $true
}

function Get-PortPid($port) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop | Select-Object -First 1
        if ($conn) { return $conn.OwningProcess }
    } catch {}
    return $null
}

function Is-NacosProcess($pid) {
    try {
        $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction Stop
        if ($proc -and $proc.CommandLine -match "nacos") { return $true }
    } catch {}
    return $false
}

function Stop-NacosProcess($pid) {
    try {
        Stop-Process -Id $pid -Force -ErrorAction Stop
        return $true
    } catch { return $false }
}

function Handle-PortConflict($port, $portName, $allowKill) {
    Write-Warn "Port $port ($portName) is already in use"
    $pid = Get-PortPid $port
    if ($pid -and (Is-NacosProcess $pid)) {
        if ($allowKill) {
            Write-Warn "Stopping existing Nacos process (PID: $pid)..."
            if (Stop-NacosProcess $pid) { Start-Sleep -Seconds 2; return $true }
            return $false
        }
        return $false
    }
    return $false
}

function Find-AvailablePort($startPort) {
    $port = [int]$startPort
    while ($port -lt 65535) {
        if (Test-PortAvailable $port) { return $port }
        $port++
    }
    return $null
}

function Find-AvailableNacosPort($startPort) {
    $port = [int]$startPort
    while ($port -lt 64535) {
        $grpcClient = $port + 1000
        $grpcServer = $port + 1001
        $raft = $port - 1000
        if ($raft -gt 0 -and (Test-PortAvailable $port) -and (Test-PortAvailable $grpcClient) -and (Test-PortAvailable $grpcServer) -and (Test-PortAvailable $raft)) {
            return $port
        }
        $port++
    }
    return $null
}

function Allocate-StandalonePorts($basePort, $nacosVersion, $advancedMode, $allowKill) {
    $nacosMajor = [int]($nacosVersion.Split('.')[0])
    $needConsole = $nacosMajor -ge 3
    $serverPort = [int]$basePort
    $consolePort = 8080

    if (-not (Test-PortAvailable $serverPort)) {
        if (Handle-PortConflict $serverPort "Server Port" $allowKill) {
            # freed
        } elseif (-not $advancedMode) {
            $serverPort = Find-AvailableNacosPort 18848
            if (-not $serverPort) { throw "No available port pair found" }
            Write-Info "Auto-selected port: $serverPort"
        } else {
            throw "Port $serverPort unavailable"
        }
    }

    $grpcPort = $serverPort + 1000
    if (-not (Test-PortAvailable $grpcPort)) {
        $serverPort = Find-AvailableNacosPort ($serverPort + 1)
        if (-not $serverPort) { throw "No available port pair found" }
        Write-Info "Reallocated to port pair: $serverPort"
    }

    if ($needConsole) {
        $consolePort = 8080 + [int](($serverPort - 8848) / 10)
        if (-not (Test-PortAvailable $consolePort)) {
            $consolePort = Find-AvailablePort $consolePort
            if (-not $consolePort) { $consolePort = Find-AvailablePort 18080 }
            if (-not $consolePort) { throw "No available console port found" }
        }
    }

    return @($serverPort, $consolePort)
}

function Allocate-ClusterPorts($basePort, $nodeCount, $nacosVersion) {
    $nacosMajor = [int]($nacosVersion.Split('.')[0])
    $result = @()
    for ($i=0; $i -lt $nodeCount; $i++) {
        $target = $basePort + $i * 10
        $main = $target
        $grpcClient = $target + 1000
        $grpcServer = $target + 1001
        $raft = $target - 1000
        $conflict = $false
        if (-not (Test-PortAvailable $target)) { $conflict = $true }
        elseif (-not (Test-PortAvailable $grpcClient)) { $conflict = $true }
        elseif (-not (Test-PortAvailable $grpcServer)) { $conflict = $true }
        elseif ($raft -gt 0 -and -not (Test-PortAvailable $raft)) { $conflict = $true }

        if ($conflict) {
            $main = Find-AvailableNacosPort ($target + 1)
            if (-not $main) { throw "No available port set for node $i" }
        }

        $console = 0
        if ($nacosMajor -ge 3) {
            $console = 8080 + $i * 10
            $attempts = 0
            while ($attempts -lt 10 -and -not (Test-PortAvailable $console)) {
                $console++
                $attempts++
            }
            if ($attempts -ge 10) { $console = Find-AvailablePort (18080 + $i * 10) }
            if (-not $console) { throw "No available console port for node $i" }
        }

        $result += "$main:$console"
    }
    return ,$result
}

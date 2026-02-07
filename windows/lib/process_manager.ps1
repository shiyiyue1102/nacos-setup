# Process management for Windows nacos-setup
. $PSScriptRoot\common.ps1
. $PSScriptRoot\java_manager.ps1

function Find-NacosProcessPid($installDir) {
    try {
        $procs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine -match [Regex]::Escape($installDir) -and $_.CommandLine -match "java" }
        $proc = $procs | Select-Object -First 1
        if ($proc) { return $proc.ProcessId }
    } catch {}
    return $null
}

function Start-NacosProcess($installDir, $mode, $useDerby) {
    if (-not (Test-Path $installDir)) { throw "Install dir not found: $installDir" }
    $startup = Join-Path $installDir "bin\startup.cmd"
    if (-not (Test-Path $startup)) { throw "startup.cmd not found" }

    $javaOpts = Get-JavaRuntimeOptions
    if ($javaOpts) { $env:JAVA_OPT = $javaOpts }

    $args = @("-m", $mode)
    if ($useDerby -and $mode -eq "cluster") { $args += @("-p", "embedded") }

    Start-Process -FilePath $startup -WorkingDirectory $installDir -ArgumentList $args -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 2
    $pid = $null
    $retry = 0
    while ($retry -lt 10 -and -not $pid) {
        Start-Sleep -Seconds 1
        $pid = Find-NacosProcessPid $installDir
        $retry++
    }

    Remove-Item Env:JAVA_OPT -ErrorAction SilentlyContinue
    return $pid
}

function Wait-ForNacosReady($mainPort, $consolePort, $version, $maxWait) {
    if (-not $maxWait) { $maxWait = 60 }
    $major = [int]($version.Split('.')[0])
    $healthUrl = if ($major -ge 3) { "http://localhost:$consolePort/v3/console/health/readiness" } else { "http://localhost:$mainPort/nacos/v2/console/health/readiness" }
    for ($i=0; $i -lt $maxWait; $i++) {
        try {
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                $r = Invoke-WebRequest -UseBasicParsing -Uri $healthUrl -Method Get -TimeoutSec 5
            } else {
                $r = Invoke-WebRequest -Uri $healthUrl -Method Get -TimeoutSec 5
            }
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 300) { return $true }
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

function Initialize-AdminPassword($mainPort, $consolePort, $version, $password) {
    if (-not $password -or $password -eq "nacos") { return $true }
    $major = [int]($version.Split('.')[0])
    $apiUrl = if ($major -ge 3) { "http://localhost:$consolePort/v3/auth/user/admin" } else { "http://localhost:$mainPort/nacos/v1/auth/users/admin" }
    try {
        $body = "password=$password"
        if ($PSVersionTable.PSVersion.Major -lt 6) {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri $apiUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $body
        } else {
            $resp = Invoke-WebRequest -Uri $apiUrl -Method Post -ContentType "application/x-www-form-urlencoded" -Body $body
        }
        return $true
    } catch { return $false }
}

function Print-CompletionInfo($installDir, $consoleUrl, $serverPort, $consolePort, $version, $username, $password) {
    Write-Host ""
    Write-Host "========================================"
    Write-Info "Nacos Started Successfully!"
    Write-Host "========================================"
    Write-Host ""
    Write-Host "Installation Directory: $installDir"
    Write-Host "Console URL: $consoleUrl"
    Write-Host ""
    Write-Info "Port allocation:"
    Write-Host "  - Server Port: $serverPort"
    Write-Host "  - Client gRPC Port: $($serverPort + 1000)"
    Write-Host "  - Server gRPC Port: $($serverPort + 1001)"
    Write-Host "  - Raft Port: $($serverPort - 1000)"
    if ([int]($version.Split('.')[0]) -ge 3) { Write-Host "  - Console Port: $consolePort" }
    Write-Host ""
    if ($password) {
        Write-Host "Authentication is enabled."
        Write-Host "  Username: $username"
        Write-Host "  Password: $password"
    } else {
        Write-Host "Default login: nacos / nacos"
    }
    Write-Host ""
}

function Copy-PasswordToClipboard($password) {
    try {
        if ($password) {
            Set-Clipboard -Value $password
            return $true
        }
    } catch {}
    return $false
}

function Open-Browser($url) {
    try {
        Start-Process $url | Out-Null
        return $true
    } catch { return $false }
}

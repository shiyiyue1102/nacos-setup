# Configuration management for Windows nacos-setup
. $PSScriptRoot\common.ps1

$Global:GlobalDatasourceConfig = Join-Path $env:USERPROFILE "ai-infra\nacos\default.properties"

function Load-GlobalDatasourceConfig {
    if (Test-Path $Global:GlobalDatasourceConfig -PathType Leaf) {
        $content = Get-Content -Path $Global:GlobalDatasourceConfig | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }
        if ($content -match '^(spring\.(datasource|sql\.init)\.platform|db\.num)') {
            return $Global:GlobalDatasourceConfig
        }
    }
    return $null
}

function Apply-DatasourceConfig($configFile, $datasourceFile) {
    if (-not (Test-Path $configFile)) { throw "Config file not found: $configFile" }
    if (-not $datasourceFile -or -not (Test-Path $datasourceFile)) { return $false }

    $lines = Get-Content -Path $datasourceFile | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s*$' }
    foreach ($line in $lines) {
        if ($line -match '^(.*?)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim()
            Update-ConfigProperty $configFile $key $value
        }
    }
    return $true
}

function Configure-Derby-For-Cluster($configFile) {
    Update-ConfigProperty $configFile "spring.sql.init.platform" "derby"
    $lines = Get-Content -Path $configFile -Raw -Encoding UTF8
    $lines = [Regex]::Replace($lines, "(?m)^spring\.datasource\.platform=.*$", "")
    $lines = [Regex]::Replace($lines, "(?m)^db\.(num|url|user|password).*\n?", "")
    Set-Content -Path $configFile -Value $lines -Encoding UTF8
}

function Apply-SecurityConfig($configFile, $tokenSecret, $identityKey, $identityValue) {
    Update-ConfigProperty $configFile "nacos.core.auth.enabled" "true"
    Update-ConfigProperty $configFile "nacos.core.auth.plugin.nacos.token.secret.key" $tokenSecret
    Update-ConfigProperty $configFile "nacos.core.auth.server.identity.key" $identityKey
    Update-ConfigProperty $configFile "nacos.core.auth.server.identity.value" $identityValue
}

function Configure-Standalone-Security($configFile, $advancedMode) {
    if (-not $advancedMode) {
        $Global:TOKEN_SECRET = Generate-SecretKey
        $Global:IDENTITY_KEY = "nacos_identity_" + [int][double]::Parse((Get-Date -UFormat %s))
        $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16)
        $Global:NACOS_PASSWORD = Generate-Password
    } else {
        $Global:TOKEN_SECRET = Read-Host "Enter JWT token secret key (empty for auto)"
        if (-not $Global:TOKEN_SECRET) { $Global:TOKEN_SECRET = Generate-SecretKey }
        $Global:IDENTITY_KEY = Read-Host "Enter server identity key (empty for auto)"
        if (-not $Global:IDENTITY_KEY) { $Global:IDENTITY_KEY = "nacos_identity_" + [int][double]::Parse((Get-Date -UFormat %s)) }
        $Global:IDENTITY_VALUE = Read-Host "Enter server identity value (empty for auto)"
        if (-not $Global:IDENTITY_VALUE) { $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16) }
        $Global:NACOS_PASSWORD = Read-Host "Enter admin password (empty for auto)"
        if (-not $Global:NACOS_PASSWORD) { $Global:NACOS_PASSWORD = Generate-Password }
    }

    Apply-SecurityConfig $configFile $Global:TOKEN_SECRET $Global:IDENTITY_KEY $Global:IDENTITY_VALUE
}

function Configure-Cluster-Security($clusterDir, $advancedMode) {
    if (-not $advancedMode) {
        $Global:TOKEN_SECRET = Generate-SecretKey
        $Global:IDENTITY_KEY = "nacos_cluster_" + [int][double]::Parse((Get-Date -UFormat %s))
        $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16)
        $Global:NACOS_PASSWORD = Generate-Password
    } else {
        $Global:TOKEN_SECRET = Read-Host "Enter JWT token secret key (empty for auto)"
        if (-not $Global:TOKEN_SECRET) { $Global:TOKEN_SECRET = Generate-SecretKey }
        $Global:IDENTITY_KEY = Read-Host "Enter server identity key (empty for auto)"
        if (-not $Global:IDENTITY_KEY) { $Global:IDENTITY_KEY = "nacos_cluster_" + [int][double]::Parse((Get-Date -UFormat %s)) }
        $Global:IDENTITY_VALUE = Read-Host "Enter server identity value (empty for auto)"
        if (-not $Global:IDENTITY_VALUE) { $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16) }
        $Global:NACOS_PASSWORD = Read-Host "Enter admin password (empty for auto)"
        if (-not $Global:NACOS_PASSWORD) { $Global:NACOS_PASSWORD = Generate-Password }
    }

    $shareFile = Join-Path $clusterDir "share.properties"
    @"
# Nacos Cluster Shared Security Configuration
nacos.core.auth.plugin.nacos.token.secret.key=$($Global:TOKEN_SECRET)
nacos.core.auth.server.identity.key=$($Global:IDENTITY_KEY)
nacos.core.auth.server.identity.value=$($Global:IDENTITY_VALUE)
admin.password=$($Global:NACOS_PASSWORD)
"@ | Set-Content -Path $shareFile -Encoding UTF8
}

function Update-PortConfig($configFile, $serverPort, $consolePort, $nacosVersion) {
    $major = [int]($nacosVersion.Split('.')[0])
    if ($major -ge 3) {
        Update-ConfigProperty $configFile "nacos.server.main.port" $serverPort
        Update-ConfigProperty $configFile "nacos.console.port" $consolePort
    } else {
        Update-ConfigProperty $configFile "server.port" $serverPort
    }
}

function Configure-DatasourceConf {
    Ensure-Directory (Split-Path $Global:GlobalDatasourceConfig -Parent)

    $dbType = Read-Host "Database type (mysql/postgresql)"
    if (-not $dbType) { throw "Database type is required" }
    $dbType = $dbType.ToLower()
    if ($dbType -ne "mysql" -and $dbType -ne "postgresql") { throw "Unsupported database type" }

    $host = Read-Host "Database host"
    if (-not $host) { throw "Database host is required" }

    $port = Read-Host "Database port"
    if (-not $port) {
        $port = if ($dbType -eq "mysql") { "3306" } else { "5432" }
    }

    $dbName = Read-Host "Database name"
    if (-not $dbName) { throw "Database name is required" }

    $user = Read-Host "Database username"
    if (-not $user) { throw "Database username is required" }

    $pass = Read-Host "Database password"
    if (-not $pass) { $pass = "" }

    if ($dbType -eq "mysql") {
        $jdbc = "jdbc:mysql://$host`:$port/$dbName?characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useUnicode=true&useSSL=false&serverTimezone=UTC"
    } else {
        $jdbc = "jdbc:postgresql://$host`:$port/$dbName?stringtype=unspecified"
    }

    @"
# Nacos datasource config (auto-generated)
spring.sql.init.platform=$dbType
spring.datasource.platform=$dbType
db.num=1
db.url.0=$jdbc
db.user.0=$user
db.password.0=$pass
"@ | Set-Content -Path $Global:GlobalDatasourceConfig -Encoding UTF8

    Write-Info "Datasource configuration saved to: $Global:GlobalDatasourceConfig"
}

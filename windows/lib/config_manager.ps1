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
        
        Write-Host ""
        Write-Info "===================================="
        Write-Info "Auto-Generated Security Configuration"
        Write-Info "===================================="
        Write-Host ""
        Write-Host "JWT Token Secret Key:"
        Write-Host "  $($Global:TOKEN_SECRET)"
        Write-Host ""
        Write-Host "Server Identity Key:"
        Write-Host "  $($Global:IDENTITY_KEY)"
        Write-Host ""
        Write-Host "Server Identity Value:"
        Write-Host "  $($Global:IDENTITY_VALUE)"
        Write-Host ""
        Write-Host "Admin Password:"
        Write-Host "  $($Global:NACOS_PASSWORD)"
        Write-Host ""
        Write-Info "These credentials will be automatically configured"
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
    Write-Host ""
    
    if (-not $advancedMode) {
        Write-Info "Simplified mode: Auto-generating shared security keys for cluster..."
        
        $Global:TOKEN_SECRET = Generate-SecretKey
        $Global:IDENTITY_KEY = "nacos_cluster_" + [int][double]::Parse((Get-Date -UFormat %s))
        $Global:IDENTITY_VALUE = (Generate-SecretKey).Substring(0,16)
        $Global:NACOS_PASSWORD = Generate-Password
        
        Write-Host ""
        Write-Info "==========================================="
        Write-Info "Auto-Generated Cluster Security Configuration"
        Write-Info "==========================================="
        Write-Host ""
        Write-Host "JWT Token Secret Key:"
        Write-Host "  $($Global:TOKEN_SECRET)"
        Write-Host ""
        Write-Host "Server Identity Key:"
        Write-Host "  $($Global:IDENTITY_KEY)"
        Write-Host ""
        Write-Host "Server Identity Value:"
        Write-Host "  $($Global:IDENTITY_VALUE)"
        Write-Host ""
        Write-Info "These credentials will be shared across all cluster nodes"
        Write-Info "Admin password will be set after cluster startup"
        Write-Host ""
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
    
    Write-Info "Security configuration saved to: $shareFile"
}

function Update-PortConfig($configFile, $serverPort, $consolePort, $nacosVersion) {
    if ([string]::IsNullOrWhiteSpace($configFile)) { throw "Update-PortConfig: Config file path is missing" }
    $major = [int]($nacosVersion.Split('.')[0])
    if ($major -ge 3) {
        Update-ConfigProperty $configFile "nacos.server.main.port" $serverPort
        Update-ConfigProperty $configFile "nacos.console.port" $consolePort
    } else {
        Update-ConfigProperty $configFile "server.port" $serverPort
    }
}

function Configure-DatasourceConf {
    Write-Host ""
    Write-Info "========================================"
    Write-Info "External Datasource Configuration"
    Write-Info "========================================"
    Write-Host ""
    Write-Host "This will create a global datasource configuration that will be"
    Write-Host "used by all future Nacos installations (standalone or cluster)."
    Write-Host ""
    Write-Host "Supported databases: MySQL, PostgreSQL"
    Write-Host ""
    
    # Check if config already exists
    if (Test-Path $Global:GlobalDatasourceConfig) {
        Write-Warn "Existing datasource configuration found at:"
        Write-Warn "  $Global:GlobalDatasourceConfig"
        Write-Host ""
        $confirm = Read-Host "Overwrite existing configuration? (y/N)"
        if ($confirm -notmatch '^[Yy]$') {
            Write-Info "Operation cancelled"
            return
        }
        Write-Host ""
    }
    
    # Database Type
    Write-Host "Step 1/6: Database Type"
    Write-Host "  1) MySQL"
    Write-Host "  2) PostgreSQL"
    Write-Host ""
    
    $dbPlatform = ""
    while ($true) {
        $dbTypeChoice = Read-Host "Select database type (1-2)"
        switch ($dbTypeChoice) {
            "1" { $dbPlatform = "mysql"; break }
            "2" { $dbPlatform = "postgresql"; break }
            default { Write-Host "Invalid choice. Please enter 1 or 2." }
        }
        if ($dbPlatform) { break }
    }
    Write-Host ""
    
    # Database Host
    Write-Host "Step 2/6: Database Host"
    $dbHost = Read-Host "Enter database host (default: localhost)"
    if (-not $dbHost) { $dbHost = "localhost" }
    Write-Host ""
    
    # Database Port
    Write-Host "Step 3/6: Database Port"
    $defaultPort = if ($dbPlatform -eq "mysql") { "3306" } else { "5432" }
    $dbPort = Read-Host "Enter database port (default: $defaultPort)"
    if (-not $dbPort) { $dbPort = $defaultPort }
    Write-Host ""
    
    # Database Name
    Write-Host "Step 4/6: Database Name"
    $dbName = Read-Host "Enter database name (default: nacos)"
    if (-not $dbName) { $dbName = "nacos" }
    Write-Host ""
    
    # Database User
    Write-Host "Step 5/6: Database User"
    $dbUser = Read-Host "Enter database username"
    while (-not $dbUser) {
        Write-Host "Username cannot be empty"
        $dbUser = Read-Host "Enter database username"
    }
    Write-Host ""
    
    # Database Password
    Write-Host "Step 6/6: Database Password"
    $securePassword = Read-Host "Enter database password" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
    $dbPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    Write-Host ""
    
    while (-not $dbPassword) {
        Write-Host "Password cannot be empty"
        $securePassword = Read-Host "Enter database password" -AsSecureString
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $dbPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        Write-Host ""
    }
    
    # Construct database URL
    $dbUrl = ""
    if ($dbPlatform -eq "mysql") {
        $dbUrl = "jdbc:mysql://${dbHost}:${dbPort}/${dbName}?characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useSSL=false&allowPublicKeyRetrieval=true"
    } else {
        $dbUrl = "jdbc:postgresql://${dbHost}:${dbPort}/${dbName}?currentSchema=public"
    }
    
    # Create directory if not exists
    $datasourceDir = Split-Path $Global:GlobalDatasourceConfig -Parent
    Ensure-Directory $datasourceDir
    
    # Write configuration
    $configContent = @"
# Nacos External Datasource Configuration
# Auto-generated on $(Get-Date)

# Database platform (mysql or postgresql)
spring.sql.init.platform=$dbPlatform

# Database connection pool size
db.num=1

# Database connection URL
db.url.0=$dbUrl

# Database credentials
db.user.0=$dbUser
db.password.0=$dbPassword

# Connection pool configuration
db.pool.config.connectionTimeout=30000
db.pool.config.validationTimeout=10000
db.pool.config.maximumPoolSize=20
db.pool.config.minimumIdle=2
"@
    
    Set-Content -Path $Global:GlobalDatasourceConfig -Value $configContent -Encoding UTF8
    
    Write-Host ""
    Write-Success "Datasource configuration saved to:"
    Write-Success "  $Global:GlobalDatasourceConfig"
    Write-Host ""
    Write-Info "Configuration Summary:"
    Write-Host "  Platform:  $dbPlatform"
    Write-Host "  Host:      $dbHost"
    Write-Host "  Port:      $dbPort"
    Write-Host "  Database:  $dbName"
    Write-Host "  User:      $dbUser"
    Write-Host ""
    Write-Info "This configuration will be used by all future Nacos installations."
    Write-Warn "Make sure the database exists and is accessible before installing Nacos."
    Write-Host ""
    
    # Provide SQL initialization hint
    if ($dbPlatform -eq "mysql") {
        Write-Info "To initialize the database schema, run:"
        Write-Host "  mysql -h$dbHost -P$dbPort -u$dbUser -p $dbName < `$NACOS_HOME\conf\mysql-schema.sql"
    } else {
        Write-Info "To initialize the database schema, run:"
        Write-Host "  psql -h$dbHost -p$dbPort -U$dbUser -d$dbName -f `$NACOS_HOME\conf\postgresql-schema.sql"
    }
    Write-Host ""
}


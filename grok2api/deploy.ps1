# ==============================================================================
# Grok2API 交互式部署与更新脚本 (Windows PowerShell - 1474443844/Build)
# ==============================================================================

$Repo = "1474443844/Build"
$DefaultInstallDir = "C:\grok2api"
$TaskName = "Grok2API"

$CurrentUser = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $CurrentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "请以管理员身份运行此 PowerShell 脚本！"
    Pause
    Exit
}

function Get-InstallDir {
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        return $existingTask.Actions[0].WorkingDirectory
    }
    return $DefaultInstallDir
}

function Get-CurrentPort {
    $configPath = "$InstallDir\config.yaml"
    $parsedPort = "8000"
    if (Test-Path $configPath) {
        $listenLine = Get-Content $configPath | Where-Object { $_ -match "listen:" } | Select-Object -First 1
        if ($listenLine -and $listenLine -match '(\d+)') {
            $parsedPort = $Matches[1]
        }
    }
    return $parsedPort
}

function Get-LatestRelease {
    Write-Host "正在从 1474443844/Build 检索最新的 grok2api 构建版本..." -ForegroundColor Cyan
    
    $targetRelease = $null
    $page = 1
    
    while ($true) {
        Write-Host "正在检索 releases 列表第 $page 页..." -ForegroundColor Gray
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=100&page=$page"
        
        if (-not $releases -or $releases.Count -eq 0) {
            break
        }
        
        $targetRelease = $releases | Where-Object { $_.tag_name -like "grok2api-*" } | Select-Object -First 1
        if ($targetRelease) {
            break
        }
        
        $page++
    }
    
    if (-not $targetRelease) {
        Write-Error "错误：遍历了所有 Release 仍未找到任何带有 'grok2api-' 前缀的正式版。"
        return $null
    }
    
    $asset = $targetRelease.assets | Where-Object { $_.name -like "*windows-amd64.zip" } | Select-Object -First 1
    return @{ Tag = $targetRelease.tag_name; Url = $asset.browser_download_url }
}

function Interactive-Configure {
    param (
        [string]$configPath
    )
    Write-Host "=== Grok2API 交互式配置助手 ===" -ForegroundColor Cyan

    # 1. 端口
    $port = Read-Host "请输入服务监听端口 [默认: 8000]"
    if (-not $port) { $port = "8000" }

    # 2. 用户
    $adminUser = Read-Host "请输入管理员用户名 [默认: admin]"
    if (-not $adminUser) { $adminUser = "admin" }

    # 3. 密码
    $adminPass = Read-Host "请输入管理员初始密码 [直接回车将自动生成随机强密码]"
    $isRandom = $false
    if (-not $adminPass) {
        $isRandom = $true
        $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        $random = New-Object Byte[] 16
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($random)
        $adminPass = ""
        foreach ($b in $random) {
            $adminPass += $chars[$b % $chars.Length]
        }
    }

    # 4. 存储
    Write-Host "`n请选择数据库存储驱动类型：" -ForegroundColor Gray
    Write-Host "  1. SQLite (单实例极速部署推荐)" -ForegroundColor Gray
    Write-Host "  2. PostgreSQL (多实例负载高可用推荐)" -ForegroundColor Gray
    $dbChoice = Read-Host "请选择 [1-2, 默认: 1]"
    $dbDriver = "sqlite"
    $pgDsn = "postgres://user:password@127.0.0.1:5432/grok2api?sslmode=disable"
    if ($dbChoice -eq "2") {
        $dbDriver = "postgres"
        $inputDsn = Read-Host "请输入 PostgreSQL DSN 连接串 [默认: $pgDsn]"
        if ($inputDsn) { $pgDsn = $inputDsn }
    }

    # 5. 缓存驱动
    Write-Host "`n请选择运行缓存驱动类型：" -ForegroundColor Gray
    Write-Host "  1. Memory (单机轻量)" -ForegroundColor Gray
    Write-Host "  2. Redis (多实例高可用集群推荐)" -ForegroundColor Gray
    $storeChoice = Read-Host "请选择 [1-2, 默认: 1]"
    $storeDriver = "memory"
    $redisAddr = "127.0.0.1:6379"
    $redisPass = ""
    if ($storeChoice -eq "2") {
        $storeDriver = "redis"
        $inputRedisAddr = Read-Host "请输入 Redis 连接地址 [默认: $redisAddr]"
        if ($inputRedisAddr) { $redisAddr = $inputRedisAddr }
        $inputRedisPass = Read-Host "请输入 Redis 访问密码 [默认: 无]"
        if ($inputRedisPass) { $redisPass = $inputRedisPass }
    }

    # 6. 生成安全随机密钥
    $bytes = New-Object Byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $JwtSecret = [System.BitConverter]::ToString($bytes).Replace("-", "").ToLower()
    
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $EncKey = [System.Convert]::ToBase64String($bytes)

    Copy-Item -Path "$InstallDir\config.example.yaml" -Destination $configPath -Force
    $content = Get-Content -Path $configPath -Raw

    # 正则安全替换
    $content = $content -replace 'listen: "127.0.0.1:8000"', "listen: `"0.0.0.0:$port`""
    $content = $content -replace 'jwtSecret: "replace-with-at-least-32-characters"', "jwtSecret: `"$JwtSecret`""
    $content = $content -replace 'credentialEncryptionKey: "replace-with-base64-key"', "credentialEncryptionKey: `"$EncKey`""
    $content = $content -replace 'username: "admin"', "username: `"$adminUser`""
    $content = $content -replace 'password: "replace-with-a-strong-password"', "password: `"$adminPass`""
    
    $content = $content -replace 'driver: sqlite # sqlite \| postgres', "driver: $dbDriver # sqlite | postgres"
    if ($dbDriver -eq "postgres") {
        $content = $content -replace 'postgres://user:password@127.0.0.1:5432/grok2api\?sslmode=disable', $pgDsn
    }

    $content = $content -replace 'driver: memory # memory \| redis', "driver: $storeDriver # memory | redis"
    if ($storeDriver -eq "redis") {
        $content = $content -replace 'address: "127.0.0.1:6379"', "address: `"$redisAddr`""
        $content = $content -replace 'password: ""', "password: `"$redisPass`""
    }

    Set-Content -Path $configPath -Value $content -Force

    Write-Host "🎉 config.yaml 交互配置写入完成！" -ForegroundColor Green
    Write-Host "=======================================================" -ForegroundColor Yellow
    Write-Host " 🚀 初始管理员安全凭证已成功配置：" -ForegroundColor Yellow
    Write-Host " 初始账户: $adminUser" -ForegroundColor Yellow
    Write-Host " 初始密码: $adminPass" -ForegroundColor Yellow
    if ($isRandom) {
        Write-Host " (提示: 这是系统为您随机生成的强密码，请妥善保存！)" -ForegroundColor Yellow
    }
    Write-Host "=======================================================" -ForegroundColor Yellow

    $global:ListenPort = $port
}

function Install-App {
    $InstallDir = Get-InstallDir
    
    $inputDir = Read-Host "请输入自定义安装路径 [当前/默认: $InstallDir]"
    if ($inputDir) { $InstallDir = $inputDir }

    $release = Get-LatestRelease
    if (-not $release) { return }
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    
    $zipPath = "$InstallDir\temp.zip"
    Write-Host "正在下载 ($($release.Tag))..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $release.Url -OutFile $zipPath

    Write-Host "正在停止旧进程并解压..." -ForegroundColor Cyan
    Stop-Process -Name "grok2api" -ErrorAction SilentlyContinue
    Expand-Archive -Path $zipPath -DestinationPath $InstallDir -Force
    Remove-Item $zipPath -Force

    $configPath = "$InstallDir\config.yaml"
    if (-not (Test-Path $configPath)) {
        if (Test-Path "$InstallDir\config.example.yaml") {
            Interactive-Configure $configPath
        } else {
            New-Item -ItemType File -Path $configPath -Force | Out-Null
            Write-Host "警告：未能在包中找到 config.example.yaml 模板，已生成空白 config.yaml。" -ForegroundColor Yellow
        }
    } else {
        $global:ListenPort = Get-CurrentPort
    }

    Write-Host "正在创建 Windows 计划任务实现开机自启后台运行..." -ForegroundColor Cyan
    $action = New-ScheduledTaskAction -Execute "$InstallDir\grok2api.exe" -Argument "--config `"$configPath`"" -WorkingDirectory $InstallDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Write-Host "`n安装完成！服务已在后台运行。" -ForegroundColor Green
    Pause
}

function Update-App {
    $InstallDir = Get-InstallDir
    if (-not (Test-Path "$InstallDir\grok2api.exe")) {
        Write-Error "未检测到安装。请先选择“1”进行安装。"
        Pause
        return
    }

    $release = Get-LatestRelease
    if (-not $release) { return }
    Write-Host "正在备份当前版本并下载更新..." -ForegroundColor Cyan
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Stop-Process -Name "grok2api" -ErrorAction SilentlyContinue

    Rename-Item -Path "$InstallDir\grok2api.exe" -NewName "grok2api.bak" -Force -ErrorAction SilentlyContinue

    $zipPath = "$InstallDir\temp.zip"
    try {
        Invoke-WebRequest -Uri $release.Url -OutFile $zipPath
        Expand-Archive -Path $zipPath -DestinationPath $InstallDir -Force
        Remove-Item $zipPath -Force
        Remove-Item "$InstallDir\grok2api.bak" -Force -ErrorAction SilentlyContinue
        Start-ScheduledTask -TaskName $TaskName
        Write-Host "更新成功！最新版本: $($release.Tag)" -ForegroundColor Green
    } catch {
        Write-Host "更新失败，恢复备份中..." -ForegroundColor Red
        if (Test-Path "$InstallDir\grok2api.bak") {
            Rename-Item -Path "$InstallDir\grok2api.bak" -NewName "grok2api.exe" -Force
            Start-ScheduledTask -TaskName $TaskName
        }
    }
    Pause
}

function Uninstall-App {
    $InstallDir = Get-InstallDir
    $confirm = Read-Host "确定要彻底卸载并停止服务吗？ [Y/N]"
    if ($confirm -match '^[Yy]$') {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Stop-Process -Name "grok2api" -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        
        $delete = Read-Host "是否同时删除安装目录及数据 ($InstallDir)？ [Y/N]"
        if ($delete -match '^[Yy]$') {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Host "卸载完成！" -ForegroundColor Green
        Pause
    }
}

while ($true) {
    Clear-Host
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "       Grok2API 一键部署/管理 (Windows)   " -ForegroundColor Green
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "  1. 安装 / 重新安装 Grok2API"
    Write-Host "  2. 一键升级至最新版本"
    Write-Host "  3. 启动后台服务"
    Write-Host "  4. 停止后台服务"
    Write-Host "  5. 卸载 Grok2API"
    Write-Host "  0. 退出脚本"
    Write-Host "=========================================" -ForegroundColor Cyan
    $choice = Read-Host "请选择 [0-5]"

    switch ($choice) {
        "1" { Install-App }
        "2" { Update-App }
        "3" { Start-ScheduledTask -TaskName $TaskName; Write-Host "服务已启动"; Pause }
        "4" { Stop-ScheduledTask -TaskName $TaskName; Stop-Process -Name "grok2api" -ErrorAction SilentlyContinue; Write-Host "服务已停止"; Pause }
        "5" { Uninstall-App }
        "0" { Exit }
    }
}
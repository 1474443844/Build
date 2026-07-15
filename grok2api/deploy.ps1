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
    # 动态抓取注册于 Windows 计划任务中的自定义物理路径
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        return $existingTask.Actions[0].WorkingDirectory
    }
    return $DefaultInstallDir
}

function Get-LatestRelease {
    Write-Host "正在从 1474443844/Build 获取最新 Release 链接..." -ForegroundColor Cyan
    $api = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    $asset = $api.assets | Where-Object { $_.name -like "*windows-amd64.zip" } | Select-Object -First 1
    return @{ Tag = $api.tag_name; Url = $asset.browser_download_url }
}

function Install-App {
    $InstallDir = Get-InstallDir
    
    # 提示并接受 Windows 的自定义目录
    $inputDir = Read-Host "请输入自定义安装路径 [当前/默认: $InstallDir]"
    if ($inputDir) { $InstallDir = $inputDir }

    $release = Get-LatestRelease
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
        New-Item -ItemType File -Path $configPath -Force | Out-Null
        Write-Host "已自动创建空白 config.yaml，请后续进行修改。" -ForegroundColor Yellow
    }

    $port = Read-Host "请输入监听端口 [默认: 8000]"
    if (-not $port) { $port = "8000" }

    Write-Host "正在创建 Windows 计划任务实现开机自启后台运行..." -ForegroundColor Cyan
    # 将自定义路径动态写入 Windows 计划任务的操作和工作目录参数中
    $action = New-ScheduledTaskAction -Execute "$InstallDir\grok2api.exe" -Argument "--config `"$configPath`" --listen 0.0.0.0:$port" -WorkingDirectory $InstallDir
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
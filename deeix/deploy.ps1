# DEEIX-Chat Windows 部署脚本
# PowerShell 执行：
#   irm https://raw.githubusercontent.com/1474443844/Build/main/deeix/deploy-windows.ps1 | iex
# 指定版本：
#   $env:VERSION='deeix-chat-0.3.3'; irm ... | iex

$ErrorActionPreference = 'Stop'

$Repo        = '1474443844/Build'
$AppName     = 'deeix-chat'
$InstallDir  = if ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'deeix-chat' }
$BinDir      = if ($env:BIN_DIR) { $env:BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps' }
$Version     = if ($env:VERSION) { $env:VERSION } else { '' }
$Arch        = 'amd64'
$Asset       = "$AppName-windows-$Arch.zip"

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Url = "https://github.com/$Repo/releases/latest/download/$Asset"
} else {
  $Url = "https://github.com/$Repo/releases/download/$Version/$Asset"
}

Write-Host '==> DEEIX-Chat Windows 部署'
Write-Host "    安装目录: $InstallDir"
Write-Host "    下载: $Url"

$TmpDir = Join-Path $env:TEMP ("deeix-chat-install-" + [guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TmpDir | Out-Null
$ZipPath = Join-Path $TmpDir $Asset

try {
  Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing

  if (Test-Path $InstallDir) {
    Remove-Item -Recurse -Force $InstallDir
  }
  New-Item -ItemType Directory -Path $InstallDir | Out-Null
  Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force

  $ExePath = Join-Path $InstallDir "$AppName.exe"
  if (-not (Test-Path $ExePath)) {
    $found = Get-ChildItem -Path $InstallDir -Recurse -Filter "$AppName.exe" | Select-Object -First 1
    if ($null -eq $found) {
      throw "未找到 $AppName.exe"
    }
    # 若在子目录，尽量展平
    $parent = $found.Directory.FullName
    if ($parent -ne $InstallDir) {
      Get-ChildItem -Path $parent -Force | ForEach-Object {
        Move-Item -Force -Path $_.FullName -Destination $InstallDir
      }
    }
  }

  if (-not (Test-Path (Join-Path $InstallDir "$AppName.exe"))) {
    throw "安装后仍未找到 $AppName.exe"
  }

  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'storage') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'data') | Out-Null
  New-Item -ItemType Directory -Force -Path $BinDir | Out-Null

  # 启动器 .cmd
  $CmdPath = Join-Path $BinDir "$AppName.cmd"
  @"
@echo off
setlocal
cd /d "$InstallDir"
if "%FRONTEND_DIST_DIR%"=="" set FRONTEND_DIST_DIR=./frontend/out
"$InstallDir\$AppName.exe" %*
"@ | Set-Content -Path $CmdPath -Encoding ASCII

  # 可选：当前用户 PATH 追加 BinDir
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ';' + $BinDir), 'User')
    Write-Host "    已将 $BinDir 加入用户 PATH（新开终端生效）"
  }

  Write-Host ''
  Write-Host '✅ Windows 部署完成'
  Write-Host "   安装目录: $InstallDir"
  Write-Host "   启动命令: $AppName"
  Write-Host ''
  Write-Host '立即运行（当前窗口）:'
  Write-Host "  & `"$CmdPath`""
  Write-Host ''
  Write-Host '卸载:'
  Write-Host "  Remove-Item -Recurse -Force `"$InstallDir`""
  Write-Host "  Remove-Item -Force `"$CmdPath`""
}
finally {
  if (Test-Path $TmpDir) {
    Remove-Item -Recurse -Force $TmpDir
  }
}

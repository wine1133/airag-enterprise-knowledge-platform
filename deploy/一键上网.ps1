# AIRAG 高级企业知识库平台 · 一键上网
# 自动完成：检查数据库 -> 构建前端 -> 启动后端 -> 建立 Cloudflare 公网隧道 -> 打开网址
# 用法：右键“使用 PowerShell 运行”，或在 PowerShell 中执行 .\一键上网.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$project = Join-Path $root "RAG高级企业知识库平台"
$app = Join-Path $project "ai_rag\fastapi-app"
$vue = Join-Path $project "ai_rag\vue"
$dist = Join-Path $vue "dist"
$venv = Join-Path $app ".venv"
$python = Join-Path $venv "Scripts\python.exe"
$logDir = Join-Path $PSScriptRoot "logs"
$urlFile = Join-Path $PSScriptRoot "公网地址.txt"
$cloudflared = Join-Path $PSScriptRoot "cloudflared.exe"

New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Test-PortOpen([int]$Port) {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

function Wait-Http([string]$Url, [int]$Seconds) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 4
            if ($response.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Seconds 1
    }
    return $false
}

function Ensure-Database([int]$Port, [string]$NamePattern, [string]$Label) {
    if (Test-PortOpen $Port) {
        Write-Host "  [就绪] $Label（端口 $Port）" -ForegroundColor Green
        return $true
    }
    $services = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match $NamePattern -or $_.DisplayName -match $NamePattern
    }
    foreach ($service in $services) {
        if ($service.Status -ne "Running") {
            Write-Host "  正在启动 $Label 服务：$($service.DisplayName)"
            try { Start-Service -Name $service.Name -ErrorAction Stop } catch {}
        }
        if (Wait-Http "http://127.0.0.1:$Port" 1) { break }
    }
    for ($i = 0; $i -lt 30; $i++) {
        if (Test-PortOpen $Port) {
            Write-Host "  [就绪] $Label（端口 $Port）" -ForegroundColor Green
            return $true
        }
        Start-Sleep -Seconds 1
    }
    Write-Host "  [失败] $Label 没有启动，请确认本机已安装并运行该数据库。" -ForegroundColor Red
    return $false
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  AIRAG 高级企业知识库平台 · 一键上网" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path $project)) {
    throw "没有找到项目目录：$project"
}

Write-Host "[1/5] 检查本地数据库"
if (-not (Ensure-Database 3306 "mysql" "MySQL 业务库")) { exit 1 }
if (-not (Ensure-Database 5432 "postgres" "PostgreSQL 向量库")) { exit 1 }

Write-Host "[2/5] 检查后端运行环境"
if (-not (Test-Path $python)) {
    $bootstrap = Get-Command python -ErrorAction SilentlyContinue
    if (-not $bootstrap) { throw "没有找到 Python，请先安装 Python 3.12。" }
    Write-Host "  首次运行：正在创建 Python 虚拟环境……"
    & $bootstrap.Source -m venv $venv
}
& $python -c "import fastapi, uvicorn, tortoise" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  首次运行：正在安装后端依赖，可能需要几分钟……"
    & $python -m pip install --upgrade pip
    & $python -m pip install -r (Join-Path $app "requirements.txt")
    if ($LASTEXITCODE -ne 0) { throw "后端依赖安装失败。" }
}
Write-Host "  [就绪] Python 运行环境" -ForegroundColor Green

Write-Host "[3/5] 检查前端页面"
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
if (-not $npm) { throw "没有找到 Node.js/npm，请先安装 Node.js 18 或更高版本。" }
$needsBuild = -not (Test-Path (Join-Path $dist "index.html"))
if (-not $needsBuild) {
    $distTime = (Get-Item (Join-Path $dist "index.html")).LastWriteTimeUtc
    $newestSource = Get-ChildItem (Join-Path $vue "src") -Recurse -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $packageTime = (Get-Item (Join-Path $vue "package.json")).LastWriteTimeUtc
    $needsBuild = ($newestSource.LastWriteTimeUtc -gt $distTime) -or ($packageTime -gt $distTime)
}
if ($needsBuild) {
    Push-Location $vue
    try {
        if (-not (Test-Path (Join-Path $vue "node_modules"))) {
            Write-Host "  首次运行：正在安装前端依赖……"
            & $npm.Source install
            if ($LASTEXITCODE -ne 0) { throw "前端依赖安装失败。" }
        }
        Write-Host "  正在构建生产页面……"
        & $npm.Source run build
        if ($LASTEXITCODE -ne 0) { throw "前端构建失败。" }
    } finally {
        Pop-Location
    }
}
Write-Host "  [就绪] 前端生产页面" -ForegroundColor Green

Write-Host "[4/5] 启动后端服务"
$backendErr = Join-Path $logDir "backend.err.log"
$backendOut = Join-Path $logDir "backend.out.log"
if (-not (Test-PortOpen 9090)) {
    $args = @("-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", "9090", "--loop", "main:loop_factory")
    Start-Process -FilePath $python -ArgumentList $args -WorkingDirectory $app -WindowStyle Hidden -RedirectStandardOutput $backendOut -RedirectStandardError $backendErr
}
if (-not (Wait-Http "http://127.0.0.1:9090/" 60)) {
    Write-Host "  后端启动失败，请查看：$backendErr" -ForegroundColor Red
    exit 1
}
Write-Host "  [就绪] 本地地址：http://127.0.0.1:9090" -ForegroundColor Green

Write-Host "[5/5] 建立公网入口"
$url = $null
if (Test-Path $urlFile) {
    $saved = (Get-Content $urlFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($saved -match "^https://[a-z0-9-]+\.trycloudflare\.com$" -and (Wait-Http $saved 3)) {
        $url = $saved
        Write-Host "  当前公网隧道仍在线，直接复用。" -ForegroundColor Green
    }
}

if (-not $url) {
    if (-not (Test-Path $cloudflared)) {
        $candidates = @(
            (Join-Path $env:TEMP "cloudflared\cloudflared.exe"),
            (Join-Path $env:LOCALAPPDATA "cloudflared\cloudflared.exe")
        )
        foreach ($candidate in $candidates) {
            if (Test-Path $candidate) { Copy-Item -LiteralPath $candidate -Destination $cloudflared -Force; break }
        }
    }
    if (-not (Test-Path $cloudflared)) {
        Write-Host "  正在下载 Cloudflare 隧道工具……"
        curl.exe -L --fail --retry 3 -o $cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $cloudflared)) { throw "Cloudflare 隧道工具下载失败。" }
    }

    $cfOut = Join-Path $logDir "cloudflared.out.log"
    $cfErr = Join-Path $logDir "cloudflared.err.log"
    Set-Content -LiteralPath $cfOut -Value "" -Encoding UTF8
    Set-Content -LiteralPath $cfErr -Value "" -Encoding UTF8
    $cfArgs = @("tunnel", "--url", "http://127.0.0.1:9090", "--no-autoupdate")
    Start-Process -FilePath $cloudflared -ArgumentList $cfArgs -WindowStyle Hidden -RedirectStandardOutput $cfOut -RedirectStandardError $cfErr

    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 1
        $logs = @()
        if (Test-Path $cfOut) { $logs += Get-Content $cfOut -Raw -ErrorAction SilentlyContinue }
        if (Test-Path $cfErr) { $logs += Get-Content $cfErr -Raw -ErrorAction SilentlyContinue }
        $match = [regex]::Match(($logs -join "`n"), "https://[a-z0-9-]+\.trycloudflare\.com")
        if ($match.Success) { $url = $match.Value; break }
    }
    if (-not $url) {
        Write-Host "  公网隧道创建失败，请查看：$cfErr" -ForegroundColor Red
        exit 1
    }
    $url | Set-Content -LiteralPath $urlFile -Encoding UTF8
    Write-Host "  正在等待公网地址生效……"
}

if (-not (Wait-Http $url 45)) {
    Write-Host "  公网地址暂时无法访问，请稍后重试或查看：$logDir" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  上线成功" -ForegroundColor Green
Write-Host "  用户端：$url/front/home"
Write-Host "  管理端：$url/manager/home"
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "公网地址已保存到：$urlFile"
Write-Host "注意：这是临时地址，电脑关机或隧道重启后会变化；重新运行本脚本即可生成新地址。" -ForegroundColor Yellow
Start-Sleep -Seconds 1
Start-Process $url

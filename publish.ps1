<#
.SYNOPSIS
    博客一键发布脚本：提交新博客并推送到 GitHub，自动触发页面构建。

.DESCRIPTION
    写好博客文档后运行本脚本，将自动完成：
      1. 拉取远程最新改动并同步 FeelIt 子模块
      2. 检查是否有草稿（draft = true）文章被提交（默认拒绝，防止发布后不显示）
      3. 本地运行 hugo 做一次构建检查（未安装 hugo 时自动跳过）
      4. 提交所有更改并推送到 GitHub
      5. GitHub Actions 检测到 push 后自动构建并部署到 GitHub Pages

.PARAMETER Message
    自定义 git 提交信息。省略时自动从新文章标题生成，如 "post: 我的第一篇博客"。

.PARAMETER IncludeDrafts
    允许提交 draft = true 的草稿文章。

.PARAMETER SkipBuildCheck
    跳过本地 hugo 构建检查。

.EXAMPLE
    .\publish.ps1
.EXAMPLE
    .\publish.ps1 "发布新博客"
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\publish.ps1   # 系统禁止运行脚本时使用
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Message,

    [switch]$IncludeDrafts,
    [switch]$SkipBuildCheck
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

function Invoke-Git {
    param([string[]]$Arguments)
    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') 执行失败（退出码 $LASTEXITCODE）"
    }
}

# 读取 Markdown 文件的 front matter（+++ 或 --- 包裹），返回 title 和 draft
function Read-FrontMatter {
    param([string]$Path)
    $title = $null
    $draft = $null
    $inFrontMatter = $false
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $inFrontMatter) {
            if ($line -match '^\s*(\+\+\+|---)\s*$') { $inFrontMatter = $true }
            continue
        }
        if ($line -match '^\s*(\+\+\+|---)\s*$') { break }   # front matter 结束
        if ($null -eq $title -and $line -match '^\s*title\s*[:=]\s*["'']?(.*?)\s*["'']?\s*$') {
            $title = $Matches[1]
        }
        if ($null -eq $draft -and $line -match '^\s*draft\s*[:=]\s*true\b') {
            $draft = $true
        }
    }
    [PSCustomObject]@{ Title = $title; Draft = $draft }
}

$branch = (& git branch --show-current).Trim()
if (-not $branch) { throw '当前处于 detached HEAD 状态，请先切换回 master 分支再运行。' }

Write-Host '==> 拉取远程最新改动并同步子模块 ...' -ForegroundColor Cyan
Invoke-Git @('pull', '--rebase', '--autostash', 'origin', $branch)
Invoke-Git @('submodule', 'update', '--init', '--recursive')

if ($branch -ne 'master') {
    Write-Host "注意：当前分支是 $branch，GitHub Actions 只在 master 分支推送时自动构建部署。" -ForegroundColor Yellow
}

# 收集本次改动（-uall 让未跟踪目录展开为单个文件；关闭 quotepath 避免中文路径被转义）
$changed = @(& git -c core.quotepath=false status --porcelain -uall)

# 未推送的本地提交数（比如上次推送失败时留下的）
$unpushed = 0
$count = & git rev-list --count "origin/$branch..HEAD"
if ($LASTEXITCODE -eq 0) { $unpushed = [int]$count }

if ($changed.Count -eq 0 -and $unpushed -eq 0) {
    Write-Host '没有需要上传的更改，本次无需操作。' -ForegroundColor Yellow
    exit 0
}

# porcelain 每行固定格式：前两个字符是状态（XY），第 4 个字符起是路径
$contentFiles = @()   # 所有改动的文章文件
$newPostPaths = @()   # 新增（A / ??）的文章文件
foreach ($line in $changed) {
    $status = $line.Substring(0, 2)
    $path = $line.Substring(3)
    if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1] }   # 重命名取新路径
    if ($status[0] -eq 'D' -or $status[1] -eq 'D') { continue }      # 已删除的文件跳过
    if ($path -notmatch '^content/.+\.md$') { continue }             # 只关心文章
    if (-not (Test-Path -LiteralPath $path)) { continue }            # 路径已不存在时跳过
    $contentFiles += $path
    if ($status[0] -in @('A', '?')) { $newPostPaths += $path }
}

# 草稿检查：draft = true 的文章发布后不会显示
$draftFiles = @()
foreach ($path in $contentFiles) {
    $fm = Read-FrontMatter $path
    if ($fm -and $fm.Draft) { $draftFiles += $path }
}
if ($draftFiles.Count -gt 0 -and -not $IncludeDrafts) {
    Write-Host '以下文章是草稿（draft = true），发布后不会出现在网站上：' -ForegroundColor Red
    $draftFiles | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host '如果确实要提交草稿，请加上 -IncludeDrafts 参数重新运行。' -ForegroundColor Red
    exit 1
}

# 生成默认提交信息（优先取新文章的标题）
if ([string]::IsNullOrWhiteSpace($Message)) {
    $titles = @()
    foreach ($path in $newPostPaths) {
        if ($path -match 'index\.md$') { continue }        # 目录页不算新文章
        $fm = Read-FrontMatter $path
        if ($fm -and $fm.Title) { $titles += $fm.Title }
    }
    if ($titles.Count -gt 0) {
        $Message = "post: $($titles -join ', ')"
    } else {
        $Message = 'chore: update site content'
    }
}

# 本地构建检查：提前发现错误，避免把构建失败的页面推上去
if ($changed.Count -gt 0 -and -not $SkipBuildCheck) {
    if (Get-Command hugo -ErrorAction SilentlyContinue) {
        Write-Host '==> 本地构建检查（hugo）...' -ForegroundColor Cyan
        & hugo
        if ($LASTEXITCODE -ne 0) {
            throw "本地 Hugo 构建失败（退出码 $LASTEXITCODE），请修复后再发布。"
        }
        Write-Host '    构建检查通过。' -ForegroundColor Green
    } else {
        Write-Host '未检测到 hugo，跳过本地构建检查。' -ForegroundColor DarkYellow
    }
}

# 提交并推送
if ($changed.Count -gt 0) {
    Write-Host "==> 提交更改：$Message" -ForegroundColor Cyan
    Invoke-Git @('add', '-A')
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host '没有可提交的内容（更改可能位于 FeelIt 子模块内部，请先在子模块中提交）。' -ForegroundColor Yellow
        exit 0
    }
    Invoke-Git @('commit', '-m', $Message)
} else {
    Write-Host "工作区没有新改动，直接推送本地已有的 $unpushed 个提交。" -ForegroundColor Yellow
}

Write-Host '==> 推送到 GitHub ...' -ForegroundColor Cyan
Invoke-Git @('push', 'origin', $branch)

$remote = (& git config --get remote.origin.url) -replace '\.git$', ''
Write-Host ''
Write-Host '✔ 推送成功！GitHub Actions 将自动构建并部署页面。' -ForegroundColor Green
Write-Host "  查看部署进度：$remote/actions"

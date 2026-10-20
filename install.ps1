# 皮肤工坊（Skin Studio）Windows 安装器
# 用法：右键「使用 PowerShell 运行」，或在 PowerShell 里执行：
#   .\install.ps1
# 可选指定 Hermes 家目录： .\install.ps1 -HermesHome "E:\Hermes"
param(
    [string]$HermesHome = ""
)

$ErrorActionPreference = "Stop"

function Resolve-HermesHome {
    # 优先级：命令行参数 > 环境变量 HERMES_HOME > 常见盘符下的 config.yaml > LOCALAPPDATA\hermes
    if ($HermesHome) { return (Resolve-Path $HermesHome).Path }

    if ($env:HERMES_HOME -and (Test-Path (Join-Path $env:HERMES_HOME "config.yaml"))) {
        return $env:HERMES_HOME
    }

    # 扫描常见盘符（C: 到 Z:）根目录下的 hermes 目录，挑有 config.yaml 的
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem)) {
        $candidate = Join-Path $drive.Root "Hermes"
        if (Test-Path (Join-Path $candidate "config.yaml")) {
            return $candidate
        }
    }

    # 回退到平台默认
    $default = Join-Path $env:LOCALAPPDATA "hermes"
    return $default
}

function Ensure-PluginsEnabled {
    # 安全地把插件名加进 config.yaml 的 plugins.enabled 列表。
    # 幂等；保留 CRLF、BOM 和全部注释（只插一行，不动其他字节）。
    param([string]$ConfigPath, [string]$PluginName)

    $bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }  # 去掉 BOM 字符，稍后写回

    # 检测行尾风格
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $text.Split([string[]]@("`r`n", "`n"), [System.StringSplitOptions]::None)

    # 1) 幂等检查：plugins 段里是否已有该插件
    $inPlugins = $false
    foreach ($l in $lines) {
        if ($l -match '^plugins\s*:') { $inPlugins = $true; continue }
        if ($inPlugins -and $l -match '^\S' -and $l.Trim() -ne '') { $inPlugins = $false; continue }
        if ($inPlugins -and $l -match ('^\s*-\s*' + [regex]::Escape($PluginName) + '\s*$')) {
            return $false  # 已启用，无需改动
        }
    }

    # 2) 定位 plugins 段内 enabled 列表，找插入点（列表最后一项之后）
    $inPlugins = $false
    $inEnabled = $false
    $insertAt = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -match '^plugins\s*:') { $inPlugins = $true; $inEnabled = $false; continue }
        if ($inPlugins -and $l -match '^\S' -and $l.Trim() -ne '') { $inPlugins = $false; $inEnabled = $false; continue }
        if ($inPlugins -and $l -match '^  enabled\s*:') { $inEnabled = $true; $insertAt = $i + 1; continue }
        if ($inEnabled -and $l -match '^\s*-\s') {
            # 列表项：插入点推进到这一项之后
            $insertAt = $i + 1
            continue
        }
        if ($inEnabled -and $l.Trim() -ne '' -and $l -notmatch '^\s*-\s' -and $l -notmatch '^\s*(#.*)?$') {
            # 遇到 enabled 列表之外的实义行，停止
            break
        }
    }

    if ($insertAt -lt 0) {
        # 没有 plugins: 或 enabled: 段——保守处理，不破坏文件
        Write-Host "  ! 未找到 plugins.enabled 段，跳过自动启用（请手动把 $PluginName 加进 plugins.enabled）" -ForegroundColor Yellow
        return $null
    }

    # 3) 插入一行（4 空格缩进，与现有列表项对齐）
    $indent = '    '
    $newLines = New-Object System.Collections.Generic.List[string]
    for ($k = 0; $k -lt $insertAt; $k++) { $newLines.Add($lines[$k]) }
    $newLines.Add($indent + '- ' + $PluginName)
    for ($k = $insertAt; $k -lt $lines.Count; $k++) { $newLines.Add($lines[$k]) }

    $newText = $newLines -join $eol
    $outBytes = [System.Text.Encoding]::UTF8.GetBytes($newText)
    if ($hasBom) {
        $bom = [byte[]](0xEF, 0xBB, 0xBF)
        $outBytes = $bom + $outBytes
    }
    [System.IO.File]::WriteAllBytes($ConfigPath, $outBytes)
    return $true
}

# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────
$srcDir = $PSScriptRoot
$pluginName = "skin-studio"
$target = Resolve-HermesHome
$configPath = Join-Path $target "config.yaml"

Write-Host "皮肤工坊 (Skin Studio) Windows 安装程序" -ForegroundColor Cyan
Write-Host "  源目录:  $srcDir"
Write-Host "  目标:    $target"
Write-Host ""

if (-not (Test-Path $configPath)) {
    Write-Warning "目标家目录没有 config.yaml（$configPath）。请确认 Hermes Desktop 已安装并用 -HermesHome 指定正确路径。"
    exit 1
}

# 1) 复制桌面插件（前端）
$frontDir = Join-Path $target "desktop-plugins\$pluginName"
New-Item -ItemType Directory -Force -Path $frontDir | Out-Null
foreach ($f in @("plugin.js", "LICENSE", "README.md")) {
    if (Test-Path (Join-Path $srcDir $f)) {
        Copy-Item (Join-Path $srcDir $f) $frontDir -Force
    }
}
Write-Host "  前端插件 -> $frontDir" -ForegroundColor Green

# 2) 复制 Python 后端（dashboard 插件，「应用」按钮 + 皮肤持久化）
$backDir = Join-Path $target "plugins\$pluginName\dashboard"
New-Item -ItemType Directory -Force -Path $backDir | Out-Null
foreach ($f in @("manifest.json", "plugin_api.py")) {
    if (Test-Path (Join-Path $srcDir "dashboard\$f")) {
        Copy-Item (Join-Path $srcDir "dashboard\$f") $backDir -Force
    }
}
Write-Host "  后端插件 -> $backDir" -ForegroundColor Green

# 3) 启用插件（写入 plugins.enabled，幂等）
$result = Ensure-PluginsEnabled -ConfigPath $configPath -PluginName $pluginName
if ($result -eq $true) {
    Write-Host "  已把 $pluginName 加进 plugins.enabled" -ForegroundColor Green
} elseif ($result -eq $false) {
    Write-Host "  plugins.enabled 已包含 $pluginName，跳过" -ForegroundColor Green
} else {
    Write-Host "  （未自动启用，见上方提示）" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "安装完成！接下来：" -ForegroundColor Cyan
Write-Host "  1. 完全退出 Hermes Desktop 再重新打开"
Write-Host "  2. 命令面板（Windows: Ctrl+K）→ Reload desktop plugins"
Write-Host "  3. 侧边栏出现「皮肤工坊」→ 选主题 → 点「应用」"
Write-Host ""
Write-Host "有问题或建议：https://github.com/simonimhotep/hermes-skin-studio"

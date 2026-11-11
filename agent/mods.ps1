# ============================================================
#  Nafx Mod 加载器
#
#  一个 mod 就是一个 .mod.json 文件，放在 <项目根>\mod\ 下面。
#  它能在不改任何源码的前提下改这些：
#
#    config   覆盖运行时配置（temperature / maxSteps / personalPrompt …）
#    tools    改工具：禁用、改描述、改参数说明
#    prompt   追加一段人设/规则到系统提示词末尾
#    docs     往里塞 md 文档，内容会跟着提示词一起发
#    script   PowerShell 脚本，加载时跑一次（能改环境变量、写文件）
#
#  mod 文件长这样：
#  {
#    "id": "coder-mode",
#    "name": "程序员模式",
#    "version": "1.0",
#    "enabled": true,
#    "config": { "temperature": 0.1, "maxSteps": 40 },
#    "tools": {
#      "write_file": { "enabled": false },
#      "run_cmd":    { "description": "跑命令。这个 mod 里所有命令都要带日志" }
#    },
#    "prompt": "你在程序员的电脑上工作，改代码前先看 git 状态。",
#    "docs": [
#      { "name": "命名规范", "content": "变量用驼峰，函数用动词开头。" }
#    ],
#    "script": "Write-Host 'coder-mode 已加载'"
#  }
# ============================================================

function Get-ModDir {
    param([string]$Root)
    return (Join-Path $Root 'mod')
}

# 读出所有 mod（按文件名排序，后加载的覆盖先加载的）
function Get-Mods {
    param(
        [string]$Root,
        [switch]$IncludeDisabled
    )
    $dir = Get-ModDir -Root $Root
    if (-not (Test-Path $dir)) { return @() }

    $list = New-Object System.Collections.ArrayList
    $files = @(Get-ChildItem $dir -Filter '*.mod.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        try {
            $raw = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
            $obj = $raw | ConvertFrom-Json
        } catch {
            Write-Host ("  [mod] 跳过 " + $f.Name + "：JSON 解析失败") -ForegroundColor Yellow
            continue
        }
        if (-not $obj.id) { $obj | Add-Member -NotePropertyName id -NotePropertyValue $f.BaseName -Force }
        if (-not $obj.name) { $obj | Add-Member -NotePropertyName name -NotePropertyValue $obj.id -Force }
        if ($null -eq $obj.enabled) { $obj | Add-Member -NotePropertyName enabled -NotePropertyValue $true -Force }
        $obj | Add-Member -NotePropertyName _file -NotePropertyValue $f.FullName -Force
        if (-not $IncludeDisabled -and $obj.enabled -eq $false) { continue }
        [void]$list.Add($obj)
    }
    return $list.ToArray()
}

# 把 mod 的 config 合并进现有配置（运行时字段有效，context/maxTokens 这类要重启模型）
function Apply-ModConfig {
    param($Mods, $Cfg)
    if (-not $Mods -or $Mods.Count -eq 0) { return $Cfg }
    $applied = @()
    foreach ($m in $Mods) {
        if (-not $m.config) { continue }
        foreach ($p in $m.config.PSObject.Properties) {
            try {
                $Cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                $applied += ($m.id + '.' + $p.Name)
            } catch { }
        }
    }
    return [pscustomobject]@{ Cfg = $Cfg; Applied = $applied }
}

# 把 mod 的 tools 覆盖合并进工具定义表
#   $ToolMap 是 名字 -> schema(JSON 字符串) 的哈希表
function Apply-ModTools {
    param($Mods, $ToolMap)
    if (-not $Mods -or $Mods.Count -eq 0) { return @() }
    $log = @()
    foreach ($m in $Mods) {
        if (-not $m.tools) { continue }
        foreach ($p in $m.tools.PSObject.Properties) {
            $tname = $p.Name
            $rule = $p.Value
            if (-not $ToolMap.ContainsKey($tname)) {
                Write-Host ("  [mod] " + $m.id + " 想改工具 " + $tname + "，但没这个工具，跳过") -ForegroundColor Yellow
                continue
            }
            if ($rule.enabled -eq $false) {
                $ToolMap.Remove($tname)
                $log += ($m.id + ' 禁用 ' + $tname)
                continue
            }
            if ($rule.description) {
                # 直接换掉 schema 里的 description 字段
                $sc = [string]$ToolMap[$tname]
                $newDesc = [string]$rule.description
                # JSON 转义双引号和反斜杠
                $esc = $newDesc.Replace('\', '\\').Replace('"', '\"')
                $sc2 = [regex]::Replace($sc, '"description":"(?:[^"\\]|\\.)*"', ('"description":"' + $esc + '"'), 1)
                $ToolMap[$tname] = $sc2
                $log += ($m.id + ' 改描述 ' + $tname)
            }
        }
    }
    return $log
}

# mod 追加的提示词（人设 + 文档）
function Get-ModPrompt {
    param($Mods)
    if (-not $Mods -or $Mods.Count -eq 0) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($m in $Mods) {
        if ($m.prompt) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('## ' + $m.name + '（mod）')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine([string]$m.prompt)
        }
        if ($m.docs) {
            foreach ($d in @($m.docs)) {
                if (-not $d.content) { continue }
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine('### ' + [string]$d.name)
                [void]$sb.AppendLine('')
                [void]$sb.AppendLine([string]$d.content)
            }
        }
    }
    return $sb.ToString()
}

# 跑 mod 自带的脚本（加载时执行一次）
function Invoke-ModScripts {
    param($Mods, [string]$Root)
    if (-not $Mods -or $Mods.Count -eq 0) { return @() }
    $log = @()
    foreach ($m in $Mods) {
        if (-not $m.script) { continue }
        try {
            $sb = [scriptblock]::Create([string]$m.script)
            & $sb 2>&1 | Out-Null
            $log += ($m.id + ' 脚本执行完成')
        } catch {
            $log += ($m.id + ' 脚本报错：' + $_.Exception.Message)
        }
    }
    return $log
}

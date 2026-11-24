# 生成 mod-editor-standalone.html：把配置/工具/mods 数据内联进 HTML，
# 这样双击就能用，不需要任何服务（8GB 内存下 8070 经常起不来）。
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

$htmlPath = Join-Path $Root 'mod-editor.html'
$outPath  = Join-Path $Root 'mod-editor-standalone.html'

if (-not (Test-Path $htmlPath)) { Write-Output "找不到 $htmlPath"; exit 1 }

function J($s) {
    if ($null -eq $s) { return '""' }
    $e = [string]$s
    $e = $e.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $e + '"'
}

# ---------- 1) 配置（直接从 config.json 读，跳过 _ 开头的说明字段）----------
$cfgPath = Join-Path $Root 'config.json'
$cfgJson = '{}'
if (Test-Path $cfgPath) {
    $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{')
    $first = $true
    foreach ($p in $cfg.PSObject.Properties) {
        if ($p.Name -like '_*') { continue }
        $v = $p.Value
        $vs = if ($null -eq $v) { 'null' }
              elseif ($v -is [bool]) { if ($v) { 'true' } else { 'false' } }
              elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { [string]$v }
              else { J ([string]$v) }
        if (-not $first) { [void]$sb.Append(',') }
        [void]$sb.Append((J $p.Name) + ':' + $vs)
        $first = $false
    }
    [void]$sb.Append('}')
    $cfgJson = $sb.ToString()
}
$cfgCheck = $null
try { $cfgCheck = $cfgJson | ConvertFrom-Json } catch { Write-Output "配置 JSON 生成失败"; exit 1 }
Write-Output ("1) 配置 " + @($cfgCheck.PSObject.Properties).Count + " 项")

# ---------- 2) 工具（带分组）----------
$groups = @{
    '文件' = @('file_editor','write_file','read_file','list_dir','hash_file','read_lines','zip_list','diff_files','replace_in_file','set_line','append_file','make_dir','find_files','file_info','move_path','copy_path','grep_file','delete_path')
    '执行' = @('run_cmd','run_ps','run_ps1','run_bat','run_js','run_python','write_script')
    '系统' = @('sys_info','clipboard','env_get','open_app','kill_process','ps','install')
    '网络' = @('download_file','web_search','web_fetch')
    '数据' = @('json_format','csv_preview')
    '查询' = @('now','date_calc','unit_convert','project_doc','help','syshelp','win_doc')
    '流程' = @('say','rethink','plan','learn','finish')
    '技能' = @('skill','write_skill','unzip')
    '版本' = @('git')
}
$nameToGroup = @{}
foreach ($gName in $groups.Keys) { foreach ($tn in $groups[$gName]) { $nameToGroup[$tn] = $gName } }

$schemaPath = Join-Path $Root 'agent\tools-schema.json'
$toolItems = @()
if (Test-Path $schemaPath) {
    $items = Get-Content $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($it in $items) {
        $tn = [string]$it.function.name
        $grp = if ($nameToGroup.ContainsKey($tn)) { $nameToGroup[$tn] } else { '其他' }
        $toolItems += ('{"name":' + (J $tn) + ',"description":' + (J $it.function.description) + ',"group":' + (J $grp) + '}')
    }
}
$toolsJson = '[' + ($toolItems -join ',') + ']'
$toolsCheck = $null
try { $toolsCheck = $toolsJson | ConvertFrom-Json } catch { Write-Output "工具 JSON 生成失败"; exit 1 }
Write-Output ("2) 工具 " + @($toolsCheck).Count + " 个")

# ---------- 3) 已有 mod（只有元数据，和 API 一致）----------
$modDir = Join-Path $Root 'mod'
$modItems = @()
if (Test-Path $modDir) {
    foreach ($mf in @(Get-ChildItem $modDir -Filter '*.mod.json' -File | Sort-Object Name)) {
        try {
            $mj = Get-Content $mf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $en = if ($null -eq $mj.enabled) { 'true' } else { if ($mj.enabled) { 'true' } else { 'false' } }
            $docCnt = @($mj.docs).Count
            $toolCnt = @($mj.tools.PSObject.Properties).Count
            $cfgCnt = @($mj.config.PSObject.Properties).Count
            $modItems += ('{"file":' + (J $mf.Name) + ',"id":' + (J $mj.id) + ',"name":' + (J $mj.name) +
                          ',"version":' + (J $mj.version) + ',"enabled":' + $en +
                          ',"hasPrompt":' + $(if ($mj.prompt) { 'true' } else { 'false' }) +
                          ',"docCount":' + $docCnt + ',"toolCount":' + $toolCnt + ',"cfgCount":' + $cfgCnt + '}')
        } catch { }
    }
}
$modsJson = '[' + ($modItems -join ',') + ']'
$modsCheck = $null
try { $modsCheck = $modsJson | ConvertFrom-Json } catch { Write-Output "mods JSON 生成失败"; exit 1 }
Write-Output ("3) mod " + @($modsCheck).Count + " 个")

# ---------- 4) 读 HTML 并注入 ----------
$html = [IO.File]::ReadAllText($htmlPath, [Text.Encoding]::UTF8)

# 注入数据块（在 </head> 前）
$dataBlock = @"
<script>
/* 独立版内联数据 - 生成时间 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') */
const INLINE_DATA = {
  '/api/config': $cfgJson,
  '/api/tools':  $toolsJson,
  '/api/mods':   $modsJson
};
const STANDALONE_MODE = true;
</script>
"@
if ($html -match '</head>') {
    $html = $html -replace '</head>', ($dataBlock + "`r`n</head>")
} else {
    Write-Output '找不到 </head>'; exit 1
}

# 替换 jget
$oldJget = @"
async function jget(url){
  const r = await fetch(url);
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return await r.json();
}
"@
$newJget = @"
async function jget(url){
  // 独立版：直接返回内联数据（file:// 下 fetch 会被浏览器拦掉）
  if (typeof STANDALONE_MODE !== 'undefined' && STANDALONE_MODE && INLINE_DATA[url]) {
    return JSON.parse(JSON.stringify(INLINE_DATA[url]));
  }
  const r = await fetch(url);
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return await r.json();
}
"@
if ($html.Contains($oldJget)) {
    $html = $html.Replace($oldJget, $newJget)
    Write-Output '4) jget 已改成优先用内联数据'
} else {
    Write-Output '4) 警告：没匹配到 jget，检查是否被改写'
}

# 顶栏加个"独立版"标记
$html = $html.Replace('<span class="badge">8070</span>', '<span class="badge">独立版</span>')

# ---------- 5) 写文件（无 BOM）----------
[IO.File]::WriteAllText($outPath, $html, (New-Object Text.UTF8Encoding($false)))
$final = [IO.File]::ReadAllBytes($outPath)
Write-Output ("5) 生成 " + $outPath + "  " + $final.Length + " 字节  BOM=" + ((($final[0..2] -join ',') -eq '239,187,191')))

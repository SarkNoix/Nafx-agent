# ============================================================
#  Nafx Mod 编辑器服务
#
#  跑在 8070 端口，提供一个网页让你改 mod。
#  改完点「下载 mod 文件」，浏览器会存一个 xxx.mod.json，
#  把它丢进 <项目根>\mod\ 目录，agent 下次运行就加载了。
#
#  为什么用「下载文件」而不是「直接保存」：
#    · 不用给服务写文件权限，安全
#    · 一个 mod 就是一个文件，好备份、好分享
#    · 你想放哪就放哪，放 mod\ 才生效
# ============================================================

param([int]$Port = 8070)


$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
# ---- 启动日志（写文件，不依赖控制台）----
$BootLog = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'logs\editor-boot.log'
function BootLog { param([string]$m) try { [IO.File]::AppendAllText($BootLog, ((Get-Date -Format 'HH:mm:ss') + ' ' + $m + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false))) } catch { } }
BootLog '脚本开始'

$HtmlPath = Join-Path $Root 'mod-editor.html'
$ModDir = Join-Path $Root 'mod'

if (-not (Test-Path $HtmlPath)) {
BootLog ("HtmlPath=" + $HtmlPath + " 存在=" + (Test-Path $HtmlPath))
    Write-Output "找不到 mod-editor.html，应该在：$HtmlPath"
    exit 1
}

function J($s) {
    if ($null -eq $s) { return '""' }
    $esc = [string]$s
    $esc = $esc.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $esc + '"'
}

function Send-Bytes {
    param($Response, [byte[]]$Bytes, [string]$ContentType = 'application/json; charset=utf-8', [int]$Code = 200)
    try {
        $Response.StatusCode = $Code
        $Response.ContentType = $ContentType
        $Response.ContentLength64 = $Bytes.Length
        $Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
        $Response.OutputStream.Close()
    } catch { }
}

function Read-Body {
    param($Request)
    try {
        $reader = New-Object System.IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        $reader.Close()
        return $text
    } catch { return '' }
}
function Send-Json {
    param($Response, [string]$Json, [int]$Code = 200)
    Send-Bytes -Response $Response -Bytes ([Text.Encoding]::UTF8.GetBytes($Json)) -ContentType 'application/json; charset=utf-8' -Code $Code
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() }
catch {
    Write-Output "8070 端口起不来（可能被占用）：$($_.Exception.Message)"
    exit 1
}

Write-Output ""
BootLog ("监听 " + $Port + " 成功 IsListening=" + $listener.IsListening + " Prefixes=" + ($listener.Prefixes -join ',') + " Auth=" + $listener.AuthenticationSchemes)
Write-Output "  Nafx Mod 编辑器"
Write-Output "  http://127.0.0.1:$Port/"
Write-Output ""
Write-Output "  改完点「下载 mod 文件」，把下载到的 .mod.json 放进："
Write-Output "  $ModDir"
Write-Output ""

try {
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        $req = $ctx.Request
        $res = $ctx.Response
        $path = $req.Url.AbsolutePath

        try {
            switch ($path) {
                '/' {
                    $html = [IO.File]::ReadAllText($HtmlPath, [Text.Encoding]::UTF8)
                    Send-Bytes -Response $res -Bytes ([Text.Encoding]::UTF8.GetBytes($html)) -ContentType 'text/html; charset=utf-8'
                }
                '/api/tools' {
                    # 工具名 + 描述 + 分组。全部平铺太长，编辑器里要折叠和搜索。
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
                    $arr = @()
                    if (Test-Path $schemaPath) {
                        try {
                            $raw = [IO.File]::ReadAllText($schemaPath, [Text.Encoding]::UTF8)
                            $items = $raw | ConvertFrom-Json
                            foreach ($it in $items) {
                                $tn = [string]$it.function.name
                                $grp = if ($nameToGroup.ContainsKey($tn)) { $nameToGroup[$tn] } else { '其他' }
                                $arr += ('{"name":' + (J $tn) + ',"description":' + (J $it.function.description) + ',"group":' + (J $grp) + '}')
                            }
                        } catch { }
                    }
                    Send-Json -Response $res -Json ('[' + ($arr -join ',') + ']')
                }
                '/api/mods' {
                    # 已有 mod 列表（可以基于它改）
                    $arr = @()
                    if (Test-Path $ModDir) {
                        foreach ($f in @(Get-ChildItem $ModDir -Filter '*.mod.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                            try {
                                $one = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8)
                                $arr += ('{"file":' + (J $f.Name) + ',"json":' + (J $one) + '}')
                            } catch { }
                        }
                    }
                    Send-Json -Response $res -Json ('[' + ($arr -join ',') + ']')
                }
                '/api/checkscript' {
                    # 语法检查。手写 mod 最容易漏逗号，提前查出来比加载失败强。
                    if ($req.HttpMethod -ne 'POST') { Send-Json -Response $res -Json '{"ok":false,"msg":"只接受 POST"}' -Code 405; break }
                    $b = $null
                    try { $b = (Read-Body $req) | ConvertFrom-Json } catch { }
                    $ckType = if ($b -and $b.type) { [string]$b.type } else { 'ps1' }
                    $ckCode = if ($b -and $null -ne $b.code) { [string]$b.code } else { '' }
                    $errs = New-Object System.Collections.ArrayList
                    $ckOk = $true
                    if (-not [string]::IsNullOrWhiteSpace($ckCode)) {
                        if ($ckType -eq 'json') {
                            try { $null = ($ckCode | ConvertFrom-Json) }
                            catch {
                                $ckOk = $false
                                [void]$errs.Add('{"line":0,"col":0,"msg":' + (J ([string]$_.Exception.Message)) + '}')
                            }
                        } else {
                            $pe = $null
                            [void][System.Management.Automation.Language.Parser]::ParseInput($ckCode, [ref]$null, [ref]$pe)
                            if ($pe -and @($pe).Count -gt 0) {
                                $ckOk = $false
                                foreach ($one in @($pe)) {
                                    [void]$errs.Add('{"line":' + $one.Extent.StartLineNumber + ',"col":' + $one.Extent.StartColumnNumber + ',"msg":' + (J ([string]$one.Message)) + '}')
                                }
                            }
                        }
                    }
                    $errJson = if ($errs.Count -gt 0) { '[' + ($errs -join ',') + ']' } else { '[]' }
                    Send-Json -Response $res -Json ('{"ok":' + $(if ($ckOk) { 'true' } else { 'false' }) + ',"errors":' + $errJson + '}')
                }
                '/api/config' {
                    # 当前配置，给表单预填
                    $cfgPath = Join-Path $Root 'config.json'
                    $obj = @{}
                    if (Test-Path $cfgPath) {
                        try { $obj = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
                    }
                    $sb = New-Object System.Text.StringBuilder
                    [void]$sb.Append('{')
                    $first = $true
                    foreach ($p in $obj.PSObject.Properties) {
                        if ($p.Name -like '_*') { continue }
                        $v = $p.Value
                        $vs = if ($null -eq $v) { 'null' } elseif ($v -is [bool]) { if ($v) { 'true' } else { 'false' } } elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { [string]$v } else { J ([string]$v) }
                        if (-not $first) { [void]$sb.Append(',') }
                        [void]$sb.Append((J $p.Name) + ':' + $vs)
                        $first = $false
                    }
                    [void]$sb.Append('}')
                    Send-Json -Response $res -Json $sb.ToString()
                }
                default {
                    Send-Json -Response $res -Json '{"ok":false,"err":"not found"}' -Code 404
                }
            }
        } catch {
            try { Send-Json -Response $res -Json ('{"ok":false,"err":' + (J $_.Exception.Message) + '}') -Code 500 } catch { }
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    Write-Output "  编辑器已停止"
}
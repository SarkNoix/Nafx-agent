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
# ---- 启动日志（Write-Host 在重定向下会丢，所以直接写文件）----
$BootLog = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'logs\editor-boot.log'
function BootLog { param([string]$m) try { [IO.File]::AppendAllText($BootLog, ((Get-Date -Format 'HH:mm:ss') + ' ' + $m + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false))) } catch { } }
BootLog '脚本开始'

$HtmlPath = Join-Path $Root 'mod-editor.html'
$ModDir = Join-Path $Root 'mod'

if (-not (Test-Path $HtmlPath)) {
BootLog ("HtmlPath=" + $HtmlPath + " 存在=" + (Test-Path $HtmlPath))
    Write-Host "找不到 mod-editor.html，应该在：$HtmlPath" -ForegroundColor Red
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

function Send-Json {
    param($Response, [string]$Json, [int]$Code = 200)
    Send-Bytes -Response $Response -Bytes ([Text.Encoding]::UTF8.GetBytes($Json)) -ContentType 'application/json; charset=utf-8' -Code $Code
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
try { $listener.Start() }
catch {
    Write-Host "8070 端口起不来（可能被占用）：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ""
BootLog ("监听 " + $Port + " 成功")
Write-Host "  Nafx Mod 编辑器" -ForegroundColor Cyan
Write-Host "  http://127.0.0.1:$Port/" -ForegroundColor Green
Write-Host ""
Write-Host "  改完点「下载 mod 文件」，把下载到的 .mod.json 放进：" -ForegroundColor DarkGray
Write-Host "  $ModDir" -ForegroundColor DarkGray
Write-Host ""

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
                    # 现有工具名 + 描述，给「改工具」那块用
                    $schemaPath = Join-Path $Root 'agent\tools-schema.json'
                    $arr = @()
                    if (Test-Path $schemaPath) {
                        try {
                            $raw = [IO.File]::ReadAllText($schemaPath, [Text.Encoding]::UTF8)
                            $items = $raw | ConvertFrom-Json
                            foreach ($it in $items) {
                                $arr += ('{"name":' + (J $it.function.name) + ',"description":' + (J $it.function.description) + '}')
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
    Write-Host "  编辑器已停止" -ForegroundColor DarkGray
}
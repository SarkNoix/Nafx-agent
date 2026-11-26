# ============================================================
#  用真浏览器打开面板，把侧栏卡片的实际状态抓出来
#
#  为什么不再"读代码猜"：
#    这个问题我改了四轮，每一轮都是看着 CSS/JS 觉得对，
#    但用户看到的还是空白。说明我的判断和浏览器的实际行为不一样。
#    与其继续猜，不如让浏览器自己把真实值吐出来。
#
#  原理：
#    Edge 用 --remote-debugging-port 起一个调试端口，
#    再用 CDP（Chrome DevTools Protocol）发 Runtime.evaluate，
#    在页面里执行 JS 读取 DOM 和 getComputedStyle。
# ============================================================

param(
    [string]$Url = 'http://127.0.0.1:8090/',
    [int]$Port = 9333
)

$ErrorActionPreference = 'SilentlyContinue'
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) { Write-Host '找不到 Edge' -ForegroundColor Red; exit 1 }

# 干净的用户数据目录，避免和你正在用的浏览器打架
$userDir = Join-Path $env:TEMP ('nafx-probe-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Force -Path $userDir | Out-Null

Write-Host ''
Write-Host '  启动浏览器...' -ForegroundColor Cyan
$proc = Start-Process -FilePath $edge -ArgumentList @(
    '--headless=new',
    ('--remote-debugging-port=' + $Port),
    ('--user-data-dir=' + $userDir),
    '--no-first-run',
    '--disable-gpu',
    '--window-size=1400,900',
    $Url
) -PassThru -WindowStyle Hidden

# 等调试端口
$ok = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    try {
        $null = Invoke-WebRequest ("http://127.0.0.1:" + $Port + '/json/version') -UseBasicParsing -TimeoutSec 2
        $ok = $true
        break
    } catch { }
}
if (-not $ok) {
    Write-Host '  调试端口没起来' -ForegroundColor Red
    try { Stop-Process -Id $proc.Id -Force } catch { }
    exit 1
}
Write-Host '  已就绪' -ForegroundColor Green

# 找一个页面 target
$targets = $null
for ($i = 0; $i -lt 20; $i++) {
    try {
        $r = Invoke-WebRequest ("http://127.0.0.1:" + $Port + '/json/list') -UseBasicParsing -TimeoutSec 2
        $targets = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
        $page = @($targets | Where-Object { $_.type -eq 'page' }) | Select-Object -First 1
        if ($page) { break }
    } catch { }
    Start-Sleep -Milliseconds 500
}
if (-not $page) {
    Write-Host '  找不到页面 target' -ForegroundColor Red
    try { Stop-Process -Id $proc.Id -Force } catch { }
    exit 1
}

# ------------------------------------------------------------
#  连 WebSocket 发 CDP 命令
# ------------------------------------------------------------
Add-Type -AssemblyName System.Net.WebSockets
$ws = New-Object System.Net.WebSockets.ClientWebSocket
$ct = [Threading.CancellationToken]::None
$ws.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $ct).Wait(10000) | Out-Null

$script:msgId = 0
function Send-Cdp {
    param([string]$Method, $Params)
    $script:msgId++
    $obj = @{ id = $script:msgId; method = $Method }
    if ($Params) { $obj.params = $Params }
    $json = $obj | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object ArraySegment[byte] -ArgumentList @(,$bytes)
    $ws.SendAsync($seg, [Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).Wait(5000) | Out-Null

    # 读回结果（可能有事件消息混进来，一直读到 id 对上）
    $buf = New-Object byte[] 1048576
    for ($try = 0; $try -lt 60; $try++) {
        $sb = New-Object Text.StringBuilder
        do {
            $res = $ws.ReceiveAsync((New-Object ArraySegment[byte] -ArgumentList @(,$buf)), $ct)
            $res.Wait(15000) | Out-Null
            if ($res.Result.Count -gt 0) {
                [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $res.Result.Count))
            }
        } while (-not $res.Result.EndOfMessage)

        $text = $sb.ToString()
        if (-not $text) { continue }
        try { $o = $text | ConvertFrom-Json } catch { continue }
        if ($o.id -eq $script:msgId) { return $o }
    }
    return $null
}

function Eval-Js {
    param([string]$Expr)
    $r = Send-Cdp -Method 'Runtime.evaluate' -Params @{
        expression = $Expr
        returnByValue = $true
        awaitPromise = $true
    }
    return $r
}

Write-Host ''
Write-Host '  等页面加载...' -ForegroundColor DarkGray
Start-Sleep -Seconds 3

# ------------------------------------------------------------
#  探针：读侧栏卡片的真实状态
# ------------------------------------------------------------
$probe = @'
(function(){
  var out = { found: {}, sizes: [] };

  // 1. 建一个临时气泡，塞进各种 markdown，看渲染结果
  var host = document.createElement('div');
  host.className = 'msg assistant';
  host.id = '__probe_host';
  host.style.cssText = 'position:fixed;left:-9999px;top:0;width:700px';
  var wrap = document.createElement('div'); wrap.className = 'wrap';
  var bub = document.createElement('div'); bub.className = 'bubble';
  wrap.appendChild(bub); host.appendChild(wrap);
  document.body.appendChild(host);

  // 用页面自己的渲染函数（如果找得到）
  var md = null;
  var names = ['fmtMsg'];
  for (var i = 0; i < names.length; i++){
    try { if (typeof window[names[i]] === 'function') { md = window[names[i]]; out.found.fn = names[i]; break; } } catch(e){}
  }

  var sample = "## 大标题\n### 三级标题\n正文一行普通文字。\n\n- 列表项一\n- 列表项二\n\n**加粗** 和 `代码`";

  if (md){
    try { bub.innerHTML = md(sample); } catch(e){ out.found.err = String(e); bub.textContent = sample; }
  } else {
    bub.textContent = sample;
  }

  // 2. 量每种元素的字号
  var probe = [['h2','2级标题'],['h3','3级标题'],['h4','4级标题'],['h5','5级标题'],
               ['.md-h','md-h'],['p','正文'],['li','列表'],['strong','加粗'],['code','行内代码']];
  for (var j = 0; j < probe.length; j++){
    var el = bub.querySelector(probe[j][0]);
    if (!el) { out.sizes.push({ it: probe[j][1], sel: probe[j][0], size: '(无此元素)' }); continue; }
    var cs = getComputedStyle(el);
    out.sizes.push({
      it: probe[j][1],
      sel: probe[j][0],
      size: cs.fontSize,
      weight: cs.fontWeight,
      color: cs.color
    });
  }

  // 3. 气泡本身字号
  var bcs = getComputedStyle(bub);
  out.bubbleFont = bcs.fontSize;

  host.remove();
  return JSON.stringify(out);
})()
'@

$res = Eval-Js -Expr $probe
Write-Host ''
Write-Host '  ============ 消息渲染实测 ============' -ForegroundColor Cyan
if (-not $res -or -not $res.result -or -not $res.result.result.value) {
    Write-Host '  没拿到结果' -ForegroundColor Red
    if ($res) { Write-Host ('  raw: ' + (($res | ConvertTo-Json -Depth 5 -Compress)).Substring(0,[Math]::Min(300,($res | ConvertTo-Json -Depth 5 -Compress).Length))) -ForegroundColor DarkGray }
} else {
    $data = $res.result.result.value | ConvertFrom-Json
    Write-Host ('  找到渲染函数: ' + $(if ($data.found.fn) { $data.found.fn } else { '(没找到，用纯文本测)' })) -ForegroundColor Yellow
    Write-Host ('  气泡基础字号: ' + $data.bubbleFont) -ForegroundColor Yellow
    Write-Host ''
    foreach ($s in $data.sizes) {
        Write-Host ('  ' + $s.it.PadRight(10) + $s.sel.PadRight(10) + $s.size.PadRight(9) + 'w=' + $s.weight) -ForegroundColor $(if ($s.size -match '无此元素') { 'DarkGray' } else { 'White' })
    }
}
Write-Host ''Write-Host '  ============ 完 ============' -ForegroundColor Cyan


# ------------------------------------------------------------
#  清理
# ------------------------------------------------------------
try { $ws.Dispose() } catch { }
try { Stop-Process -Id $proc.Id -Force } catch { }
Start-Sleep -Milliseconds 500
Remove-Item $userDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host '  完成' -ForegroundColor Cyan
Write-Host ''

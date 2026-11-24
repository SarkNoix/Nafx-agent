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
  var out = { steps: [] };
  var b = document.querySelector('.side-block');
  if (!b) return JSON.stringify({ err: 'no side-block' });
  var h = b.querySelector('h3');
  var kid = null;
  for (var j = 0; j < b.children.length; j++){ if (b.children[j].tagName.toLowerCase() !== 'h3'){ kid = b.children[j]; break; } }

  function snap(tag){
    var cs = kid ? getComputedStyle(kid) : null;
    return {
      step: tag,
      closed: b.classList.contains('closed'),
      blockH: b.offsetHeight,
      kidH: kid ? kid.offsetHeight : -1,
      inlineMaxH: kid ? (kid.style.maxHeight || '(none)') : '',
      cssMaxH: cs ? cs.maxHeight : '',
      opacity: cs ? cs.opacity : '',
      titleVisible: h ? h.offsetHeight > 0 : false
    };
  }

  out.steps.push(snap('初始'));

  // 如果当前是展开的，先收起，再展开
  if (!b.classList.contains('closed')){
    h.click();
    out.steps.push(snap('点了收起（立即）'));
  }

  // 等 400ms 让过渡结束
  return new Promise(function(resolve){
    setTimeout(function(){
      out.steps.push(snap('400ms 后'));
      // 再点一次展开
      h.click();
      out.steps.push(snap('点了展开（立即）'));
      setTimeout(function(){
        out.steps.push(snap('又 400ms 后'));
        resolve(JSON.stringify(out));
      }, 400);
    }, 400);
  });
})()
'@

$res = Eval-Js -Expr $probe
Write-Host ''
Write-Host '  ============ 折叠/展开实测 ============' -ForegroundColor Cyan
if (-not $res -or -not $res.result -or -not $res.result.result.value) {
    Write-Host '  没拿到结果' -ForegroundColor Red
    if ($res) { Write-Host ('  raw: ' + ($res | ConvertTo-Json -Depth 4 -Compress)) -ForegroundColor DarkGray }
} else {
    $data = $res.result.result.value | ConvertFrom-Json
    foreach ($s in $data.steps) {
        $mark = if ($s.closed) { '[收起]' } else { '[展开]' }
        Write-Host ('  ' + $mark + ' ' + $s.step) -ForegroundColor White
        Write-Host ('      卡片高=' + $s.blockH + '  子元素高=' + $s.kidH + '  行内maxH=' + $s.inlineMaxH) -ForegroundColor DarkGray
        Write-Host ('      CSS maxH=' + $s.cssMaxH + '  opacity=' + $s.opacity + '  标题在=' + $s.titleVisible) -ForegroundColor DarkGray
        if (-not $s.closed -and [int]$s.kidH -le 0) {
            Write-Host '      >>> 展开状态但内容高度为 0！' -ForegroundColor Red
        }
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

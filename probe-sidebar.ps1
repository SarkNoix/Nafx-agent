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
  var out = { theme: document.documentElement.getAttribute('data-theme'), suspects: [], selects: [] };

  // 1. 把所有 select 都列出来，看它们在哪儿
  var sels = document.querySelectorAll('select');
  for (var i = 0; i < sels.length; i++){
    var s = sels[i];
    var cs = getComputedStyle(s);
    var r = s.getBoundingClientRect();
    out.selects.push({
      idx: i,
      parentTag: s.parentElement ? s.parentElement.tagName.toLowerCase() : '',
      parentCls: s.parentElement ? (s.parentElement.className||'').toString().slice(0,40) : '',
      id: s.id || '',
      cls: (s.className||'').toString().slice(0,30),
      rect: { top: Math.round(r.top), left: Math.round(r.left), w: Math.round(r.width), h: Math.round(r.height) },
      css: { position: cs.position, zIndex: cs.zIndex, top: cs.top, left: cs.left, display: cs.display, visibility: cs.visibility, opacity: cs.opacity }
    });
  }

  // 2. 找所有 position:fixed / absolute 且盖住左侧栏的元素
  var all = document.querySelectorAll('body *');
  for (var j = 0; j < all.length; j++){
    var e = all[j];
    var cs2 = getComputedStyle(e);
    if (cs2.position !== 'fixed' && cs2.position !== 'absolute') continue;
    if (cs2.display === 'none' || cs2.visibility === 'hidden') continue;
    var rr = e.getBoundingClientRect();
    if (rr.width < 20 || rr.height < 20) continue;
    // 只关心盖住左侧 340px 区域内的
    if (rr.left > 400 || rr.right < 0) continue;
    out.suspects.push({
      tag: e.tagName.toLowerCase(),
      cls: (e.className||'').toString().slice(0,45),
      id: e.id || '',
      rect: { top: Math.round(rr.top), left: Math.round(rr.left), w: Math.round(rr.width), h: Math.round(rr.height) },
      css: { position: cs2.position, zIndex: cs2.zIndex, display: cs2.display, opacity: cs2.opacity, pointerEvents: cs2.pointerEvents }
    });
  }
  return JSON.stringify(out);
})()
'@

$res = Eval-Js -Expr $probe
Write-Host ''
Write-Host '  ============ 所有 select 的位置 ============' -ForegroundColor Cyan
if (-not $res -or -not $res.result -or -not $res.result.result.value) {
    Write-Host '  没拿到结果' -ForegroundColor Red
} else {
    $data = $res.result.result.value | ConvertFrom-Json
    Write-Host ('  主题: ' + $data.theme) -ForegroundColor Yellow
    Write-Host ''
    foreach ($s in $data.selects) {
        Write-Host ('  select #' + $s.idx + '  id=' + $s.idx + '  class=' + $s.cls) -ForegroundColor White
        Write-Host ('    父级: ' + $s.parentTag + '.' + $s.parentCls)
        Write-Host ('    位置: top=' + $s.rect.top + ' left=' + $s.rect.left + ' w=' + $s.rect.w + ' h=' + $s.rect.h)
        Write-Host ('    样式: position=' + $s.css.position + ' zIndex=' + $s.css.zIndex + ' top=' + $s.css.top + ' left=' + $s.css.left)
    }
    Write-Host ''
    Write-Host '  ============ 左侧盖住的东西 ============' -ForegroundColor Cyan
    foreach ($s in $data.suspects) {
        Write-Host ('  ' + $s.tag + '#' + $s.id + '.' + $s.cls) -ForegroundColor Yellow
        Write-Host ('    位置: top=' + $s.rect.top + ' left=' + $s.rect.left + ' w=' + $s.rect.w + ' h=' + $s.rect.h)
        Write-Host ('    position=' + $s.css.position + ' zIndex=' + $s.css.zIndex + ' display=' + $s.css.display + ' pointerEvents=' + $s.css.pointerEvents)
    }
}
Write-Host ''
Write-Host '  ============ 点击测试 ============' -ForegroundColor Cyan
$click = @'
(function(){
  var blocks = document.querySelectorAll('.side-block');
  var b = null;
  for (var i = 0; i < blocks.length; i++){ if (blocks[i].classList.contains('closed')) { b = blocks[i]; break; } }
  if (!b) return JSON.stringify({ err: '没有折叠的卡片可测' });
  var h = b.querySelector('h3');
  var before = { closed: b.classList.contains('closed') };
  h.click();
  var kid = null;
  for (var j = 0; j < b.children.length; j++){ if (b.children[j].tagName.toLowerCase() !== 'h3') { kid = b.children[j]; break; } }
  var cs = kid ? getComputedStyle(kid) : null;
  return JSON.stringify({
    title: h.textContent.trim().slice(0,20),
    closedBefore: before.closed,
    closedAfter: b.classList.contains('closed'),
    inlineMaxH: kid ? (kid.style.maxHeight || '(无)') : '',
    cssMaxH: cs ? cs.maxHeight : '',
    cssOpacity: cs ? cs.opacity : '',
    scrollH: kid ? kid.scrollHeight : 0,
    offsetH: kid ? kid.offsetHeight : 0
  });
})()
'@
$res2 = Eval-Js -Expr $click
if ($res2 -and $res2.result -and $res2.result.result.value) {
    $c = $res2.result.result.value | ConvertFrom-Json
    Write-Host ('  点的是: ' + $c.title)
    Write-Host ('  closed: ' + $c.closedBefore + ' → ' + $c.closedAfter)
    Write-Host ('  行内maxH=' + $c.inlineMaxH + '  CSS maxH=' + $c.cssMaxH)
    Write-Host ('  opacity=' + $c.cssOpacity + '  scrollH=' + $c.scrollH + '  offsetH=' + $c.offsetH)
    $good = (-not $c.closedAfter) -and ([double]$c.cssOpacity -gt 0) -and ([int]$c.offsetH -gt 0)
    Write-Host ('  ' + $(if ($good) { '✓ 点击后正常展开' } else { '✗ 点击后仍然看不见内容' })) -ForegroundColor $(if ($good) { 'Green' } else { 'Red' })
} else {
    Write-Host '  点击测试没拿到结果' -ForegroundColor Red
}

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

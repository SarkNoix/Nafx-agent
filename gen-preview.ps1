# ============================================================
#  生成面板的「单文件预览版」
#
#  目的：不启任何服务，双击就能打开面板，看 UI / 改主题 / 验布局。
#
#  为什么需要它：
#    面板是配合 monitor.ps1 用的，36 处 API 调用全靠后端。
#    改个颜色想看一眼效果，得先确认 llama 起没起、面板起没起，
#    内存紧张时还经常起不来 —— 改个 CSS 要折腾五分钟。
#    这个脚本把数据换成模拟的，双击就开。
#
#  和真实面板的区别：
#    · 数据是假的（一段写好的模拟会话），不会更新
#    · 不能发任务、不能停止、不能改配置 —— 按钮点了没反应
#    · 主题切换、侧栏折叠、抽屉、浮窗、动画全部可用
#
#  用法：
#    powershell -ExecutionPolicy Bypass -File gen-preview.ps1
#    powershell -ExecutionPolicy Bypass -File gen-preview.ps1 -Open
# ============================================================

param(
    [string]$Source = '',
    [string]$Out    = '',
    [switch]$Open          # 生成完直接打开
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

if (-not $Source) { $Source = Join-Path $Root 'agent\dashboard.html' }
if (-not $Out)    { $Out    = Join-Path $Root 'dashboard-preview.html' }

if (-not (Test-Path $Source)) {
    Write-Host ("找不到 " + $Source) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  生成面板预览版' -ForegroundColor Cyan
Write-Host '  ----------------------------------------' -ForegroundColor DarkGray
Write-Host ('  源文件  ' + $Source) -ForegroundColor DarkGray

# ------------------------------------------------------------
#  1. 造一份模拟数据
#
#  内容要覆盖所有渲染分支，不然「看着正常」其实是没测到：
#    · 用户消息 / 助手回答 / 思考 / 进度播报 四种气泡
#    · 一个多步任务（think → list_dir → note → write_script → finish）
#    · 上下文占用有数（进度条不是空的）
#    · 侧栏工作区有文件、工具列表有内容
# ------------------------------------------------------------
$now = (Get-Date).ToString('MM-dd HH:mm:ss')
$schemaPath = Join-Path $Root 'agent\tools-schema.json'
$promptPath = Join-Path $Root 'agent\prompt.md'
$schemaRaw = if (Test-Path $schemaPath) { Get-Content $schemaPath -Raw -Encoding UTF8 } else { '[]' }
$schemaItems = $schemaRaw | ConvertFrom-Json
$toolNames = @()
foreach ($item in $schemaItems) {
    if ($item.function -and $item.function.name) { $toolNames += [string]$item.function.name }
}
$toolCount = $toolNames.Count
$toolTokens = if ($schemaRaw.Length -gt 0) { [int][Math]::Round($schemaRaw.Length / 3.5) } else { 0 }
$promptText = if (Test-Path $promptPath) { Get-Content $promptPath -Raw -Encoding UTF8 } else { '' }
$promptBytes = if (Test-Path $promptPath) { (Get-Item $promptPath).Length } else { 0 }
$promptTokens = [int][Math]::Round($promptText.Length / 2.5)

$mockSession = @'
[
  {"role":"user","content":"把 data 目录里的 jsonl 按日期分组，统计每天多少条","ts":"@TS@"},
  {"role":"assistant","kind":"think","content":"· 第1步 · 要按日期分组统计 jsonl 里每天多少条。先看 data 目录里有哪些文件，再决定用 jsonl 还是别的格式。","ts":"@TS@"},
  {"role":"assistant","kind":"say","content":"· data 目录里有 4 个文件：jsonl、orders.jsonl、ps1、smoke-test.txt。先读 orders.jsonl 看结构。","ts":"@TS@"},
  {"role":"assistant","kind":"think","content":"· 第2步 · orders.jsonl 每行有 ts 和 amount 两个字段。ts 是 ISO 格式。用 run_cmd 跑一段脚本按日期 cut 出来分组计数。","ts":"@TS@"},
  {"role":"assistant","kind":"say","content":"· 写好了 group_by_day.ps1，跑出来的结果：5-01 有 12 条，5-02 有 8 条，5-03 有 15 条，共 35 条。","ts":"@TS@"},
  {"role":"assistant","content":"统计完了。orders.jsonl 里一共 35 条记录，按日期分：\n\n· 05-01  12 条\n· 05-02   8 条\n· 05-03  15 条\n\n脚本存成了 group_by_day.ps1，以后换个文件改动里面的路径就能复用。","ts":"@TS@","files":["group_by_day.ps1","data/orders.jsonl"]}
]
'@ -replace '@TS@', $now

$mockState = @'
{
  "status":"done",
  "task":"把 data 目录里的 jsonl 按日期分组，统计每天多少条",
  "step":5,
  "maxSteps":25,
  "elapsed":163.4,
  "model":"Qwen3-4B-Instruct-2507",
  "workspace":"workspace",
  "answer":"统计完了。orders.jsonl 里一共 35 条记录，按日期分：05-01 12 条、05-02 8 条、05-03 15 条。",
  "summary":"统计完了。",
  "plan":"",
  "slot":1,
  "intent":"operate",
  "flow":"count",
  "flowName":"数数量 / 统计",
  "phase":"",
  "ctxReal":6144,
  "ctxLimit":5484,
  "ctxPrompt":1510,
  "ctxTools":1090,
  "ctxHistory":1222,
  "ctxUsed":3822,
  "steps":[
    {"n":1,"tool":"think","arg":"","ok":true,"sec":62.4,"obs":"（想法已记下）","think":"先看 data 目录里有哪些文件"},
    {"n":2,"tool":"list_dir","arg":"data","ok":true,"sec":25.7,"obs":"目录 data 的内容：\n[文件] jsonl  2.1 KB\n[文件] orders.jsonl  1.8 KB\n[文件] ps1  1.2 KB\n[文件] smoke-test.txt  0 KB\n（共 4 个文件、0 个目录）"},
    {"n":3,"tool":"note","arg":"","ok":true,"sec":3.2,"obs":"","note":"data 目录里有 4 个文件，先读 orders.jsonl"},
    {"n":4,"tool":"write_script","arg":"group_by_day.ps1","ok":true,"sec":48.9,"obs":"已写 group_by_day.ps1 并运行（退出码 0）：\n--- 输出 ---\n05-01 12\n05-02 8\n05-03 15"},
    {"n":5,"tool":"finish","arg":"","ok":true,"sec":23.2,"obs":"","note":"统计完了"}
  ]
}
'@

$mockSystem = @'
{
  "model":"Qwen3-4B-Instruct-2507",
  "modelId":"models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
  "context":6144,
  "contextWant":6144,
  "contextPerSlot":6144,
  "parallel":1,
  "slotsReady":1,
  "maxTokens":600,
  "maxSteps":25,
  "temperature":0.3,
  "workspace":"workspace",
  "allowAnyPath":true,
  "promptBytes":10107,
  "promptTokens":4043,
  "toolCount":56,
  "toolTokens":9345,
  "running":0,
  "isAdmin":true,
  "modelUp":true,
  "modelMode":"local",
  "modeLabel":"Qwen3-4B-Instruct-2507",
  "apiBase":"https://api.deepseek.com/v1",
  "apiHasKey":false
}
'@
# 预览里的系统数据跟着真实 schema / prompt 走，避免面板预览越看越旧。
$mockSystem = $mockSystem.Replace('"promptBytes":10107', ('"promptBytes":' + $promptBytes)).
                            Replace('"promptTokens":4043', ('"promptTokens":' + $promptTokens)).
                            Replace('"toolCount":56', ('"toolCount":' + $toolCount)).
                            Replace('"toolTokens":9345', ('"toolTokens":' + $toolTokens))

$mockTools = (ConvertTo-Json -InputObject @($toolNames) -Compress)

$mockFiles = @'
[{"name":"data","dir":true},{"name":"test","dir":true},
 {"name":"calc.ps1","size":232},{"name":"hello.txt","size":6},
 {"name":"big.log","size":31872},{"name":"conf.json","size":418},
 {"name":"orders.jsonl","size":1843},{"name":"staff.csv","size":518}]
'@

$mockQueue = @'
[]
'@

# ------------------------------------------------------------
#  2. 读面板，注入模拟数据 + 拦截 fetch
#
#  拦截方式：在 </head> 前插一段脚本，把 window.fetch 换掉。
#  所有 /api/* 请求直接返回模拟数据，不去碰网络 ——
#  file:// 下真实 fetch 会因跨域被浏览器拦，报一堆错误。
# ------------------------------------------------------------
$html = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8)

$inject = @"
<script>
/* ============================================================
   预览版：把 fetch 全部换成模拟数据
   
   这是 gen-preview.ps1 自动插入的，不要手动改。
   重新生成：powershell -File gen-preview.ps1
   生成时间：$now
   ============================================================ */
(function(){
  var MOCK = {
    '/api/state'   : $mockState,
    '/api/system'  : $mockSystem,
    '/api/session' : $mockSession,
    '/api/tools'   : { names: $mockTools },
    '/api/files'   : $mockFiles,
    '/api/queue'   : $mockQueue,
    '/api/autopilot': { running:false },
    '/api/history' : [],
    '/api/config'  : { ok:true },
    '/api/ask'     : { id:'', question:'' },
    '/api/mods'    : [],
    '/api/stream'  : { seq:0, items:[] }
  };

  var realFetch = window.fetch ? window.fetch.bind(window) : null;

  window.fetch = function(url, opt){
    var u = String(url);
    // 只拦截 /api/*，别的（比如内联资源）照常
    if (u.indexOf('/api/') !== 0){
      return realFetch ? realFetch(url, opt) : Promise.reject(new Error('no fetch'));
    }
    // 去掉查询串再匹配
    var key = u.split('?')[0];
    var data = MOCK.hasOwnProperty(key) ? MOCK[key] : {};
    // 模拟一点点延迟，让「加载中」的状态也能看到
    return new Promise(function(resolve){
      setTimeout(function(){
        resolve({
          ok: true,
          status: 200,
          json: function(){ return Promise.resolve(data); },
          text: function(){ return Promise.resolve(JSON.stringify(data)); }
        });
      }, 30);
    });
  };

  // 预览版顶部挂个角标，别让人把假数据当真
  window.addEventListener('DOMContentLoaded', function(){
    var tip = document.createElement('div');
    tip.textContent = '预览版 · 模拟数据';
    tip.style.cssText = 'position:fixed;left:12px;bottom:12px;z-index:9999;'
      + 'padding:5px 11px;border-radius:14px;font-size:11.5px;letter-spacing:.3px;'
      + 'background:rgba(77,107,254,.16);color:#7c93ff;border:1px solid rgba(124,147,255,.45);'
      + 'backdrop-filter:blur(8px);pointer-events:none;font-family:inherit';
    document.body.appendChild(tip);
  });
})();
</script>
"@

if ($html -notmatch '</head>') {
    Write-Host '  源文件里找不到 </head>，无法注入' -ForegroundColor Red
    exit 1
}
$html = $html.Replace('</head>', ($inject + "`r`n</head>"))

# 标题改一下，浏览器标签上能分清是预览还是真面板
$html = $html -replace '<title>[^<]*</title>', '<title>Nafx 面板 · 预览</title>'

# ------------------------------------------------------------
#  3. 写文件
# ------------------------------------------------------------
[IO.File]::WriteAllText($Out, $html, (New-Object Text.UTF8Encoding($false)))

$size = [math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Host ('  输出    ' + $Out + '  (' + $size + ' KB)') -ForegroundColor Green
Write-Host ''
Write-Host '  双击打开就能看。里面是模拟数据，不会更新。' -ForegroundColor DarkGray
Write-Host '  改完 dashboard.html 后重新跑一次这个脚本。' -ForegroundColor DarkGray
Write-Host ''

if ($Open) { Start-Process $Out }

# tools.ps1 冒烟回归：真调用每个工具，既看耗时，也断言结果对不对
# 用法：pwsh -NoProfile -File scripts\tools-smoke.ps1
# 全部通过时最后一行是 PASS，任何一项不对会列出来并以 FAIL 结尾（退出码 1）

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'agent\tools.ps1')

$tmp = Join-Path $root 'outputs' ('_smoke_' + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Set-AiRoot -Path $tmp -TimeoutSeconds 30

$res = @{}
$ms = @{}
function T([string]$name, $action) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $res[$name] = [string](Invoke-AiTool -Action $action) }
    catch { $res[$name] = 'EXCEPTION: ' + $_.Exception.Message }
    $sw.Stop()
    $ms[$name] = $sw.ElapsedMilliseconds
}

# ---------- 文件读写与编辑 ----------
T 'write_file'      @{ tool='write_file'; path='a.txt'; content="你好`nworld`n第三行" }
T 'read_file'       @{ tool='read_file'; path='a.txt' }
T 'append_file'     @{ tool='append_file'; path='a.txt'; content='追加行' }
T 'set_line'        @{ tool='set_line'; path='a.txt'; command='2'; content='WORLD' }
T 'replace_in_file' @{ tool='replace_in_file'; path='a.txt'; find='WORLD'; replace='世界' }
T 'multi_edit'      @{ tool='multi_edit'; path='a.txt'; edits=@(@{find='世界';replace='W2'},@{find='追加行';replace='附加'}) }
T 'read_lines'      @{ tool='read_lines'; path='a.txt'; command='1'; content='4' }
T 'append_again'    @{ tool='append_file'; path='a.txt'; content='L1' }
T 'append_again2'   @{ tool='append_file'; path='a.txt'; content='L2' }

# ---------- 检索与目录 ----------
T 'find_files'      @{ tool='find_files'; path='.'; command='*.txt' }
T 'list_dir'        @{ tool='list_dir'; path='.' }
T 'file_info'       @{ tool='file_info'; path='a.txt' }
T 'hash_file'       @{ tool='hash_file'; path='a.txt' }
T 'write_bracket'   @{ tool='write_file'; path='bracket.txt'; content='arr[0] = 1' }
T 'grep_bracket'    @{ tool='grep_file'; path='bracket.txt'; command='arr[0]' }
T 'make_dir'        @{ tool='make_dir'; path='sub' }
T 'copy_path'       @{ tool='copy_path'; path='a.txt'; command='sub\b.txt' }
T 'move_path'       @{ tool='move_path'; path='sub\b.txt'; command='sub\c.txt' }
T 'diff_files'      @{ tool='diff_files'; path='a.txt'; command='sub\c.txt' }

# ---------- 结构化数据 ----------
T 'write_json'      @{ tool='write_file'; path='d.json'; content='{"a":1,"b":[1,2]}' }
T 'json_format'     @{ tool='json_format'; path='d.json'; command='pretty' }
T 'write_csv'       @{ tool='write_file'; path='d.csv'; content="name,age`n甲,3`n乙,5" }
T 'csv_preview'     @{ tool='csv_preview'; path='d.csv'; command='3' }
T 'write_csvq'      @{ tool='write_file'; path='q.csv'; content='"a,b",c' + "`n" + '"甲,乙",3' }
T 'csv_quoted'      @{ tool='csv_preview'; path='q.csv'; command='2' }

# ---------- 系统信息 ----------
T 'date_calc'       @{ tool='date_calc'; command='-7' }
T 'sys_info'        @{ tool='sys_info'; command='mem' }
T 'sys_info2'       @{ tool='sys_info'; command='mem' }
T 'now'             @{ tool='now' }
T 'env_get'         @{ tool='env_get'; command='USERPROFILE' }

# ---------- 跑脚本 ----------
T 'write_ps1'       @{ tool='write_file'; path='s.ps1'; content='Write-Output ("hi " + (Get-Date -Format "HH:mm"))' }
T 'run_ps1'         @{ tool='run_ps1'; path='s.ps1' }
T 'write_args'      @{ tool='write_file'; path='args.ps1'; content='param([string]$who="?")' + "`n" + 'Write-Output "hi $who"' }
T 'run_args'        @{ tool='run_ps1'; path='args.ps1'; command='-who "今天 开会"' }
T 'run_cmd'         @{ tool='run_cmd'; command='echo hello' }
T 'run_ps_quote'    @{ tool='run_ps'; command='Write-Output ("a""b" + " - " + (1+2))' }
T 'run_ps_error'    @{ tool='run_ps'; command='Get-Item C:\definitely_not_here_xyz' }
T 'write_script_ok' @{ tool='write_script'; path='calc.ps1'; content='param([int]$a=12,[int]$b=3)' + "`n" + 'Write-Output "$a + $b = $($a+$b)"'; command='-a 12 -b 3' }
T 'write_script_q'  @{ tool='write_script'; path='args2.ps1'; content='param([string]$who="?")' + "`n" + 'Write-Output "hi $who"'; command='-who "今天 开会"' }
T 'write_script_bad' @{ tool='write_script'; path='bad.ps1'; content="Write-Output `"ok`n`$x = ; " }

# ---------- 编码 ----------
$gbk = Join-Path $tmp 'gbk.txt'
[IO.File]::WriteAllText($gbk, '中文测试GBK', [Text.Encoding]::GetEncoding(936))
T 'read_gbk'        @{ tool='read_file'; path='gbk.txt' }

# ---------- 删除（应留备份） ----------
T 'delete_path'     @{ tool='delete_path'; path='bracket.txt' }

# ---------- 大文件（走流式/预览路径） ----------
$bigLog = Join-Path $tmp 'big.log'
$sw = [IO.StreamWriter]::new($bigLog, $false, [Text.Encoding]::UTF8)
for ($i = 1; $i -le 70000; $i++) { $sw.WriteLine("line $i filler filler filler filler") }
$sw.Dispose()
T 'read_file_big'   @{ tool='read_file'; path='big.log' }
T 'read_lines_big'  @{ tool='read_lines'; path='big.log'; command='69995'; content='5' }
T 'grep_big'        @{ tool='grep_file'; path='big.log'; command='line 6999 '; content='1' }
T 'file_info_dir'   @{ tool='file_info'; path='.' }

# ---------- 目录内搜内容 / 二进制 / 误把目录当文件 ----------
T 'grep_dir'        @{ tool='grep_file'; path='.'; command='L2'; content='1'; find='*.txt' }
T 'read_as_dir'     @{ tool='read_file'; path='sub' }
$png = Join-Path $tmp 'x.png'
[IO.File]::WriteAllBytes($png, [byte[]](0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x00,0x01,0x02))
T 'read_png'        @{ tool='read_file'; path='x.png' }

# ---------- 断言 ----------
$fail = @()
function Need([string]$name, [string]$cond, [string]$desc) {
    $ok = $false
    try { $ok = [bool](Invoke-Expression ('$res[''' + $name + '''] ' + $cond)) } catch { $ok = $false }
    if (-not $ok) { $fail += ("[{0}] {1}" -f $name, $desc) }
}

Need 'read_file'      '-match ''共 3 行'''                       '行数统计应为 3 行'
Need 'read_file'      '-match ''你好'''                            '中文读取正确'
Need 'set_line'       '-match ''WORLD'''                           '整行替换'
Need 'multi_edit'     '-match ''2 处替换成功'''                     '多段替换'
Need 'grep_bracket'   '-match ''arr\[0\]'''                        '带方括号的关键词能搜到'
Need 'list_dir'       '-match ''[0-9]+ B'''                        '小文件按字节显示，不能是 0 KB'
Need 'csv_quoted'     '-match ''共 2 列'''                          '引号里的逗号不算分列'
Need 'read_gbk'       '-match ''中文测试GBK'''                      'GBK 文件能正确解码'
Need 'run_ps1'        '-notmatch ''错误：'''                        '正常脚本不应报错误'
Need 'run_args'       '-match ''hi 今天 开会'''                     '带空格的参数能完整传入'
Need 'write_script_q' '-match ''hi 今天 开会'''                     'write_script 的引号参数不拆坏'
Need 'run_ps_quote'   '-match ''a"b - 3'''                         '带引号的 run_ps 命令不被截断'
Need 'run_ps_error'   '-match ''错误：'''                           '真错误必须仍判为失败'
Need 'run_ps_error'   '-match ''找不到路径'''                       '真错误文本可读'
Need 'run_ps_error'   '-notmatch ''CLIXML'''                        '错误里不该出现 XML 外壳'
Need 'write_script_bad' '-match ''第 1 行'''                        '语法错误要指出行号'
Need 'write_script_bad' '-match ''已写入'''                         '语法错误也先落盘，别逼模型整段重写'
Need 'read_file_big'  '-match ''共 70000 行'''                      '大文件预览也要给准确行数'
Need 'read_file_big'  '-notmatch ''line 20'''                       '大文件只给开头，不该把全文塞回来'
Need 'read_lines_big' '-match ''69999: line 69999'''                '流式 read_lines 行号要对得上'
Need 'read_lines_big' '-match ''大文件流式读取'''                    '大文件该走流式，不是整读'
Need 'grep_big'       '-match ''找到 1 处''                          '流式 grep 命中数要对'
Need 'grep_big'       '-match ''> 69999: line 69999'''              '流式 grep 要标对行号'
Need 'file_info_dir'  '-match ''个文件''                             '目录体积统计要能跑完'
Need 'grep_dir'       '-match ''a.txt''                             '目录模式能跨文件搜'
Need 'grep_dir'       '-match ''> ''                                '目录模式要标行号'
Need 'read_as_dir'    '-match ''是目录，不是文件''                   '把目录当文件读要给明确提示'
Need 'read_png'       '-match ''PNG 图片''                          '二进制文件不该当文本读'

$linesAfter = (Get-Content -LiteralPath (Join-Path $tmp 'a.txt')).Count
if ($linesAfter -ne 6) { $fail += "[append_file] 结尾换行导致多空行：应为 6 行，实际 $linesAfter" }
if (-not (Test-Path -LiteralPath (Join-Path $tmp '.backup'))) { $fail += '[delete_path] 没有留备份' }
if ($ms['sys_info2'] -ge 50) { $fail += "[sys_info] 缓存没生效（第二次 $($ms['sys_info2'])ms）" }

# ---------- 报告 ----------
"{0,-18} {1,6}  {2}" -f '工具', 'ms', '结果'
foreach ($k in $res.Keys) {
    $one = ($res[$k] -replace "`r?`n", ' ⏎ ')
    if ($one.Length -gt 80) { $one = $one.Substring(0, 80) + '…' }
    "{0,-18} {1,6}  {2}" -f $k, $ms[$k], $one
}
""
"总耗时 $([math]::Round((($ms.Values | Measure-Object -Sum).Sum)/1000,2)) 秒；用例 $($res.Count) 个；断言失败 $($fail.Count) 个"
if ($fail.Count -gt 0) {
    $fail | ForEach-Object { '  ✗ ' + $_ }
    'FAIL'
    exit 1
}
'PASS'

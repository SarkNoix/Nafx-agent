# Shell & CMD 常用工具手册

Windows 上写脚本、跑命令的速查手册。**格式是给人看的，也是给 `help` 工具查的。**
不确定某条命令怎么写，先在这里查；这里没有，就用 `web_search` 上网查。

> 所有命令都在 **workspace 根目录**下执行，路径用相对路径，如 `data/orders.jsonl`。

---

## 0. 选哪套

| 场景 | 用哪个 | 为什么 |
|---|---|---|
| 数行数、求和、处理文本 | `run_cmd` + `find` / `type` | 一行搞定，快 |
| 解析 JSON、复杂逻辑 | `run_ps1` | PowerShell 有对象和管道 |
| 需要循环、变量、判断 | `run_ps1` 或 `run_bat` | 别用 `run_cmd` 硬拼 |
| 系统自带老命令（dir/copy） | `run_cmd` | 直接可用 |

---

## 0.5 想做X，该用什么（意图 → 方法）

**这是最重要的一节。** 拿到需求先在这里找，找到就直接照做，别自己从零想。

| 你想要 | 用什么 | 一句关键代码 |
|---|---|---|
| 数一个文件多少行/条 | `find /c /v ""` | `find /c /v "" data\x.txt` |
| 求和 / 合计 | `Measure-Object -Sum` | `$arr \| Measure-Object -Sum` |
| 求平均 | `Measure-Object -Average` | `$arr \| Measure-Object -Average` |
| 找重复文件（内容相同） | `Get-FileHash` + `Group-Object` | 见 2.4b |
| 按扩展名分类统计 | `Group-Object Extension` | `Get-ChildItem \| Group-Object Extension` |
| 按大小排序 | `Sort-Object Length` | `Sort-Object Length -Descending` |
| 按修改时间排序 | `Sort-Object LastWriteTime` | 加 `-Descending` 是新的在前 |
| 找出最大的 N 个文件 | 排序 + `Select-Object -First` | `Sort-Object Length -Descending \| Select-Object -First 5` |
| 批量改名 | `Rename-Item` + 循环 | `Get-ChildItem \| ForEach-Object { Rename-Item ... }` |
| 批量替换文件内容 | 读 + `-replace` + 写回 | 见 2.2 节 |
| 按日期建文件夹归类 | 按 `LastWriteTime.ToString()` 分组 | 见 2.4b 的思路 |
| 删空文件夹 | `Get-ChildItem -Directory` + 检查 Count | `Where-Object { $_.GetFiles().Count -eq 0 }` |
| 查某个词在哪些文件里 | `findstr /s /i` | `findstr /s /i "词" *.txt` |
| 比较两个文件是否一样 | `Get-FileHash` 比 Hash | 哈希相同就是一样 |
| 统计某字段总和（jsonl） | 逐行 `ConvertFrom-Json` | 见 2.4 节 |
| 转 CSV | 拼字符串 + `Set-Content` | 见 2.5 节 |
| 看进程占多少内存 | `Get-Process` | `Sort-Object WorkingSet64 -Descending` |
| 看端口被谁占了 | `Get-NetTCPConnection` | `-LocalPort 8080` |
| 解压 | `Expand-Archive` / `tar` | 见 unzip 工具 |
| 定时执行 | 任务计划 `schtasks` | `schtasks /create /tn 名字 /tr 命令 /sc daily /st 09:00` |

**找不到就 `help(command="关键词")` 再查一遍。**

---

## 1. 目录与文件（cmd）
## 1. 目录与文件（cmd）

### 1.1 列目录

```bat
dir /b                      :: 只看名字
dir /b /a                  :: 包含隐藏文件
dir /s /b                  :: 连子目录一起，只输出完整路径
dir /b /o:n                :: 按名字排序
```

> `dir /b data` 只看 data 这一层。要递归就用 `/s`。
> 任务说"列出所有文件"，要说清楚是"当前层"还是"含子目录"。

### 1.2 看文件内容

```bat
type data\orders.jsonl           :: 整个打出来
type data\orders.jsonl | more    :: 分屏（可能会卡，慎用）
findstr /n "^" data\x.txt        :: 带行号
```

### 1.3 数行数（重点）

```bat
find /c /v "" data\orders.jsonl
```

输出形如 `---------- DATA\ORDERS.JSONL: 27`，冒号后面就是行数。

> 这是统计行数最可靠的 cmd 方法。`type x | find /c ""` 也行，但空文件表现不同。
> 空文件会输出 `: 0`。

### 1.4 找文字

```bat
findstr "关键词" data\x.txt                 :: 找包含关键词的行
findstr /i "keyword" data\x.txt             :: 忽略大小写
findstr /n "关键词" data\x.txt              :: 带行号
findstr /s /i "关键词" *.txt                :: 递归所有子目录
findstr /c:"多个 词 带空格" data\x.txt       :: 精确短语
findstr /v "排除词" data\x.txt              :: 不含这个词的行
```

### 1.5 复制 / 移动 / 改名 / 删除

```bat
copy a.txt b.txt                 :: 复制
xcopy /s /i srcdir dstdir        :: 复制目录（含子目录）
move a.txt b.txt                 :: 移动或改名
ren old.txt new.txt              :: 改名（同一目录）
del temp.txt                     :: 删文件
del /q *.tmp                     :: 批量删，不确认
rd /s /q olddir                  :: 删目录
```

> 删除前务必确认路径，`rd /s /q` 不提示直接删。

### 1.6 建目录

```bat
md data\reports\weekly           :: 多层一次建好
mkdir "带 空格 的目录"
```

### 1.7 输出与重定向

```bat
echo hello                       :: 输出到屏幕
echo hello > a.txt               :: 写入（覆盖）
echo hello >> a.txt              :: 追加
echo.                            :: 输出空行
dir /b > list.txt                :: 命令结果写进文件
command 2>err.txt                :: 只收错误输出
command >out.txt 2>&1            :: 输出和错误都收
```

---

## 2. 文本处理

### 2.1 排序 / 去重

```bat
sort data\x.txt                  :: 排序
sort /r data\x.txt               :: 倒序
sort data\x.txt | find /c /v ""  :: 数排序后的行数
```

> cmd 没有原生的去重，去重要用 PowerShell：
> ```powershell
> Get-Content a.txt | Sort-Object -Unique
> ```

### 2.2 取某几行

```bat
findstr /n "^" data\x.txt | findstr /b "3:"     :: 第 3 行
```

> 取行用 cmd 很别扭，建议用 PowerShell：
> ```powershell
> Get-Content a.txt | Select-Object -Index 2       # 第 3 行（从 0 数）
> Get-Content a.txt | Select-Object -Skip 4 -First 1  # 第 5 行
> ```

### 2.3 统计某个字段的总和

cmd 做不了，用 PowerShell：

```powershell
$rows = Get-Content data\sales.csv -Encoding UTF8 | Select-Object -Skip 1
$sum = ($rows | ForEach-Object { [double](($_ -split ',')[1]) } | Measure-Object -Sum).Sum
Write-Output "总金额: $sum"
```

---

### 2.4 处理 jsonl（一行一个 JSON）

**关键**：jsonl 不能用 `ConvertFrom-Json` 整个读，会报"无效的 JSON 基元"。必须逐行处理。

```powershell
# 求和
$total = (Get-Content data/orders.jsonl -Encoding UTF8 | ForEach-Object {
    ($_ | ConvertFrom-Json).amount
} | Measure-Object -Sum).Sum
"总金额: $total"

# 筛选：只留 status=paid 的行，保持原样
Get-Content data/orders.jsonl -Encoding UTF8 | ForEach-Object {
    $o = $_ | ConvertFrom-Json
    if ($o.status -eq 'paid') { $_ }
} | Set-Content paid.jsonl -Encoding UTF8

# 分组统计：每个客户几单
Get-Content data/orders.jsonl -Encoding UTF8 | ForEach-Object {
    ($_ | ConvertFrom-Json).customer
} | Group-Object | ForEach-Object {
    "{0}: {1}" -f $_.Name, $_.Count
} | Set-Content report.txt -Encoding UTF8

# 数条数（最快，不用 PowerShell）
find /c /v "" data/orders.jsonl
```

### 2.4b 找重复文件（按内容，不看名字）

**关键**：判断"内容一样"要用哈希，不能靠读出来一个个比。

```powershell
# 找出内容重复的文件，按哈希分组
Get-ChildItem 'test' -File | Get-FileHash -Algorithm MD5 |
    Group-Object Hash |
    Where-Object { $_.Count -gt 1 } |
    ForEach-Object {
        "重复组（$($_.Count) 个）："
        $_.Group | ForEach-Object { "  " + (Split-Path $_.Path -Leaf) }
    }
```

输出像这样：

```
重复组（3 个）：
  backup.txt
  report.txt
  report_copy.txt
重复组（2 个）：
  note.md
  note_v2.md
```

**为什么不能逐个 read_file 比**：10 个文件要读 10 次，每次十几秒；
算哈希是一次性扫完，快几十倍，而且文件大了也不怕。

只按**大小相同**再比哈希更省（大小不同肯定不重复）：

```powershell
Get-ChildItem 'test' -File |
    Group-Object Length | Where-Object { $_.Count -gt 1 } |
    ForEach-Object { $_.Group | Get-FileHash -Algorithm MD5 } |
    Group-Object Hash | Where-Object { $_.Count -gt 1 }
```

### 2.5 转 CSV

```powershell
$rows = Get-Content data/items.jsonl -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json }
"name,price" | Set-Content items.csv -Encoding UTF8
$rows | ForEach-Object { "{0},{1}" -f $_.name, $_.price } | Add-Content items.csv -Encoding UTF8
```

---

## 3. PowerShell 基础

### 3.1 读文件

```powershell
Get-Content data\x.txt                              # 返回行数组
Get-Content data\x.txt -Raw                         # 整个文件当一个字符串
Get-Content data\x.txt -Encoding UTF8               # 指定编码（中文必加）
Get-Content data\x.txt -TotalCount 5                # 前 5 行
Get-Content data\x.txt -Tail 5                      # 最后 5 行
```

### 3.2 数行数

```powershell
$n = (Get-Content data\x.txt -Encoding UTF8).Count
Write-Output "行数: $n"
```

> 注意：`(Get-Content 单行文件).Count` 在只读一行时可能返回 `$null`，
> 保险写法是 `@(Get-Content ...).Count`。

### 3.3 写文件

```powershell
Set-Content a.txt '内容' -Encoding UTF8            # 覆盖
Add-Content a.txt '新的一行' -Encoding UTF8        # 追加
'内容' | Out-File a.txt -Encoding UTF8             # 另一种写法
```

### 3.4 遍历目录

```powershell
Get-ChildItem                      # 当前目录
Get-ChildItem -Recurse             # 含子目录
Get-ChildItem data -Filter *.txt   # 过滤
Get-ChildItem | ForEach-Object { Write-Output $_.Name }
Get-ChildItem | Where-Object { $_.Length -gt 1KB }
```

### 3.5 字符串处理

```powershell
$s = 'a,b,c'
$s.Split(',')                     # 切成数组
$s -replace 'a','x'               # 替换
$s.ToUpper()                      # 大写
$s.Trim()                         # 去首尾空格
$s.Contains('b')                  # 判断包含
"$s!"                             # 插值
'{0} 和 {1}' -f 'A','B'           # 格式化
```

### 3.6 读 JSON / JSONL

```powershell
# 单个 JSON 文件
$obj = Get-Content data\a.json -Raw -Encoding UTF8 | ConvertFrom-Json
$obj.name

# JSONL（每行一个 JSON）
Get-Content data\orders.jsonl -Encoding UTF8 |
    ForEach-Object { $_ | ConvertFrom-Json } |
    ForEach-Object { $_.amount }
```

### 3.7 求和 / 计数 / 平均

```powershell
(1..10 | Measure-Object -Sum).Sum          # 求和
(Get-ChildItem | Measure-Object).Count     # 计数
(1,2,3 | Measure-Object -Average).Average  # 平均
Get-ChildItem | Measure-Object Length -Sum # 目录总大小
```

### 3.8 条件与循环

```powershell
if ($n -gt 10) { Write-Output '大' } else { Write-Output '小' }
foreach ($x in 1..3) { Write-Output $x }
for ($i = 1; $i -le 3; $i++) { Write-Output $i }
while ($i -lt 5) { $i++ }
```

比较运算符：`-eq` `-ne` `-gt` `-ge` `-lt` `-le` `-like` `-match` `-contains`

### 3.9 输出

```powershell
Write-Output "结果: $x"      # 标准输出，会被捕获
Write-Host "提示"            # 直接到控制台，不会被捕获
```

> 想让脚本结果被 `run_ps1` 拿到，用 `Write-Output`。

### 3.10 报错与退出码

```powershell
Write-Error "出问题了"       # 写到错误流，会被判为失败
throw "严重错误"              # 抛异常
exit 1                        # 退出码 1
```

### 3.11 找文字

```powershell
Select-String -Path data\x.txt -Pattern '关键词'
Select-String -Path data\x.txt -Pattern '关键词' | ForEach-Object { $_.Line }
Get-ChildItem -Recurse -Include *.txt | Select-String '关键词'
```

---

## 4. 日期与时间

```powershell
Get-Date                                  # 当前时间
Get-Date -Format 'yyyy-MM-dd'             # 2026-11-06
Get-Date -Format 'yyyyMMdd_HHmmss'        # 做文件名后缀
(Get-Date).AddDays(-7)                    # 7 天前
(Get-Date) - (Get-Item a.txt).LastWriteTime   # 文件多旧了
```

cmd 里：

```bat
date /t
time /t
```

---

## 5. 环境与进程

```bat
set                                :: 所有环境变量
echo %USERNAME%                    :: 取变量
ver                                :: 系统版本
systeminfo                         :: 详细系统信息（慢）
tasklist                           :: 进程列表
tasklist | findstr /i notepad      :: 找进程
```

```powershell
$env:USERNAME
Get-Process
Get-Process | Where-Object { $_.CPU -gt 100 }
Get-Service
```

---

## 6. 常见坑

| 坑 | 现象 | 怎么办 |
|---|---|---|
| 中文乱码 | 输出变成 `锟斤拷` | PowerShell 加 `-Encoding UTF8`；bat 里先 `chcp 65001` |
| `pause` 卡死 | 进程不返回 | 脚本里绝不写 `pause` / `choice` / `Read-Host` |
| 路径有空格 | 命令报"不是内部或外部命令" | 路径加英文双引号 `"C:\my dir\x.txt"` |
| 反斜杠被转义 | `data\resources` 变成 `data<回车>esources` | 脚本里路径用正斜杠 `/` 更稳 |
| `>` 覆盖了重要文件 | 原内容没了 | 谨慎用 `>`，追加用 `>>` |
| 数字被当字符串 | `1 + 2` 得到 `12` | 强转 `[int]$a + [int]$b` |
| 单行文件 Count 为 null | `$n` 是空 | 用 `@(Get-Content ...).Count` |
| cmd 不支持中文变量名 | 报错 | 变量名用英文 |

---

## 7. 常用组合示例

### 数行数并写进文件（cmd 版）

```bat
find /c /v "" data\orders.jsonl > count.txt
type count.txt
```

### 数行数并写进文件（PowerShell 版，更干净）

```powershell
$n = @(Get-Content 'data/orders.jsonl' -Encoding UTF8).Count
Set-Content 'count.txt' "订单数：$n" -Encoding UTF8
Write-Output "订单数：$n"
```

### 统计 CSV 里某列合计

```powershell
$total = 0
foreach ($line in (Get-Content 'data/sales.csv' -Encoding UTF8 | Select-Object -Skip 1)) {
    $parts = $line.Split(',')
    $total += [double]$parts[1]
}
Write-Output "总金额: $total"
Set-Content 'total.txt' "总金额：$total" -Encoding UTF8
```

### 列出所有 .txt 并计数

```powershell
$files = Get-ChildItem -Recurse -Filter *.txt
Write-Output "共 $($files.Count) 个 txt 文件"
$files | ForEach-Object { Write-Output $_.FullName }
```

### 找出最大的 5 个文件

```powershell
Get-ChildItem -Recurse -File |
    Sort-Object Length -Descending |
    Select-Object -First 5 Name, Length
```

### 批量改名（加前缀）

```powershell
Get-ChildItem *.txt | Rename-Item -NewName { 'bak_' + $_.Name }
```

### 检查某文件是否存在

```powershell
if (Test-Path 'data/x.txt') { Write-Output '存在' } else { Write-Output '不存在' }
```

```bat
if exist data\x.txt (echo 存在) else (echo 不存在)
```

---

## 8. 管道与过滤（最常用）

PowerShell 的管道是最强的工具，记住这几个动词：

| 动词 | 作用 | 例子 |
|---|---|---|
| `Where-Object` | 筛选（where） | 名字含 test 的文件 |
| `Select-Object` | 取前几个/某几列 | 前 5 个、只看名字 |
| `Sort-Object` | 排序 | 按大小倒序 |
| `ForEach-Object` | 逐个处理 | 每个加前缀 |
| `Measure-Object` | 计数/求和/平均 | 统计总大小 |
| `Group-Object` | 分组计数 | 按扩展名分组 |

```powershell
# 名字含 test 的
Get-ChildItem | Where-Object { $_.Name -like '*test*' }

# 最大的 5 个
Get-ChildItem -Recurse -File | Sort-Object Length -Descending | Select-Object -First 5 Name, Length

# 只看名字
Get-ChildItem | Select-Object -ExpandProperty Name

# 每个文件加前缀
Get-ChildItem *.txt | ForEach-Object { Rename-Item $_.Name ('new_' + $_.Name) }

# 统计总大小
(Get-ChildItem -Recurse -File | Measure-Object Length -Sum).Sum

# 按扩展名分组数
Get-ChildItem | Group-Object Extension | Select-Object Name, Count

# 排除某类
Get-ChildItem | Where-Object { $_.Extension -notin @('.log','.tmp') }
```

cmd 里的对应（能力弱很多，能不用就不用）：

```bat
dir /b *.txt                            :: 只看名字
dir /s /b | findstr /i "test"           :: 路径含 test
dir /o-s /b                             :: 按大小从小到大
```

---

## 9. 服务、进程、计划任务

```bat
:: 进程
tasklist                                :: 全部进程
tasklist /fi "imagename eq notepad.exe" :: 按名字找
taskkill /f /im notepad.exe             :: 强杀
taskkill /f /pid 1234                   :: 按 PID 杀

:: 服务
sc query                                :: 所有服务
sc query spooler                        :: 查某个服务
sc stop spooler                         :: 停止
sc start spooler                        :: 启动
net start                               :: 已启动的服务列表
net start <服务名>                       :: 启动
net stop <服务名>                        :: 停止

:: 计划任务
schtasks /query /fo LIST                :: 列出
schtasks /create /tn "我的任务" /tr "notepad.exe" /sc daily /st 09:00
schtasks /delete /tn "我的任务" /f
```

```powershell
Get-Process | Sort-Object CPU -Descending | Select-Object -First 5 Name, CPU, WS
Get-Service | Where-Object Status -eq 'Running'
Stop-Process -Name notepad -Force
Restart-Service -Name spooler
Get-ScheduledTask | Where-Object State -eq 'Ready'
```

---

## 10. 网络

```bat
ipconfig                                :: IP 配置
ipconfig /all                           :: 详细（含 MAC、DNS）
ipconfig /flushdns                      :: 清 DNS 缓存
ping 127.0.0.1                          :: 连通性
ping -n 4 example.com                   :: ping 4 次（不是 -c！）
netstat -ano                            :: 端口占用（PID 在最后一列）
netstat -ano | findstr :8090            :: 查 8090 谁占着
curl http://example.com                 :: Win10 自带 curl
curl -o out.html http://example.com     :: 下载
```

```powershell
Test-NetConnection example.com -Port 443   :: 测端口通不通
Invoke-WebRequest http://example.com -UseBasicParsing   :: 抓网页
Invoke-RestMethod https://api.github.com  :: 抓 JSON（自动解析，国内可能连不上）
(Test-Connection -Count 2 -Quiet example.com)           :: 通不通（True/False）
```

---

## 11. 压缩与解压

```powershell
# 压缩
Compress-Archive -Path 'data' -DestinationPath 'data.zip' -Force
Compress-Archive -Path 'a.txt','b.txt' -DestinationPath 'two.zip'

# 解压
Expand-Archive -Path 'data.zip' -DestinationPath 'out' -Force

# 列出压缩包内容
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::OpenRead('data.zip').Entries | Select-Object FullName, Length
```

```bat
:: 7z 如果装了
7z a out.zip data\          :: 压缩
7z x data.zip -oout         :: 解压
```

---

## 12. 文件属性与权限

```bat
attrib                                  :: 看属性
attrib +r x.txt                         :: 只读
attrib -r x.txt                         :: 去只读
attrib +h x.txt                         :: 隐藏
attrib -r -h x.txt                      :: 全去掉
icacls x.txt                            :: 看权限
icacls x.txt /grant "%USERNAME%:(F)"    :: 给自己完全控制
takeown /f x.txt                        :: 接管所有者
```

```powershell
(Get-Item x.txt).Attributes             :: 看属性
Set-ItemProperty x.txt -Name IsReadOnly -Value $true
Get-Acl x.txt | Format-List
```

> 权限类操作容易失败（需要管理员），失败就如实收尾，不要反复试。

---

## 13. 编码（中文乱码的头号来源）

| 文件类型 | 写的时候 | 为什么 |
|---|---|---|
| `.ps1` | **UTF-8 带 BOM** | PS 5.1 读无 BOM 会按 GBK 解，中文全乱 |
| `.bat` | **UTF-8 不带 BOM + 首行 chcp 65001** | cmd 把 BOM 当第一行内容 |
| `.txt` / `.md` / `.json` | UTF-8 不带 BOM | 通用 |

```powershell
# 读文件时明确编码
Get-Content 'x.txt' -Encoding UTF8
Get-Content 'x.txt' -Encoding Default      # 系统 ANSI（中文为 GBK）

# 写文件时明确编码
Set-Content 'x.txt' '内容' -Encoding UTF8
Out-File 'x.txt' -Encoding UTF8

# 转换编码（GBK 存的文件转 UTF-8）
$gbk = [Text.Encoding]::GetEncoding(936)
$txt = [IO.File]::ReadAllText('x.txt', $gbk)
[IO.File]::WriteAllText('x.txt', $txt, (New-Object Text.UTF8Encoding($false)))
```

```bat
chcp                                    :: 看当前代码页（中文系统默认 936）
chcp 65001                              :: 切 UTF-8
chcp 936                                :: 切回 GBK
```

---

## 14. 命令行参数与环境变量

```bat
set                                     :: 所有环境变量
set PATH                                :: 看某个
set MYVAR=hello                         :: 设置（本窗口有效）
%USERPROFILE%                           :: 用户目录
%TEMP%                                  :: 临时目录
%USERNAME%                              :: 用户名
%~dp0                                   :: 当前 bat 所在目录（带尾斜杠）
%~nx0                                   :: 当前 bat 的文件名
%1 %2                                   :: 第一、第二个参数
set /a result=1+2                       :: 算术
if "%1"=="" echo 没给参数               :: 判断参数
```

```powershell
$env:PATH                                # 看
$env:USERPROFILE                         # 用户目录
$env:TEMP                                # 临时目录
$x = 'hello'                             # 设变量（不用 set）
"值：$x"                                  # 插值
$PSScriptRoot                             # 脚本所在目录
$args[0]                                  # 第一个参数
```

---

## 15. 指定参数与常用开关速查

```bat
:: 这些是最容易记错的
xcopy src dst /E /I /Y                  :: 复制目录（/E 含空目录 /I 目标当目录 /Y 不问）
robocopy src dst /E /MIR                :: 镜像同步（会删多余文件，慎用）
move src dst                            :: 移动/改名
ren old.txt new.txt                     :: 改名（不能跨目录）
copy /b a+b c                           :: 二进制合并
type x.txt > y.txt                      :: 复制内容
echo. > x.txt                           :: 建空文件
type nul > x.txt                        :: 同上
copy nul x.txt                          :: 同上
```

> `copy con x.txt` 会卡住等输入，**不要用**。

---

## 16. 一次跑多条

```bat
echo 第一 && echo 第二                  :: 都执行
echo 第一 & echo 第二                   :: 都执行（不管成败）
echo 第一 || echo 第二                  :: 前面失败才执行后面
cmd1 & cmd2                             :: 顺序执行
start notepad.exe                       :: 后台开，不阻塞
start "" /wait notepad.exe              :: 等它关掉再继续
```

```powershell
Get-Process; Get-Date                   # 分号分隔
cmd1 -and cmd2                          # 逻辑
```

---

## 17. 不确定怎么办

按这个顺序，**从便宜到贵**：

1. **`syshelp(command="命令名")`** —— 查本机自带帮助，最准最快
   - `syshelp(command="find")` → cmd 的 find 完整参数
   - `syshelp(command="Get-ChildItem")` → PS 命令的语法签名
   - 这条**优先用**，不联网也不会过时

2. **`help(command="关键词")`** —— 查这本手册 + 工具手册 + 错误处理手册
   - `help(command="压缩")`、`help(command="编码")`、`help(command="进程")`

3. **`win_doc(command="命令名")`** —— 查微软官方文档
   - 只在 syshelp 和 help 都查不到时用

4. **`web_search(command="PowerShell 读 CSV 求和 官方文档")`** —— 上网搜
   - **只信这些站点**：learn.microsoft.com、docs.microsoft.com、stackoverflow.com、superusers.com
   - 看到 Linux 用法（ls、grep、chmod、apt）立刻换，那不是 Windows
   - 搜到后照抄，不要凭印象拼

5. 实在不行 → `say` 问用户，或者如实收尾说做不到

**写完跑一次再说"完成"**。命令能跑通才算会。
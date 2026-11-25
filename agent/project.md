## 写脚本：先跑通，再完善

只写 `.ps1`（需要 `.py`/`.js` 时才写别的）。一行一句，别写 `pause` / `Read-Host`（会卡住）。
**写完必须用真参数跑一遍**：测试要真调你的逻辑，`"=$(12+3)"` 是假测试；输出为空、出现「错误」都算没做完。
数字参数写类型 `param([int]$a)`；带参数跑传 `command="-a 12 -b 3"`。

**字符串里的换行**：PowerShell 用反引号加 n（`` `n ``），不要把 Markdown 的三重反引号写进代码；
多行文本用 here-string（`@'` 开头、单独一行 `'@` 结尾），否则字符串闭合不了、整段 ParserError。

**一个脚本只能有一个 `param()` 块**：多个参数合成一行
`param([string]$date = (Get-Date -Format 'yyyy-MM-dd'), [string]$entry = '')`；
第二行 `param` 会被当成命令执行。小工具先写短的（20 行内），一个入口、一个数据文件。

**写文件用 `Set-Content -Path` / `Add-Content -Path`**；`Out-File` 的参数叫 `-FilePath`，写 `-Path` 会报参数不存在。

## 「写个工具」就是写脚本，不是手动干活

用户说「写个工具 / 做个脚本 / 搞个程序」，意思是产出一个**能反复跑的 `.ps1`**，
不是让你自己一个个文件手动处理。

| 别这样 | 这样 |
|---|---|
| 7 个文件 read_file 七次 | 写个脚本一次处理完 |
| 手动比较、自己记结果 | 让脚本输出结果 |
| 处理完就完了 | 脚本留在那儿，以后还能用 |

手动做 10 次 = 10 步 + 每步十几秒；写脚本 3 步搞定还能复用。
任务里出现「工具」「脚本」「批量」「自动」，就一定要产出 `.ps1`。

**动手前先想有没有现成办法**：「找重复文件」「按日期归类」「批量改名」这类，
先 `help(command="重复文件")` / `help(command="批量")` 查配方，比硬想省十几步。

## 写小项目

流程：`plan` 列步骤 → `write_script` 写 → `run_ps1` 用真实参数跑 → 报错 `replace_in_file` 改那一行 → 跑通 `finish`。

```powershell
# 第一行：这脚本干什么、怎么用
param(<参数，带类型和默认值>)
<主体逻辑>
try/catch 把错误兜住，给人话提示
<输出结果>
```

要点：`param()` 带类型和默认值；主体用 `switch` / `if` / 循环写清；出错 `throw '中文提示'`；
**最后一定要有输出**，让人看出结果对不对；**按任务写，别照抄模板**。

## 做项目：先想清楚，再动手

让你「做个 X」，别马上写代码，先回答四个问题：

1. **谁用、干嘛用**——决定做多复杂，自己偶尔用的不要搞配置文件那套
2. **输入什么、出什么**——中间那段就是要写的
3. **会出什么岔子**——空的、错的、重名、被占用、没权限
4. **哪块核心、哪块能砍**——先做能跑的最小版

想完再 `plan`。**能跑的小东西 > 功能多但跑不起来的大东西**。做完一块立刻验证，通过再加下一块。

**需求太虚就问**：「做个管理系统」没信息量，用 `say` 问：管什么数据？给谁用？存哪？
但「模糊」不等于「什么都不做」：用户只说方向时（比如「弄个简单的小工具，帮我记每天的事，能翻历史」），
自己在 `plan` 第一行写张目标卡（谁用、最小输入→输出、最小验收），选最小版本做出来，把假设写进 README 和答复。
只有删除/覆盖别人文件、花钱、登录外部账号这类不可逆的事才停下来问。**别用「你想要什么」把问题原样推回去。**

记录类小工具可直接套这个骨架：

```powershell
param([string]$Entry = '', [switch]$List)
$log = Join-Path $PSScriptRoot 'daily.log'
if ($List) { Get-Content $log -Encoding UTF8; return }
if (-not $Entry) { Write-Host '用法：.\daily.ps1 -Entry "今天做了什么"，或 -List 查看'; exit 1 }
Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Entry) -Encoding UTF8
Write-Host "已记录：$Entry"
```

README 三行：用途、`.\daily.ps1 -Entry "..."`、`.\daily.ps1 -List`。
`write_script` 的 `content` 放**纯代码**，不要用 Markdown 的 ``` 包起来。

**结果不对先怀疑逻辑，别重跑**：判断条件对吗？数据结构对吗？拿小例子手算该出几个。同一个脚本原样重跑结果不会变。

## 多步任务：计划里要带方法

第一步 `plan`，每步写清用什么命令/函数，不能只写「做什么」。

| 差 | 好 |
|---|---|
| 统计文件数量 | 用 `Get-ChildItem` + `Group-Object Extension` |
| 找重复文件 | `Get-FileHash` + `Group-Object` |
| 生成报告 | 拼字符串，`Set-Content` 写 report.txt |

写不出方法就先查 `help(command="找重复文件")` / `help(command="统计")`。列完照自己的方法做，别中途改主意。

## jsonl 这类文件

一行一个 JSON，不能整个 `ConvertFrom-Json`。逐行处理：

```powershell
$total = (Get-Content x.jsonl -Encoding UTF8 | ForEach-Object { ($_ | ConvertFrom-Json).amount } | Measure-Object -Sum).Sum
```

数条数最快：`run_cmd(command="find /c /v "" x.jsonl")`。

## 文件类型与运行

多文件先 `file_editor(action="view", paths=[...])`（带行号、类型、运行提示）；查后缀 `file_editor(action="types", find=".py")`。

- **可直接跑**：`.ps1` `.bat` `.cmd` `.py` `.js` `.mjs` `.cjs` `.sh` `.exe`
- **不可执行**：`.json` `.jsonl` `.csv` `.md` `.txt`（`.json` 可 `file_editor run` 做合法性校验）
- **`.html`**：浏览器打开或本地服务
- **二进制**：`.zip` `.7z` `.rar` 用 `unzip` / `zip_list`；`.pdf` `.docx` `.xlsx` `.png` 用专用工具
- **要编译器**：`.java` `.c` `.cpp` `.go` `.rs`，没装就先 `install` 或直说跑不了

运行前检查 `param()` / 参数，退出码 0 不代表结果正确。

## Git 与提交

只在用户要求版本管理/提交/推送时用。`git(action="status")` → `diff` → `add`（只加任务相关文件）→ `commit`（说明写清改了什么）。
`pull` 只 `--ff-only`；`push` 不带 force；不 `reset --hard` / `clean -f` / `rebase`。
Nafx 源码目录本身不是 Git 仓库；推送克隆在 `E:\_nafx_push`。

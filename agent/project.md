## 写脚本

只写 `.ps1`。一行一句。别写 pause / Read-Host（会卡住）。

```powershell
$n = @(Get-Content 'x.txt' -Encoding UTF8).Count    # 数行数
```

**写完必须用真参数跑一遍**：测试要真调你的逻辑（`"=$(12+3)"` 是假测试）；
输出有「错误」或是空的都算没做对；运算符就用 `+ - * /`；
数字参数写类型 `param([int]$a)`；带参数跑传 `command="-a 12 -b 3"`；
改错用 `read_file` 看 → `replace_in_file` 改，别原样重写。

**字符串里的换行**：PowerShell 用反引号加 n（`` `n ``），**不要**把 Markdown 的三重反引号写进代码；
多行文本用 here-string（`@'` 开头、单独一行 `'@` 结尾），否则字符串会闭合不了、整段脚本 ParserError。

**一个脚本只能有一个 `param()` 块**：两个参数就合到一行
`param([string]$date = (Get-Date -Format 'yyyy-MM-dd'), [string]$entry = '')`；
不要写两行 `param`，第二行会被当成命令执行。小工具先做短脚本（20 行内），一个入口、一个数据文件。

**写文件用 `Set-Content -Path` / `Add-Content -Path`**；`Out-File` 的参数叫 `-FilePath`，写 `-Path` 会报参数不存在。

## "写个工具"就是写脚本，不是手动干活

用户说"写个工具""做个脚本""搞个程序"，**意思是产出一个能反复跑的 .ps1 文件**，
不是让你自己一个一个手动处理。

| 别这样 | 这样 |
|---|---|
| 有 7 个文件就 read_file 七次 | 写个脚本一次处理完 |
| 手动比较、自己记结果 | 让脚本输出结果 |
| 处理完就完了 | 脚本留在那儿，以后还能用 |

**手动做 10 次 = 10 步 + 每步十几秒**，写脚本 3 步搞定，还能重复用。

判断标准：如果任务里出现"工具""脚本""批量""自动"，那就一定要 `write_file` 产出一个 .ps1。

**动手前想一下有没有现成办法**：
"找重复文件""按日期归类""批量改名"这类活儿，手册里多半有配方。
先 `help(command="重复文件")` 或 `help(command="批量")` 查一下，
比自己硬想强——省下的不是几秒，是十几步。

## 写小项目

流程：`plan` 列步骤 → `write_file` 写脚本 → `run_ps1` 跑一遍验证 → 报错就 `replace_in_file` 改 → 跑通了 `finish`。

**脚本骨架**（照这个结构搭，具体实现自己想）：

```powershell
# 第一行注释：这脚本干什么、怎么用
param(<参数，带类型和默认值>)
<主体逻辑>
try/catch 把错误兜住，给人话提示
<输出结果>
```

要点：
- `param()` 里声明参数，能加 `[ValidateSet()]` 限制取值范围
- 主体用 `switch` / `if` / 循环把逻辑写清
- 出错时 `throw '中文提示'`，外层 `catch` 接住
- 最后一定要有输出，让人看到结果
- **不要用 `Read-Host`**，会卡住等输入

**按任务需要写，不要照抄现成模板。**

## 做项目：先想清楚，再动手

让你"做个 X"，**别马上写代码**。先回答四个问题：

1. **谁用、干嘛用**？—— 决定做多复杂。自己偶尔用的，别搞配置文件那套
2. **输入什么、出什么**？—— 这两者之间那段就是要写的
3. **会出什么岔子**？—— 空的、错的、重名的、被占用的、没权限的
4. **哪块是核心、哪块能砍**？—— 先做能跑的最小版

想完再 `plan`，一步步写。**别怕功能少** —— 能跑的小东西比功能多但跑不起来的大东西强。
做完一块立刻验证，通过再加下一块。

**需求不清楚就问**：「做个管理系统」这种话没信息量，别猜。用 `say` 问：管什么数据？给谁用？存哪？

**但“模糊”不等于“什么都不做”**：真实用户经常只说方向，比如“弄个简单的小工具，帮我记每天的事，能翻历史就行”。这时先在脑子里（或 `plan` 第一行）写一张 3 行目标卡：

- 谁用、解决什么：自己每天记一条，之后能翻看
- 最小输入 → 输出：一条文本 → 追加保存 → 列表展示
- 最小验收：入口能跑、数据能留下来、有一行用法说明

能合理默认就直接选一个最小版本做出来，把假设写进 README 和最终答复；只有删除/覆盖别人文件、花钱、登录外部账号这类不可逆的事才停下来问。**不要用“你想要什么”把问题原样推回去。**

**最小项目模板（日志/记录类可直接套，别自己发明命令）**：

```powershell
param([string]$Entry = '', [switch]$List)
$log = Join-Path $PSScriptRoot 'daily.log'
if ($List) { Get-Content $log -Encoding UTF8; return }
if (-not $Entry) { Write-Host '用法：.\daily.ps1 -Entry "今天做了什么"，或 -List 查看'; exit 1 }
Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), $Entry) -Encoding UTF8
Write-Host "已记录：$Entry"
```

配套 README 只写三行：用途、`.\daily.ps1 -Entry "..."`、`.\daily.ps1 -List`。
`write_script` 的 `content` 里放**纯代码**，不要用 Markdown 的 ``` 包脚本。

**结果不对先怀疑逻辑，别重跑**：判断条件写对了吗？数据结构对吗？拿个小例子手算该出几个。
**同一个脚本原样重跑，结果不会变。**

## 多步任务先列清单，而且要列出"用什么方法"

第一步永远是 `plan`。**每一步要写清用什么命令/函数**，不能只写"做什么"。

| 差（只说做什么） | 好（带了方法） |
|---|---|
| · 统计文件数量 | · 用 `Get-ChildItem` + `Group-Object Extension` 统计 |
| · 找出重复文件 | · 用 `Get-FileHash` 算哈希 + `Group-Object` 分组 |
| · 分析数据 | · 逐行 `ConvertFrom-Json`，`Measure-Object -Sum` 求和 |
| · 生成报告 | · 拼字符串，`Set-Content` 写进 report.txt |

**写不出方法就先查**：`help(command="找重复文件")`、`help(command="统计")`。
手册第 0.5 节有一张"想做 X 该用什么"的对照表，先去那儿找。

列出方法之后，照着自己写的方法做，别中途改主意。

## 处理 jsonl 这类文件

一行一个 JSON，不能用 `ConvertFrom-Json` 整个读。要么逐行处理，要么先用 `help(command="jsonl")` 查配方。

```powershell
# 数条数（最快）
run_cmd(command="find /c /v "" 某个文件.jsonl")

# 求和
$total = (Get-Content 某个文件.jsonl -Encoding UTF8 | ForEach-Object {
    ($_ | ConvertFrom-Json).amount
} | Measure-Object -Sum).Sum
```

## 文件类型与运行

多文件先 `file_editor(action="view", paths=[...])`；它会带行号、类型、编辑和运行提示。查后缀用 `file_editor(action="types", find=".py")`。

| 后缀 | 是什么 | 编辑 | 运行 |
|---|---|---|---|
| `.ps1` | PowerShell 脚本 | UTF-8 建议 BOM，优先 `write_script` | `file_editor run` / `run_ps1`；有 `param()` 必须传参 |
| `.bat` `.cmd` | CMD 批处理 | UTF-8 无 BOM，中文首行 `chcp 65001` | `file_editor run` / `run_bat` |
| `.py` | Python | UTF-8，注意缩进和依赖 | `file_editor run`（`python -u`） |
| `.js` `.mjs` `.cjs` | JavaScript | UTF-8；区分 Node 与浏览器 | `file_editor run`（Node）；WSH 用 `run_js` |
| `.sh` | Shell | UTF-8，LF 换行 | `file_editor run`（Git Bash） |
| `.exe` | 可执行程序 | 二进制，不能文本改 | `file_editor run`，参数放 `command` |
| `.json` | JSON 数据 | UTF-8，不能加注释 | 不可执行；`file_editor run` 做合法性校验 |
| `.jsonl` `.csv` | 数据文件 | 保留一行一条 / 表头 | 不可执行；用技能或表格工具 |
| `.md` `.txt` | 文本/文档 | UTF-8，保留换行 | 不可执行 |
| `.html` | 页面 | UTF-8，标签闭合 | 浏览器打开或本地 HTTP 服务 |
| `.zip` `.7z` `.rar` | 压缩包 | 二进制，不能文本改 | `unzip` / `zip_list` |
| `.pdf` `.docx` `.xlsx` `.png` | 文档/图片 | 二进制，不能文本改 | 对应专用工具 |

**规则**：多文件替换用 `file_editor(action="replace", paths=[...])`；二进制、Office/PDF/图片不要当文本改；编译型（`.java/.c/.cpp/.go/.rs`）本机没编译器就先 `install` 或直说跑不了；运行脚本前检查参数，退出码 0 不代表结果正确。

## Git 与提交

- 先 `git(action="status", path="仓库")`，再 `git(action="diff", path="仓库")`；确认改了什么再动手。
- 只暂存任务相关文件：`git(action="add", path="仓库", files="a.py;README.md")`；不要无脑 `add .`。
- 提交：`git(action="commit", path="仓库", message="feat: 说明改了什么")`；提交说明要写动机和结果。
- `pull` 只做 `--ff-only`；`push` 不带 force；不 `reset --hard` / `clean -f` / `rebase`。
- Nafx 源码目录本身不是 Git 仓库；需要推送用 `E:\_nafx_push` 这个克隆，先 status 看差异。

# Nafx 插件（mod）系统

一个 mod 就是一个 `.mod.json` 文件，放在这个目录（`mod/`）下。
**不用改任何源码，不用重启模型**——agent 下次运行时自动加载。

想卸载？删掉文件就行。

---

## 怎么做一个 mod

### 方式一：用编辑器（推荐）

```
双击 run-mod-editor.bat
或：powershell -File mod-editor.ps1
```

浏览器打开 `http://127.0.0.1:8070`，左边填、右边看预览，改完点右上角
**「下载 mod 文件」**，浏览器会存一个 `xxx.mod.json`，把它拖进这个目录即可。

### 方式二：手写

复制下面这个骨架，改内容，存成 `我的mod.mod.json`：

```json
{
  "id": "my-mod",
  "name": "我的插件",
  "version": "1.0",
  "enabled": true
}
```

---

## 能干哪四件事

### ① 改 Nafx 的配置

```json
"config": {
  "temperature": 0.1,
  "maxSteps": 40,
  "personalPrompt": "我是学生，解释要简单"
}
```

| 字段 | 立即生效？ | 说明 |
|---|---|---|
| `temperature` | ✅ | 越低越稳，干活用 0.1-0.4 |
| `maxSteps` | ✅ | 最多几步，复杂任务调高 |
| `maxTokens` | ✅ | 每次最多生成多少 token |
| `personalPrompt` | ✅ | 你的个人习惯，会拼进提示词 |
| `context` | ❌ 要重启模型 | 上下文窗口 |
| `threads` | ❌ 要重启模型 | CPU 线程数 |

### ② 改工具

```json
"tools": {
  "write_file": { "enabled": false },
  "run_cmd": { "description": "跑 Windows 命令。跑之前先说清楚要跑什么" }
}
```

- `enabled: false` → 这个 mod 里禁用该工具
- `description` → 换掉工具说明（模型看到的就是这句）

**改描述很有用**：模型对工具说明的依赖比你想的严重，换个说法就能改行为。

### ③ 加人设 / 规则

```json
"prompt": "你是我的编程助手。改代码前先读清楚现有内容，不许凭印象改。"
```

这段会追加到系统提示词末尾。写「你是谁、怎么说话、什么必须做、什么不许做」。

### ④ 加 md 文档

```json
"docs": [
  { "name": "命名规范", "content": "变量用驼峰，函数动词开头。" }
]
```

每份文档会跟着人设一起发给模型。适合放规范、术语表、项目背景。

### ⑤ 加载时跑脚本（可选）

```json
"script": "$env:MY_MODE = 'coder'; Write-Host '已切换'"
```

PowerShell 脚本，agent 每次启动跑一次。能改环境变量、写文件、做初始化。

---

## 现成的两个例子

目录里已经有：

| 文件 | 干什么 | 默认状态 |
|---|---|---|
| `coder-mode.mod.json` | 程序员模式：低温、多步、改前先读 | **停用** |
| `brief-mode.mod.json` | 极简模式：回答一句话 | **停用** |

**默认都是停用的**（`enabled: false`）。想用就把 `false` 改成 `true`。

---

## 多个 mod 会叠加

按**文件名排序**加载，后面的覆盖前面的。

```
a.mod.json   config.temperature = 0.5
b.mod.json   config.temperature = 0.1   ← 最终是 0.1
```

**人设和文档是全叠加的**（不会互相覆盖）。

---

## 加载时看什么

agent 启动时会打印：

```
[mod] 配置 coder-mode.temperature
已加载 2 个 mod：程序员模式、极简模式
[mod] coder-mode 改描述 run_cmd
[mod] 追加人设/文档 312 字符
[mod] coder-mode 脚本执行完成
```

日志在 `agent/logs/run_*.txt`。

---

## 常见问题

**改了没反应？**
1. 文件是不是 `.mod.json` 结尾（不是 `.json`）
2. `enabled` 是不是 `true`
3. 文件是不是放在 `mod/` 目录（不是子目录）
4. 看 agent 日志里有没有 `[mod]` 开头的行

**JSON 报错？**
用编辑器做，它生成的 JSON 一定合法。手写容易漏逗号。

**改了 context 没生效？**
`context` / `threads` 是模型启动参数，要重启模型（`重启.bat` 或重新双击 `Nafx.bat`）。

**mod 会不会有安全问题？**
`script` 字段是**真的执行 PowerShell**，权限和 agent 一样。别加载来路不明的 mod。

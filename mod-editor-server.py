#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Nafx Mod 编辑器服务（Python 版）

为什么有这一份：
  PowerShell 版（mod-editor.ps1）在「没有控制台」的进程里会卡住——
  Write-Host 跟着 $ErrorActionPreference='Stop' 会静默退出，实测
  用 Start-Process / start /b 起的进程连脚本第一行都跑不到。
  双击 bat 是有控制台的，但那样必须留一个黑窗口。

  这一份不依赖控制台，可以在后台安静地跑。

用法：
  python mod-editor-server.py            # 默认 8070
  python mod-editor-server.py 8071       # 换端口

接口和 PowerShell 版完全一致，前端不用改。
"""

import json
import os
import sys
import subprocess
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PORT = 8070

# ---------------- 工具分组 ----------------
GROUPS = {
    '文件': ['file_editor','write_file','read_file','list_dir','hash_file','read_lines','zip_list',
             'diff_files','replace_in_file','set_line','append_file','make_dir',
             'find_files','file_info','move_path','copy_path','grep_file','delete_path'],
    '执行': ['run_cmd','run_ps','run_ps1','run_bat','run_js','run_python','write_script'],
    '系统': ['sys_info','clipboard','env_get','open_app','kill_process','ps','install'],
    '网络': ['download_file','web_search','web_fetch'],
    '数据': ['json_format','csv_preview'],
    '查询': ['now','date_calc','unit_convert','project_doc','help','syshelp','win_doc'],
    '流程': ['say','rethink','plan','learn','finish'],
    '技能': ['skill','write_skill','unzip'],
    '版本': ['git'],
}
NAME_TO_GROUP = {}
for g, names in GROUPS.items():
    for n in names:
        NAME_TO_GROUP[n] = g


def read_text(path):
    with open(path, 'r', encoding='utf-8-sig') as f:
        return f.read()


def api_config():
    """当前配置。跳过 _ 开头的说明字段。"""
    p = os.path.join(ROOT, 'config.json')
    if not os.path.exists(p):
        return {}
    try:
        cfg = json.loads(read_text(p))
    except Exception:
        return {}
    return {k: v for k, v in cfg.items() if not k.startswith('_')}


def api_tools():
    """工具名 + 描述 + 分组"""
    p = os.path.join(ROOT, 'agent', 'tools-schema.json')
    if not os.path.exists(p):
        return []
    try:
        arr = json.loads(read_text(p))
    except Exception:
        return []
    out = []
    for item in arr:
        fn = item.get('function') or {}
        name = fn.get('name')
        if not name:
            continue
        out.append({
            'name': name,
            'description': fn.get('description', ''),
            'group': NAME_TO_GROUP.get(name, '其他'),
        })
    return out


def api_mods():
    """已有 mod 的元数据（不含完整内容）"""
    d = os.path.join(ROOT, 'mod')
    if not os.path.isdir(d):
        return []
    out = []
    for fn in sorted(os.listdir(d)):
        if not fn.endswith('.mod.json'):
            continue
        fp = os.path.join(d, fn)
        try:
            m = json.loads(read_text(fp))
        except Exception:
            continue
        out.append({
            'file': fn,
            'id': m.get('id', ''),
            'name': m.get('name', ''),
            'version': m.get('version', ''),
            'enabled': m.get('enabled', True) is not False,
            'hasPrompt': bool(m.get('prompt')),
            'docCount': len(m.get('docs') or []),
            'toolCount': len(m.get('tools') or {}),
            'cfgCount': len(m.get('config') or {}),
            'json': read_text(fp),      # 方便「载入已有」直接用
        })
    return out


def api_checkscript(code, kind):
    """语法检查。ps1 走 PowerShell 的 Parser，json 直接 json.loads。"""
    if not code or not code.strip():
        return {'ok': True, 'errors': []}

    if kind == 'json':
        try:
            json.loads(code)
            return {'ok': True, 'errors': []}
        except Exception as e:
            return {'ok': False, 'errors': [{'line': 0, 'col': 0, 'msg': str(e)}]}

    # PowerShell 语法检查：用一个临时脚本走 Parser
    tmp = os.path.join(ROOT, 'logs', '_check_tmp.ps1')
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    try:
        with open(tmp, 'w', encoding='utf-8-sig') as f:
            f.write(code)
        ps = ('[Console]::OutputEncoding=[Text.Encoding]::UTF8;'
              '$e=$null;'
              '$t=$null;'
              '[void][System.Management.Automation.Language.Parser]::ParseFile('
              "'" + tmp.replace("'", "''") + "', [ref]$t, [ref]$e);"
              'if(-not $e -or $e.Count -eq 0){ "OK" } else {'
              ' foreach($x in $e){ '
              '  "{0}`t{1}`t{2}" -f $x.Extent.StartLineNumber, $x.Extent.StartColumnNumber, $x.Message '
              ' } }')
        r = subprocess.run(
            ['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps],
            capture_output=True, text=True, timeout=20,
            encoding='utf-8', errors='replace')
        out = (r.stdout or '').strip()
        if out == 'OK' or out == '':
            return {'ok': True, 'errors': []}
        errs = []
        for line in out.splitlines():
            parts = line.split('\t')
            if len(parts) >= 3:
                try:
                    ln = int(parts[0])
                except Exception:
                    ln = 0
                try:
                    col = int(parts[1])
                except Exception:
                    col = 0
                errs.append({'line': ln, 'col': col, 'msg': parts[2]})
        return {'ok': False, 'errors': errs}
    except subprocess.TimeoutExpired:
        return {'ok': False, 'errors': [{'line': 0, 'col': 0, 'msg': '检查超时'}]}
    except Exception as e:
        return {'ok': False, 'errors': [{'line': 0, 'col': 0, 'msg': str(e)}]}
    finally:
        try:
            if os.path.exists(tmp):
                os.remove(tmp)
        except Exception:
            pass


class Handler(BaseHTTPRequestHandler):
    server_version = 'NafxModEditor/1.0'

    def log_message(self, fmt, *args):
        # 安静点，别刷屏
        pass

    def _send(self, code, body, ctype):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        try:
            self.wfile.write(body)
        except Exception:
            pass

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj, ensure_ascii=False), 'application/json; charset=utf-8')

    def do_GET(self):
        path = self.path.split('?')[0]

        if path in ('/', '/index.html'):
            p = os.path.join(ROOT, 'mod-editor.html')
            if not os.path.exists(p):
                self._send(500, '找不到 mod-editor.html', 'text/plain; charset=utf-8')
                return
            self._send(200, read_text(p), 'text/html; charset=utf-8')
            return

        if path == '/api/config':
            self._json(api_config())
            return

        if path == '/api/tools':
            self._json(api_tools())
            return

        if path == '/api/mods':
            self._json(api_mods())
            return

        if path == '/health':
            self._json({'ok': True, 'service': 'mod-editor'})
            return

        self._json({'ok': False, 'err': 'not found'}, 404)

    def do_POST(self):
        path = self.path.split('?')[0]
        try:
            n = int(self.headers.get('Content-Length') or 0)
            raw = self.rfile.read(n) if n else b''
            body = json.loads(raw.decode('utf-8')) if raw else {}
        except Exception:
            body = {}

        if path == '/api/checkscript':
            code = body.get('code') or ''
            kind = body.get('type') or 'ps1'
            self._json(api_checkscript(code, kind))
            return

        self._json({'ok': False, 'err': 'not found'}, 404)


def main():
    port = DEFAULT_PORT
    if len(sys.argv) > 1:
        try:
            port = int(sys.argv[1])
        except Exception:
            pass

    srv = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print('  Nafx Mod 编辑器服务(Python)')
    print('  http://127.0.0.1:%d/' % port)
    print('  改完点「下载 mod 文件」，放进 %s' % os.path.join(ROOT, 'mod'))
    print('  Ctrl+C 停止')
    print('')
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('\n  已停止')
    finally:
        srv.server_close()


if __name__ == '__main__':
    main()

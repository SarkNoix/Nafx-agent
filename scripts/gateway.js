/*
 * Nafx 入口网关（负载均衡 + 监控 + 异常处理）
 *
 *   80  ──┬─ /api/*、/、静态资源  → 8090（面板 monitor.ps1）
 *         └─ /v1/*、/health、/props、/slots、/metrics … → 8080（llama-server）
 *
 * 为什么不是"轮询两台一样的服务器"：8090 和 8080 是两个不同角色，
 * 轮流丢只会把请求送给不会处理的对方。所以这里做的是**按路径分流的
 * 前置网关**，再加上每个后端各自的并发闸门（自适应限流）、健康检查、
 * 队列、熔断和请求级日志 —— 这才是这套架构里"均衡负载"该有的样子。
 *
 * 实时调整：
 *   · 每个后端维护 EWMA 延迟 + 错误率 + 在途请求数
 *   · 延迟变慢 → 并发上限乘以 0.7（最低 2）；恢复变快 → 每 10 秒 +1（封顶）
 *   · 错误率 > 35% → 熔断 20 秒，期间直接 503（不把坏请求继续压给后端）
 *
 * 异常处理：后端没起 / 连接被拒 → 502 + 中文提示；超时 → 504；
 * 队列排太久 → 503；客户端提前断开 → 中止上游请求，不泄漏连接。
 *
 * 用法：
 *   node scripts/gateway.js                 # 监听 0.0.0.0:80
 *   node scripts/gateway.js --port 8088     # 换端口调试
 *   node scripts/gateway.js --dry           # 只打印路由表，不监听
 *
 * 常用接口（仅本机可访问）：
 *   GET /__gateway/health   存活
 *   GET /__gateway/stats    实时指标（JSON）
 */

'use strict';

const http = require('http');
const https = require('https');
const net = require('net');
const fs = require('fs');
const path = require('path');
const os = require('os');

// ---------------- 参数 ----------------

function argOf(name, def) {
  const i = process.argv.indexOf('--' + name);
  if (i >= 0 && i + 1 < process.argv.length) return process.argv[i + 1];
  return def;
}

const ROOT = path.resolve(__dirname, '..');
const LOG_DIR = path.join(ROOT, 'logs');
const LOG_FILE = path.join(LOG_DIR, 'gateway.jsonl');
const STATS_FILE = path.join(LOG_DIR, 'gateway-stats.json');
const LOG_MAX_BYTES = 8 * 1024 * 1024;

const CONFIG = {
  port: parseInt(argOf('port', process.env.NFX_GATEWAY_PORT || '80'), 10),
  bind: argOf('bind', '0.0.0.0'),
  dry: process.argv.includes('--dry'),
  panel: { host: '127.0.0.1', port: 8090, limit: 24, max: 24, slowMs: 700, ewmAlpha: 0.3 },
  model: { host: '127.0.0.1', port: 8080, limit: 6, max: 6, slowMs: 2500, ewmAlpha: 0.2 },
  queueMax: 40,
  queueWaitMs: { panel: 8000, model: 20000 },
  proxyTimeoutMs: { panel: 30000, model: 120000 },
  healthIntervalMs: 5000,
  sampleIntervalMs: 10000,
  breakerMs: 20000,
  breakerErrorRate: 0.35,
  slowRatioDown: 1.5,
  slowRatioUp: 0.6,
};

// 模型到底在哪：config.json 的 modelMode 说了算
//   local → 本地 llama-server（config.host:config.port，默认 8080）
//   api   → 外部接口（config.apiBase，比如 https://open.bigmodel.cn/api/paas/v4）
// 不跟着配置走的话，API 模式下网关会一直对着一个根本没起的 8080 探活。
const CFG_FILE = path.join(ROOT, 'config.json');
const KEY_FILE = path.join(ROOT, 'api-key.json');

const runtime = {
  mode: 'local',
  label: '',
  apiKey: '',
  model: { protocol: 'http', host: '127.0.0.1', port: 8080, basePath: '', origin: 'http://127.0.0.1:8080' },
  loadedAt: 0,
};

function loadRuntime() {
  let cfg = null;
  try { cfg = JSON.parse(fs.readFileSync(CFG_FILE, 'utf8')); } catch { }
  if (!cfg) return false;

  const mode = String(cfg.modelMode || 'local').toLowerCase() === 'api' ? 'api' : 'local';
  const prevOrigin = runtime.model.origin;
  runtime.mode = mode;

  if (mode === 'api' && cfg.apiBase) {
    let u = null;
    try { u = new URL(String(cfg.apiBase).trim()); } catch { }
    if (u) {
      runtime.model = {
        protocol: u.protocol.replace(':', '') || 'https',
        host: u.hostname,
        port: parseInt(u.port || (u.protocol === 'https:' ? '443' : '80'), 10),
        basePath: u.pathname.replace(/\/+$/, ''),
        origin: u.origin,
      };
      runtime.label = String(cfg.apiModel || 'api');
    }
  } else {
    const h = String(cfg.host || '127.0.0.1');
    const p = parseInt(cfg.port || 8080, 10);
    runtime.model = { protocol: 'http', host: h, port: p, basePath: '', origin: 'http://' + h + ':' + p };
    runtime.label = String(cfg.modelLabel || 'local');
  }

  // api-key.json 里带 # 注释（和 agent 的 Read-JsonFile 一个风格），
  // 直接 JSON.parse 会失败，得先把注释行去掉。
  try {
    const raw = fs.readFileSync(KEY_FILE, 'utf8');
    const clean = raw.split(/\r?\n/).filter((l) => !l.trimStart().startsWith('#')).join('\n');
    const kj = JSON.parse(clean);
    runtime.apiKey = String(kj.apiKey || '').trim();
  } catch { runtime.apiKey = ''; }

  runtime.loadedAt = Date.now();
  if (runtime.model.origin !== prevOrigin) {
    logLine({ t: nowStr(), ev: 'model-target', mode: runtime.mode, target: runtime.model.origin, label: runtime.label });
  }
  return true;
}

// 路由：谁该接这个请求
function pickBackend(pathname) {
  if (runtime.mode === 'api') {
    // 接口模式没有 /props /slots /metrics 这些 llama 专有端点，
    // 只把 /v1/* 送出去，其余交给面板（面板自己有 404）。
    return (pathname === '/v1' || pathname.startsWith('/v1/')) ? 'model' : 'panel';
  }
  for (const p of MODEL_PREFIXES) {
    if (pathname === p || pathname.startsWith(p)) return 'model';
  }
  if (MODEL_EXACT.includes(pathname)) return 'model';
  return 'panel';
}

// ---------------- 后端状态 ----------------

function mkBackend(name, cfg) {
  return {
    name,
    host: cfg.host,
    port: cfg.port,
    limit: cfg.limit,
    max: cfg.max,
    slowMs: cfg.slowMs,
    alpha: cfg.ewmAlpha,
    inflight: 0,
    ewmaMs: null,
    windowReq: 0,
    windowErr: 0,
    totalReq: 0,
    totalErr: 0,
    bytesIn: 0,
    bytesOut: 0,
    alive: false,
    lastCheckAt: 0,
    breakerUntil: 0,
    lastError: '',
    queue: [],
  };
}

const BACKENDS = {
  panel: mkBackend('panel', CONFIG.panel),
  model: mkBackend('model', CONFIG.model),
};

// ---------------- 日志 ----------------

function ensureDir(p) {
  try { fs.mkdirSync(p, { recursive: true }); } catch { }
}

function rotateIfNeeded(file) {
  try {
    const st = fs.statSync(file);
    if (st.size > LOG_MAX_BYTES) {
      fs.renameSync(file, file + '.1');
    }
  } catch { }
}

function logLine(obj) {
  const line = JSON.stringify(obj);
  ensureDir(LOG_DIR);
  rotateIfNeeded(LOG_FILE);
  fs.appendFile(LOG_FILE, line + '\n', () => { });
  if (process.env.NFX_GATEWAY_ECHO === '1') console.log(line);
}

// ---------------- 自适应限流 ----------------

function currentLimit(b) {
  return Math.max(1, b.limit);
}

function noteLatency(b, ms) {
  b.ewmaMs = b.ewmaMs === null ? ms : (b.ewmaMs * (1 - b.alpha) + ms * b.alpha);
}

function noteResult(b, ok) {
  b.windowReq++;
  b.totalReq++;
  if (!ok) { b.windowErr++; b.totalErr++; }
}

function adapt() {
  for (const b of Object.values(BACKENDS)) {
    const errRate = b.windowReq > 0 ? b.windowErr / b.windowReq : 0;
    const floor = Math.max(2, Math.floor(b.max * 0.15));
    if (errRate >= CONFIG.breakerErrorRate && b.windowReq >= 5) {
      b.breakerUntil = Date.now() + CONFIG.breakerMs;
      b.limit = 1;
      b.healthyStreak = 0;
      logLine({ t: nowStr(), ev: 'breaker', backend: b.name, errRate: round(errRate, 3), ms: CONFIG.breakerMs });
    } else if (b.ewmaMs !== null && b.ewmaMs > b.slowMs * CONFIG.slowRatioDown) {
      b.healthyStreak = 0;
      const next = Math.max(floor, Math.floor(b.limit * 0.7));
      if (next !== b.limit) {
        logLine({ t: nowStr(), ev: 'limit-down', backend: b.name, from: b.limit, to: next, ewma: Math.round(b.ewmaMs) });
        b.limit = next;
      }
    } else if (b.ewmaMs !== null && b.ewmaMs < b.slowMs * CONFIG.slowRatioUp) {
      // 恢复用乘法：之前每次只 +1，降到 2 之后要爬 4 分钟才回得去，
      // 这 4 分钟里所有请求都在排队，等于自己把自己限死。现在连续 2 个
      // 采样都健康就 ×1.5，约 1 分钟回到上限。
      b.healthyStreak = (b.healthyStreak || 0) + 1;
      if (b.healthyStreak >= 2 && b.limit < b.max) {
        const next = Math.min(b.max, Math.ceil(b.limit * 1.5));
        logLine({ t: nowStr(), ev: 'limit-up', backend: b.name, from: b.limit, to: next, ewma: Math.round(b.ewmaMs) });
        b.limit = next;
      }
    } else {
      b.healthyStreak = 0;
    }
    b.windowReq = 0;
    b.windowErr = 0;
  }
}

// ---------------- 健康检查 ----------------

function checkPanel(b) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: b.host, port: b.port });
    let done = false;
    const finish = (ok) => {
      if (done) return;
      done = true;
      try { sock.destroy(); } catch { }
      resolve(ok);
    };
    sock.setTimeout(1500);
    sock.once('connect', () => finish(true));
    sock.once('timeout', () => finish(false));
    sock.once('error', () => finish(false));
  });
}

function checkModel(b) {
  return new Promise((resolve) => {
    const m = runtime.model;
    const mod = m.protocol === 'https' ? https : http;
    // 接口模式探 apiBase 的 /models：401/403 也说明网络通了，只有连不上或 5xx 才算挂
    const probePath = runtime.mode === 'api'
      ? (m.basePath + '/models')
      : '/health';
    const headers = {};
    if (runtime.mode === 'api' && runtime.apiKey) headers.Authorization = 'Bearer ' + runtime.apiKey;
    const req = mod.request({
      host: m.host, port: m.port, path: probePath, method: 'GET', timeout: 3000,
      headers, servername: m.protocol === 'https' ? m.host : undefined,
    }, (res) => {
      res.resume();
      resolve(res.statusCode < 500);
    });
    req.on('timeout', () => { req.destroy(); resolve(false); });
    req.on('error', () => resolve(false));
    req.end();
  });
}

async function healthLoop() {
  loadRuntime(); // 跟着 config.json 走：面板里切 local/api，这里 30 秒内自动跟过去
  if (runtime.mode === 'local') {
    BACKENDS.model.host = runtime.model.host;
    BACKENDS.model.port = runtime.model.port;
  }
  for (const b of Object.values(BACKENDS)) {
    const was = b.alive;
    b.alive = b.name === 'panel' ? await checkPanel(b) : await checkModel(b);
    b.lastCheckAt = Date.now();
    if (was !== b.alive) {
      logLine({ t: nowStr(), ev: b.alive ? 'backend-up' : 'backend-down', backend: b.name, mode: runtime.mode });
    }
    if (!b.alive) drainQueue(b, 'backend_down');
  }
}

// ---------------- 队列 ----------------

function drainQueue(b, reason) {
  while (b.queue.length) {
    const item = b.queue.shift();
    replyError(item.res, 503, b.name, reason, '后端当前不可用');
  }
}

function enqueue(b, item) {
  if (b.queue.length >= CONFIG.queueMax) {
    replyError(item.res, 503, b.name, 'queue_full', '排队的人太多了，稍后再试');
    return false;
  }
  item.queuedAt = Date.now();
  b.queue.push(item);
  const waited = Date.now() - item.queuedAt;
  const maxWait = CONFIG.queueWaitMs[b.name];
  const timer = setTimeout(() => {
    const i = b.queue.indexOf(item);
    if (i >= 0) {
      b.queue.splice(i, 1);
      replyError(item.res, 503, b.name, 'queue_timeout', '等了 ' + Math.round(maxWait / 1000) + ' 秒还没轮到');
    }
  }, Math.max(0, maxWait - waited));
  if (timer.unref) timer.unref();
  item.queueTimer = timer;
  return true;
}

function pumpQueue(b) {
  while (b.queue.length && b.inflight < currentLimit(b) && Date.now() >= b.breakerUntil) {
    const item = b.queue.shift();
    clearTimeout(item.queueTimer);
    forward(item, b);
  }
}

// ---------------- 响应工具 ----------------

function round(n, d = 1) {
  const f = Math.pow(10, d);
  return Math.round(n * f) / f;
}

function nowStr() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

function replyJson(res, code, obj) {
  if (res.headersSent) { try { res.destroy(); } catch { } return; }
  const body = Buffer.from(JSON.stringify(obj), 'utf8');
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function replyError(res, code, backend, reason, hint) {
  replyJson(res, code, {
    ok: false,
    error: reason,
    backend,
    hint,
    where: 'nafx-gateway',
    at: nowStr(),
  });
}

// ---------------- 转发 ----------------

const HOP_HEADERS = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade',
]);

function cleanHeaders(raw) {
  const out = {};
  for (const [k, v] of Object.entries(raw)) {
    if (!HOP_HEADERS.has(k.toLowerCase())) out[k] = v;
  }
  return out;
}

function targetPathFor(b, req) {
  if (b.name !== 'model' || runtime.mode !== 'api') return req.url;
  // 接口模式下把 /v1/xxx 换成 apiBase + /xxx：
  // apiBase = https://open.bigmodel.cn/api/paas/v4 时，
  // /v1/chat/completions → /api/paas/v4/chat/completions
  const q = req.url.indexOf('?');
  const p = q >= 0 ? req.url.slice(0, q) : req.url;
  const s = q >= 0 ? req.url.slice(q) : '';
  let rel = p.replace(/^\/v1/, '');
  if (!rel) rel = '';
  return runtime.model.basePath + rel + s;
}

function isLoopback(req) {
  const ra = req.socket.remoteAddress || '';
  return ra === '127.0.0.1' || ra === '::1' || ra === '::ffff:127.0.0.1';
}

function forward(item, b) {
  const { req, res, pathname } = item;
  const t0 = Date.now();
  const startedInflight = b.inflight;

  const m = b.name === 'model' ? runtime.model : null;
  const mod = (m && m.protocol === 'https') ? https : http;
  const headers = cleanHeaders(req.headers);
  delete headers.host;
  if (m) headers.host = m.port === 443 || m.port === 80 ? m.host : (m.host + ':' + m.port);
  // 接口模式下，本机来的请求如果没带 key，就用 api-key.json 里的那把补上
  // （浏览器直接打开 80 端口就能试模型）。局域网来的请求不代付，得自己带 key。
  if (m && runtime.mode === 'api' && runtime.apiKey && !headers.authorization && isLoopback(req)) {
    headers.authorization = 'Bearer ' + runtime.apiKey;
  }

  const proxyReq = mod.request({
    host: m ? m.host : b.host,
    port: m ? m.port : b.port,
    method: req.method,
    path: targetPathFor(b, req),
    headers,
    agent: false,
    servername: (m && m.protocol === 'https') ? m.host : undefined,
  });

  b.inflight++;
  let finished = false;

  const done = (ok, code, bytesOut) => {
    if (finished) return;
    finished = true;
    b.inflight = Math.max(0, b.inflight - 1);
    const ms = Date.now() - t0;
    noteResult(b, ok);
    noteLatency(b, ms);
    if (ok) b.bytesOut += bytesOut || 0;
    logLine({
      t: nowStr(),
      ev: 'req',
      backend: b.name,
      m: req.method,
      path: pathname,
      code,
      ms,
      out: bytesOut || 0,
      queued: item.queuedAt ? 0 : 1,
      inflight: startedInflight,
      limit: currentLimit(b),
    });
    pumpQueue(b);
  };

  proxyReq.on('response', (proxyRes) => {
    const code = proxyRes.statusCode || 502;
    // SSE / 流式：不能加 Content-Length，也不能攒着——直接边收边发
    const outHeaders = cleanHeaders(proxyRes.headers);
    if (proxyRes.headers['content-type'] === undefined) { /* 交给后端语义 */ }
    res.writeHead(code, outHeaders);
    let bytes = 0;
    proxyRes.on('data', (chunk) => {
      bytes += chunk.length;
      b.bytesIn += chunk.length;
      if (!res.write(chunk)) proxyRes.pause();
    });
    res.on('drain', () => proxyRes.resume());
    proxyRes.on('end', () => { res.end(); done(code < 500, code, bytes); });
    proxyRes.on('aborted', () => { try { res.destroy(); } catch { } done(false, 499, bytes); });
    proxyRes.on('error', () => { try { res.destroy(); } catch { } done(false, 502, bytes); });
  });

  proxyReq.on('error', (err) => {
    const msg = String(err && err.message || err);
    b.lastError = msg;
    if (!res.headersSent) {
      replyError(res, 502, b.name, 'backend_unreachable',
        b.name === 'panel' ? '面板没起来？看门狗会每 10 秒拉一次，也可以手动跑 launcher.ps1' :
          '模型服务没起来（llama-server 没在 8080），面板里点「启动模型」');
    } else {
      try { res.destroy(); } catch { }
    }
    done(false, 502, 0);
  });

  // 后端长时间没响应（流式也不算，流式有自己的 data 事件续命）
  const timeoutMs = CONFIG.proxyTimeoutMs[b.name];
  let idleTimer = setTimeout(() => {
    proxyReq.destroy(new Error('gateway timeout'));
  }, timeoutMs);
  proxyReq.on('response', () => { clearTimeout(idleTimer); });
  const bump = () => {
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => proxyReq.destroy(new Error('gateway idle timeout')), timeoutMs);
  };
  proxyReq.on('socket', (s) => { s.on('data', bump); });

  req.on('aborted', () => { try { proxyReq.destroy(); } catch { } });
  req.on('error', () => { try { proxyReq.destroy(); } catch { } });

  if (req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS') {
    proxyReq.end();
  } else {
    req.pipe(proxyReq);
  }
}

// ---------------- 主处理 ----------------

const T0 = Date.now();
const lastSample = { at: Date.now(), req: 0 };

function handle(req, res) {
  const url = req.url || '/';
  const pathname = url.split('?')[0];

  // 管理接口：只允许本机
  if (pathname === '/__gateway/health' || pathname === '/__gateway/stats') {
    const ra = req.socket.remoteAddress || '';
    const local = ra === '127.0.0.1' || ra === '::1' || ra === '::ffff:127.0.0.1';
    if (!local) { replyJson(res, 403, { ok: false, error: 'loopback_only' }); return; }
    if (pathname === '/__gateway/health') {
      replyJson(res, 200, { ok: true, uptimeSec: Math.round(process.uptime()) });
      return;
    }
    replyJson(res, 200, statsSnapshot());
    return;
  }

  // 接口模式下没有 llama 的 /health，这里就地回一份网关+后端的聚合状态
  if (pathname === '/health' && runtime.mode === 'api') {
    const b = BACKENDS.model;
    replyJson(res, 200, {
      ok: true,
      gateway: { port: CONFIG.port, uptimeSec: Math.round(process.uptime()) },
      model: {
        mode: 'api',
        model: runtime.label,
        target: runtime.model.origin,
        alive: b.alive,
        inflight: b.inflight,
        limit: currentLimit(b),
        ewmaMs: b.ewmaMs === null ? null : Math.round(b.ewmaMs),
        lastError: b.lastError,
      },
      panel: { alive: BACKENDS.panel.alive, target: BACKENDS.panel.host + ':' + BACKENDS.panel.port },
    });
    return;
  }

  const b = BACKENDS[pickBackend(pathname)];
  const item = { req, res, pathname };

  if (req.headers.upgrade) {
    replyError(res, 426, b.name, 'upgrade_unsupported', '这个网关暂时不转发 WebSocket，面板用的是轮询/短连接');
    return;
  }

  if (Date.now() < b.breakerUntil) {
    replyError(res, 503, b.name, 'breaker_open', '后端刚连续出错，熔断 ' + Math.round(CONFIG.breakerMs / 1000) + ' 秒');
    return;
  }

  if (b.inflight >= currentLimit(b)) {
    enqueue(b, item);
    return;
  }

  forward(item, b);
}

function statsSnapshot() {
  const out = {
    ok: true,
    gateway: {
      port: CONFIG.port,
      uptimeSec: Math.round((Date.now() - T0) / 1000),
      now: nowStr(),
    },
    host: {
      freeMB: round(os.freemem() / 1048576, 0),
      totalMB: round(os.totalmem() / 1048576, 0),
      load1: round(os.loadavg()[0], 2),
    },
    modelMode: runtime.mode,
    modelLabel: runtime.label,
    backends: {},
  };
  for (const b of Object.values(BACKENDS)) {
    out.backends[b.name] = {
      alive: b.alive,
      inflight: b.inflight,
      queued: b.queue.length,
      limit: currentLimit(b),
      max: b.max,
      ewmaMs: b.ewmaMs === null ? null : Math.round(b.ewmaMs),
      slowMs: b.slowMs,
      totalReq: b.totalReq,
      totalErr: b.totalErr,
      errRate: b.totalReq ? round(b.totalErr / b.totalReq, 3) : 0,
      bytesIn: b.bytesIn,
      bytesOut: b.bytesOut,
      breaker: Date.now() < b.breakerUntil,
      lastError: b.lastError,
      target: b.name === 'model' ? runtime.model.origin : (b.host + ':' + b.port),
      model: b.name === 'model' ? runtime.label : undefined,
    };
  }
  return out;
}

function sampleLoop() {
  const snap = statsSnapshot();
  snap.window = {
    sec: Math.round((Date.now() - lastSample.at) / 1000),
    req: lastSample.req,
    rpm: Math.round(lastSample.req / Math.max(1, (Date.now() - lastSample.at) / 60000)),
  };
  lastSample.at = Date.now();
  lastSample.req = 0;
  ensureDir(LOG_DIR);
  try {
    const tmp = STATS_FILE + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(snap));
    fs.renameSync(tmp, STATS_FILE);
  } catch { }
}

// ---------------- 启动 ----------------

if (CONFIG.dry) {
  loadRuntime();
  console.log('路由（' + runtime.mode + ' 模式）：');
  if (runtime.mode === 'api') {
    console.log('  /v1/* → ' + runtime.model.origin + runtime.model.basePath + '（模型接口：' + runtime.label + '）');
    console.log('  /、/api/*、静态 → ' + CONFIG.panel.host + ':' + CONFIG.panel.port + '（面板）');
    console.log('  /health → 网关就地返回聚合状态');
  } else {
    console.log('  /v1/*, /health, /props, /slots, /metrics → ' + runtime.model.host + ':' + runtime.model.port + '（本地 llama）');
    console.log('  其余 → ' + CONFIG.panel.host + ':' + CONFIG.panel.port + '（面板）');
  }
  process.exit(0);
}

const server = http.createServer((req, res) => {
  lastSample.req++;
  try {
    handle(req, res);
  } catch (e) {
    replyError(res, 500, 'gateway', 'gateway_internal', String(e && e.message || e));
  }
});

server.keepAliveTimeout = 60 * 1000;
server.headersTimeout = 15 * 1000;

server.on('upgrade', (req, socket) => {
  try {
    socket.write('HTTP/1.1 426 Upgrade Required\r\nContent-Type: application/json; charset=utf-8\r\nConnection: close\r\n\r\n' +
      JSON.stringify({ ok: false, error: 'upgrade_unsupported' }));
  } catch { }
  socket.destroy();
});

server.on('clientError', (err, socket) => {
  try { socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); } catch { }
});

server.on('error', (err) => {
  if (err.code === 'EACCES') {
    console.error('端口 ' + CONFIG.port + ' 需要管理员权限（<1024 是系统端口），用管理员 PowerShell 跑 gateway.ps1');
  } else if (err.code === 'EADDRINUSE') {
    console.error('端口 ' + CONFIG.port + ' 已被占用，先查是谁：Get-NetTCPConnection -LocalPort ' + CONFIG.port);
  } else {
    console.error('监听失败：' + err.message);
  }
  process.exit(1);
});

server.listen(CONFIG.port, CONFIG.bind, () => {
  ensureDir(LOG_DIR);
  loadRuntime();
  logLine({
    t: nowStr(), ev: 'start', port: CONFIG.port, bind: CONFIG.bind, pid: process.pid,
    modelMode: runtime.mode, modelTarget: runtime.model.origin, model: runtime.label,
  });
  console.log('Nafx 网关已启动：http://127.0.0.1:' + CONFIG.port + '  pid=' + process.pid);
  if (runtime.mode === 'api') {
    console.log('  面板 → ' + CONFIG.panel.host + ':' + CONFIG.panel.port + ' ；模型接口 → ' + runtime.model.origin + '（' + runtime.label + '）');
  } else {
    console.log('  面板 → ' + CONFIG.panel.host + ':' + CONFIG.panel.port + ' ；本地模型 → ' + runtime.model.origin);
  }
  console.log('  指标 → /__gateway/stats');
  healthLoop().catch(() => { });
  setInterval(() => { healthLoop().catch(() => { }); }, CONFIG.healthIntervalMs).unref();
  setInterval(adapt, CONFIG.sampleIntervalMs).unref();
  setInterval(sampleLoop, CONFIG.sampleIntervalMs).unref();
});

function shutdown(sig) {
  logLine({ t: nowStr(), ev: 'stop', signal: sig });
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('uncaughtException', (e) => {
  logLine({ t: nowStr(), ev: 'crash', msg: String(e && e.message || e), stack: String(e && e.stack || '') });
  console.error('网关异常：' + (e && e.message));
});

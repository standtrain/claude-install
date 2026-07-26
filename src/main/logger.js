/**
 * 日志中枢：控制台 + 本地文件 + 通过 webContents 推送到渲染进程。
 * 敏感信息脱敏：长 Token、URL 凭据及常见敏感查询参数均不落盘。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');

const LONG_OPAQUE_VALUE_RE = /[A-Za-z0-9]{40,}/g;
const AUTHORIZATION_RE = /(["']?\b(?:proxy-)?authorization\b["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|(?:(?:bearer|basic)\s+)?[^\s,;]+)/gi;
const BEARER_RE = /(\bbearer\s+)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[A-Za-z0-9._~+\/=\-]+)/gi;
const COOKIE_RE = /(["']?\b(?:set-cookie|cookie)\b["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\r\n]*)/gi;
const SENSITIVE_ASSIGNMENT_RE = /(["']?\b(?:(?:[a-z0-9]+[_-])*(?:password|passwd|pwd|secret|client[_-]?secret|consumer[_-]?secret|(?:access|refresh|id|auth|session|bearer)[_-]?token|token|api[_-]?key|access[_-]?key|secret[_-]?key|private[_-]?key|signing[_-]?key|credentials?))\b["']?\s*[:=]\s*)(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;}\]]+)/gi;
const PRIVATE_IPV4_RE = /\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b/g;

class Logger {
  constructor() {
    this.win = null;
    const dir = path.join(process.env.LOCALAPPDATA || os.tmpdir(), 'ClaudeCLIInstaller');
    fs.mkdirSync(dir, { recursive: true });
    try { fs.chmodSync(dir, 0o700); } catch (_) {}
    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    this.logPath = path.join(dir, `install-${ts}.log`);
    this.stream = fs.createWriteStream(this.logPath, { flags: 'a', encoding: 'utf8', mode: 0o600 });
  }

  attach(win) {
    this.win = win;
  }

  sanitize(text) {
    const value = typeof text === 'string' ? text : String(text);
    return value
      .replace(COOKIE_RE, '$1***')
      .replace(AUTHORIZATION_RE, '$1***')
      .replace(SENSITIVE_ASSIGNMENT_RE, '$1***')
      .replace(BEARER_RE, '$1***')
      .replace(LONG_OPAQUE_VALUE_RE, '***')
      .replace(/(https?:\/\/)[^\s/@:]+:[^\s/@]+@/gi, '$1***@')
      .replace(PRIVATE_IPV4_RE, '[private-ip]');
  }

  emit(level, text) {
    const clean = this.sanitize(text);
    const line = `[${new Date().toISOString()}] [${level.toUpperCase()}] ${clean}`;
    // eslint-disable-next-line no-console
    console.log(line);
    this.stream.write(line + os.EOL);
    if (this.win && !this.win.isDestroyed()) {
      this.win.webContents.send('log', { level, text: clean, ts: Date.now() });
    }
  }

  info(t) { this.emit('info', t); }
  ok(t) { this.emit('ok', t); }
  warn(t) { this.emit('warn', t); }
  err(t) { this.emit('err', t); }
  cmd(t) { this.emit('cmd', t); }
  step(t) { this.emit('step', t); }

  progress(step, percent, detail) {
    if (this.win && !this.win.isDestroyed()) {
      const cleanDetail = typeof detail === 'string' ? this.sanitize(detail).slice(0, 1024) : '';
      this.win.webContents.send('progress', { step, percent, detail: cleanDetail, ts: Date.now() });
    }
  }

  setStep(id, status, extra) {
    if (this.win && !this.win.isDestroyed()) {
      const safeExtra = extra && typeof extra.message === 'string'
        ? { message: this.sanitize(extra.message).slice(0, 1024) }
        : undefined;
      this.win.webContents.send('step', { id, status, extra: safeExtra, ts: Date.now() });
    }
  }
}

module.exports = new Logger();

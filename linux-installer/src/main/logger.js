/**
 * 日志中枢：控制台 + 本地文件 + 通过 webContents 推送到渲染进程。
 * Linux 日志存放于 $XDG_CACHE_HOME/ClaudeCLIInstaller/ 或 /tmp/ClaudeCLIInstaller/。
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
    const xdgCache = process.platform === 'win32'
      ? os.tmpdir()
      : process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache');
    const directoryName = process.platform === 'win32'
      ? 'ClaudeCLIInstallerLinuxTest'
      : 'ClaudeCLIInstaller';
    const dir = fs.existsSync(xdgCache)
      ? path.join(xdgCache, directoryName)
      : path.join(os.tmpdir(), directoryName);
    fs.mkdirSync(dir, { recursive: true });
    if (process.platform !== 'win32') fs.chmodSync(dir, 0o700);
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

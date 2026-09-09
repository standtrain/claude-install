/**
 * 下载器：校验每一跳 URL、限制响应体、原子落盘并支持取消。
 */
const https = require('https');
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { URL } = require('url');
const env = require('../env');

const MAX_URL_LENGTH = 2048;
const MAX_REDIRECTS = 8;
const MAX_PROBE_BYTES = 128 * 1024;
const MAX_JSON_BYTES = 1024 * 1024;
const DEFAULT_MAX_DOWNLOAD_BYTES = 1024 * 1024 * 1024;

function parseAllowedUrl(value) {
  if (typeof value !== 'string' || value.length === 0 || value.length > MAX_URL_LENGTH) return null;

  let parsed;
  try {
    parsed = new URL(value);
  } catch (_) {
    return null;
  }

  const hostname = parsed.hostname.toLowerCase();
  const isLoopback = hostname === '127.0.0.1' || hostname === '::1';
  if (parsed.protocol !== 'https:' && !(parsed.protocol === 'http:' && isLoopback)) return null;
  if (parsed.username || parsed.password) return null;

  const host = (parsed.port ? `${hostname}:${parsed.port}` : hostname);
  const allowed = env.URL_WHITELIST.some((entry) => host === String(entry).toLowerCase());

  return allowed ? parsed : null;
}

function isAllowed(value) {
  return parseAllowedUrl(value) !== null;
}

function requireAllowedUrl(value) {
  const parsed = parseAllowedUrl(value);
  if (!parsed) throw new Error('URL 协议、长度或主机不在允许范围内');
  return parsed;
}

function clientFor(parsed) {
  return parsed.protocol === 'https:' ? https : http;
}

function redirectUrl(location, currentUrl) {
  if (typeof location !== 'string' || location.length === 0 || location.length > MAX_URL_LENGTH) {
    throw new Error('重定向地址无效');
  }
  return requireAllowedUrl(new URL(location, currentUrl).href).href;
}

function validTimeout(value, fallback) {
  return Number.isInteger(value) && value >= 1000 && value <= 300000 ? value : fallback;
}

function head(url, timeoutMs, redirects, startedAt, signal) {
  const timeout = validTimeout(timeoutMs, env.DOWNLOAD_TIMEOUT_MS);
  const redirectCount = redirects || 0;
  const start = startedAt || Date.now();

  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = requireAllowedUrl(url);
    } catch (error) {
      reject(error);
      return;
    }

    let settled = false;
    let currentRes = null;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      removeAbortListener();
      if (error) reject(error);
      else resolve(result);
    };
    // 用户取消：立即销毁在途响应与请求，让测速快速中止而不是等超时。
    const onAbort = () => {
      try { if (currentRes) currentRes.destroy(); } catch (_) { /* 忽略 */ }
      try { req.destroy(); } catch (_) { /* 忽略 */ }
      finish(new Error('用户已取消下载'));
    };
    const removeAbortListener = () => {
      if (signal && typeof signal.removeEventListener === 'function') {
        try { signal.removeEventListener('abort', onAbort); } catch (_) { /* 忽略 */ }
      }
    };
    if (signal) {
      if (signal.aborted) {
        reject(new Error('用户已取消下载'));
        return;
      }
      if (typeof signal.addEventListener === 'function') {
        signal.addEventListener('abort', onAbort, { once: true });
      }
    }

    const req = clientFor(parsed).request(parsed, {
      method: 'GET',
      headers: {
        Range: `bytes=0-${MAX_PROBE_BYTES - 1}`,
        'User-Agent': 'ClaudeCLIInstaller',
      },
    }, (res) => {
      currentRes = res;
      if ([301, 302, 303, 307, 308].indexOf(res.statusCode) !== -1 && res.headers.location) {
        res.resume();
        if (redirectCount >= MAX_REDIRECTS) {
          finish(new Error('重定向次数超过限制'));
          return;
        }
        let next;
        try {
          next = redirectUrl(res.headers.location, parsed);
        } catch (error) {
          finish(error);
          return;
        }
        head(next, timeout, redirectCount + 1, start, signal).then(
          (result) => finish(null, result),
          finish,
        );
        return;
      }

      if (res.statusCode !== 200 && res.statusCode !== 206) {
        res.resume();
        finish(new Error(`测速请求返回 HTTP ${res.statusCode}`));
        return;
      }

      let bytes = 0;
      res.on('data', (chunk) => {
        bytes += chunk.length;
        if (bytes >= MAX_PROBE_BYTES) {
          finish(null, { url: parsed.href, ms: Date.now() - start, bytes });
          res.destroy();
        }
      });
      res.on('end', () => finish(null, { url: parsed.href, ms: Date.now() - start, bytes }));
      res.on('error', finish);
    });
    req.on('error', finish);
    req.setTimeout(timeout, () => req.destroy(new Error('测速超时')));
    req.end();
  });
}

async function speedTest(sources, signal) {
  if (!Array.isArray(sources) || sources.length > 20) {
    throw new Error('下载源列表无效或数量超过限制');
  }
  if (signal && signal.aborted) throw new Error('用户已取消下载');

  const results = await Promise.all(sources.map(async (source) => {
    if (!source || typeof source.id !== 'string' || source.id.length > 80 || !isAllowed(source.url)) {
      return Object.assign({}, source, { ok: false, ms: Infinity, error: '下载源格式无效' });
    }
    try {
      const result = await head(source.url, undefined, undefined, undefined, signal);
      return Object.assign({}, source, { ok: true, ms: result.ms, bytes: result.bytes });
    } catch (error) {
      // 已取消时直接上抛，令 Promise.all 立刻失败，不再等待其余慢源。
      if (signal && signal.aborted) throw new Error('用户已取消下载');
      return Object.assign({}, source, {
        ok: false,
        ms: Infinity,
        error: String(error && error.message ? error.message : error),
      });
    }
  }));

  return results.sort((left, right) => left.ms - right.ms);
}

function readJson(url, options) {
  const settings = options || {};
  const timeout = validTimeout(settings.timeoutMs, env.DOWNLOAD_TIMEOUT_MS);
  const maxBytes = Number.isInteger(settings.maxBytes) && settings.maxBytes > 0
    ? Math.min(settings.maxBytes, MAX_JSON_BYTES)
    : MAX_JSON_BYTES;

  function requestJson(currentUrl, redirects) {
    return new Promise((resolve, reject) => {
      let parsed;
      try {
        parsed = requireAllowedUrl(currentUrl);
      } catch (error) {
        reject(error);
        return;
      }

      const req = clientFor(parsed).get(parsed, {
        headers: {
          Accept: 'application/vnd.github+json, application/json',
          'User-Agent': 'ClaudeCLIInstaller',
        },
      }, (res) => {
        if ([301, 302, 303, 307, 308].indexOf(res.statusCode) !== -1 && res.headers.location) {
          res.resume();
          if (redirects >= MAX_REDIRECTS) {
            reject(new Error('重定向次数超过限制'));
            return;
          }
          try {
            requestJson(redirectUrl(res.headers.location, parsed), redirects + 1).then(resolve, reject);
          } catch (error) {
            reject(error);
          }
          return;
        }

        if (res.statusCode !== 200) {
          res.resume();
          reject(new Error(`JSON 请求返回 HTTP ${res.statusCode}`));
          return;
        }

        const declared = Number(res.headers['content-length'] || 0);
        if (declared > maxBytes) {
          res.destroy();
          reject(new Error('JSON 响应超过大小限制'));
          return;
        }

        let bytes = 0;
        let raw = '';
        res.setEncoding('utf8');
        res.on('data', (chunk) => {
          bytes += Buffer.byteLength(chunk, 'utf8');
          if (bytes > maxBytes) {
            res.destroy(new Error('JSON 响应超过大小限制'));
            return;
          }
          raw += chunk;
        });
        res.on('error', reject);
        res.on('end', () => {
          try {
            resolve(JSON.parse(raw));
          } catch (_) {
            reject(new Error('JSON 响应格式无效'));
          }
        });
      });
      req.on('error', reject);
      req.setTimeout(timeout, () => req.destroy(new Error('JSON 请求超时')));
    });
  }

  return requestJson(url, 0);
}

function download(url, dest, onProgress, signal, options) {
  const settings = options || {};
  const maxBytes = Number.isInteger(settings.maxBytes) && settings.maxBytes > 0
    ? Math.min(settings.maxBytes, DEFAULT_MAX_DOWNLOAD_BYTES)
    : DEFAULT_MAX_DOWNLOAD_BYTES;
  const timeout = validTimeout(settings.timeoutMs, 60000);

  return new Promise((resolve, reject) => {
    let initial;
    try {
      initial = requireAllowedUrl(url);
      if (typeof dest !== 'string' || dest.length === 0 || dest.length > 32767) {
        throw new Error('下载目标路径无效');
      }
    } catch (error) {
      reject(error);
      return;
    }

    fs.mkdirSync(path.dirname(dest), { recursive: true });
    const part = `${dest}.part-${process.pid}-${Date.now()}`;
    let currentReq = null;
    let currentRes = null;
    let file = null;
    let settled = false;
    let received = 0;

    const removePart = () => {
      try { fs.unlinkSync(part); } catch (_) {}
    };
    const removeAbortListener = () => {
      if (signal && typeof signal.removeEventListener === 'function') {
        signal.removeEventListener('abort', abort);
      }
    };
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      removeAbortListener();
      if (error) {
        try { if (currentRes) currentRes.destroy(); } catch (_) {}
        try { if (currentReq) currentReq.destroy(); } catch (_) {}
        try { if (file) file.destroy(); } catch (_) {}
        removePart();
        reject(error);
      } else {
        resolve(result);
      }
    };
    const abort = () => finish(new Error('用户已取消下载'));

    if (signal) {
      if (signal.aborted) {
        abort();
        return;
      }
      if (typeof signal.addEventListener === 'function') {
        signal.addEventListener('abort', abort, { once: true });
      }
    }

    const requestFile = (currentUrl, redirects) => {
      let parsed;
      try {
        parsed = requireAllowedUrl(currentUrl);
      } catch (error) {
        finish(error);
        return;
      }

      const req = clientFor(parsed).get(parsed, {
        headers: { 'User-Agent': 'ClaudeCLIInstaller' },
      }, (res) => {
        currentRes = res;
        if ([301, 302, 303, 307, 308].indexOf(res.statusCode) !== -1 && res.headers.location) {
          res.resume();
          if (redirects >= MAX_REDIRECTS) {
            finish(new Error('重定向次数超过限制'));
            return;
          }
          try {
            requestFile(redirectUrl(res.headers.location, parsed), redirects + 1);
          } catch (error) {
            finish(error);
          }
          return;
        }

        if (res.statusCode !== 200) {
          res.resume();
          finish(new Error(`下载请求返回 HTTP ${res.statusCode}`));
          return;
        }

        const total = Number(res.headers['content-length'] || 0);
        if (total > maxBytes) {
          finish(new Error('下载文件超过大小限制'));
          return;
        }

        try {
          file = fs.createWriteStream(part, { flags: 'wx', mode: 0o600 });
        } catch (error) {
          finish(error);
          return;
        }

        res.on('data', (chunk) => {
          received += chunk.length;
          if (received > maxBytes) {
            finish(new Error('下载文件超过大小限制'));
            return;
          }
          if (onProgress) {
            const percent = total ? Math.min(100, Math.floor(received / total * 100)) : 0;
            onProgress({ loaded: received, total, percent });
          }
        });
        res.on('aborted', () => finish(new Error('下载连接意外中断')));
        res.on('error', finish);
        file.on('error', finish);
        file.on('finish', () => {
          file.close(() => {
            try {
              if (fs.existsSync(dest)) fs.unlinkSync(dest);
              fs.renameSync(part, dest);
              finish(null, { path: dest, bytes: received });
            } catch (error) {
              finish(error);
            }
          });
        });
        res.pipe(file);
      });
      currentReq = req;
      req.on('error', (error) => finish(error));
      req.setTimeout(timeout, () => req.destroy(new Error('下载连接超时')));
    };

    requestFile(initial.href, 0);
  });
}

function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(hash.digest('hex').toLowerCase()));
  });
}

function createAbortController() {
  const listeners = [];
  const signal = {
    aborted: false,
    addEventListener: (event, listener) => {
      if (event === 'abort' && typeof listener === 'function' && listeners.indexOf(listener) === -1) {
        listeners.push(listener);
      }
    },
    removeEventListener: (event, listener) => {
      if (event !== 'abort') return;
      const index = listeners.indexOf(listener);
      if (index !== -1) listeners.splice(index, 1);
    },
  };

  return {
    signal,
    abort: () => {
      if (signal.aborted) return;
      signal.aborted = true;
      const pending = listeners.splice(0, listeners.length);
      pending.forEach((listener) => {
        try { listener(); } catch (_) {}
      });
    },
  };
}

module.exports = {
  createAbortController,
  download,
  isAllowed,
  readJson,
  sha256File,
  speedTest,
};

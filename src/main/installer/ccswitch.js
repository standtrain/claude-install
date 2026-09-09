/**
 * CC Switch Windows 安装：可信多源下载、SHA256 校验、静默安装。
 */
const fs = require('fs');
const { spawn } = require('child_process');
const env = require('../env');
const logger = require('../logger');
const { download, isAllowed, sha256File, speedTest } = require('./downloader');
const { assertPrivateFile, cleanupTaskTempDir, createTaskTempDir, taskFile } = require('./privateTemp');
const { EXECUTABLES, systemOptions } = require('./windowsSystem');

const MIN_MSI_BYTES = 1024 * 1024;
const MAX_MSI_BYTES = 256 * 1024 * 1024;

function addSourceWithProxies(target, seen, source) {
  const add = (entry) => {
    if (!entry || seen.has(entry.url) || !isAllowed(entry.url)) return;
    if (!/^[a-f0-9]{64}$/i.test(entry.sha256 || '')) return;
    seen.add(entry.url);
    target.push(entry);
  };
  add(source);
  (env.CCSWITCH.ghMirrorProxies || []).forEach((proxy, index) => {
    if (!proxy || typeof proxy.name !== 'string' || proxy.name.length > 80
        || typeof proxy.url !== 'string' || proxy.url.length > 256) return;
    const url = `${proxy.url}${source.url}`;
    add(Object.assign({}, source, {
      id: `${source.id}-mirror-${index + 1}`,
      name: `${source.name} · ${proxy.name}`,
      url,
    }));
  });
}

async function buildSources() {
  const sources = [];
  const seen = new Set();
  const pinned = env.CCSWITCH.pinned;
  if (!pinned || !Number.isSafeInteger(pinned.size)
      || pinned.size < MIN_MSI_BYTES || pinned.size > MAX_MSI_BYTES
      || !/^[a-f0-9]{64}$/i.test(pinned.sha256 || '') || !isAllowed(pinned.url)) {
    throw new Error('CC Switch 固定版本元数据无效');
  }
  addSourceWithProxies(sources, seen, {
    id: 'github-pinned',
    name: `GitHub 固定版本 ${pinned.version}`,
    url: pinned.url,
    version: pinned.version,
    size: pinned.size,
    sha256: pinned.sha256,
  });
  return sources;
}

function runMsi(dest, controller) {
  if (controller) controller.checkCancel();
  return new Promise((resolve, reject) => {
    const proc = spawn(EXECUTABLES.msiexec, ['/i', dest, '/qn', '/norestart'], systemOptions());
    // 注册到取消控制器：取消时由控制器 taskkill /T /F 递归结束 msiexec。
    if (controller) controller.registerChild(proc);
    let settled = false;
    const finish = (error, code) => {
      if (settled) return;
      settled = true;
      if (controller) controller.clearChild();
      if (controller && controller.cancelled) {
        reject(new Error('用户已取消安装'));
      } else if (error) {
        reject(error);
      } else if (code === 0 || code === 3010) {
        if (code === 3010) logger.warn('MSI 提示建议重启（3010）');
        resolve();
      } else {
        reject(new Error(`msiexec 退出码 ${code}`));
      }
    };
    proc.once('error', (error) => finish(error));
    proc.once('exit', (code) => finish(null, code));
  });
}

async function install(onProgress, controller) {
  const signal = controller && controller.abortController ? controller.abortController.signal : undefined;
  const throwIfCancelled = () => { if (controller) controller.checkCancel(); };

  logger.step('准备安装 CC Switch（Claude Code 供应商切换工具）');
  throwIfCancelled();
  const sources = await buildSources();
  if (sources.length === 0) throw new Error('无可用且可校验的 CC Switch 下载源');

  logger.info('CC Switch 下载源测速…');
  const ranked = await speedTest(sources, signal);
  throwIfCancelled();
  ranked.forEach((source) => {
    logger.info(`  · ${source.id}  ${source.ok ? `${source.ms}ms` : `失败：${source.error}`}`);
  });
  const usable = ranked.filter((source) => source.ok);
  if (usable.length === 0) throw new Error('所有 CC Switch 下载源均不可达');

  const tempDir = createTaskTempDir('ccswitch');
  const dest = taskFile(tempDir, 'CC-Switch.msi');
  let selected = null;
  try {
    let lastError = null;
    for (const source of usable) {
      throwIfCancelled();
      try {
        logger.info(`开始下载 CC Switch（${source.name}）`);
        await download(source.url, dest, (progress) => {
          logger.progress('ccswitch', progress.percent,
            `${(progress.loaded / 1048576).toFixed(1)} / ${(progress.total / 1048576).toFixed(1)} MB`);
          if (typeof onProgress === 'function') onProgress(progress);
        }, signal, { maxBytes: MAX_MSI_BYTES, timeoutMs: 300000 });
        assertPrivateFile(tempDir, dest);

        const size = fs.statSync(dest).size;
        if (size !== source.size) throw new Error(`文件大小校验失败：期望 ${source.size}，实际 ${size}`);
        const actual = await sha256File(dest);
        if (actual !== source.sha256.toLowerCase()) throw new Error('SHA256 校验失败');
        logger.ok(`CC Switch 下载与 SHA256 校验完成（${(size / 1048576).toFixed(1)} MB）`);
        selected = source;
        break;
      } catch (error) {
        // 用户取消时立即停止，不再尝试下一个下载源。
        if (controller && controller.cancelled) throw new Error('用户已取消安装');
        lastError = error;
        try { fs.unlinkSync(dest); } catch (_) {}
        logger.warn(`该源下载或校验失败：${error.message}，尝试下一个`);
      }
    }
    throwIfCancelled();
    if (!selected) throw lastError || new Error('CC Switch 下载失败');
    logger.step(`静默安装 CC Switch ${selected.version}…`);
    await runMsi(dest, controller);
    logger.ok('CC Switch 安装完成');
  } finally {
    if (controller) controller.clearChild();
    cleanupTaskTempDir(tempDir, [dest]);
  }
}

module.exports = { buildSources, install };

/**
 * Git Bash 静默安装：多源测速 → 下载 → /VERYSILENT 安装。
 */
const fs = require('fs');
const { spawn } = require('child_process');
const { speedTest, download, sha256File } = require('./downloader');
const { fileExists } = require('./detect');
const env = require('../env');
const logger = require('../logger');
const { assertPrivateFile, cleanupTaskTempDir, createTaskTempDir, taskFile } = require('./privateTemp');
const { systemOptions } = require('./windowsSystem');

function isInstalled() {
  return fileExists('C:\\Program Files\\Git\\cmd\\git.exe')
      || fileExists('C:\\Program Files (x86)\\Git\\cmd\\git.exe');
}

async function install(onProgress, installer) {
  if (isInstalled()) {
    logger.ok('检测到 Git 已安装，跳过');
    return { skipped: true };
  }

  logger.info('对 Git 下载源进行测速…');
  const ranked = await speedTest(env.GIT_MIRRORS);
  ranked.forEach(r => logger.info(`  · ${r.name}  ${r.ok ? r.ms + 'ms' : '失败：' + r.error}`));

  const usable = ranked.filter(r => r.ok);
  if (usable.length === 0) {
    throw new Error('所有 Git 镜像源均不可达');
  }

  const signal = installer && installer.abortController ? installer.abortController.signal : undefined;
  const tempDir = createTaskTempDir('git');
  const dest = taskFile(tempDir, 'Git-Setup.exe');
  try {
    let ok = false;
    let lastErr;
    for (const src of usable) {
      if (installer && installer.cancelled) throw new Error('用户已取消安装');
      try {
        if (!Number.isSafeInteger(src.size) || !/^[a-f0-9]{64}$/i.test(src.sha256 || '')) {
          throw new Error('镜像缺少可信大小或 SHA256');
        }
        logger.info(`开始下载 Git 安装包（来源：${src.name}）`);
        await download(src.url, dest, (p) => {
          if (onProgress) onProgress(p);
        }, signal, { maxBytes: 128 * 1024 * 1024, timeoutMs: 300000 });
        assertPrivateFile(tempDir, dest);
        const size = fs.statSync(dest).size;
        if (size !== src.size) throw new Error(`文件大小校验失败：期望 ${src.size}，实际 ${size}`);
        const fd = fs.openSync(dest, 'r');
        try {
          const magic = Buffer.alloc(2);
          if (fs.readSync(fd, magic, 0, 2, 0) !== 2 || magic.toString('ascii') !== 'MZ') {
            throw new Error('下载内容不是有效 Windows 可执行文件');
          }
        } finally {
          fs.closeSync(fd);
        }
        const actual = await sha256File(dest);
        if (actual !== src.sha256.toLowerCase()) throw new Error('SHA256 校验失败');
        logger.ok(`Git 安装包大小、文件头和 SHA256 校验通过（${(size / 1048576).toFixed(1)} MB）`);
        ok = true;
        break;
      } catch (e) {
        lastErr = e;
        try { fs.unlinkSync(dest); } catch (_) {}
        if (installer && installer.cancelled) throw e;
        logger.warn(`该源下载或校验失败：${e.message}，尝试下一个`);
      }
    }
    if (!ok) throw lastErr || new Error('Git 安装包下载失败');
    if (installer && installer.cancelled) throw new Error('用户已取消安装');

    logger.step('静默安装 Git for Windows…');
    await new Promise((resolve, reject) => {
      const proc = spawn(dest, env.GIT_SETUP_ARGS, systemOptions());
      if (installer) installer.registerChild(proc);
      let settled = false;
      const finish = (error, code) => {
        if (settled) return;
        settled = true;
        if (installer) installer.clearChild();
        if (installer && installer.cancelled) return reject(new Error('用户已取消安装'));
        if (error) return reject(error);
        if (code === 0) resolve();
        else reject(new Error(`Git 安装器退出码 ${code}`));
      };
      proc.once('error', (error) => finish(error));
      proc.once('close', (code) => finish(null, code));
    });

    if (!isInstalled()) throw new Error('Git 安装完成后未检测到 git.exe');
    logger.ok('Git for Windows 安装完成');
    return { skipped: false };
  } finally {
    cleanupTaskTempDir(tempDir, [dest]);
  }
}

module.exports = { install, isInstalled };

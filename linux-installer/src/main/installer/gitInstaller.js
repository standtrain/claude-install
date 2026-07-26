/**
 * Install Git through a fixed, root-owned package manager with one pkexec
 * authorization. No renderer value reaches the command or its arguments.
 */
const { spawn, execFile } = require('child_process');
const env = require('../env');
const logger = require('../logger');
const {
  cleanRootEnvironment,
  createRootCommand,
  findTrustedExecutable,
} = require('./privilege');

const MAX_LOG_FRAGMENT = 8192;
const GIT_EXECUTABLES = ['/usr/bin/git', '/bin/git', '/usr/local/bin/git'];

function isInstalled() {
  const executable = findTrustedExecutable(GIT_EXECUTABLES);
  if (!executable) return Promise.resolve(false);
  return new Promise((resolve) => {
    execFile(executable, ['--version'], {
      env: cleanRootEnvironment(),
      timeout: 5000,
      maxBuffer: 4096,
    }, (error) => resolve(!error));
  });
}

function forwardOutput(stream, level) {
  let pending = '';
  stream.setEncoding('utf8');
  stream.on('data', (chunk) => {
    pending += chunk;
    let newline;
    while ((newline = pending.indexOf('\n')) !== -1) {
      const line = pending.slice(0, newline).replace(/\r$/, '');
      pending = pending.slice(newline + 1);
      if (line.trim()) logger.emit(level, line.slice(0, MAX_LOG_FRAGMENT));
    }
    if (pending.length > MAX_LOG_FRAGMENT) {
      logger.emit(level, `${pending.slice(0, MAX_LOG_FRAGMENT)} [输出已截断]`);
      pending = '';
    }
  });
  return () => {
    if (pending.trim()) logger.emit(level, pending.slice(0, MAX_LOG_FRAGMENT));
  };
}

function installWithPackageManager(entry, installer) {
  const executable = findTrustedExecutable(entry.executable);
  if (!executable || !Array.isArray(entry.args)
      || entry.args.some((arg) => typeof arg !== 'string' || arg.length > 64
        || /[\u0000-\u001f\u007f]/.test(arg))) {
    return Promise.reject(new Error('包管理器配置无效'));
  }
  const command = createRootCommand(executable, entry.args, {
    DEBIAN_FRONTEND: 'noninteractive',
  });

  logger.cmd(`${command.elevated ? 'pkexec ' : ''}${executable} ${entry.args.join(' ')}`);
  return new Promise((resolve, reject) => {
    const proc = spawn(command.executable, command.args, {
      cwd: '/',
      detached: true,
      shell: false,
      env: command.env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    if (installer) installer.registerChild(proc);
    const flushStdout = forwardOutput(proc.stdout, 'info');
    const flushStderr = forwardOutput(proc.stderr, 'warn');
    let settled = false;
    const finish = (error, code) => {
      if (settled) return;
      settled = true;
      if (installer) installer.clearChild();
      flushStdout();
      flushStderr();
      if (installer && installer.cancelled) reject(new Error('用户已取消安装'));
      else if (error) reject(error);
      else if (code === 0) resolve();
      else reject(new Error(`${entry.name} 退出码 ${code}`));
    };
    proc.once('error', (error) => finish(error));
    proc.once('close', (code) => finish(null, code));
  });
}

async function install(onProgress, installer) {
  if (await isInstalled()) {
    logger.ok('检测到 Git 已安装，跳过');
    return { skipped: true };
  }

  logger.info('系统未检测到 Git，将通过包管理器安装…');
  for (const entry of env.GIT_PACKAGES) {
    if (installer && installer.cancelled) throw new Error('用户已取消安装');
    if (!findTrustedExecutable(entry.executable)) continue;
    try {
      logger.info(`使用 ${entry.name} 安装 Git…`);
      await installWithPackageManager(entry, installer);
      if (await isInstalled()) {
        if (onProgress) onProgress({ percent: 100, detail: `${entry.name} 安装完成` });
        logger.ok(`Git 通过 ${entry.name} 安装完成`);
        return { skipped: false };
      }
    } catch (error) {
      logger.warn(`${entry.name} 安装 Git 失败：${error.message || String(error)}`);
    }
  }

  throw new Error('无法自动安装 Git，请先通过系统包管理器安装后重试');
}

module.exports = { install, installWithPackageManager, isInstalled };

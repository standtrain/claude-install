const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { app } = require('electron');
const logger = require('../logger');
const { createRootCommand, trustedExecutable } = require('./privilege');

const MAX_SCRIPT_BYTES = 2 * 1024 * 1024;
const MAX_LOG_FRAGMENT = 8192;
const SCRIPT_PATH_PATTERN = /^deploy\/(?:cc-custom|ccswitch)\.sh$/;

function resolveScriptPath(metadata) {
  if (!metadata || !SCRIPT_PATH_PATTERN.test(metadata.relativePath || '')) {
    throw new Error('内置安装脚本元数据无效');
  }
  const appRoot = app.getAppPath();
  const candidates = app.isPackaged
    ? [path.join(process.resourcesPath, metadata.relativePath)]
    : [
      path.join(appRoot, metadata.relativePath),
      path.resolve(appRoot, '..', metadata.relativePath),
    ];
  const scriptPath = candidates.find((candidate) => fs.existsSync(candidate));
  if (scriptPath) return scriptPath;
  throw new Error('内置安装脚本不存在');
}

function readVerifiedScript(metadata) {
  if (!/^[a-f0-9]{64}$/.test(metadata && metadata.sha256 || '')) {
    throw new Error('内置安装脚本缺少可信 SHA256');
  }
  const filePath = resolveScriptPath(metadata);
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 || stat.size > MAX_SCRIPT_BYTES) {
    throw new Error('内置安装脚本文件无效');
  }
  const content = fs.readFileSync(filePath);
  const actual = crypto.createHash('sha256').update(content).digest('hex');
  if (actual !== metadata.sha256) throw new Error('内置安装脚本 SHA256 校验失败');
  return content;
}

function targetUserEnvironment() {
  const result = {};
  const sudoUser = process.env.SUDO_USER;
  const pkexecUid = process.env.PKEXEC_UID;
  if (typeof sudoUser === 'string' && /^[a-z_][a-z0-9_-]{0,31}\$?$/i.test(sudoUser)) {
    result.SUDO_USER = sudoUser;
  }
  if (typeof pkexecUid === 'string' && /^\d{1,10}$/.test(pkexecUid)) {
    result.PKEXEC_UID = pkexecUid;
  }
  return result;
}

function rootCommand() {
  const bash = trustedExecutable(['/bin/bash', '/usr/bin/bash'], 'bash');
  return createRootCommand(bash, ['-s', '--'], targetUserEnvironment());
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

function executeAsRoot(content, label, installer) {
  const command = rootCommand();
  logger.cmd(`${label}：${command.elevated ? 'pkexec ' : ''}/bin/bash -s -- < <内置已校验脚本>`);
  return new Promise((resolve, reject) => {
    const proc = spawn(command.executable, command.args, {
      cwd: '/',
      detached: true,
      shell: false,
      env: command.env,
      stdio: ['pipe', 'pipe', 'pipe'],
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
      else reject(new Error(`${label}退出码 ${code}`));
    };
    proc.stdin.on('error', (error) => {
      if (!error || error.code !== 'EPIPE') finish(error);
    });
    proc.once('error', (error) => finish(error));
    proc.once('close', (code) => finish(null, code));
    proc.stdin.end(content);
  });
}

async function run(metadata, label, installer) {
  const content = readVerifiedScript(metadata);
  await executeAsRoot(content, label, installer);
}

module.exports = { readVerifiedScript, run };

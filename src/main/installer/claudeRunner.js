/**
 * 从安装包读取固定哈希的 PowerShell 脚本，并通过标准输入执行。
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { app } = require('electron');
const logger = require('../logger');

const MAX_SCRIPT_BYTES = 2 * 1024 * 1024;
const MAX_LOG_FRAGMENT = 8192;

function scriptPath(metadata) {
  if (!metadata || metadata.relativePath !== 'deploy/cc-custom.ps1') {
    throw new Error('内置安装脚本元数据无效');
  }
  const appRoot = app.getAppPath();
  const packagedPath = path.join(appRoot, metadata.relativePath);
  if (fs.existsSync(packagedPath)) return packagedPath;
  if (!app.isPackaged) {
    const developmentPath = path.resolve(appRoot, '..', metadata.relativePath);
    if (fs.existsSync(developmentPath)) return developmentPath;
  }
  throw new Error('内置安装脚本不存在');
}

function readVerifiedScript(metadata) {
  if (!/^[a-f0-9]{64}$/.test(metadata && metadata.sha256 || '')) {
    throw new Error('内置安装脚本缺少可信 SHA256');
  }
  const filePath = scriptPath(metadata);
  const stat = fs.lstatSync(filePath);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size <= 0 || stat.size > MAX_SCRIPT_BYTES) {
    throw new Error('内置安装脚本文件无效');
  }
  const content = fs.readFileSync(filePath);
  const actual = crypto.createHash('sha256').update(content).digest('hex');
  if (actual !== metadata.sha256) throw new Error('内置安装脚本 SHA256 校验失败');
  return content;
}

function windowsScriptEnvironment() {
  const userProfile = process.env.USERPROFILE;
  if (typeof userProfile !== 'string' || userProfile.length > 32767
      || !path.win32.isAbsolute(userProfile) || /[\u0000-\u001f\u007f]/.test(userProfile)) {
    throw new Error('USERPROFILE 路径无效');
  }
  const systemRoot = 'C:\\Windows';
  return {
    SystemRoot: systemRoot,
    WINDIR: systemRoot,
    COMSPEC: `${systemRoot}\\System32\\cmd.exe`,
    PATH: `${systemRoot}\\System32;${systemRoot};${systemRoot}\\System32\\WindowsPowerShell\\v1.0`,
    PATHEXT: '.COM;.EXE;.BAT;.CMD',
    PROGRAMDATA: 'C:\\ProgramData',
    USERPROFILE: userProfile,
    TEMP: `${systemRoot}\\Temp`,
    TMP: `${systemRoot}\\Temp`,
    PROCESSOR_ARCHITECTURE: process.arch === 'arm64' ? 'ARM64' : 'AMD64',
  };
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

function executeScript(content, installer) {
  const systemRoot = 'C:\\Windows';
  const powershell = `${systemRoot}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe`;
  const loader = [
    '[Console]::OutputEncoding=[Text.UTF8Encoding]::new();',
    '$stream=[Console]::OpenStandardInput();',
    '$memory=New-Object IO.MemoryStream;',
    '$stream.CopyTo($memory);',
    '$utf8=New-Object Text.UTF8Encoding($true,$true);',
    '$code=$utf8.GetString($memory.ToArray());',
    '&([ScriptBlock]::Create($code))',
  ].join('');
  const args = ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-Command', loader];
  logger.cmd('powershell -NoProfile -NonInteractive -Command <内置已校验脚本>');

  return new Promise((resolve, reject) => {
    const proc = spawn(powershell, args, {
      cwd: systemRoot,
      windowsHide: true,
      shell: false,
      env: windowsScriptEnvironment(),
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
      else reject(new Error(`Claude 安装脚本退出码 ${code}`));
    };
    proc.stdin.on('error', (error) => {
      if (!error || error.code !== 'EPIPE') finish(error);
    });
    proc.once('error', (error) => finish(error));
    proc.once('close', (code) => finish(null, code));
    proc.stdin.end(content);
  });
}

async function install(metadata, installer) {
  logger.step('执行安装包内置 Claude 安装脚本');
  const content = readVerifiedScript(metadata);
  await executeScript(content, installer);
}

module.exports = { install, readVerifiedScript };

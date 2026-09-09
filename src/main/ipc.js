/**
 * IPC 路由集中注册。所有高权限调用都只接受主窗口的主 frame。
 */
const { ipcMain, app } = require('electron');
const path = require('path');
const { execFile } = require('child_process');
const detect = require('./installer/detect');
const logger = require('./logger');
const env = require('./env');
const { systemOptions } = require('./installer/windowsSystem');

const hasOwn = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
const INSTALL_OPTION_KEYS = ['installGit'];

let installer = null;
let installTask = null;
let ccSwitchTask = null;
let ccSwitchController = null;
let ccSwitchInstalled = false;

function normalizeVersionOutput(value) {
  return String(value || '')
    .split(/\r?\n/, 1)[0]
    .replace(/[^\x20-\x7e]/g, '')
    .trim()
    .slice(0, 256);
}

function verifyClaudeVersion() {
  const executable = path.join(env.INSTALL_BIN_DIR, 'claude.exe');
  return new Promise((resolve) => {
    execFile(executable, ['--version'], systemOptions({
      timeout: 10000,
      maxBuffer: 4096,
    }), (error, stdout) => {
      const version = normalizeVersionOutput(stdout);
      if (error || !version) {
        logger.warn('Claude CLI 版本验证失败');
        resolve({ ok: false });
        return;
      }
      logger.ok(`Claude CLI 版本验证通过：${version}`);
      resolve({ ok: true, version });
    });
  });
}

function isPlainRecord(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function assertOnlyKeys(value, allowedKeys, label) {
  const invalidKey = Object.keys(value).find((key) => !allowedKeys.includes(key));
  if (invalidKey) throw new TypeError(`${label} 包含不支持的字段`);
}

function validateInstallerOptions(opts) {
  if (!isPlainRecord(opts)) throw new TypeError('安装选项必须是对象');
  assertOnlyKeys(opts, INSTALL_OPTION_KEYS, '安装选项');
  if (!hasOwn(opts, 'installGit') || typeof opts.installGit !== 'boolean') {
    throw new TypeError('installGit 必须是布尔值');
  }
  return { installGit: opts.installGit };
}

function assertTrustedSender(event, mainWindow) {
  // 安全校验点：高权限 IPC 仅接受受控窗口的主 frame。
  if (!event || !mainWindow || mainWindow.isDestroyed()) {
    throw new Error('拒绝无效窗口的 IPC 调用');
  }
  const webContents = mainWindow.webContents;
  if (webContents.isDestroyed()
    || event.sender !== webContents
    || event.senderFrame !== webContents.mainFrame
    || event.senderFrame.url !== webContents.getURL()) {
    logger.warn('已拒绝非主窗口主 frame 的 IPC 调用');
    throw new Error('拒绝未经授权的 IPC 调用');
  }
}

async function startInstall(mainWindow, rawOptions) {
  const options = validateInstallerOptions(rawOptions);
  if (installTask || ccSwitchTask) throw new Error('已有安装任务正在运行，请等待其完成');

  const Installer = require('./installer');
  const currentInstaller = new Installer(mainWindow, options);
  const currentTask = Promise.resolve().then(() => currentInstaller.run());
  installer = currentInstaller;
  installTask = currentTask;

  try {
    await currentTask;
    return { ok: true };
  } finally {
    if (installer === currentInstaller) installer = null;
    if (installTask === currentTask) installTask = null;
  }
}

async function installCCSwitch() {
  if (ccSwitchInstalled) return { ok: true, alreadyInstalled: true };
  if (ccSwitchTask) return ccSwitchTask;
  if (installTask) throw new Error('主安装任务正在运行，请等待其完成');

  const { createInstallController } = require('./installer/controller');
  const ccswitch = require('./installer/ccswitch');
  const controller = createInstallController();
  ccSwitchController = controller;
  const currentTask = Promise.resolve()
    .then(() => ccswitch.install(undefined, controller))
    .then(() => {
      ccSwitchInstalled = true;
      return { ok: true, alreadyInstalled: false, cancelled: false };
    })
    .catch((error) => {
      if (controller.cancelled) return { ok: false, cancelled: true };
      throw error;
    });
  ccSwitchTask = currentTask;

  try {
    return await currentTask;
  } finally {
    if (ccSwitchTask === currentTask) ccSwitchTask = null;
    if (ccSwitchController === controller) ccSwitchController = null;
  }
}

function register(mainWindow) {
  const handle = (channel, handler) => {
    ipcMain.handle(channel, async (event, ...args) => {
      assertTrustedSender(event, mainWindow);
      return handler(...args);
    });
  };

  // ── 通用 ──
  handle('app:quit', () => app.quit());
  handle('app:minimize', () => mainWindow.minimize());
  handle('app:about', () => {
    const pkg = require('../../package.json');
    const buildTime = pkg.buildTime || new Date().toISOString();
    return {
      name: pkg.description || pkg.name,
      version: pkg.version,
      buildTime,
      author: pkg.author,
      license: pkg.license,
    };
  });

  // ── 环境探测 ──
  handle('detect', () => detect.run());

  // ── 安装控制 ──
  handle('installer:start', (opts) => startInstall(mainWindow, opts));
  handle('installer:cancel', () => {
    // 同一时刻只可能有一个安装任务在跑；主安装与 CC Switch 任一活动都要能取消。
    let acted = false;
    if (installer) { installer.cancel(); acted = true; }
    if (ccSwitchController) { ccSwitchController.cancel(); acted = true; }
    return { ok: acted };
  });

  // ── 工具 ──
  handle('installer:verifyClaude', () => verifyClaudeVersion());

  handle('installer:installCCSwitch', () => installCCSwitch());
  handle('installer:openLogFile', () => {
    const { shell } = require('electron');
    shell.showItemInFolder(logger.logPath);
  });
}

module.exports = { register, validateInstallerOptions };

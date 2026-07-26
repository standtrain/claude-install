/**
 * 主进程入口：单例、窗口、UAC 检查、IPC 注册。
 */
const { app, BrowserWindow, dialog } = require('electron');
const path = require('path');
const { pathToFileURL } = require('url');
const logger = require('./logger');
const { isAdmin } = require('./installer/admin');
const { register: registerIPC } = require('./ipc');

let mainWindow = null;

function lockNavigation(window, rendererFile) {
  // 安全校验点：窗口只允许停留在打包内的唯一 renderer 页面。
  const trustedUrl = pathToFileURL(rendererFile).href;
  const blockUntrustedNavigation = (event, targetUrl) => {
    if (targetUrl !== trustedUrl) {
      event.preventDefault();
      logger.warn('已阻止渲染窗口跳转到非本地页面');
    }
  };

  window.webContents.on('will-navigate', blockUntrustedNavigation);
  window.webContents.on('will-redirect', blockUntrustedNavigation);
  window.webContents.on('will-attach-webview', (event) => event.preventDefault());
  window.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
}

function createWindow() {
  const rendererFile = path.join(__dirname, '..', 'renderer', 'index.html');
  mainWindow = new BrowserWindow({
    width: 980,
    height: 720,
    minWidth: 860,
    minHeight: 640,
    frame: false,
    transparent: false,
    resizable: true,
    backgroundColor: '#FAF9F5',
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
      webSecurity: true,
      allowRunningInsecureContent: false,
      webviewTag: false,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  lockNavigation(mainWindow, rendererFile);
  mainWindow.loadFile(rendererFile);
  logger.attach(mainWindow);

  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
  });

  registerIPC(mainWindow);
}

// 单例锁
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.focus();
    }
  });
}

app.whenReady().then(async () => {
  // 检查管理员权限
  const admin = await isAdmin();
  const devBypass = !app.isPackaged;
  if (!admin && !devBypass) {
    dialog.showErrorBox(
      '需要管理员权限',
      '安装器必须以管理员身份运行才能完成系统级配置。\n请右键 → 以管理员身份运行。',
    );
    app.quit();
    return;
  }
  if (!admin) {
    logger.warn('当前非管理员运行（开发模式）：写 HKLM / 安装 Git 等操作会失败');
  } else {
    logger.ok('进程以管理员权限启动');
  }
  createWindow();
});

app.on('window-all-closed', () => {
  app.quit();
});

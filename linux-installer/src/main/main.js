/**
 * 主进程入口：普通用户 GUI、Chromium 沙箱与 IPC 注册。
 */
const { app, BrowserWindow } = require('electron');
const path = require('path');
const { pathToFileURL } = require('url');
const logger = require('./logger');
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

app.whenReady().then(() => {
  logger.info('图形进程以普通用户运行；系统级步骤将通过 pkexec 单次授权');
  createWindow();
});

app.on('window-all-closed', () => {
  app.quit();
});

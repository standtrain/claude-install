/**
 * 预加载脚本：通过 contextBridge 暴露白名单 API 给渲染层。
 */
const { contextBridge, ipcRenderer } = require('electron');

const onceOnly = new Set();

function subscribeOnce(key, channel, callback) {
  if (typeof callback !== 'function') throw new TypeError('IPC 事件回调必须是函数');
  if (onceOnly.has(key)) return false;
  onceOnly.add(key);
  ipcRenderer.on(channel, (_event, data) => callback(data));
  return true;
}

contextBridge.exposeInMainWorld('installerAPI', {
  detect: () => ipcRenderer.invoke('detect'),
  startInstall: (opts) => ipcRenderer.invoke('installer:start', opts),
  cancel: () => ipcRenderer.invoke('installer:cancel'),
  verifyClaude: () => ipcRenderer.invoke('installer:verifyClaude'),
  installCCSwitch: () => ipcRenderer.invoke('installer:installCCSwitch'),
  openLogFile: () => ipcRenderer.invoke('installer:openLogFile'),
  quit: () => ipcRenderer.invoke('app:quit'),
  minimize: () => ipcRenderer.invoke('app:minimize'),
  about: () => ipcRenderer.invoke('app:about'),

  onLog: (callback) => subscribeOnce('log', 'log', callback),
  onProgress: (callback) => subscribeOnce('progress', 'progress', callback),
  onStep: (callback) => subscribeOnce('step', 'step', callback),
});

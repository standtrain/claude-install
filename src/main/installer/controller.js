/**
 * 安装任务取消控制器：与 Installer 类暴露的取消接口保持兼容
 * （abortController.signal / registerChild / clearChild / cancelled），
 * 供 CC Switch 这类独立安装任务复用——下载用 signal 中止，子进程用 taskkill 递归结束。
 */
const { execFile } = require('child_process');
const { createAbortController } = require('./downloader');
const { EXECUTABLES, systemOptions } = require('./windowsSystem');

function createInstallController() {
  const controller = {
    cancelled: false,
    abortController: createAbortController(),
    activeChild: null,
    registerChild(child) { this.activeChild = child; },
    clearChild() { this.activeChild = null; },
    checkCancel() {
      if (this.cancelled) throw new Error('用户已取消安装');
    },
    cancel() {
      if (this.cancelled) return;
      this.cancelled = true;
      try { this.abortController.abort(); } catch (_) { /* 忽略重复中止 */ }
      try {
        if (this.activeChild && !this.activeChild.killed) {
          // Windows 上纯 SIGTERM 对安装器子进程不总管用，用 taskkill /T /F 递归杀。
          const pid = this.activeChild.pid;
          try {
            execFile(EXECUTABLES.taskkill, ['/pid', String(pid), '/T', '/F'],
              systemOptions({ timeout: 10000, maxBuffer: 64 * 1024 }), () => {});
          } catch (_) { /* 忽略 taskkill 启动失败 */ }
          try { this.activeChild.kill('SIGTERM'); } catch (_) { /* 忽略 */ }
        }
      } catch (_) { /* 忽略取消清理异常 */ }
    },
  };
  return controller;
}

module.exports = { createInstallController };
